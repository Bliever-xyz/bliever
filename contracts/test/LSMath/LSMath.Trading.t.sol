// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2} from "forge-std/Test.sol";
import {LSMathHarness} from "./harness/LSMathHarness.sol";
import {LSMath} from "../../src/LSMath.sol";

/// @title LSMath Trading & Utility Test Suite
/// @notice Tests for:
///         - calculateTradeCost()        — cost to move market state from q0 to q1
///         - calculateWorstCaseLoss()    — maximum possible loss for the market maker
///         - hasOutcomeIndependentProfit() — whether MM has guaranteed profit
///
///         These are the "business logic" layer above the raw math. They combine
///         costFunction() results into meaningful market-maker risk metrics.
contract LSMathTradingTest is Test {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant SCALE   = 1e18;
    uint256 internal constant ALPHA_5 = 5e16;   // 5 %

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

    /// @dev Clone a quantity array and increase one outcome by `amount`
    function _buy(
        uint256[] memory q,
        uint256 index,
        uint256 amount
    ) internal pure returns (uint256[] memory qNew) {
        qNew = new uint256[](q.length);
        for (uint256 i; i < q.length; ++i) qNew[i] = q[i];
        qNew[index] += amount;
    }

    /*//////////////////////////////////////////////////////////////
                    calculateTradeCost() — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Buying shares (increasing qi) must have a positive cost
    ///      i.e., the trader must PAY the market maker
    function test_calculateTradeCost_buying_is_positive() public view {
        uint256[] memory qBefore = _binary(100e18, 100e18);
        uint256[] memory qAfter  = _buy(qBefore, 0, 50e18); // buy 50 of outcome 0

        int256 cost = h.calculateTradeCost(qBefore, qAfter, ALPHA_5);

        assertGt(cost, 0, "buying shares must have positive cost");
        console2.log("trade cost (buy 50):", cost);
    }

    /// @dev Zero trade (same state before and after) → cost = 0
    function test_calculateTradeCost_zero_trade_zero_cost() public view {
        uint256[] memory q = _binary(100e18, 100e18);
        int256 cost = h.calculateTradeCost(q, q, ALPHA_5);
        assertEq(cost, 0, "zero trade should have zero cost");
    }

    /// @dev Buying more shares costs more (monotonicity: larger trade = higher cost)
    function test_calculateTradeCost_larger_buy_costs_more() public view {
        uint256[] memory q = _binary(100e18, 100e18);

        int256 cost10 = h.calculateTradeCost(q, _buy(q, 0, 10e18), ALPHA_5);
        int256 cost50 = h.calculateTradeCost(q, _buy(q, 0, 50e18), ALPHA_5);

        assertGt(cost50, cost10, "larger purchase must cost more");
    }

    /// @dev "Selling" (reducing qi) should produce a negative cost
    ///      i.e., the market maker pays the seller
    ///      Here we simulate by swapping qBefore/qAfter
    function test_calculateTradeCost_selling_is_negative() public view {
        uint256[] memory qSmall = _binary(100e18, 100e18);
        uint256[] memory qLarge = _buy(qSmall, 0, 50e18); // pretend we had more

        // Selling: moving from qLarge back to qSmall
        int256 cost = h.calculateTradeCost(qLarge, qSmall, ALPHA_5);

        assertLt(cost, 0, "selling shares should return negative cost (MM pays seller)");
    }

    /// @dev Cost is antisymmetric: buy cost + sell cost for same trade ≈ 0
    ///      (not exactly 0 because LS-LMSR is path-dependent with variable b)
    ///      But we can at least verify the signs flip.
    function test_calculateTradeCost_buy_sell_sign_flip() public view {
        uint256[] memory qBefore = _binary(100e18, 100e18);
        uint256[] memory qAfter  = _buy(qBefore, 0, 50e18);

        int256 buyCost  = h.calculateTradeCost(qBefore, qAfter,  ALPHA_5);
        int256 sellCost = h.calculateTradeCost(qAfter,  qBefore, ALPHA_5);

        assertGt(buyCost,  0, "buy cost must be positive");
        assertLt(sellCost, 0, "sell cost must be negative");
    }

    /// @dev Multi-outcome market trade cost is positive when buying
    function test_calculateTradeCost_multi_outcome_buying() public view {
        uint256[] memory q = _uniform(5, 50e18);
        uint256[] memory qNew = _buy(q, 2, 20e18); // buy outcome 2

        int256 cost = h.calculateTradeCost(q, qNew, ALPHA_5);
        assertGt(cost, 0, "multi-outcome buy must have positive cost");
    }

    /*//////////////////////////////////////////////////////////////
                  calculateTradeCost() — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    /// @dev Mismatched array lengths must revert
    function test_calculateTradeCost_reverts_length_mismatch() public {
        uint256[] memory q2 = _binary(100e18, 100e18);
        uint256[] memory q3 = _uniform(3, 100e18);

        vm.expectRevert(LSMath.InvalidOutcomeIndex.selector);
        h.calculateTradeCost(q2, q3, ALPHA_5);
    }

    /// @dev Invalid alpha propagates
    function test_calculateTradeCost_reverts_invalid_alpha() public {
        uint256[] memory q = _binary(100e18, 100e18);
        vm.expectRevert(LSMath.InvalidAlpha.selector);
        h.calculateTradeCost(q, q, 0);
    }

    /*//////////////////////////////////////////////////////////////
              calculateTradeCost() — FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Buying any valid amount always increases cost (monotone trade)
    function testFuzz_calculateTradeCost_buying_always_positive(
        uint256 baseQty,
        uint256 tradeSize,
        uint256 alpha
    ) public view {
        alpha     = bound(alpha,     5e16,  2e17);
        baseQty   = bound(baseQty,   1e15,  1e26);
        tradeSize = bound(tradeSize, 1e12,  1e26);

        uint256[] memory qBefore = _binary(baseQty, baseQty);
        uint256[] memory qAfter  = _buy(qBefore, 0, tradeSize);

        int256 cost = h.calculateTradeCost(qBefore, qAfter, alpha);
        assertGt(cost, 0, "any buy trade must have positive cost");
    }

    /*//////////////////////////////////////////////////////////////
              calculateWorstCaseLoss() — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Worst-case loss is always non-negative
    ///      Formula: Loss = C(q0) - C(q) + max(qi)
    function test_calculateWorstCaseLoss_non_negative() public view {
        uint256[] memory q0 = _binary(100e18, 100e18);
        uint256[] memory q  = _binary(150e18, 100e18); // after trade

        uint256 loss = h.calculateWorstCaseLoss(q, q0, ALPHA_5);
        // Just verify it doesn't revert and returns a sensible value
        // Loss may be 0 if market maker is profitable
        console2.log("worst case loss:", loss);
        // Non-negative is guaranteed by uint256 return type and conditional in contract
    }

    /// @dev At initial state (q == q0), worst-case loss equals C(q0) itself
    ///      because: Loss = C(q0) - C(q0) + max(q0) = max(q0)
    ///      Wait actually at q==q0: cost(current) = cost(initial), so
    ///      if cost >= maxQ → loss = costInitial - (costCurrent - maxQ)
    ///      = costInitial - costInitial + maxQ = maxQ
    function test_calculateWorstCaseLoss_at_initial_state_equals_max_q() public view {
        uint256[] memory q0 = _binary(100e18, 100e18);
        uint256 loss = h.calculateWorstCaseLoss(q0, q0, ALPHA_5);
        // At q == q0: loss = max(qi) = 100e18 (when cost >= maxQ which it always is)
        assertEq(loss, 100e18, "at initial state, loss should equal max(qi)");
    }

    /// @dev Loss must be bounded — should not revert for normal market states
    function test_calculateWorstCaseLoss_no_revert_after_trade() public view {
        uint256[] memory q0 = _binary(100e18, 100e18);
        uint256[] memory q  = _buy(q0, 0, 50e18);

        // Should not revert; value itself depends on market dynamics
        h.calculateWorstCaseLoss(q, q0, ALPHA_5);
    }

    /*//////////////////////////////////////////////////////////////
              calculateWorstCaseLoss() — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    /// @dev Empty current quantities → EmptyQuantities
    function test_calculateWorstCaseLoss_reverts_empty_current() public {
        uint256[] memory empty = new uint256[](0);
        uint256[] memory q0    = _binary(100e18, 100e18);

        vm.expectRevert(LSMath.EmptyQuantities.selector);
        h.calculateWorstCaseLoss(empty, q0, ALPHA_5);
    }

    /// @dev Empty initial quantities → EmptyQuantities
    function test_calculateWorstCaseLoss_reverts_empty_initial() public {
        uint256[] memory q     = _binary(100e18, 100e18);
        uint256[] memory empty = new uint256[](0);

        vm.expectRevert(LSMath.EmptyQuantities.selector);
        h.calculateWorstCaseLoss(q, empty, ALPHA_5);
    }

    /// @dev Mismatched array lengths → ArrayLengthMismatch
    function test_calculateWorstCaseLoss_reverts_length_mismatch() public {
        uint256[] memory q2 = _binary(100e18, 100e18);
        uint256[] memory q3 = _uniform(3, 100e18);

        vm.expectRevert(LSMath.ArrayLengthMismatch.selector);
        h.calculateWorstCaseLoss(q2, q3, ALPHA_5);
    }

    /*//////////////////////////////////////////////////////////////
           hasOutcomeIndependentProfit() — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev At the initial state (q == q0), revenue = C(q) - max(q) - C(q0)
    ///      = C(q0) - max(q0) - C(q0) = -max(q0) < 0 → no profit initially
    function test_hasOutcomeIndependentProfit_no_profit_at_initial_state() public view {
        uint256[] memory q0 = _binary(100e18, 100e18);
        (bool hasProfit, uint256 profit) = h.hasOutcomeIndependentProfit(q0, q0, ALPHA_5);

        assertFalse(hasProfit, "MM should not have guaranteed profit at initial state");
        assertEq(profit, 0,     "profit must be 0 when hasProfit is false");
    }

    /// @dev After many trades (accumulated fees), check profit status
    ///      This is a smoke test — exact behavior depends on market volume
    function test_hasOutcomeIndependentProfit_after_large_volume() public view {
        uint256[] memory q0 = _binary(100e18, 100e18);
        // Simulate market where a lot of volume has flowed in
        uint256[] memory qCurrent = _binary(1000e18, 1000e18);

        (bool hasProfit, uint256 profit) = h.hasOutcomeIndependentProfit(qCurrent, q0, ALPHA_5);

        console2.log("hasProfit after volume:", hasProfit);
        console2.log("profit amount:", profit);

        // If no profit, profit must be 0
        if (!hasProfit) {
            assertEq(profit, 0, "profit must be 0 when hasProfit is false");
        } else {
            assertGt(profit, 0, "profit must be positive when hasProfit is true");
        }
    }

    /// @dev profit is 0 whenever hasProfit is false — always consistent
    function test_hasOutcomeIndependentProfit_consistency() public view {
        uint256[] memory q0 = _binary(100e18, 100e18);
        uint256[] memory q  = _binary(150e18, 100e18);

        (bool hasProfit, uint256 profit) = h.hasOutcomeIndependentProfit(q, q0, ALPHA_5);

        if (!hasProfit) {
            assertEq(profit, 0, "profit must be 0 when hasProfit is false");
        } else {
            assertGt(profit, 0, "profit must be > 0 when hasProfit is true");
        }
    }

    /*//////////////////////////////////////////////////////////////
           hasOutcomeIndependentProfit() — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    /// @dev Empty current quantities → EmptyQuantities
    function test_hasOutcomeIndependentProfit_reverts_empty_current() public {
        uint256[] memory empty = new uint256[](0);
        uint256[] memory q0    = _binary(100e18, 100e18);

        vm.expectRevert(LSMath.EmptyQuantities.selector);
        h.hasOutcomeIndependentProfit(empty, q0, ALPHA_5);
    }

    /// @dev Mismatched lengths → ArrayLengthMismatch
    function test_hasOutcomeIndependentProfit_reverts_length_mismatch() public {
        uint256[] memory q2 = _binary(100e18, 100e18);
        uint256[] memory q3 = _uniform(3, 100e18);

        vm.expectRevert(LSMath.ArrayLengthMismatch.selector);
        h.hasOutcomeIndependentProfit(q2, q3, ALPHA_5);
    }

    /*//////////////////////////////////////////////////////////////
         hasOutcomeIndependentProfit() — FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev For any valid market state, the (hasProfit, profit) pair must be internally consistent
    function testFuzz_hasOutcomeIndependentProfit_consistent_return(
        uint256 q0Val,
        uint256 q1Val,
        uint256 alpha
    ) public view {
        alpha = bound(alpha, 5e16, 2e17);
        q0Val = bound(q0Val, 1e15, 1e26);
        q1Val = bound(q1Val, 1e15, 1e26);

        uint256[] memory q0 = _binary(q0Val, q0Val);    // initial
        uint256[] memory q  = _binary(q0Val + q1Val, q0Val); // after trade

        (bool hasProfit, uint256 profit) = h.hasOutcomeIndependentProfit(q, q0, alpha);

        if (hasProfit) {
            assertGt(profit, 0, "hasProfit=true must have profit > 0");
        } else {
            assertEq(profit, 0, "hasProfit=false must have profit == 0");
        }
    }
}
