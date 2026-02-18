// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LSMath - Liquidity-Sensitive Logarithmic Market Scoring Rule Mathematics
/// @author LS-LMSR Protocol
/// @notice Core mathematical library implementing the LS-LMSR algorithm for prediction markets
/// @dev This contract provides stateless, pure mathematical functions for LS-LMSR calculations.
///      It implements the liquidity-sensitive automated market maker described in:
///      "A Practical Liquidity-Sensitive Automated Market Maker" by Othman et al. (2013)
///
///      Key differences from standard LMSR:
///      - Variable liquidity parameter: b(q) = α * Σqi (not constant)
///      - Prices sum to > 1 (not translation invariant)
///      - Bounded loss that approaches zero as initial liquidity approaches zero
///      - Homogeneous of degree one (scales proportionally with market volume)
///
///      This contract is designed to be imported and used by market contracts, LP vaults,
///      and other system components. It contains ONLY mathematical logic with no state.
library LSMath {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when alpha parameter is zero or exceeds maximum allowed value
    error InvalidAlpha();

    /// @notice Thrown when a quantity array is empty
    error EmptyQuantities();

    /// @notice Thrown when a quantity value is negative (not allowed in positive orthant)
    error NegativeQuantity();

    /// @notice Thrown when sum of quantities is zero (undefined liquidity parameter)
    error ZeroQuantitySum();

    /// @notice Thrown when outcome index exceeds array bounds
    error InvalidOutcomeIndex();

    /// @notice Thrown when arithmetic operation would overflow
    error ArithmeticOverflow();

    /// @notice Thrown when multiplication would overflow
    error MultiplicationOverflow();

    /// @notice Thrown when division by zero is attempted
    error DivisionByZero();

    /// @notice Thrown when market state is invalid or inconsistent
    error InvalidMarketState();

    /// @notice Thrown when array has insufficient outcomes (need at least 2)
    error InsufficientOutcomes();

    /// @notice Thrown when array lengths don't match
    error ArrayLengthMismatch();

    /// @notice Thrown when logarithm input is zero or negative
    error InvalidLogInput();

    /// @notice Thrown when exponential calculation would overflow
    error ExponentialOverflow();

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fixed-point scaling factor for precision (18 decimals)
    /// @dev All calculations use 18 decimal precision to match ETH/Wei standard
    uint256 internal constant SCALE = 1e18;

    /// @notice Maximum allowed alpha value (prevents excessive fees)
    /// @dev Alpha represents commission rate; max 0.2 (20%) prevents unfair pricing
    uint256 internal constant MAX_ALPHA = 2e17; // 0.2 in 18-decimal fixed point

    /// @notice Minimum alpha value (prevents zero division)
    uint256 internal constant MIN_ALPHA = 1e12; // 0.000001 in 18-decimal fixed point

    /// @notice Maximum number of outcomes supported
    /// @dev Limited to prevent gas exhaustion in loops
    uint256 internal constant MAX_OUTCOMES = 100;

    /// @notice Natural logarithm of 2 in 18-decimal fixed point
    /// @dev Used for log2 to ln conversion: ln(x) = log2(x) * LN_2
    uint256 internal constant LN_2 = 693147180559945309; // ln(2) ≈ 0.693147...

    /// @notice Maximum exponent input to prevent overflow
    /// @dev exp(MAX_EXP_INPUT) ≈ 2^256 when scaled
    uint256 internal constant MAX_EXP_INPUT = 135305999368893231589; // ~135.3 in 18-decimal

    /// @notice Minimum term value for early exit in Taylor series
    /// @dev When term contribution falls below this, further terms are negligible
    uint256 internal constant MIN_TERM = 100;

    /*//////////////////////////////////////////////////////////////
                        CORE LS-LMSR FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates the liquidity parameter b(q) = α * Σqi
    /// @dev The liquidity parameter determines price sensitivity to trades.
    ///      As total quantity increases, b(q) increases, making prices less elastic.
    ///      This is the key innovation of LS-LMSR over standard LMSR.
    ///
    ///      Mathematical definition:
    ///      b(q) = α * Σ(i=1 to n) qi
    ///
    ///      Where:
    ///      - α (alpha) is the commission parameter (fixed)
    ///      - qi is the quantity outstanding for outcome i
    ///      - Σqi is the total volume that has flowed through the market
    ///
    /// @param quantities Array of outstanding quantities [q1, q2, ..., qn]
    /// @param alpha Commission parameter in 18-decimal fixed point (e.g., 0.05e18 for 5%)
    /// @return b Liquidity parameter in 18-decimal fixed point
    function liquidityParameter(
        uint256[] memory quantities,
        uint256 alpha
    ) internal pure returns (uint256 b, uint256 sumQ) {
        // Input validation
        if (alpha < MIN_ALPHA || alpha > MAX_ALPHA) revert InvalidAlpha();
        if (quantities.length == 0) revert EmptyQuantities();
        if (quantities.length > MAX_OUTCOMES) revert InvalidOutcomeIndex();

        // Calculate sum of quantities: Σqi
        uint256 sumQ = 0;
        uint256 length = quantities.length;
        
        for (uint256 i = 0; i < length; ) {
            // Check for negative quantities (reverts on underflow in unsigned)
            uint256 qi = quantities[i];
            
            // Accumulate sum with overflow check
            sumQ += qi;
            if (sumQ < qi) revert ArithmeticOverflow();

            unchecked {
                ++i; // Safe: i < length checked in loop condition
            }
        }

        if (sumQ == 0) revert ZeroQuantitySum();

        // Calculate b(q) = α * Σqi
        // Both values are in 18-decimal fixed point, so we need to divide by SCALE
        b = (alpha * sumQ) / SCALE;

        // Ensure b is non-zero after scaling
        if (b == 0) revert ZeroQuantitySum();
    }

    /// @notice Calculates the cost function C(q) = b(q) * ln(Σ exp(qi/b(q)))
    /// @dev The cost function represents the total amount paid into the market.
    ///      It is the integral over instantaneous prices and serves as the
    ///      "potential field" from which prices are derived via gradient.
    ///
    ///      Mathematical definition:
    ///      C(q) = b(q) * ln(Σ(i=1 to n) exp(qi/b(q)))
    ///
    ///      Where:
    ///      - b(q) = α * Σqi (liquidity parameter)
    ///      - qi is the quantity for outcome i
    ///      - ln is the natural logarithm
    ///      - exp is the exponential function
    ///
    ///      Properties:
    ///      - Path independent (gradient of scalar field)
    ///      - Positive homogeneous of degree 1: C(γq) = γC(q)
    ///      - Bounded loss: C(q) ≥ max(qi)
    ///      - Worst-case loss bounded by C(q0) for initial state q0
    ///
    /// @param quantities Array of outstanding quantities [q1, q2, ..., qn]
    /// @param alpha Commission parameter in 18-decimal fixed point
    /// @return cost Cost function value in 18-decimal fixed point
    function costFunction(
        uint256[] memory quantities,
        uint256 alpha
    ) internal pure returns (uint256 cost) {
        // Calculate liquidity parameter b(q)
        uint256 b = liquidityParameter(quantities, alpha);

        // Calculate Σ exp(qi/b)
        uint256 sumExp = 0;
        uint256 length = quantities.length;

        for (uint256 i = 0; i < length; ) {
            uint256 qi = quantities[i];
            
            // Calculate qi/b in fixed point
            // qi and b are both in base units, result needs to be scaled
            uint256 ratio = (qi * SCALE) / b;

            // Calculate exp(qi/b)
            uint256 expValue = exp(ratio);

            // Accumulate sum
            sumExp += expValue;
            if (sumExp < expValue) revert ArithmeticOverflow();

            unchecked {
                ++i;
            }
        }

        // Calculate ln(Σ exp(qi/b))
        uint256 lnSum = ln(sumExp);

        // Calculate C(q) = b * ln(Σ exp(qi/b))
        // b is in base units, lnSum is in SCALE, so result is in base units
        cost = (b * lnSum) / SCALE;
    }

    /// @notice Calculates the instantaneous price for outcome i
    /// @dev Price is the partial derivative of the cost function with respect to qi.
    ///      Due to variable b(q), the price formula is more complex than standard LMSR.
    ///
    ///      Mathematical definition (from paper, Section 4.1):
    ///      pi(q) = α * ln(Σ exp(qj/b(q))) + 
    ///              [Σqj * exp(qi/b(q)) - Σqj * exp(qj/b(q))] / [Σqj * Σexp(qj/b(q))]
    ///
    ///      Simplified:
    ///      pi(q) = α * ln(Σ exp(qj/b)) + [weighted_i - weighted_sum] / [sum_q * sum_exp]
    ///
    ///      Where:
    ///      - weighted_i = Σqj * exp(qi/b)
    ///      - weighted_sum = Σqj * exp(qj/b) / Σexp(qj/b)
    ///      - b = α * Σqj
    ///
    ///      Properties:
    ///      - Prices sum to > 1 (not translation invariant)
    ///      - 1 ≤ Σpi(q) ≤ 1 + αn*ln(n)
    ///      - Liquidity sensitive: prices become less elastic as volume increases
    ///
    /// @param quantities Array of outstanding quantities [q1, q2, ..., qn]
    /// @param outcomeIndex Index of outcome to get price for (0-based)
    /// @param alpha Commission parameter in 18-decimal fixed point
    /// @return price Price in 18-decimal fixed point (can be > 1)
    function getPrice(
        uint256[] memory quantities,
        uint256 outcomeIndex,
        uint256 alpha
    ) internal pure returns (uint256 price) {
        if (outcomeIndex >= quantities.length) revert InvalidOutcomeIndex();

        // Calculate b(q) and sum of quantities
        uint256 b = liquidityParameter(quantities, alpha);
        uint256 sumQ = 0;
        uint256 sumExp = 0;
        uint256 length = quantities.length;

        // First pass: calculate sumQ and sumExp
        for (uint256 i = 0; i < length; ) {
            uint256 qi = quantities[i];
            sumQ += qi;

            uint256 ratio = (qi * SCALE) / b;
            uint256 expValue = exp(ratio);
            sumExp += expValue;

            unchecked {
                ++i;
            }
        }

        // Calculate first term: α * ln(Σ exp(qj/b))
        uint256 lnSum = ln(sumExp);
        uint256 term1 = (alpha * lnSum) / SCALE;

        // Calculate second term components
        // weighted_i = sumQ * exp(qi/b)
        uint256 qi = quantities[outcomeIndex];
        uint256 ratioI = (qi * SCALE) / b;
        uint256 expI = exp(ratioI);
        uint256 weightedI = (sumQ * expI) / SCALE;

        // weighted_sum = Σ(qj * exp(qj/b))
        uint256 weightedSum = 0;
        for (uint256 i = 0; i < length; ) {
            uint256 qj = quantities[i];
            uint256 ratioJ = (qj * SCALE) / b;
            uint256 expJ = exp(ratioJ);
            uint256 product = (qj * expJ) / SCALE;
            weightedSum += product;

            unchecked {
                ++i;
            }
        }

        // Calculate second term: (weighted_i - weighted_sum) / (sumQ * sumExp)
        // Note: This can be negative, but we handle it as int256 then convert
        int256 numerator = int256(weightedI) - int256(weightedSum);
        uint256 denominator = (sumQ * sumExp) / SCALE;

        int256 term2 = (numerator * int256(SCALE)) / int256(denominator);

        // Combine terms: price = term1 + term2
        // term1 is always positive, term2 can be negative
        int256 priceInt = int256(term1) + term2;

        // Price should always be positive in valid markets
        if (priceInt <= 0) revert ArithmeticOverflow();

        price = uint256(priceInt);
    }

    /// @notice Calculates prices for all outcomes simultaneously
    /// @dev More gas-efficient than calling getPrice() multiple times
    ///      as it reuses intermediate calculations.
    ///
    /// @param quantities Array of outstanding quantities [q1, q2, ..., qn]
    /// @param alpha Commission parameter in 18-decimal fixed point
    /// @return prices Array of prices, one per outcome, in 18-decimal fixed point
    function getAllPrices(
        uint256[] memory quantities,
        uint256 alpha
    ) internal pure returns (uint256[] memory prices) {
        uint256 length = quantities.length;
        prices = new uint256[](length);

        // Calculate b(q) and shared values
        uint256 b = liquidityParameter(quantities, alpha);
        uint256 sumQ = 0;
        uint256 sumExp = 0;

        // Cache exp values to avoid recalculation
        uint256[] memory expValues = new uint256[](length);

        // First pass: calculate sumQ, sumExp, and cache exp values
        for (uint256 i = 0; i < length; ) {
            uint256 qi = quantities[i];
            sumQ += qi;

            uint256 ratio = (qi * SCALE) / b;
            uint256 expValue = exp(ratio);
            expValues[i] = expValue;
            sumExp += expValue;

            unchecked {
                ++i;
            }
        }

        // Calculate shared term: α * ln(Σ exp(qj/b))
        uint256 lnSum = ln(sumExp);
        uint256 alphaTerm = (alpha * lnSum) / SCALE;

        // Calculate weighted sum (used for all outcomes)
        uint256 weightedSum = 0;
        for (uint256 i = 0; i < length; ) {
            uint256 qj = quantities[i];
            uint256 product = (qj * expValues[i]) / SCALE;
            weightedSum += product;

            unchecked {
                ++i;
            }
        }

        // Calculate denominator (same for all outcomes)
        uint256 denominator = (sumQ * sumExp) / SCALE;

        // Second pass: calculate price for each outcome
        for (uint256 i = 0; i < length; ) {
            // weighted_i = sumQ * exp(qi/b)
            uint256 weightedI = (sumQ * expValues[i]) / SCALE;

            // Calculate term2
            int256 numerator = int256(weightedI) - int256(weightedSum);
            int256 term2 = (numerator * int256(SCALE)) / int256(denominator);

            // Combine terms
            int256 priceInt = int256(alphaTerm) + term2;

            if (priceInt <= 0) revert ArithmeticOverflow();

            prices[i] = uint256(priceInt);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Calculates the cost to move from quantity vector q0 to q1
    /// @dev This is used to determine the payment required for a trade.
    ///      Cost = C(q1) - C(q0)
    ///      Positive cost means trader pays market maker.
    ///      Negative cost means market maker pays trader (selling back).
    ///
    /// @param quantitiesFrom Initial quantity vector q0
    /// @param quantitiesTo Final quantity vector q1
    /// @param alpha Commission parameter in 18-decimal fixed point
    /// @return tradeCost Cost difference (can be negative if selling)
    function calculateTradeCost(
        uint256[] memory quantitiesFrom,
        uint256[] memory quantitiesTo,
        uint256 alpha
    ) internal pure returns (int256 tradeCost) {
        if (quantitiesFrom.length != quantitiesTo.length) revert InvalidOutcomeIndex();

        uint256 costFrom = costFunction(quantitiesFrom, alpha);
        uint256 costTo = costFunction(quantitiesTo, alpha);

        tradeCost = int256(costTo) - int256(costFrom);
    }

    /// @notice Calculates the sum of all prices
    /// @dev Useful for validating market state and understanding fee structure.
    ///
    ///      Theoretical bounds (from paper Section 4.2):
    ///      1 + O(α²) ≤ Σpi(q) ≤ 1 + αn*ln(n)
    ///
    ///      - Lower bound approaches 1 for small α
    ///      - Upper bound achieved when all qi are equal (q = k*1)
    ///      - Sum > 1 represents the market maker's edge (commission)
    ///
    /// @param quantities Array of outstanding quantities
    /// @param alpha Commission parameter in 18-decimal fixed point
    /// @return sum Sum of all prices in 18-decimal fixed point
    function sumOfPrices(
        uint256[] memory quantities,
        uint256 alpha
    ) internal pure returns (uint256 sum) {
        uint256[] memory prices = getAllPrices(quantities, alpha);
        uint256 length = prices.length;

        for (uint256 i = 0; i < length; ) {
            sum += prices[i];
            if (sum < prices[i]) revert ArithmeticOverflow();

            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        MATHEMATICAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates e^x using Taylor series approximation
    /// @dev Implements exp(x) for fixed-point numbers (18 decimals).
    ///      Uses Taylor series: e^x = 1 + x + x²/2! + x³/3! + ...
    ///
    ///      Optimizations:
    ///      - Range reduction: large x handled via e^x = e^(x-ln2) * 2
    ///      - Precision: 18 terms for ~1e-18 accuracy
    ///      - Overflow protection: reverts if x > MAX_EXP_INPUT
    ///
    /// @param x Exponent in 18-decimal fixed point
    /// @return result e^x in 18-decimal fixed point
    function exp(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) return SCALE;
        if (x > MAX_EXP_INPUT) revert ExponentialOverflow();

        // Range reduction: if x > ln(2), use e^x = 2 * e^(x-ln2)
        uint256 multiplier = SCALE;
        while (x > LN_2) {
            x -= LN_2;
            multiplier = multiplier * 2;
            if (multiplier < SCALE) revert ExponentialOverflow();
        }

        // Taylor series: e^x = 1 + x + x²/2! + x³/3! + ...
        uint256 sum = SCALE; // Start with 1
        uint256 term = SCALE; // Current term in series

        // Calculate 18 terms (sufficient for 1e-18 precision)
        for (uint256 i = 1; i <= 18; ) {
            term = (term * x) / (i * SCALE);
            sum += term;
            
            // Early exit if term becomes negligible
            if (term < MIN_TERM) break;

            unchecked {
                ++i;
            }
        }

        // Apply multiplier from range reduction
        result = (sum * multiplier) / SCALE;
    }

    /// @notice Calculates ln(x) using logarithm approximation
    /// @dev Implements natural logarithm for fixed-point numbers (18 decimals).
    ///      Uses bit-by-bit logarithm algorithm for gas efficiency.
    ///
    ///      Algorithm:
    ///      1. Find integer part via bit position of MSB
    ///      2. Calculate fractional part via binary search
    ///      3. Combine: ln(x) = ln(2^n * m) = n*ln(2) + ln(m)
    ///
    /// @param x Input in 18-decimal fixed point (must be > 0)
    /// @return result ln(x) in 18-decimal fixed point
    function ln(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) revert InvalidLogInput();
        if (x == SCALE) return 0; // ln(1) = 0

        // Handle x < 1 by using ln(x) = -ln(1/x)
        bool isLessThanOne = x < SCALE;
        if (isLessThanOne) {
            x = (SCALE * SCALE) / x;
        }

        // Find the integer part (MSB position)
        uint256 intPart = 0;
        uint256 y = x / SCALE;

        if (y >= 2**128) { y >>= 128; intPart += 128; }
        if (y >= 2**64) { y >>= 64; intPart += 64; }
        if (y >= 2**32) { y >>= 32; intPart += 32; }
        if (y >= 2**16) { y >>= 16; intPart += 16; }
        if (y >= 2**8) { y >>= 8; intPart += 8; }
        if (y >= 2**4) { y >>= 4; intPart += 4; }
        if (y >= 2**2) { y >>= 2; intPart += 2; }
        if (y >= 2**1) { intPart += 1; }

        // Integer part contribution: intPart * ln(2)
        uint256 intPartContribution = intPart * LN_2;

        // Calculate fractional part using binary search
        // Normalize x to [1, 2) range
        uint256 xNorm = (x << (256 - 1 - intPart)) >> (256 - 1 - 59); // 59 bits precision
        uint256 fracPart = 0;

        // Binary search for ln(x) where x ∈ [1, 2)
        for (uint256 i = 0; i < 59; ) {
            xNorm = (xNorm * xNorm) >> 59;
            if (xNorm >= 2**59) {
                xNorm >>= 1;
                fracPart += LN_2 >> (i + 1);
            }
            unchecked {
                ++i;
            }
        }

        result = intPartContribution + fracPart;

        // Apply sign if original x was < 1
        if (isLessThanOne) {
            // Return value should be negative, but we use uint256
            // Caller must handle negative logarithm cases
            revert InvalidLogInput();
        }
    }

    /// @notice Multiplies two 18-decimal fixed-point numbers
    /// @dev (a * b) / SCALE with overflow protection
    /// @param a First operand in 18-decimal fixed point
    /// @param b Second operand in 18-decimal fixed point
    /// @return result Product in 18-decimal fixed point
    function mulScale(uint256 a, uint256 b) internal pure returns (uint256 result) {
        uint256 product = a * b;
        if (product / a != b) revert ArithmeticOverflow();
        result = product / SCALE;
    }

    /// @notice Divides two 18-decimal fixed-point numbers
    /// @dev (a * SCALE) / b with overflow protection
    /// @param a Numerator in 18-decimal fixed point
    /// @param b Denominator in 18-decimal fixed point
    /// @return result Quotient in 18-decimal fixed point
    function divScale(uint256 a, uint256 b) internal pure returns (uint256 result) {
        if (b == 0) revert ArithmeticOverflow();
        uint256 scaled = a * SCALE;
        if (scaled / a != SCALE) revert ArithmeticOverflow();
        result = scaled / b;
    }

    /*//////////////////////////////////////////////////////////////
                        VALIDATION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates that quantities are in the valid region (positive orthant)
    /// @dev All quantities must be non-negative for LS-LMSR to function correctly
    /// @param quantities Array to validate
    /// @return valid True if all quantities are valid
    function validateQuantities(uint256[] memory quantities) internal pure returns (bool valid) {
        if (quantities.length < 2) return false;
        if (quantities.length > MAX_OUTCOMES) return false;

        uint256 sum = 0;
        for (uint256 i = 0; i < quantities.length; ) {
            // In uint256, we can't have negative values, but we check for meaningful values
            sum += quantities[i];
            unchecked {
                ++i;
            }
        }

        return sum > 0;
    }

    /// @notice Checks if alpha is within valid range
    /// @param alpha Alpha parameter to validate
    /// @return valid True if alpha is valid
    function validateAlpha(uint256 alpha) internal pure returns (bool valid) {
        return alpha >= MIN_ALPHA && alpha <= MAX_ALPHA;
    }

    /*//////////////////////////////////////////////////////////////
                        UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates worst-case loss for a market state
    /// @dev Worst-case loss = C(q0) - C(q) + max(qi)
    ///      By Proposition 4.9, loss is bounded by C(q0)
    ///
    /// @param quantities Current quantity vector
    /// @param initialQuantities Initial quantity vector q0
    /// @param alpha Commission parameter
    /// @return worstCaseLoss Maximum possible loss
    function calculateWorstCaseLoss(
        uint256[] memory quantities,
        uint256[] memory initialQuantities,
        uint256 alpha
    ) internal pure returns (uint256 worstCaseLoss) {
        // Validation: arrays must have same length and not be empty
        if (quantities.length == 0 || initialQuantities.length == 0) revert EmptyQuantities();
        if (quantities.length != initialQuantities.length) revert ArrayLengthMismatch();
        
        uint256 costCurrent = costFunction(quantities, alpha);
        uint256 costInitial = costFunction(initialQuantities, alpha);

        // Find max quantity
        uint256 maxQ = quantities[0];
        for (uint256 i = 1; i < quantities.length; ) {
            if (quantities[i] > maxQ) {
                maxQ = quantities[i];
            }
            unchecked {
                ++i;
            }
        }

        // Loss = C(q0) - C(q) + max(qi)
        // This should never be negative if C(q) >= max(qi) (Lemma 4.5)
        if (costCurrent < maxQ) {
            worstCaseLoss = costInitial + maxQ - costCurrent;
        } else {
            if (costInitial > costCurrent - maxQ) {
                worstCaseLoss = costInitial - (costCurrent - maxQ);
            } else {
                worstCaseLoss = 0; // Market maker has profit
            }
        }
    }

    /// @notice Checks if market maker has outcome-independent profit
    /// @dev Revenue R(q) = C(q) - max(qi) - C(q0)
    ///      If R(q) > 0, market maker profits regardless of outcome
    ///
    /// @param quantities Current quantity vector
    /// @param initialQuantities Initial quantity vector
    /// @param alpha Commission parameter
    /// @return hasProfit True if market maker has guaranteed profit
    /// @return profit Amount of guaranteed profit (0 if hasProfit is false)
    function hasOutcomeIndependentProfit(
        uint256[] memory quantities,
        uint256[] memory initialQuantities,
        uint256 alpha
    ) internal pure returns (bool hasProfit, uint256 profit) {
        uint256 costCurrent = costFunction(quantities, alpha);
        uint256 costInitial = costFunction(initialQuantities, alpha);

        // Find max quantity
        uint256 maxQ = quantities[0];
        for (uint256 i = 1; i < quantities.length; ) {
            if (quantities[i] > maxQ) {
                maxQ = quantities[i];
            }
            unchecked {
                ++i;
            }
        }

        // Revenue = C(q) - max(qi) - C(q0)
        int256 revenue = int256(costCurrent) - int256(maxQ) - int256(costInitial);

        if (revenue > 0) {
            hasProfit = true;
            profit = uint256(revenue);
        } else {
            hasProfit = false;
            profit = 0;
        }
    }
}
