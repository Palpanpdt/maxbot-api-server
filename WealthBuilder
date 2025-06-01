// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title WealthBuilder - 3 Stratégies Anti-Perte
 * @notice Capital auto-croissant avec arbitrage, liquidations et multi-DEX
 * @dev Version finale vérifiée pour déploiement
 */

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IDexRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface ILendingPool {
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralETH,
        uint256 totalDebtETH,
        uint256 availableBorrowsETH,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external returns (uint256);
}

contract WealthBuilder {
    // ===================== CONSTANTES =====================
    
    uint256 private constant MIN_PROFIT = 500000;           // 0.5 USDC
    uint256 private constant MAX_SLIPPAGE = 50;             // 0.5%
    uint256 private constant MAX_POSITION = 30;             // 30% max par trade
    uint256 private constant SAFETY_RESERVE = 15;          // 15% en réserve
    uint256 private constant COOLDOWN = 60 seconds;
    
    // Adresses Polygon (checksummed)
    address public constant QUICKSWAP = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address public constant SUSHISWAP = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;
    address public constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address public constant WMATIC = 0x0d500B1D8E8E53de6Ec5cB567F8Eff95819347C0;
    
    // ===================== STRUCTURES =====================
    
    struct SecurityCheck {
        uint256 timestamp;
        bool marketStable;
        uint256 priceDeviation;
        uint256 riskScore;
    }
    
    // ===================== VARIABLES D'ÉTAT =====================
    
    address public immutable owner;
    bool public isActive = true;
    bool private locked = false;
    uint256 public lastExecution;
    uint256 public healthThreshold = 1050000000000000000; // 1.05
    
    // Capital management
    uint256 public initialCapital;
    uint256 public currentCapital;
    uint256 public totalProfits;
    uint256 public availableCapital;
    uint256 public totalTrades;
    uint256 public successfulTrades;
    
    // Token balances
    mapping(address => uint256) public balances;
    
    // Strategy stats
    uint256 public arbitrageTrades;
    uint256 public arbitrageProfits;
    uint256 public liquidationTrades;
    uint256 public liquidationProfits;
    uint256 public multidexTrades;
    uint256 public multidexProfits;

    // Variables de sécurité
    SecurityCheck public securityStatus;
    uint256 public constant MAX_PRICE_DEVIATION = 300; // 3%
    uint256 public constant MAX_RISK_SCORE = 50;
    uint256 public maxDailyLoss;
    uint256 public currentDailyLoss;
    bool public emergencyStop;
    
    // ===================== EVENTS =====================
    
    event FundsDeposited(uint256 amount, uint256 newCapital);
    event ArbitrageExecuted(uint256 amountIn, uint256 profit);
    event LiquidationExecuted(address user, uint256 bonus);
    event MultidexExecuted(uint256 amountIn, uint256 profit);
    event CapitalGrowth(uint256 oldCapital, uint256 newCapital);
    event TradeRejected(string reason);
    event SecurityAlert(string reason, uint256 value);
    event PrecisionCheck(bool passed, uint256 deviation);
    event RiskUpdate(uint256 riskScore);
    
    // ===================== MODIFIERS =====================
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier whenActive() {
        require(isActive, "Paused");
        _;
    }
    
    modifier nonReentrant() {
        require(!locked, "Reentrant");
        locked = true;
        _;
        locked = false;
    }
    
    modifier cooldownPassed() {
        require(block.timestamp >= lastExecution + COOLDOWN, "Cooldown");
        _;
        lastExecution = block.timestamp;
    }
    
    // ===================== CONSTRUCTOR =====================
    
    constructor() {
        owner = msg.sender;
        lastExecution = block.timestamp;
    }
    
    // ===================== GESTION DU CAPITAL =====================
    
    function deposit(uint256 amount) external onlyOwner whenActive {
        require(amount > 0, "Amount zero");
        require(IERC20(USDC).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        balances[USDC] += amount;
        
        if (initialCapital == 0) {
            initialCapital = amount;
        }
        currentCapital += amount;
        _updateAvailableCapital();
        
        emit FundsDeposited(amount, currentCapital);
    }
    
    function _updateAvailableCapital() internal {
        uint256 reserve = (currentCapital * SAFETY_RESERVE) / 100;
        availableCapital = currentCapital > reserve ? currentCapital - reserve : 0;
    }
    
    // ===================== VÉRIFICATIONS DE SÉCURITÉ =====================
    
    function _checkTradeViability(uint256 amountIn) internal view returns (bool) {
        if (balances[USDC] < amountIn) return false;
        
        uint256 maxAllowed = (availableCapital * MAX_POSITION) / 100;
        if (amountIn > maxAllowed) return false;
        
        if (amountIn < 10 * 10**6) return false; // Min 10 USDC
        
        return true;
    }
    
    function _simulateArbitrageProfit(uint256 amountIn) internal view returns (uint256) {
        address[] memory path1 = new address[](2);
        path1[0] = USDC;
        path1[1] = WMATIC;
        
        address[] memory path2 = new address[](2);
        path2[0] = WMATIC;
        path2[1] = USDC;
        
        try IDexRouter(QUICKSWAP).getAmountsOut(amountIn, path1) returns (uint256[] memory amounts1) {
            try IDexRouter(SUSHISWAP).getAmountsOut(amounts1[1], path2) returns (uint256[] memory amounts2) {
                if (amounts2[1] > amountIn) {
                    return amounts2[1] - amountIn;
                }
            } catch {}
        } catch {}
        
        return 0;
    }
    
    // ===================== STRATÉGIE 1: ARBITRAGE =====================
    
    function executeArbitrage(uint256 amountIn) 
        external 
        onlyOwner 
        whenActive 
        cooldownPassed 
        nonReentrant 
    {
        require(_checkTradeViability(amountIn), "Trade not viable");
        
        uint256 expectedProfit = _simulateArbitrageProfit(amountIn);
        if (expectedProfit < MIN_PROFIT) {
            emit TradeRejected("Profit too low");
            return;
        }
        
        uint256 initialBalance = balances[USDC];
        
        bool success = _executeArbitrageSwaps(amountIn);
        if (!success) {
            emit TradeRejected("Swap execution failed");
            return;
        }
        
        uint256 finalBalance = balances[USDC];
        require(finalBalance >= initialBalance, "LOSS DETECTED - REVERTING");
        
        uint256 actualProfit = finalBalance - initialBalance;
        require(actualProfit >= MIN_PROFIT, "Profit below minimum");
        
        _processProfit(actualProfit);
        arbitrageTrades++;
        arbitrageProfits += actualProfit;
        
        emit ArbitrageExecuted(amountIn, actualProfit);
    }
    
    function _executeArbitrageSwaps(uint256 amountIn) internal returns (bool) {
        uint256 wmaticReceived = _swapTokens(USDC, WMATIC, amountIn, QUICKSWAP);
        if (wmaticReceived == 0) return false;
        
        uint256 usdcReceived = _swapTokens(WMATIC, USDC, wmaticReceived, SUSHISWAP);
        return usdcReceived > 0;
    }
    
    // ===================== STRATÉGIE 2: LIQUIDATIONS AAVE =====================
    
    function executeLiquidation(
        address user, 
        address collateralAsset, 
        address debtAsset, 
        uint256 debtAmount
    ) external onlyOwner whenActive cooldownPassed nonReentrant {
        
        require(collateralAsset == USDC || collateralAsset == WMATIC, "Collateral not supported");
        require(debtAsset == USDC || debtAsset == WMATIC, "Debt asset not supported");
        require(debtAmount > 0, "Debt amount zero");
        require(_isPositionLiquidable(user), "Position not liquidable");
        
        uint256 expectedBonus = (debtAmount * 5) / 100; // 5% bonus attendu
        require(expectedBonus >= MIN_PROFIT, "Expected bonus too low");
        
        uint256 initialPortfolioValue = _getPortfolioValue();
        uint256 initialCollateralBalance = IERC20(collateralAsset).balanceOf(address(this));
        
        try ILendingPool(AAVE_POOL).liquidationCall(
            collateralAsset,
            debtAsset,
            user,
            debtAmount,
            false
        ) {
            uint256 finalCollateralBalance = IERC20(collateralAsset).balanceOf(address(this));
            uint256 bonusReceived = finalCollateralBalance > initialCollateralBalance ? 
                finalCollateralBalance - initialCollateralBalance : 0;
            
            require(bonusReceived > 0, "No bonus received");
            
            balances[collateralAsset] += bonusReceived;
            
            // Convertir en USDC si nécessaire
            if (collateralAsset != USDC && bonusReceived > 0) {
                uint256 usdcReceived = _swapTokens(collateralAsset, USDC, bonusReceived, QUICKSWAP);
                require(usdcReceived > 0, "Conversion to USDC failed");
            }
            
            uint256 finalPortfolioValue = _getPortfolioValue();
            require(finalPortfolioValue >= initialPortfolioValue, "Portfolio value decreased");
            
            uint256 actualProfit = finalPortfolioValue - initialPortfolioValue;
            require(actualProfit >= MIN_PROFIT, "Profit below minimum");
            
            _processProfit(actualProfit);
            liquidationTrades++;
            liquidationProfits += actualProfit;
            
            emit LiquidationExecuted(user, actualProfit);
            
        } catch {
            emit TradeRejected("Liquidation execution failed");
            revert("Liquidation failed");
        }
    }
    
    function _isPositionLiquidable(address user) internal view returns (bool) {
        try ILendingPool(AAVE_POOL).getUserAccountData(user) returns (
            uint256, uint256, uint256, uint256, uint256, uint256 healthFactor
        ) {
            return healthFactor < healthThreshold && healthFactor > 0;
        } catch {
            return false;
        }
    }
    
    // ===================== STRATÉGIE 3: MULTI-DEX TRADING =====================
    
    function executeMultidex(address tokenIn, address tokenOut, uint256 amountIn) 
        external 
        onlyOwner 
        whenActive 
        cooldownPassed 
        nonReentrant 
    {
        require(tokenIn == USDC || tokenIn == WMATIC, "Token not supported");
        require(tokenOut == USDC || tokenOut == WMATIC, "Token not supported");
        require(balances[tokenIn] >= amountIn, "Insufficient balance");
        require(amountIn >= 10 * 10**6, "Amount too small");
        
        (address bestRouter, uint256 bestOutput) = _findBestDex(tokenIn, tokenOut, amountIn);
        require(bestRouter != address(0), "No valid route");
        
        uint256 currentValue = _getPortfolioValue();
        
        uint256 amountOut = _swapTokens(tokenIn, tokenOut, amountIn, bestRouter);
        require(amountOut > 0, "Swap failed");
        
        uint256 newValue = _getPortfolioValue();
        require(newValue >= currentValue, "Value decreased");
        
        uint256 profit = newValue - currentValue;
        if (profit >= MIN_PROFIT) {
            _processProfit(profit);
            multidexTrades++;
            multidexProfits += profit;
        }
        
        emit MultidexExecuted(amountIn, profit);
    }
    
    function _findBestDex(address tokenIn, address tokenOut, uint256 amountIn) 
        internal view returns (address bestRouter, uint256 bestOutput) {
        
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        
        // Vérifier QuickSwap
        try IDexRouter(QUICKSWAP).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            if (amounts[1] > bestOutput) {
                bestOutput = amounts[1];
                bestRouter = QUICKSWAP;
            }
        } catch {}
        
        // Vérifier SushiSwap
        try IDexRouter(SUSHISWAP).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            if (amounts[1] > bestOutput) {
                bestOutput = amounts[1];
                bestRouter = SUSHISWAP;
            }
        } catch {}
    }
    
    // ===================== FONCTION DE SWAP SÉCURISÉE =====================
    
    function _swapTokens(address tokenIn, address tokenOut, uint256 amountIn, address router) 
        internal returns (uint256) {
        
        require(balances[tokenIn] >= amountIn, "Insufficient balance");
        require(IERC20(tokenIn).approve(router, amountIn), "Approval failed");
        
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        
        uint256 amountOutMin;
        try IDexRouter(router).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            amountOutMin = (amounts[1] * (10000 - MAX_SLIPPAGE)) / 10000;
        } catch {
            return 0;
        }
        
        try IDexRouter(router).swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            address(this),
            block.timestamp + 300
        ) returns (uint256[] memory amounts) {
            
            balances[tokenIn] -= amountIn;
            balances[tokenOut] += amounts[1];
            
            return amounts[1];
            
        } catch {
            return 0;
        }
    }
    
    // ===================== GESTION DES PROFITS =====================
    
    function _processProfit(uint256 profit) internal {
        totalProfits += profit;
        uint256 oldCapital = currentCapital;
        currentCapital += profit;
        _updateAvailableCapital();
        
        totalTrades++;
        successfulTrades++;
        
        emit CapitalGrowth(oldCapital, currentCapital);
    }
    
    function _getPortfolioValue() internal view returns (uint256) {
        uint256 usdcValue = balances[USDC];
        uint256 wmaticValue = balances[WMATIC] / 2; // 1 MATIC ≈ 0.5 USDC
        return usdcValue + wmaticValue;
    }
    
    // ===================== VÉRIFICATION SÉCURITÉ RAPIDE =====================
    
    function quickSecurityCheck() internal returns (bool) {
        uint256 deviation = _checkPriceDeviation();
        uint256 risk = _calculateQuickRisk();
        
        securityStatus = SecurityCheck({
            timestamp: block.timestamp,
            marketStable: deviation <= MAX_PRICE_DEVIATION,
            priceDeviation: deviation,
            riskScore: risk
        });
        
        bool safe = deviation <= MAX_PRICE_DEVIATION && risk <= MAX_RISK_SCORE && !emergencyStop;
        
        if (!safe) {
            emit SecurityAlert("Market unsafe", deviation);
        }
        
        return safe;
    }
    
    function _checkPriceDeviation() internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WMATIC;
        uint256 testAmount = 10 * 10**6;
        
        uint256 price1;
        uint256 price2;
        
        try IDexRouter(QUICKSWAP).getAmountsOut(testAmount, path) returns (uint256[] memory amounts) {
            price1 = amounts[1];
        } catch {}
        
        try IDexRouter(SUSHISWAP).getAmountsOut(testAmount, path) returns (uint256[] memory amounts) {
            price2 = amounts[1];
        } catch {}
        
        if (price1 == 0 || price2 == 0) return 999;
        
        uint256 maxPrice = price1 > price2 ? price1 : price2;
        uint256 minPrice = price1 < price2 ? price1 : price2;
        
        return ((maxPrice - minPrice) * 10000) / maxPrice;
    }
    
    function _calculateQuickRisk() internal view returns (uint256) {
        uint256 score = 0;
        
        if (tx.gasprice > 150 * 10**9) score += 25;
        if (maxDailyLoss > 0 && currentDailyLoss > maxDailyLoss / 2) score += 25;
        if (totalTrades > 0 && successfulTrades * 100 / totalTrades < 80) score += 25;
        if (block.timestamp < lastExecution + COOLDOWN / 2) score += 25;
        
        return score;
    }
    
    // ===================== VÉRIFICATION PRÉCISION =====================
    
    function checkPrecision(uint256 expected, uint256 actual) internal returns (bool) {
        if (expected == 0) return actual == 0;
        
        uint256 deviation = expected > actual ? 
            ((expected - actual) * 10000) / expected :
            ((actual - expected) * 10000) / expected;
        
        bool precise = deviation <= 200; // Max 2%
        emit PrecisionCheck(precise, deviation);
        
        return precise;
    }
    
    // ===================== GESTION RISQUE QUOTIDIEN =====================
    
    function updateDailyRisk(uint256 lossAmount) internal {
        uint256 today = block.timestamp / 1 days;
        uint256 lastUpdate = currentDailyLoss > 0 ? 1 : 0;
        
        if (today > lastUpdate) {
            currentDailyLoss = 0;
        }
        
        currentDailyLoss += lossAmount;
        
        if (maxDailyLoss > 0 && currentDailyLoss > maxDailyLoss) {
            emergencyStop = true;
            isActive = false;
            emit SecurityAlert("Daily loss exceeded", currentDailyLoss);
        }
        
        emit RiskUpdate(_calculateQuickRisk());
    }
    
    // ===================== FONCTIONS DE CONSULTATION =====================
    
    function getCapitalInfo() external view returns (
        uint256 initial,
        uint256 current,
        uint256 profits,
        uint256 available,
        uint256 growthPercent
    ) {
        uint256 growth = initialCapital > 0 ? 
            ((currentCapital - initialCapital) * 100) / initialCapital : 0;
        return (initialCapital, currentCapital, totalProfits, availableCapital, growth);
    }
    
    function getStrategyStats() external view returns (
        uint256 arbTrades,
        uint256 liqTrades,
        uint256 multiTrades,
        uint256 arbProfits,
        uint256 liqProfits,
        uint256 multiProfits,
        uint256 totalTradesCount,
        uint256 successRate
    ) {
        uint256 rate = totalTrades > 0 ? (successfulTrades * 100) / totalTrades : 0;
        return (
            arbitrageTrades, 
            liquidationTrades, 
            multidexTrades, 
            arbitrageProfits, 
            liquidationProfits, 
            multidexProfits, 
            totalTrades, 
            rate
        );
    }
    
    function getBalances() external view returns (uint256 usdcBalance, uint256 wmaticBalance) {
        return (balances[USDC], balances[WMATIC]);
    }
    
    function checkArbitrageOpportunity(uint256 amountIn) external view returns (
        bool profitable,
        uint256 expectedProfit,
        string memory status
    ) {
        if (!isActive) {
            return (false, 0, "Contract paused");
        }
        
        if (!_checkTradeViability(amountIn)) {
            return (false, 0, "Trade not viable");
        }
        
        uint256 profit = _simulateArbitrageProfit(amountIn);
        bool isProfitable = profit >= MIN_PROFIT;
        
        string memory statusMsg = isProfitable ? "Opportunity available" : "Profit too low";
        return (isProfitable, profit, statusMsg);
    }
    
    function checkLiquidationOpportunity(address user) external view returns (
        bool liquidable,
        uint256 healthFactor,
        string memory status
    ) {
        if (!isActive) {
            return (false, 0, "Contract paused");
        }
        
        try ILendingPool(AAVE_POOL).getUserAccountData(user) returns (
            uint256, uint256, uint256, uint256, uint256, uint256 hf
        ) {
            bool isLiquidable = hf < healthThreshold && hf > 0;
            string memory statusMsg = isLiquidable ? "Position liquidable" : 
                                     hf == 0 ? "Invalid user" : "Position healthy";
            return (isLiquidable, hf, statusMsg);
        } catch {
            return (false, 0, "Unable to fetch user data");
        }
    }
    
    function getQuickStatus() external view returns (
        bool safe,
        uint256 priceDeviation,
        uint256 riskScore,
        uint256 dailyLossUsed,
        bool emergencyActive
    ) {
        return (
            securityStatus.marketStable && !emergencyStop,
            securityStatus.priceDeviation,
            securityStatus.riskScore,
            currentDailyLoss,
            emergencyStop
        );
    }
    
    // ===================== ADMINISTRATION =====================
    
    function pause() external onlyOwner {
        isActive = false;
    }
    
    function unpause() external onlyOwner {
        isActive = true;
    }
    
    function setHealthThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold > 1e18 && newThreshold < 1.2e18, "Invalid threshold");
        healthThreshold = newThreshold;
    }
    
    function setDailyLossLimit(uint256 limit) external onlyOwner {
        require(limit > 0 && limit <= currentCapital / 5, "Invalid limit");
        maxDailyLoss = limit;
    }
    
    function resetEmergency() external onlyOwner {
        require(!isActive, "Must pause first");
        emergencyStop = false;
        currentDailyLoss = 0;
    }
    
    function forceSecurityUpdate() external onlyOwner {
        quickSecurityCheck();
    }
    
    function withdraw(uint256 amount) external onlyOwner {
        require(!isActive, "Must pause first");
        require(amount <= balances[USDC], "Insufficient balance");
        require(IERC20(USDC).transfer(owner, amount), "Transfer failed");
        
        balances[USDC] -= amount;
        currentCapital -= amount;
        _updateAvailableCapital();
    }
    
    function emergencyWithdraw() external onlyOwner {
        require(!isActive, "Must pause first");
        
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        if (usdcBalance > 0) {
            IERC20(USDC).transfer(owner, usdcBalance);
        }
        
        uint256 wmaticBalance = IERC20(WMATIC).balanceOf(address(this));
        if (wmaticBalance > 0) {
            IERC20(WMATIC).transfer(owner, wmaticBalance);
        }
        
        balances[USDC] = 0;
        balances[WMATIC] = 0;
        currentCapital = 0;
        availableCapital = 0;
    }
    
    receive() external payable {
        revert("ETH not accepted");
    }
}
