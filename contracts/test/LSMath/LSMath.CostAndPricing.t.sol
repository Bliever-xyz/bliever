// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2} from "forge-std/Test.sol";
import {LSMathHarness} from "./harness/LSMathHarness.sol";
import {LSMath} from "../../src/LSMath.sol";

/// @title LSMath Cost & Pricing Test Suite
/// @notice Tests for costFunction(), getPrice(), getAllPrices(), and sumOfPrices().
///
///         These functions implement the LS-LMSR market equations that determine
///         what traders pay and what current prices are.  This file also covers
///         the numerical-stability tests (Log-Sum-Exp trick, large/imbalanced markets)
///         mentioned in the developer documentation as critical safety fixes.
contract LSMathCostAndPricingTest is Test {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant SCALE     = 1e18;
    uint256 internal constant ALPHA_5   = 5e16;   // 5 %
    uint256 internal constant ALPHA_10  = 1e17;   // 10 %
    uint256 internal constant MAX_ALPHA = 2e17;

    /// @dev 0.1 % relative tolerance for transcendental-math assertions
    uint256 internal constant REL_TOL = 1e15;

    /*//////////////////////////////////////////////////////////////
                            STATE & SETUP
    //////////////////////////////////////////////////////////////*/

    LSMathHarness internal h;

    function setUp() public {
        h = new LSMathHarness();
        vm.label(address(h), "LSMathHarness");
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _binary(uint256 q0, uint256 q1) internal pure returns (uint256[] memory q) {
        q = new uint256[](2);
        q[0] = q0;
        q[1] = q1;
    }

    function _uniform(uint256 n, uint256 qty) internal pure returns (uint256[] memory q) {
        q = new uint256[](n);
        for (uint256 i; i < n; ++i) q[i] = qty;
    }

    /*//////////////////////////////////////////////////////////////
                      costFunction() — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev For the symmetric market [100, 100] the cost must be > max(qi).
    ///      Lemma 4.5 of the paper: C(q) >= max(qi)
    function test_costFunction_exceeds_max_quantity() public view {
        uint256[] memory q = _binary(100e18, 100e18);
        uint256 cost = h.costFunction(q, ALPHA_5);

        assertGt(cost, 100e18, "C(q) must be >= max(qi)");
    }

    /// @dev Reference value for [100, 100], alpha=5 %:
    ///      b = 10e18, ratio = 10e18, sumExp = 2e18
    ///      adjustedLn = 10e18 + ln(2) ≈ 10.6931e18
    ///      cost ≈ 10e18 * 10.6931e18 / 1e18 ≈ 106.93e18
    function test_costFunction_known_value_symmetric_binary() public view {
        uint256[] memory q = new uint256[](2);
        q[0] = 100 * SCALE;
        q[1] = 100 * SCALE;
        
        uint256 cost = h.costFunction(q, 5e16); // 5% alpha
        
        // ADDED THE MISSING 0 AT THE END: 106.93 * 1e18
        uint256 expected = 106_931_471_805_599_453_090; 
        
        assertApproxEqAbs(cost, expected, 1000, "costFunction [100,100] alpha=5%");
    }

    /// @dev Cost is strictly positive for any valid input
    function test_costFunction_always_positive() public view {
        uint256[] memory q = _binary(1e18, 1e18);
        uint256 cost = h.costFunction(q, ALPHA_5);
        assertGt(cost, 0, "cost must be positive");
    }

    /// @dev Monotonicity: adding quantity to an outcome increases total cost.
    ///      C(q') > C(q) when q' has a larger element than q.
    function test_costFunction_monotone_increasing_with_quantity() public view {
        uint256[] memory qBefore = _binary(100e18, 100e18);
        uint256[] memory qAfter  = _binary(150e18, 100e18);

        uint256 c0 = h.costFunction(qBefore, ALPHA_5);
        uint256 c1 = h.costFunction(qAfter,  ALPHA_5);

        assertGt(c1, c0, "buying more must increase total cost");
    }

    /// @dev Higher alpha produces lower cost for the same quantity
    ///      (because a larger b smooths exp differences, reducing the log-sum-exp).
    ///      Actually: larger b makes qi/b smaller, so exp(qi/b) closer to 1,
    ///      and ln(Σexp) smaller — thus cost can be higher or lower depending on direction.
    ///      The key constraint we can assert: cost is always >= max(qi).
    function test_costFunction_lower_bound_always_max_qi() public view {
        uint256[] memory q = _binary(80e18, 120e18);
        uint256 maxQ = 120e18;

        uint256 cost5  = h.costFunction(q, ALPHA_5);
        uint256 cost10 = h.costFunction(q, ALPHA_10);
        uint256 cost20 = h.costFunction(q, MAX_ALPHA);

        assertGe(cost5,  maxQ, "C(q) >= max(qi) for alpha=5%");
        assertGe(cost10, maxQ, "C(q) >= max(qi) for alpha=10%");
        assertGe(cost20, maxQ, "C(q) >= max(qi) for alpha=20%");
    }

    /// @dev Multi-outcome (5 equal outcomes) cost must be > max element
    function test_costFunction_five_equal_outcomes() public view {
        uint256[] memory q = _uniform(5, 50e18);
        uint256 cost = h.costFunction(q, ALPHA_5);
        assertGt(cost, 50e18, "cost must exceed max(qi) in 5-way market");
    }

    /*//////////////////////////////////////////////////////////////
                     costFunction() — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    /// @dev Propagates alpha validation from liquidityParameter
    function test_costFunction_reverts_invalid_alpha() public {
        uint256[] memory q = _binary(1e18, 1e18);
        vm.expectRevert(LSMath.InvalidAlpha.selector);
        h.costFunction(q, 0);
    }

    /// @dev Propagates empty array validation
    function test_costFunction_reverts_empty_array() public {
        uint256[] memory q = new uint256[](0);
        vm.expectRevert(LSMath.EmptyQuantities.selector);
        h.costFunction(q, ALPHA_5);
    }

    /// @dev All-zero quantities → ZeroQuantitySum
    function test_costFunction_reverts_all_zero_quantities() public {
        uint256[] memory q = _binary(0, 0);
        vm.expectRevert(LSMath.ZeroQuantitySum.selector);
        h.costFunction(q, ALPHA_5);
    }

    /*//////////////////////////////////////////////////////////////
                    costFunction() — NUMERICAL STABILITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Large market (80 equal outcomes) must NOT revert.
    ///      This validates the Log-Sum-Exp trick is active in costFunction.
    ///      Without stabilization, exp(qi/b) would overflow for large ratio values.
    function test_costFunction_large_market_no_overflow() public view {
        uint256[] memory q = _uniform(80, 1e30);
        // Must not revert — numerical stability is required
        uint256 cost = h.costFunction(q, ALPHA_5);
        assertGt(cost, 0, "large market cost must be positive");
        console2.log("costFunction 80 outcomes cost:", cost);
    }

    /// @dev Highly imbalanced market: one dominant outcome, rest tiny.
    ///      exp of large differences must be handled via Log-Sum-Exp.
    function test_costFunction_imbalanced_market_no_overflow() public view {
        uint256[] memory q = new uint256[](10);
        q[0] = 1e40; // dominant
        for (uint256 i = 1; i < 10; ++i) q[i] = 1e18; // tiny

        uint256 cost = h.costFunction(q, ALPHA_5);
        // Cost must be at least the dominant quantity
        assertGe(cost, q[0], "cost must be >= dominant quantity");
    }

    /*//////////////////////////////////////////////////////////////
                getPrice() / getAllPrices() — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Symmetric market → all prices must be equal (exact symmetry)
    function test_getAllPrices_symmetric_market_equal_prices() public view {
        uint256[] memory q = _binary(100e18, 100e18);
        uint256[] memory prices = h.getAllPrices(q, ALPHA_5);

        assertEq(prices.length, 2, "should return 2 prices");
        // Symmetric market: both prices must be equal within rounding
        assertApproxEqAbs(prices[0], prices[1], 1, "symmetric prices must be equal");
    }

    /// @dev All prices must be strictly positive
    function test_getAllPrices_all_prices_positive() public view {
        uint256[] memory q = _binary(80e18, 120e18);
        uint256[] memory prices = h.getAllPrices(q, ALPHA_5);

        assertGt(prices[0], 0, "price[0] must be positive");
        assertGt(prices[1], 0, "price[1] must be positive");
    }

    /// @dev The higher-quantity outcome should have a higher price
    ///      (basic monotonicity of LS-LMSR pricing)
    function test_getAllPrices_higher_quantity_higher_price() public view {
        uint256[] memory q = _binary(80e18, 120e18); // q[1] > q[0]
        uint256[] memory prices = h.getAllPrices(q, ALPHA_5);

        assertGt(prices[1], prices[0], "higher quantity outcome should have higher price");
    }

    /// @dev getPrice(i) must return the same value as getAllPrices()[i]
    function test_getPrice_matches_getAllPrices_index() public view {
        uint256[] memory q = _binary(80e18, 120e18);
        uint256[] memory allPrices = h.getAllPrices(q, ALPHA_5);

        uint256 p0 = h.getPrice(q, 0, ALPHA_5);
        uint256 p1 = h.getPrice(q, 1, ALPHA_5);

        assertEq(p0, allPrices[0], "getPrice(0) must match getAllPrices()[0]");
        assertEq(p1, allPrices[1], "getPrice(1) must match getAllPrices()[1]");
    }

    /// @dev Prices are returned for all n outcomes in correct order
    function test_getAllPrices_correct_length() public view {
        uint256[] memory q = _uniform(5, 50e18);
        uint256[] memory prices = h.getAllPrices(q, ALPHA_5);
        assertEq(prices.length, 5, "should return one price per outcome");
    }

    /// @dev Five-way equal market: all five prices should be equal
    function test_getAllPrices_five_equal_outcomes_equal_prices() public view {
        uint256[] memory q = _uniform(5, 50e18);
        uint256[] memory prices = h.getAllPrices(q, ALPHA_5);

        for (uint256 i = 1; i < 5; ++i) {
            assertApproxEqAbs(prices[0], prices[i], 1, "equal quantities must produce equal prices");
        }
    }

    /*//////////////////////////////////////////////////////////////
                      getPrice() — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    /// @dev Out-of-bounds index must revert
    function test_getPrice_reverts_invalid_index() public {
        uint256[] memory q = _binary(100e18, 100e18);
        vm.expectRevert(LSMath.InvalidOutcomeIndex.selector);
        h.getPrice(q, 2, ALPHA_5); // index 2 is out of bounds for length-2 array
    }

    /// @dev Invalid alpha propagates through getPrice
    function test_getPrice_reverts_invalid_alpha() public {
        uint256[] memory q = _binary(100e18, 100e18);
        vm.expectRevert(LSMath.InvalidAlpha.selector);
        h.getPrice(q, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                getAllPrices() — NUMERICAL STABILITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Large 80-outcome market must not overflow in getAllPrices.
    ///      The developer noted getAllPrices was missing the Log-Sum-Exp stabilization
    ///      that costFunction had — this test validates the fix is in place.
    function test_getAllPrices_large_market_no_overflow() public view {
        uint256[] memory q = _uniform(80, 1e30);
        uint256[] memory prices = h.getAllPrices(q, ALPHA_5);

        assertEq(prices.length, 80, "should return 80 prices");
        // All prices positive
        for (uint256 i; i < 80; ++i) {
            assertGt(prices[i], 0, "every price must be positive in large market");
        }
    }

    /// @dev Highly imbalanced market: dominant outcome gets much higher price
    function test_getAllPrices_imbalanced_dominant_gets_higher_price() public view {
        uint256[] memory q = new uint256[](3);
        q[0] = 1e28; // dominant
        q[1] = 1e18;
        q[2] = 1e18;

        uint256[] memory prices = h.getAllPrices(q, ALPHA_5);

        assertGt(prices[0], prices[1], "dominant outcome must have highest price");
        assertGt(prices[0], prices[2], "dominant outcome must have highest price");
    }

    /*//////////////////////////////////////////////////////////////
                       sumOfPrices() — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Theory (Section 4.2): Σpi(q) > 1 always (market maker's edge)
    function test_sumOfPrices_always_greater_than_one() public view {
        uint256[] memory q = _binary(100e18, 100e18);
        uint256 sum = h.sumOfPrices(q, ALPHA_5);
        assertGt(sum, SCALE, "sum of prices must exceed 1");
    }

    /// @dev Upper bound: Σpi(q) ≤ 1 + alpha * n * ln(n)
    ///      For n=2, alpha=5%, ln(2)≈0.693: upper ≈ 1 + 0.05 * 2 * 0.693 ≈ 1.0693
    ///      Test that the sum is reasonably bounded (within 2x the upper bound as sanity check)
    function test_sumOfPrices_within_theoretical_upper_bound() public view {
        uint256 alpha = ALPHA_5;
        uint256[] memory q = _binary(100e18, 100e18); // equal → approaching upper bound

        uint256 sum = h.sumOfPrices(q, alpha);
        uint256 lnN = 693147180559945309; // ln(2)
        uint256 n   = 2;
        // upper = 1 + alpha * n * ln(n) / SCALE / SCALE
        uint256 upper = SCALE + (alpha * n * lnN) / SCALE;

        // Allow 1 % tolerance above upper bound for rounding
        uint256 tolerance = upper / 100;
        assertLe(sum, upper + tolerance, "sum must be <= theoretical upper bound (with tolerance)");
    }

    /// @dev Sum increases with alpha (higher commission = bigger spread above 1)
    function test_sumOfPrices_increases_with_alpha() public view {
        uint256[] memory q = _binary(100e18, 100e18);
        uint256 sum5  = h.sumOfPrices(q, ALPHA_5);
        uint256 sum10 = h.sumOfPrices(q, ALPHA_10);
        assertGt(sum10, sum5, "higher alpha must produce larger price sum");
    }

    /// @dev Sum is consistent with sum of individual getAllPrices results
    function test_sumOfPrices_consistent_with_getAllPrices() public view {
        uint256[] memory q = _binary(80e18, 120e18);
        uint256[] memory prices = h.getAllPrices(q, ALPHA_5);
        uint256 manualSum = prices[0] + prices[1];
        uint256 libSum    = h.sumOfPrices(q, ALPHA_5);

        assertEq(libSum, manualSum, "sumOfPrices must match manual sum of getAllPrices");
    }

    /*//////////////////////////////////////////////////////////////
                    PRICING — FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev For any valid symmetric binary market, prices must be equal
    function testFuzz_prices_symmetric_equal(uint256 qty, uint256 alpha) public view {
        qty   = bound(qty,   1e15,  1e32);
        alpha = bound(alpha, 5e16, 2e17); // 5–20 %

        uint256[] memory q = _binary(qty, qty);
        uint256[] memory prices = h.getAllPrices(q, alpha);

        assertApproxEqAbs(prices[0], prices[1], 2, "symmetric market must have equal prices");
    }

    /// @dev For any valid market, sum of prices must be > 1
    function testFuzz_sumOfPrices_always_above_one(
        uint256 q0,
        uint256 q1,
        uint256 alpha
    ) public view {
        alpha = bound(alpha, 5e16, 2e17);
        q0    = bound(q0, 1e15,  1e28);
        q1    = bound(q1, 1e15,  1e28);

        uint256[] memory q = _binary(q0, q1);
        uint256 sum = h.sumOfPrices(q, alpha);
        assertGt(sum, SCALE, "sumOfPrices must always exceed 1");
    }

    /// @dev C(q) >= max(qi) for any valid binary market (Lemma 4.5)
    function testFuzz_costFunction_lower_bound(
        uint256 q0,
        uint256 q1,
        uint256 alpha
    ) public view {
        alpha = bound(alpha, 5e16, 2e17);
        q0    = bound(q0, 1e15, 1e28);
        q1    = bound(q1, 1e15, 1e28);

        uint256[] memory q = _binary(q0, q1);
        uint256 cost = h.costFunction(q, alpha);
        uint256 maxQ = q0 > q1 ? q0 : q1;

        assertGe(cost, maxQ, "C(q) must be >= max(qi) (Lemma 4.5)");
    }
}
