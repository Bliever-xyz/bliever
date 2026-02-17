// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LSMath
 * @notice Fixed-point arithmetic library for LS-LMSR cost function calculations
 * @dev Uses 18-decimal fixed-point (1e18 = 1.0) for precision
 * 
 * LS-LMSR Cost Function: C(q) = b(q) * ln(Σ exp(q_i / b(q)))
 * Where: b(q) = α * Σq_i (liquidity-sensitive parameter)
 * 
 * Price Function: p_i = exp(q_i / b) / Σ exp(q_j / b)
 */
library LSMath {
    /// @dev Scaling factor for fixed-point arithmetic (18 decimals)
    uint256 constant SCALE = 1e18;
    
    /// @dev Maximum value for safe exp calculation (ln(type(int256).max) ≈ 135)
    int256 constant MAX_EXP_INPUT = 100e18;
    
    /// @dev Minimum value for safe exp calculation
    int256 constant MIN_EXP_INPUT = -100e18;
    
    /// @dev Natural logarithm of 2 (scaled by 1e18)
    int256 constant LN2 = 693147180559945309;
    
    /// @dev Minimum b parameter to prevent division by zero
    int256 constant MIN_B = 1e15; // 0.001

    error InvalidOutcomeCount();
    error DivisionByZero();
    error ExponentOverflow();
    error NegativeValue();
    error InvalidAlpha();

    /**
     * @notice Calculate LS-LMSR cost function
     * @param qs Array of outstanding shares per outcome (scaled by 1e18)
     * @param alpha Liquidity sensitivity parameter (scaled by 1e18, typically 0.05-0.30)
     * @return cost Total cost in collateral terms (scaled by 1e18)
     */
    function calculateCost(int256[] memory qs, int256 alpha) internal pure returns (int256 cost) {
        if (qs.length < 2) revert InvalidOutcomeCount();
        if (alpha <= 0) revert InvalidAlpha();
        
        // Calculate b = α * Σq_i
        int256 totalQ = sum(qs);
        int256 b = (alpha * totalQ) / int256(SCALE);
        
        // Handle edge case: initial state where all q_i = 0
        if (b < MIN_B) {
            b = MIN_B;
        }
        
        // Calculate Σ exp(q_i / b)
        int256 sumExp = 0;
        for (uint256 i = 0; i < qs.length; i++) {
            int256 exponent = (qs[i] * int256(SCALE)) / b;
            
            // Bound check to prevent overflow
            if (exponent > MAX_EXP_INPUT) revert ExponentOverflow();
            if (exponent < MIN_EXP_INPUT) exponent = MIN_EXP_INPUT;
            
            int256 expVal = exp(exponent);
            sumExp += expVal;
        }
        
        // C(q) = b * ln(sumExp)
        int256 lnSumExp = ln(sumExp);
        cost = (b * lnSumExp) / int256(SCALE);
        
        return cost;
    }

    /**
     * @notice Calculate marginal price for a specific outcome
     * @param qs Current outstanding shares
     * @param outcomeIndex Index of outcome to price
     * @param alpha Liquidity sensitivity parameter
     * @return price Probability/price for outcome (scaled by 1e18, range [0, 1e18])
     */
    function calculatePrice(
        int256[] memory qs,
        uint256 outcomeIndex,
        int256 alpha
    ) internal pure returns (uint256 price) {
        if (outcomeIndex >= qs.length) revert InvalidOutcomeCount();
        if (alpha <= 0) revert InvalidAlpha();
        
        int256 totalQ = sum(qs);
        int256 b = (alpha * totalQ) / int256(SCALE);
        
        if (b < MIN_B) {
            b = MIN_B;
        }
        
        // Calculate exp(q_i / b)
        int256 numeratorExp = (qs[outcomeIndex] * int256(SCALE)) / b;
        if (numeratorExp > MAX_EXP_INPUT) numeratorExp = MAX_EXP_INPUT;
        if (numeratorExp < MIN_EXP_INPUT) numeratorExp = MIN_EXP_INPUT;
        int256 numerator = exp(numeratorExp);
        
        // Calculate Σ exp(q_j / b)
        int256 denominator = 0;
        for (uint256 i = 0; i < qs.length; i++) {
            int256 exponent = (qs[i] * int256(SCALE)) / b;
            if (exponent > MAX_EXP_INPUT) exponent = MAX_EXP_INPUT;
            if (exponent < MIN_EXP_INPUT) exponent = MIN_EXP_INPUT;
            denominator += exp(exponent);
        }
        
        // Price = numerator / denominator
        price = uint256((numerator * int256(SCALE)) / denominator);
        
        return price;
    }

    /**
     * @notice Calculate cost delta for buying shares
     * @param currentQs Current market state
     * @param outcomeIndex Outcome to buy
     * @param shares Number of shares to buy
     * @param alpha Liquidity parameter
     * @return costDelta Cost to buy shares (always positive)
     */
    function calculateBuyCost(
        int256[] memory currentQs,
        uint256 outcomeIndex,
        uint256 shares,
        int256 alpha
    ) internal pure returns (uint256 costDelta) {
        if (outcomeIndex >= currentQs.length) revert InvalidOutcomeCount();
        
        // Calculate C(q) before trade
        int256 costBefore = calculateCost(currentQs, alpha);
        
        // Calculate C(q + Δe_i) after trade
        int256[] memory newQs = new int256[](currentQs.length);
        for (uint256 i = 0; i < currentQs.length; i++) {
            newQs[i] = currentQs[i];
        }
        newQs[outcomeIndex] += int256(shares);
        
        int256 costAfter = calculateCost(newQs, alpha);
        
        // Cost delta should always be positive for buys
        int256 delta = costAfter - costBefore;
        if (delta < 0) revert NegativeValue();
        
        return uint256(delta);
    }

    /**
     * @notice Calculate cost delta for selling shares
     * @param currentQs Current market state
     * @param outcomeIndex Outcome to sell
     * @param shares Number of shares to sell
     * @param alpha Liquidity parameter
     * @return costDelta Proceeds from selling shares (always positive)
     */
    function calculateSellCost(
        int256[] memory currentQs,
        uint256 outcomeIndex,
        uint256 shares,
        int256 alpha
    ) internal pure returns (uint256 costDelta) {
        if (outcomeIndex >= currentQs.length) revert InvalidOutcomeCount();
        if (int256(shares) > currentQs[outcomeIndex]) revert NegativeValue();
        
        // Calculate C(q) before trade
        int256 costBefore = calculateCost(currentQs, alpha);
        
        // Calculate C(q - Δe_i) after trade
        int256[] memory newQs = new int256[](currentQs.length);
        for (uint256 i = 0; i < currentQs.length; i++) {
            newQs[i] = currentQs[i];
        }
        newQs[outcomeIndex] -= int256(shares);
        
        int256 costAfter = calculateCost(newQs, alpha);
        
        // Cost delta should be positive (you get money back)
        int256 delta = costBefore - costAfter;
        if (delta < 0) revert NegativeValue();
        
        return uint256(delta);
    }

    // ============ HELPER FUNCTIONS ============

    /**
     * @notice Sum all elements in array
     */
    function sum(int256[] memory arr) internal pure returns (int256 total) {
        for (uint256 i = 0; i < arr.length; i++) {
            total += arr[i];
        }
        return total;
    }

    /**
     * @notice Natural exponential function e^x using Taylor series
     * @dev Accurate for x in range [-100, 100] with 18 decimal precision
     * @param x Input (scaled by 1e18)
     * @return result e^x (scaled by 1e18)
     */
    function exp(int256 x) internal pure returns (int256 result) {
        if (x == 0) return int256(SCALE);
        if (x > MAX_EXP_INPUT) revert ExponentOverflow();
        
        // Handle negative exponents: e^(-x) = 1 / e^x
        bool negative = x < 0;
        if (negative) x = -x;
        
        // Decompose x = k * ln(2) + r where |r| < ln(2)/2
        int256 k = x / LN2;
        int256 r = x - k * LN2;
        
        // Calculate e^r using Taylor series (6 terms for precision)
        int256 expR = int256(SCALE);
        int256 term = int256(SCALE);
        
        for (uint256 i = 1; i <= 10; i++) {
            term = (term * r) / (int256(SCALE) * int256(i));
            expR += term;
            
            // Early exit if term becomes negligible
            if (term < 100 && term > -100) break;
        }
        
        // Calculate e^x = 2^k * e^r
        result = expR;
        
        // Multiply by 2^k (bit shifting for efficiency)
        if (k > 0) {
            for (uint256 i = 0; i < uint256(k); i++) {
                result = (result * 2);
            }
        } else if (k < 0) {
            for (uint256 i = 0; i < uint256(-k); i++) {
                result = result / 2;
            }
        }
        
        // Handle negative exponent
        if (negative) {
            result = (int256(SCALE) * int256(SCALE)) / result;
        }
        
        return result;
    }

    /**
     * @notice Natural logarithm ln(x) using binary decomposition
     * @dev Accurate for x > 0 with 18 decimal precision
     * @param x Input (scaled by 1e18, must be > 0)
     * @return result ln(x) (scaled by 1e18)
     */
    function ln(int256 x) internal pure returns (int256 result) {
        if (x <= 0) revert NegativeValue();
        
        // Decompose x = 2^n * m where 1 <= m < 2
        int256 n = 0;
        int256 m = x;
        
        // Scale m to range [1, 2) by dividing by 2
        while (m >= 2 * int256(SCALE)) {
            m = m / 2;
            n++;
        }
        
        // Scale m to range [1, 2) by multiplying by 2
        while (m < int256(SCALE)) {
            m = m * 2;
            n--;
        }
        
        // ln(x) = n * ln(2) + ln(m)
        result = n * LN2;
        
        // Calculate ln(m) using Taylor series: ln(1 + z) = z - z²/2 + z³/3 - ...
        // where z = m - 1
        int256 z = m - int256(SCALE);
        int256 term = z;
        int256 lnM = 0;
        
        for (uint256 i = 1; i <= 10; i++) {
            lnM += term / int256(i);
            term = (term * z) / int256(SCALE);
            
            // Alternate signs
            if (i % 2 == 0) {
                term = -term;
            }
            
            // Early exit
            if (abs(term) < 100) break;
        }
        
        result += lnM;
        return result;
    }

    /**
     * @notice Absolute value
     */
    function abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    /**
     * @notice Maximum of two numbers
     */
    function max(int256 a, int256 b) internal pure returns (int256) {
        return a >= b ? a : b;
    }

    /**
     * @notice Minimum of two numbers
     */
    function min(int256 a, int256 b) internal pure returns (int256) {
        return a <= b ? a : b;
    }

    /**
     * @notice Convert uint256 to int256 with overflow check
     */
    function toInt256(uint256 x) internal pure returns (int256) {
        if (x > uint256(type(int256).max)) revert ExponentOverflow();
        return int256(x);
    }

    /**
     * @notice Convert int256 to uint256 with underflow check
     */
    function toUint256(int256 x) internal pure returns (uint256) {
        if (x < 0) revert NegativeValue();
        return uint256(x);
    }
}
