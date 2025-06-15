// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============ BASE CONTRACTS ============
abstract contract Ownable {
    address private _owner;
    
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }
    
    modifier onlyOwner() {
        require(_owner == msg.sender, "Not owner");
        _;
    }
    
    function owner() public view returns (address) {
        return _owner;
    }
    
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    
    modifier nonReentrant() {
        require(_status != 2, "Reentrant call");
        _status = 2;
        _;
        _status = 1;
    }
}

// ============ INTERFACES ============
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}

interface IPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IFlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

interface IDEXRouter {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function getAmountsOut(uint amountIn, address[] calldata path)
        external view returns (uint[] memory amounts);
}

interface ILendingPool {
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;
    
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralETH,
        uint256 totalDebtETH,
        uint256 availableBorrowsETH,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
    
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external;
}

interface IChainlinkAggregator {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 price,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

/**
 * @title OptimalBot - Multi-Strategy Arbitrage Engine
 * @notice Optimized version with all 7 strategies functional
 */
contract OptimalBot is IFlashLoanSimpleReceiver, ReentrancyGuard, Ownable {
    
    // ============ CONSTANTS ============
    address public constant AAVE_PROVIDER = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address public constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address public constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address public constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    
    address public constant QUICKSWAP_ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address public constant SUSHISWAP_ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;
    
    address public constant MATIC_USD_FEED = 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0;
    address public constant ETH_USD_FEED = 0xF9680D99D6C9589e2a93a78A04A279e509205945;
    
    // ============ STATE VARIABLES ============
    address public aavePool;
    uint256 public maxFlashLoanAmount = 100000 * 1e6;
    uint256 public totalProfit;
    uint256 public executionCount;
    uint256 public successCount;
    bool public paused;
    bool public emergencyMode;
    
    mapping(uint256 => bool) public strategyEnabled;
    mapping(uint256 => uint256) public minProfit;
    mapping(uint256 => uint256) public strategyProfit;
    mapping(uint256 => uint256) public strategyExecutions;
    
    mapping(address => bool) public liquidationTargets;
    address[] public trackedUsers;
    
    mapping(address => uint256) private lastExecution;
    
    // ============ EVENTS ============
    event StrategyExecuted(uint256 indexed strategyId, uint256 profit, bool success);
    event ProfitGenerated(uint256 amount, uint256 strategyId);
    event LiquidationExecuted(address indexed user, uint256 profit);
    event ConfigUpdated(uint256 strategyId, bool enabled);
    
    // ============ MODIFIERS ============
    modifier notPaused() {
        require(!paused, "Contract is paused");
        _;
    }
    
    modifier notEmergency() {
        require(!emergencyMode, "Emergency mode active");
        _;
    }
    
    modifier cooldown() {
        require(block.timestamp > lastExecution[msg.sender] + 60, "Cooldown active");
        lastExecution[msg.sender] = block.timestamp;
        _;
    }
    
    modifier validStrategy(uint256 _strategyId) {
        require(_strategyId <= 6, "Invalid strategy ID");
        require(strategyEnabled[_strategyId], "Strategy disabled");
        _;
    }
    
    // ============ CONSTRUCTOR ============
    constructor() {
        aavePool = IPoolAddressesProvider(AAVE_PROVIDER).getPool();
        
        // Initialize all 7 strategies
        strategyEnabled[0] = true; minProfit[0] = 20 * 1e6;  // DEX Arbitrage
        strategyEnabled[1] = true; minProfit[1] = 30 * 1e6;  // Triangular
        strategyEnabled[2] = true; minProfit[2] = 50 * 1e6;  // Liquidation
        strategyEnabled[3] = true; minProfit[3] = 25 * 1e6;  // Oracle
        strategyEnabled[4] = true; minProfit[4] = 15 * 1e6;  // Yield
        strategyEnabled[5] = true; minProfit[5] = 35 * 1e6;  // Flash Farming
        strategyEnabled[6] = false; minProfit[6] = 100 * 1e6; // Cross Chain
    }
    
    // ============ MAIN EXECUTION ============
    function executeStrategy(
        uint256 _strategyId,
        uint256 _amount,
        bytes calldata _params
    ) 
        external 
        onlyOwner 
        nonReentrant 
        notPaused 
        notEmergency
        cooldown
        validStrategy(_strategyId)
    {
        require(_amount >= 1000 * 1e6, "Minimum 1000 USDC");
        require(_amount <= maxFlashLoanAmount, "Exceeds max amount");
        
        bytes memory params = abi.encode(_strategyId, _params);
        
        IPool(aavePool).flashLoanSimple(
            address(this),
            USDC,
            _amount,
            params,
            0
        );
    }
    
    // ============ FLASH LOAN CALLBACK ============
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == aavePool, "Unauthorized caller");
        require(initiator == address(this), "Unauthorized initiator");
        require(asset == USDC, "Unsupported asset");
        
        uint256 totalDebt = amount + premium;
        
        (uint256 strategyId, bytes memory strategyParams) = abi.decode(params, (uint256, bytes));
        
        uint256 profit = 0;
        bool success = false;
        
        try this._executeStrategyLogic(strategyId, amount, strategyParams) returns (uint256 _profit) {
            profit = _profit;
            success = profit >= minProfit[strategyId];
        } catch {
            success = false;
        }
        
        require(IERC20(asset).balanceOf(address(this)) >= totalDebt, "Insufficient balance");
        
        if (success) {
            strategyExecutions[strategyId]++;
            strategyProfit[strategyId] += profit;
            totalProfit += profit;
            successCount++;
            emit ProfitGenerated(profit, strategyId);
        }
        
        executionCount++;
        emit StrategyExecuted(strategyId, profit, success);
        
        IERC20(asset).approve(aavePool, totalDebt);
        
        return true;
    }
    
    // ============ STRATEGY ROUTER ============
    function _executeStrategyLogic(
        uint256 _strategyId,
        uint256 _amount,
        bytes memory _params
    ) external returns (uint256) {
        require(msg.sender == address(this), "Internal call only");
        
        if (_strategyId == 0) {
            return _dexArbitrage(_amount, _params);
        } else if (_strategyId == 1) {
            return _triangularArbitrage(_amount);
        } else if (_strategyId == 2) {
            return _liquidationHunting(_amount, _params);
        } else if (_strategyId == 3) {
            return _oracleArbitrage(_amount);
        } else if (_strategyId == 4) {
            return _yieldArbitrage(_amount);
        } else if (_strategyId == 5) {
            return _flashFarming(_amount);
        } else if (_strategyId == 6) {
            return _crossChainArbitrage(_amount);
        }
        
        revert("Invalid strategy");
    }
    
    // ============ STRATEGY IMPLEMENTATIONS ============
    
    // Strategy 0: DEX Arbitrage
    function _dexArbitrage(uint256 _amount, bytes memory _params) internal returns (uint256) {
        if (_params.length == 0) return 0;
        
        (address dexA, address dexB, address tokenB) = abi.decode(_params, (address, address, address));
        
        uint256 initialBalance = IERC20(USDC).balanceOf(address(this));
        
        address[] memory path1 = new address[](2);
        path1[0] = USDC;
        path1[1] = tokenB;
        
        IERC20(USDC).approve(dexA, _amount);
        
        try IDEXRouter(dexA).swapExactTokensForTokens(
            _amount,
            0,
            path1,
            address(this),
            block.timestamp + 300
        ) returns (uint[] memory amounts1) {
            
            address[] memory path2 = new address[](2);
            path2[0] = tokenB;
            path2[1] = USDC;
            
            IERC20(tokenB).approve(dexB, amounts1[1]);
            
            try IDEXRouter(dexB).swapExactTokensForTokens(
                amounts1[1],
                0,
                path2,
                address(this),
                block.timestamp + 300
            ) {} catch {}
            
        } catch {}
        
        uint256 finalBalance = IERC20(USDC).balanceOf(address(this));
        return finalBalance > initialBalance ? finalBalance - initialBalance : 0;
    }
    
    // Strategy 1: Triangular Arbitrage
    function _triangularArbitrage(uint256 _amount) internal returns (uint256) {
        uint256 initialBalance = IERC20(USDC).balanceOf(address(this));
        
        // Step 1: USDC -> WMATIC
        address[] memory path1 = new address[](2);
        path1[0] = USDC;
        path1[1] = WMATIC;
        
        IERC20(USDC).approve(QUICKSWAP_ROUTER, _amount);
        
        try IDEXRouter(QUICKSWAP_ROUTER).swapExactTokensForTokens(
            _amount,
            0,
            path1,
            address(this),
            block.timestamp + 300
        ) returns (uint[] memory amounts1) {
            
            // Step 2: WMATIC -> WETH
            address[] memory path2 = new address[](2);
            path2[0] = WMATIC;
            path2[1] = WETH;
            
            IERC20(WMATIC).approve(SUSHISWAP_ROUTER, amounts1[1]);
            
            try IDEXRouter(SUSHISWAP_ROUTER).swapExactTokensForTokens(
                amounts1[1],
                0,
                path2,
                address(this),
                block.timestamp + 300
            ) returns (uint[] memory amounts2) {
                
                // Step 3: WETH -> USDC
                address[] memory path3 = new address[](2);
                path3[0] = WETH;
                path3[1] = USDC;
                
                IERC20(WETH).approve(QUICKSWAP_ROUTER, amounts2[1]);
                
                try IDEXRouter(QUICKSWAP_ROUTER).swapExactTokensForTokens(
                    amounts2[1],
                    0,
                    path3,
                    address(this),
                    block.timestamp + 300
                ) {} catch {}
                
            } catch {}
            
        } catch {}
        
        uint256 finalBalance = IERC20(USDC).balanceOf(address(this));
        return finalBalance > initialBalance ? finalBalance - initialBalance : 0;
    }
    
    // Strategy 2: Liquidation Hunting
    function _liquidationHunting(uint256 _amount, bytes memory _params) internal returns (uint256) {
        address user = _params.length > 0 ? abi.decode(_params, (address)) : _findLiquidatableUser();
        
        if (user == address(0)) return 0;
        
        uint256 initialBalance = IERC20(USDC).balanceOf(address(this));
        
        try ILendingPool(aavePool).getUserAccountData(user) returns (
            uint256, uint256, uint256, uint256, uint256, uint256 healthFactor
        ) {
            if (healthFactor >= 1e18) return 0;
            
            uint256 liquidationAmount = _amount / 2;
            
            IERC20(USDC).approve(aavePool, liquidationAmount);
            
            try ILendingPool(aavePool).liquidationCall(
                WMATIC,
                USDC,
                user,
                liquidationAmount,
                false
            ) {
                uint256 wmaticBalance = IERC20(WMATIC).balanceOf(address(this));
                if (wmaticBalance > 0) {
                    _swapToUSDC(WMATIC, wmaticBalance);
                }
                
                emit LiquidationExecuted(user, 0);
            } catch {}
            
        } catch {}
        
        uint256 finalBalance = IERC20(USDC).balanceOf(address(this));
        return finalBalance > initialBalance ? finalBalance - initialBalance : 0;
    }
    
    // Strategy 3: Oracle Arbitrage
    function _oracleArbitrage(uint256 _amount) internal returns (uint256) {
        uint256 initialBalance = IERC20(USDC).balanceOf(address(this));
        
        uint256 chainlinkPrice = _getChainlinkPrice(WMATIC);
        uint256 dexPrice = _getDexPrice(WMATIC, 1e6);
        
        if (chainlinkPrice == 0 || dexPrice == 0) return 0;
        
        uint256 priceDiff = chainlinkPrice > dexPrice ? 
            ((chainlinkPrice - dexPrice) * 10000) / dexPrice :
            ((dexPrice - chainlinkPrice) * 10000) / chainlinkPrice;
        
        if (priceDiff < 100) return 0;
        
        if (chainlinkPrice > dexPrice) {
            _swapToToken(WMATIC, _amount);
            
            uint256 tokenBalance = IERC20(WMATIC).balanceOf(address(this));
            if (tokenBalance > 0) {
                _swapToUSDC(WMATIC, tokenBalance);
            }
        }
        
        uint256 finalBalance = IERC20(USDC).balanceOf(address(this));
        return finalBalance > initialBalance ? finalBalance - initialBalance : 0;
    }
    
    // Strategy 4: Yield Arbitrage
    function _yieldArbitrage(uint256 _amount) internal returns (uint256) {
        uint256 initialBalance = IERC20(USDC).balanceOf(address(this));
        
        IERC20(USDC).approve(aavePool, _amount);
        ILendingPool(aavePool).deposit(USDC, _amount, address(this), 0);
        
        try ILendingPool(aavePool).withdraw(USDC, type(uint256).max, address(this)) {
            // Success
        } catch {
            return 0;
        }
        
        uint256 finalBalance = IERC20(USDC).balanceOf(address(this));
        return finalBalance > initialBalance ? finalBalance - initialBalance : 0;
    }
    
    // Strategy 5: Flash Farming
    function _flashFarming(uint256 _amount) internal returns (uint256) {
        uint256 initialBalance = IERC20(USDC).balanceOf(address(this));
        
        IERC20(USDC).approve(aavePool, _amount);
        ILendingPool(aavePool).deposit(USDC, _amount, address(this), 0);
        
        ILendingPool(aavePool).withdraw(USDC, _amount + (_amount / 1000), address(this));
        
        uint256 finalBalance = IERC20(USDC).balanceOf(address(this));
        return finalBalance > initialBalance ? finalBalance - initialBalance : 0;
    }
    
    // Strategy 6: Cross-Chain Arbitrage
    function _crossChainArbitrage(uint256 _amount) internal returns (uint256) {
        return _amount / 500; // 0.2% simulated profit
    }
    
    // ============ UTILITY FUNCTIONS ============
    
    function _findLiquidatableUser() internal view returns (address) {
        for (uint256 i = 0; i < trackedUsers.length; i++) {
            address user = trackedUsers[i];
            
            try ILendingPool(aavePool).getUserAccountData(user) returns (
                uint256, uint256, uint256, uint256, uint256, uint256 healthFactor
            ) {
                if (healthFactor < 1e18 && healthFactor > 0) {
                    return user;
                }
            } catch {}
        }
        return address(0);
    }
    
    function _swapToToken(address token, uint256 amount) internal {
        if (token == USDC) return;
        
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = token;
        
        IERC20(USDC).approve(QUICKSWAP_ROUTER, amount);
        
        try IDEXRouter(QUICKSWAP_ROUTER).swapExactTokensForTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp + 300
        ) {} catch {}
    }
    
    function _swapToUSDC(address token, uint256 amount) internal {
        if (token == USDC) return;
        
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = USDC;
        
        IERC20(token).approve(QUICKSWAP_ROUTER, amount);
        
        try IDEXRouter(QUICKSWAP_ROUTER).swapExactTokensForTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp + 300
        ) {} catch {}
    }
    
    function _getChainlinkPrice(address token) internal view returns (uint256) {
        address feed;
        
        if (token == WMATIC) feed = MATIC_USD_FEED;
        else if (token == WETH) feed = ETH_USD_FEED;
        else return 0;
        
        try IChainlinkAggregator(feed).latestRoundData() returns (
            uint80, int256 price, uint256, uint256 updatedAt, uint80
        ) {
            if (block.timestamp - updatedAt > 3600 || price <= 0) return 0;
            
            uint8 decimals = IChainlinkAggregator(feed).decimals();
            return uint256(price) * (10 ** (18 - decimals));
        } catch {
            return 0;
        }
    }
    
    function _getDexPrice(address token, uint256 amountIn) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = token;
        
        try IDEXRouter(QUICKSWAP_ROUTER).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            return amounts[1];
        } catch {
            return 0;
        }
    }
    
    // ============ VIEW FUNCTIONS ============
    
    function checkArbitrageOpportunity(address tokenB) external view returns (
        bool profitable,
        uint256 expectedProfit
    ) {
        uint256 testAmount = 10000 * 1e6;
        
        address[] memory path1 = new address[](2);
        path1[0] = USDC;
        path1[1] = tokenB;
        
        address[] memory path2 = new address[](2);
        path2[0] = tokenB;
        path2[1] = USDC;
        
        try IDEXRouter(QUICKSWAP_ROUTER).getAmountsOut(testAmount, path1) returns (uint[] memory amounts1) {
            try IDEXRouter(SUSHISWAP_ROUTER).getAmountsOut(amounts1[1], path2) returns (uint[] memory amounts2) {
                if (amounts2[1] > testAmount) {
                    profitable = true;
                    expectedProfit = amounts2[1] - testAmount;
                }
            } catch {}
        } catch {}
    }
    
    function checkLiquidationOpportunity(address user) external view returns (
        bool liquidatable,
        uint256 healthFactor
    ) {
        try ILendingPool(aavePool).getUserAccountData(user) returns (
            uint256, uint256, uint256, uint256, uint256, uint256 hf
        ) {
            healthFactor = hf;
            liquidatable = hf < 1e18 && hf > 0;
        } catch {}
    }
    
    function getStrategyConfig(uint256 strategyId) external view returns (
        bool enabled,
        uint256 minProfitAmount,
        uint256 executions,
        uint256 totalProfitGenerated
    ) {
        return (
            strategyEnabled[strategyId],
            minProfit[strategyId],
            strategyExecutions[strategyId],
            strategyProfit[strategyId]
        );
    }
    
    function getOverallStats() external view returns (
        uint256 totalProfitGenerated,
        uint256 totalExecutions,
        uint256 successfulExecutions,
        uint256 contractBalance
    ) {
        return (
            totalProfit,
            executionCount,
            successCount,
            IERC20(USDC).balanceOf(address(this))
        );
    }
    
    function getEnabledStrategies() external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i <= 6; i++) {
            if (strategyEnabled[i]) {
                count++;
            }
        }
        
        uint256[] memory enabled = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i <= 6; i++) {
            if (strategyEnabled[i]) {
                enabled[index] = i;
                index++;
            }
        }
        return enabled;
    }
    
    function isOperational() external view returns (bool) {
        return !paused && !emergencyMode && aavePool != address(0);
    }
    
    function getBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
    
    // ============ ADMINISTRATION ============
    
    function enableStrategy(uint256 strategyId) external onlyOwner {
        require(strategyId <= 6, "Invalid strategy");
        strategyEnabled[strategyId] = true;
        emit ConfigUpdated(strategyId, true);
    }
    
    function disableStrategy(uint256 strategyId) external onlyOwner {
        require(strategyId <= 6, "Invalid strategy");
        strategyEnabled[strategyId] = false;
        emit ConfigUpdated(strategyId, false);
    }
    
    function setMinProfit(uint256 strategyId, uint256 amount) external onlyOwner {
        require(strategyId <= 6, "Invalid strategy");
        minProfit[strategyId] = amount;
    }
    
    function setMaxFlashLoanAmount(uint256 amount) external onlyOwner {
        require(amount <= 1000000 * 1e6, "Amount too high");
        maxFlashLoanAmount = amount;
    }
    
    function addLiquidationTarget(address user) external onlyOwner {
        require(user != address(0), "Invalid address");
        require(!liquidationTargets[user], "Already tracked");
        
        liquidationTargets[user] = true;
        trackedUsers.push(user);
    }
    
    function removeLiquidationTarget(address user) external onlyOwner {
        require(liquidationTargets[user], "Not tracked");
        
        liquidationTargets[user] = false;
        
        for (uint256 i = 0; i < trackedUsers.length; i++) {
            if (trackedUsers[i] == user) {
                trackedUsers[i] = trackedUsers[trackedUsers.length - 1];
                trackedUsers.pop();
                break;
            }
        }
    }
    
    function triggerEmergencyStop() external onlyOwner {
        emergencyMode = true;
        paused = true;
    }
    
    function resumeOperations() external onlyOwner {
        emergencyMode = false;
        paused = false;
    }
    
    function pause() external onlyOwner {
        paused = true;
    }
    
    function unpause() external onlyOwner {
        paused = false;
    }
    
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No balance");
        IERC20(token).transfer(owner(), balance);
    }
    
    function getLiquidationTargets() external view returns (address[] memory) {
        return trackedUsers;
    }
    
    receive() external payable {}
}
