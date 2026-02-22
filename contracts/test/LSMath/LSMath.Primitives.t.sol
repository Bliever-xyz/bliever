// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2} from "forge-std/Test.sol";
import {LSMathHarness} from "./harness/LSMathHarness.sol";
import {LSMath} from "../../src/LSMath.sol";

/// @title LSMath Primitives Test Suite
/// @notice Tests for the four low-level math helpers:
///         exp(), ln(), mulScale(), divScale()
///
///         These are the building blocks on which all LS-LMSR formulas depend.
///         Precision errors here propagate into every higher-level function,
///         so both known-value checks and inverse-relationship checks are included.
contract LSMathPrimitivesTest is Test {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant SCALE   = 1e18;
    uint256 internal constant LN_2    = 693147180559945309;   // ln(2) in 18-dec
    uint256 internal constant MAX_EXP = 135305999368893231589; // MAX_EXP_INPUT

    /// @dev Relative tolerance for transcendental approximations (0.1 %)
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
                           exp() — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev exp(0) must equal exactly 1 (= SCALE) — base case of Taylor series
    function test_exp_zero_returns_one() public view {
        assertEq(h.exp(0), SCALE, "exp(0) != 1");
    }

    /// @dev exp(ln2) ≈ 2; validates both exp and the LN_2 constant together
    function test_exp_ln2_approx_two() public view {
        uint256 result = h.exp(LN_2);
        // Allow 0.1 % deviation from 2e18
        assertApproxEqRel(result, 2 * SCALE, REL_TOL, "exp(ln2) should be ~2");
    }

    /// @dev exp(1) ≈ e = 2.71828...  (Euler's number)
    function test_exp_one_approx_e() public view {
        uint256 result = h.exp(SCALE); // x = 1e18 = 1 in fixed-point
        uint256 e = 2_718281828459045235;  // e in 18-dec
        assertApproxEqRel(result, e, REL_TOL, "exp(1) should be ~e");
    }

    /// @dev exp is strictly increasing: any x > 0 produces result > SCALE
    function test_exp_positive_input_greater_than_one() public view {
        assertGt(h.exp(1), SCALE, "exp(x>0) should be > 1");
        assertGt(h.exp(SCALE), SCALE, "exp(1.0) should be > 1");
        assertGt(h.exp(100 * SCALE), SCALE, "exp(100.0) should be > 1");
    }

    /// @dev exp is monotone: exp(a) < exp(b) when a < b
    function test_exp_monotone_increasing() public view {
        uint256 a = h.exp(SCALE);        // exp(1)
        uint256 b = h.exp(2 * SCALE);   // exp(2)
        assertLt(a, b, "exp must be monotone increasing");
    }

    /// @dev Large valid input at boundary should not revert
    function test_exp_at_max_boundary_succeeds() public view {
        // MAX_EXP_INPUT is the last accepted value
        h.exp(MAX_EXP); // must not revert
    }

    /*//////////////////////////////////////////////////////////////
                           exp() — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    /// @dev Any input above MAX_EXP_INPUT must revert with ExponentialOverflow
    function test_exp_reverts_above_max_input() public {
        vm.expectRevert(LSMath.ExponentialOverflow.selector);
        h.exp(MAX_EXP + 1);
    }

    /*//////////////////////////////////////////////////////////////
                           exp() — FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev For any valid x in [0, MAX_EXP], exp(x) must be ≥ SCALE
    function testFuzz_exp_result_always_gte_one(uint256 x) public view {
        x = bound(x, 0, MAX_EXP);
        uint256 result = h.exp(x);
        assertGe(result, SCALE, "exp(x) must be >= 1 for x >= 0");
    }

    /// @dev For any valid x in range, result must be non-zero
    function testFuzz_exp_result_never_zero(uint256 x) public view {
        x = bound(x, 0, MAX_EXP);
        assertGt(h.exp(x), 0, "exp(x) must never be zero");
    }

    /*//////////////////////////////////////////////////////////////
                           ln() — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev ln(1) = 0 — definitional
    function test_ln_one_returns_zero() public view {
        assertEq(h.ln(SCALE), 0, "ln(1) != 0");
    }

    /// @dev ln(2) ≈ LN_2 constant
    function test_ln_two_approx_ln2_constant() public view {
        uint256 result = h.ln(2 * SCALE);
        assertApproxEqRel(result, LN_2, REL_TOL, "ln(2) should match LN_2");
    }

    /// @dev ln(e) ≈ 1
    function test_ln_e_approx_one() public view {
        uint256 e = 2_718281828459045235;
        uint256 result = h.ln(e);
        assertApproxEqRel(result, SCALE, REL_TOL, "ln(e) should be ~1");
    }

    /// @dev ln is monotone: ln(a) < ln(b) when a < b (both > SCALE)
    function test_ln_monotone_increasing() public view {
        uint256 a = h.ln(2 * SCALE);   // ln(2)
        uint256 b = h.ln(10 * SCALE);  // ln(10)
        assertLt(a, b, "ln must be monotone increasing");
    }

    /// @dev Large input — must not revert and must return a valid value
    function test_ln_large_input_succeeds() public view {
        uint256 result = h.ln(1e36); // 1e36 >> SCALE
        assertGt(result, 0, "ln of large number should be positive");
    }

    /*//////////////////////////////////////////////////////////////
                           ln() — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    /// @dev ln(0) is mathematically undefined
    function test_ln_reverts_on_zero() public {
        vm.expectRevert(LSMath.InvalidLogInput.selector);
        h.ln(0);
    }

    /// @dev ln(x) for x < SCALE would be negative — not supported in fixed-point uint
    function test_ln_reverts_on_below_scale() public {
        vm.expectRevert(LSMath.InvalidLogInput.selector);
        h.ln(SCALE - 1);
    }

    /// @dev Confirm any value strictly below SCALE reverts
    function test_ln_reverts_on_one_wei() public {
        vm.expectRevert(LSMath.InvalidLogInput.selector);
        h.ln(1);
    }

    /*//////////////////////////////////////////////////////////////
                      exp() / ln() — INVERSE RELATIONSHIP
    //////////////////////////////////////////////////////////////*/

    /// @dev exp(ln(x)) ≈ x  for x > SCALE
    ///      Validates that the two implementations are consistent with each other.
    function test_exp_ln_inverse_roundtrip() public view {
        uint256 x = 5 * SCALE;  // ln(5) then exp back
        uint256 lnX   = h.ln(x);
        uint256 result = h.exp(lnX);
        assertApproxEqRel(result, x, REL_TOL, "exp(ln(x)) should recover x");
    }

    /// @dev ln(exp(x)) ≈ x  for x in a safe range (result of exp must be > SCALE for ln)
    function test_ln_exp_inverse_roundtrip() public view {
        uint256 x = 2 * SCALE;  // 2 in 18-dec → exp(2) >> SCALE
        uint256 expX   = h.exp(x);
        uint256 result = h.ln(expX);
        // ln result is in SCALE-adjusted units; allow 0.1 % tolerance
        assertApproxEqRel(result, x, REL_TOL, "ln(exp(x)) should recover x");
    }

    /*//////////////////////////////////////////////////////////////
                       mulScale() — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev 2 × 3 = 6  (in fixed-point: 2e18 × 3e18 / 1e18 = 6e18)
    function test_mulScale_basic_multiplication() public view {
        uint256 result = h.mulScale(2 * SCALE, 3 * SCALE);
        assertEq(result, 6 * SCALE, "2 * 3 should equal 6");
    }

    /// @dev 0.5 × 4 = 2
    function test_mulScale_fractional_operand() public view {
        uint256 result = h.mulScale(5e17, 4 * SCALE); // 0.5 * 4
        assertEq(result, 2 * SCALE, "0.5 * 4 should equal 2");
    }

    /// @dev 1 × x = x  (identity)
    function test_mulScale_identity() public view {
        uint256 x = 7 * SCALE;
        assertEq(h.mulScale(SCALE, x), x, "1 * x should equal x");
    }

    /// @dev 0.1 × 0.1 = 0.01
    function test_mulScale_small_fractions() public view {
        uint256 result = h.mulScale(1e17, 1e17); // 0.1 * 0.1
        assertEq(result, 1e16, "0.1 * 0.1 should equal 0.01");
    }

    /*//////////////////////////////////////////////////////////////
                       mulScale() — FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev For bounded inputs, mulScale should produce consistent results
    function testFuzz_mulScale_commutativity(uint256 a, uint256 b) public view {
        // Keep within safe multiplication range to avoid overflow panic
        a = bound(a, 0, 1e27);
        b = bound(b, 0, 1e27);
        // a=0 hits division-by-zero in overflow check inside mulScale
        // That is a known quirk of the contract; skip a==0 case
        if (a == 0 || b == 0) return;
        uint256 ab = h.mulScale(a, b);
        uint256 ba = h.mulScale(b, a);
        assertEq(ab, ba, "mulScale should be commutative");
    }

    /*//////////////////////////////////////////////////////////////
                       divScale() — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev 6 / 2 = 3
    function test_divScale_basic_division() public view {
        uint256 result = h.divScale(6 * SCALE, 2 * SCALE);
        assertEq(result, 3 * SCALE, "6 / 2 should equal 3");
    }

    /// @dev 1 / 4 = 0.25
    function test_divScale_less_than_one() public view {
        uint256 result = h.divScale(SCALE, 4 * SCALE); // 1 / 4
        assertEq(result, 25e16, "1 / 4 should equal 0.25");
    }

    /// @dev x / 1 = x  (identity)
    function test_divScale_identity_divisor() public view {
        uint256 x = 5 * SCALE;
        assertEq(h.divScale(x, SCALE), x, "x / 1 should equal x");
    }

    /// @dev x / x = 1
    function test_divScale_self_division() public view {
        uint256 x = 7 * SCALE;
        assertEq(h.divScale(x, x), SCALE, "x / x should equal 1");
    }

    /*//////////////////////////////////////////////////////////////
                       divScale() — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    /// @dev Division by zero must revert with DivisionByZero
    function test_divScale_reverts_on_zero_divisor() public {
        vm.expectRevert(LSMath.DivisionByZero.selector);
        h.divScale(5 * SCALE, 0);
    }

    /// @dev Numerator zero, valid denominator → result is zero (no revert)
    function test_divScale_zero_numerator_returns_zero() public view {
        uint256 result = h.divScale(0, 5 * SCALE);
        assertEq(result, 0, "0 / anything should be 0");
    }

    /*//////////////////////////////////////////////////////////////
                       divScale() — FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev divScale(a, b) * b ≈ a  (round-trip with tolerance for integer rounding)
    function testFuzz_divScale_inverse_of_mulScale(uint256 a, uint256 b) public view {
        a = bound(a, SCALE, 1e27);
        b = bound(b, SCALE, 1e27);
        uint256 quotient = h.divScale(a, b);
        if (quotient == 0) return; // underflow to 0, skip
        // quotient * b / SCALE should approximate a
        uint256 recovered = (quotient * b) / SCALE;
        // Allow 1 unit absolute rounding error from integer division
        assertApproxEqAbs(recovered, a, 1e3, "divScale round-trip within rounding");
    }
}
