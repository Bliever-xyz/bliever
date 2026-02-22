// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2} from "forge-std/Test.sol";
import {LSMathHarness} from "./harness/LSMathHarness.sol";
import {LSMath} from "../../src/LSMath.sol";

/// @title LSMath Liquidity Parameter Test Suite
/// @notice Tests for liquidityParameter(), validateAlpha(), and validateQuantities().
///
///         liquidityParameter() is the entry-point calculation that every higher-level
///         function depends on: b(q) = α × Σqi.  Getting it wrong — especially the
///         overflow guard and alpha bounds — would corrupt all downstream pricing.
///
///         Validation helpers are also tested here because they share the same
///         input-domain logic (alpha bounds, array size limits, non-zero sums).
contract LSMathLiquidityParameterTest is Test {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant SCALE       = 1e18;
    uint256 internal constant MAX_ALPHA   = 2e17;   // 0.2
    uint256 internal constant MIN_ALPHA   = 1e12;   // 0.000001
    uint256 internal constant MAX_OUTCOMES = 100;

    /// @dev Standard 5 % alpha used in most tests
    uint256 internal constant ALPHA_5PCT = 5e16;

    /*//////////////////////////////////////////////////////////////
                            STATE & SETUP
    //////////////////////////////////////////////////////////////*/

    LSMathHarness internal h;

    function setUp() public {
        h = new LSMathHarness();
        vm.label(address(h), "LSMathHarness");
    }

    /*//////////////////////////////////////////////////////////////
                   HELPERS — reusable quantity arrays
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
                  liquidityParameter() — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Symmetric binary market: sumQ = 200e18, b = 0.05 × 200e18 / 1e18 = 10e18
    function test_liquidityParameter_symmetric_binary() public view {
        uint256[] memory q = _binary(100e18, 100e18);
        (uint256 b, uint256 sumQ) = h.liquidityParameter(q, ALPHA_5PCT);

        assertEq(sumQ, 200e18, "sumQ should be sum of quantities");
        assertEq(b, 10e18,    "b should be alpha * sumQ / SCALE");
    }

    /// @dev Asymmetric binary: sumQ = 300e18, b = 0.05 × 300 = 15e18
    function test_liquidityParameter_asymmetric_binary() public view {
        uint256[] memory q = _binary(200e18, 100e18);
        (uint256 b, uint256 sumQ) = h.liquidityParameter(q, ALPHA_5PCT);

        assertEq(sumQ, 300e18, "sumQ should be 300e18");
        assertEq(b, 15e18,    "b should be 15e18");
    }

    /// @dev Formula check for arbitrary alpha: b = (alpha * sumQ) / SCALE
    function test_liquidityParameter_formula_invariant() public view {
        uint256 alpha  = 1e17; // 10 %
        uint256[] memory q = _binary(50e18, 50e18);
        (uint256 b, uint256 sumQ) = h.liquidityParameter(q, alpha);

        uint256 expected = (alpha * sumQ) / SCALE;
        assertEq(b, expected, "b must equal (alpha * sumQ) / SCALE");
    }

    /// @dev Minimum valid alpha still produces a non-zero b
    function test_liquidityParameter_min_alpha() public view {
        uint256[] memory q = _binary(1e18, 1e18);
        (uint256 b,) = h.liquidityParameter(q, MIN_ALPHA);
        assertGt(b, 0, "b must be non-zero at MIN_ALPHA");
    }

    /// @dev Maximum valid alpha (20 %) still succeeds
    function test_liquidityParameter_max_alpha() public view {
        uint256[] memory q = _binary(100e18, 100e18);
        (uint256 b,) = h.liquidityParameter(q, MAX_ALPHA);
        assertEq(b, 40e18, "b = 0.2 * 200e18 / 1e18 = 40e18");
    }

    /// @dev Multi-outcome (5-way market) — sum across all outcomes
    function test_liquidityParameter_five_outcomes() public view {
        uint256[] memory q = _uniform(5, 20e18); // 5 × 20 = 100
        (uint256 b, uint256 sumQ) = h.liquidityParameter(q, ALPHA_5PCT);

        assertEq(sumQ, 100e18, "sumQ should be 100e18");
        assertEq(b, 5e18,     "b = 0.05 * 100 = 5");
    }

    /// @dev b scales linearly with alpha (b proportional to alpha)
    function test_liquidityParameter_scales_with_alpha() public view {
        uint256[] memory q = _binary(100e18, 100e18);
        (uint256 b1,) = h.liquidityParameter(q, 5e16);   // 5 %
        (uint256 b2,) = h.liquidityParameter(q, 1e17);   // 10 % = 2×

        assertEq(b2, 2 * b1, "b should double when alpha doubles");
    }

    /// @dev b scales linearly with quantity (b proportional to Σqi)
    function test_liquidityParameter_scales_with_quantity() public view {
        uint256[] memory q1 = _binary(100e18, 100e18);   // sumQ = 200
        uint256[] memory q2 = _binary(200e18, 200e18);   // sumQ = 400

        (uint256 b1,) = h.liquidityParameter(q1, ALPHA_5PCT);
        (uint256 b2,) = h.liquidityParameter(q2, ALPHA_5PCT);

        assertEq(b2, 2 * b1, "b should double when all quantities double");
    }

    /*//////////////////////////////////////////////////////////////
                  liquidityParameter() — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    /// @dev Alpha below minimum → InvalidAlpha
    function test_liquidityParameter_reverts_alpha_below_min() public {
        uint256[] memory q = _binary(1e18, 1e18);
        vm.expectRevert(LSMath.InvalidAlpha.selector);
        h.liquidityParameter(q, MIN_ALPHA - 1);
    }

    /// @dev Alpha = 0 → InvalidAlpha
    function test_liquidityParameter_reverts_alpha_zero() public {
        uint256[] memory q = _binary(1e18, 1e18);
        vm.expectRevert(LSMath.InvalidAlpha.selector);
        h.liquidityParameter(q, 0);
    }

    /// @dev Alpha above maximum → InvalidAlpha
    function test_liquidityParameter_reverts_alpha_above_max() public {
        uint256[] memory q = _binary(1e18, 1e18);
        vm.expectRevert(LSMath.InvalidAlpha.selector);
        h.liquidityParameter(q, MAX_ALPHA + 1);
    }

    /// @dev Empty quantities array → EmptyQuantities
    function test_liquidityParameter_reverts_empty_array() public {
        uint256[] memory q = new uint256[](0);
        vm.expectRevert(LSMath.EmptyQuantities.selector);
        h.liquidityParameter(q, ALPHA_5PCT);
    }

    /// @dev Array length > MAX_OUTCOMES (100) → InvalidOutcomeIndex
    function test_liquidityParameter_reverts_array_too_large() public {
        uint256[] memory q = _uniform(101, 1e18);
        vm.expectRevert(LSMath.InvalidOutcomeIndex.selector);
        h.liquidityParameter(q, ALPHA_5PCT);
    }

    /// @dev All quantities zero → ZeroQuantitySum
    function test_liquidityParameter_reverts_all_zeros() public {
        uint256[] memory q = _binary(0, 0);
        vm.expectRevert(LSMath.ZeroQuantitySum.selector);
        h.liquidityParameter(q, ALPHA_5PCT);
    }

    /// @dev One non-zero outcome is enough to proceed
    function test_liquidityParameter_one_nonzero_quantity() public view {
        uint256[] memory q = _binary(0, 100e18);
        (uint256 b, uint256 sumQ) = h.liquidityParameter(q, ALPHA_5PCT);

        assertEq(sumQ, 100e18, "sumQ should count non-zero quantity");
        assertGt(b, 0,         "b should be non-zero");
    }

    /*//////////////////////////////////////////////////////////////
                  liquidityParameter() — FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev For any two valid quantities and any valid alpha,
    ///      b must always equal (alpha * sumQ) / SCALE  (invariant)
    function testFuzz_liquidityParameter_formula_holds(
        uint256 q0,
        uint256 q1,
        uint256 alpha
    ) public view {
        alpha = bound(alpha, MIN_ALPHA, MAX_ALPHA);
        // Keep sum comfortably below uint256 max to avoid overflow
        q0    = bound(q0, 0, 1e36);
        q1    = bound(q1, 1, 1e36); // at least 1 to avoid ZeroQuantitySum

        // Also ensure alpha * sumQ doesn't produce b = 0 after SCALE division
        // (very tiny q values could round b to 0)
        if (q0 + q1 < SCALE / alpha) return; // b would round to 0

        uint256[] memory q = _binary(q0, q1);
        (uint256 b, uint256 sumQ) = h.liquidityParameter(q, alpha);

        assertEq(sumQ, q0 + q1,         "sumQ must equal q0 + q1");
        assertEq(b, (alpha * sumQ) / SCALE, "b must equal alpha * sumQ / SCALE");
    }

    /*//////////////////////////////////////////////////////////////
                      validateAlpha() — TESTS
    //////////////////////////////////////////////////////////////*/

    function test_validateAlpha_returns_true_for_valid_alpha() public view {
        assertTrue(h.validateAlpha(ALPHA_5PCT),  "5 % should be valid");
        assertTrue(h.validateAlpha(MIN_ALPHA),    "MIN_ALPHA should be valid");
        assertTrue(h.validateAlpha(MAX_ALPHA),    "MAX_ALPHA should be valid");
        assertTrue(h.validateAlpha(1e17),         "10 % should be valid");
    }

    function test_validateAlpha_returns_false_for_zero() public view {
        assertFalse(h.validateAlpha(0), "0 should be invalid");
    }

    function test_validateAlpha_returns_false_below_min() public view {
        assertFalse(h.validateAlpha(MIN_ALPHA - 1), "below MIN_ALPHA should be invalid");
    }

    function test_validateAlpha_returns_false_above_max() public view {
        assertFalse(h.validateAlpha(MAX_ALPHA + 1), "above MAX_ALPHA should be invalid");
    }

    function testFuzz_validateAlpha_consistent_with_liquidityParameter(
        uint256 alpha
    ) public {
        bool valid = h.validateAlpha(alpha);

        uint256[] memory q = _binary(1e18, 1e18);

        if (valid) {
            // liquidityParameter must succeed if validateAlpha passes
            h.liquidityParameter(q, alpha); // should not revert
        } else {
            // liquidityParameter must fail with InvalidAlpha
            vm.expectRevert(LSMath.InvalidAlpha.selector);
            h.liquidityParameter(q, alpha);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    validateQuantities() — TESTS
    //////////////////////////////////////////////////////////////*/

    function test_validateQuantities_valid_binary_market() public view {
        assertTrue(h.validateQuantities(_binary(100e18, 100e18)), "binary market should be valid");
    }

    function test_validateQuantities_valid_one_nonzero() public view {
        // Valid as long as sum > 0 and length >= 2
        uint256[] memory q = _binary(0, 100e18);
        assertTrue(h.validateQuantities(q), "one nonzero outcome is sufficient");
    }

    function test_validateQuantities_invalid_single_element() public view {
        uint256[] memory q = new uint256[](1);
        q[0] = 100e18;
        assertFalse(h.validateQuantities(q), "single outcome is invalid (need >= 2)");
    }

    function test_validateQuantities_invalid_empty_array() public view {
        uint256[] memory q = new uint256[](0);
        assertFalse(h.validateQuantities(q), "empty array is invalid");
    }

    function test_validateQuantities_invalid_all_zeros() public view {
        assertFalse(h.validateQuantities(_binary(0, 0)), "all-zero array is invalid");
    }

    function test_validateQuantities_invalid_exceeds_max_outcomes() public view {
        uint256[] memory q = _uniform(101, 1e18);
        assertFalse(h.validateQuantities(q), "array > 100 should be invalid");
    }

    function test_validateQuantities_valid_exactly_max_outcomes() public view {
        uint256[] memory q = _uniform(MAX_OUTCOMES, 1e18);
        assertTrue(h.validateQuantities(q), "array of exactly 100 should be valid");
    }

    function test_validateQuantities_valid_multi_outcome() public view {
        uint256[] memory q = _uniform(10, 50e18);
        assertTrue(h.validateQuantities(q), "10-outcome market should be valid");
    }
}
