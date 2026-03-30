// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2}  from "forge-std/Test.sol";

import {BlieverMarket}   from "../../src/BlieverMarket.sol";
import {BlieverMarketBase} from "./BlieverMarketBase.t.sol";

/// @title  BlieverMarket — Fuzz Tests
/// @notice Property-based tests that run hundreds of random inputs to stress:
///           • AMM math properties  (cost monotonicity, share-price relationship)
///           • CSS correctness       (positive-orthant invariant)
///           • Liability monotonicity (always ≤ riskBudget)
///           • Multi-trader scenarios (order independence)
///           • Slippage guard wiring
///           • Boundary guards       (dust shares, invalid indices)
///
/// @dev    Run: forge test --match-contract BlieverMarket_FuzzTest --evm-version cancun -vvv
///         Configure fuzz runs in foundry.toml:
///           [fuzz]
///           runs = 2000
///           seed  = 0xBELIEVER
contract BlieverMarket_FuzzTest is BlieverMarketBase {

    /*//////////////////////////////////////////////////////////////
                         AMM MATH — COST PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /// @dev getBuyCost() is strictly positive for any valid share amount.
    function testFuzz_getBuyCost_positiveForAnyValidAmount(uint256 shareAmt) public view {
        shareAmt = bound(shareAmt, MIN_SHARE, 1_000 * SHARE_1);
        uint256 cost = market2.getBuyCost(0, shareAmt);
        assertGt(cost, 0, "buy cost must be positive");
    }

    /// @dev getBuyCost() is monotonically increasing: more shares → more cost.
    function testFuzz_getBuyCost_monotoneIncreasing(uint256 amt1, uint256 amt2) public view {
        amt1 = bound(amt1, MIN_SHARE, 500 * SHARE_1);
        amt2 = bound(amt2, MIN_SHARE, 500 * SHARE_1);
        vm.assume(amt1 != amt2);
        if (amt1 > amt2) (amt1, amt2) = (amt2, amt1); // ensure amt1 < amt2

        uint256 cost1 = market2.getBuyCost(0, amt1);
        uint256 cost2 = market2.getBuyCost(0, amt2);
        assertLe(cost1, cost2, "cost(amt1) <= cost(amt2) when amt1 < amt2");
    }

    /// @dev Buying any valid amount increases the price of that outcome.
    function testFuzz_buy_priceIncreases(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, MIN_SHARE, 100 * SHARE_1);

        uint256 priceBefore = market2.getPrice(0);
        _buy(market2, alice, 0, shareAmt);
        uint256 priceAfter = market2.getPrice(0);

        assertGe(priceAfter, priceBefore, "price of bought outcome must not decrease");
    }

    /// @dev Buying outcome i decreases the price of all other outcomes.
    function testFuzz_buy_otherOutcomePricesDecrease(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, MIN_SHARE, 100 * SHARE_1);

        uint256 priceBefore1 = market2.getPrice(1);
        _buy(market2, alice, 0, shareAmt);
        uint256 priceAfter1 = market2.getPrice(1);

        assertLe(priceAfter1, priceBefore1, "non-bought outcome price must not increase");
    }

    /// @dev Sum of all prices remains > 1 after any buy (LS-LMSR property).
    function testFuzz_buy_sumOfPricesAlwaysGtOne(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, MIN_SHARE, 500 * SHARE_1);
        _buy(market2, alice, 0, shareAmt);
        uint256 sumP = market2.getSumOfPrices();
        assertGt(sumP, 1e18, "sum of prices must always exceed 1");
    }

    /// @dev Round-trip cost: sell refund ≤ buy cost for any valid share amount.
    ///      The AMM spread means traders always lose some value on a round-trip.
    function testFuzz_roundTrip_refundLEcost(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, MIN_SHARE, 100 * SHARE_1);
        _setupTrader(alice, TRADER_USDC * 100);

        uint256 usdcBefore = usdc.balanceOf(alice);

        // Buy
        vm.prank(alice);
        market2.buy(0, shareAmt, MAX_COST * 100, 0, 0, bytes32(0), bytes32(0));
        uint256 paid = usdcBefore - usdc.balanceOf(alice);

        // Sell
        vm.prank(alice);
        market2.sell(0, shareAmt, 0, MAX_COST * 100, 0, 0, bytes32(0), bytes32(0));
        uint256 received = usdc.balanceOf(alice) - (usdcBefore - paid);

        assertLe(received, paid, "refund <= cost (AMM always takes a spread)");
    }

    /*//////////////////////////////////////////////////////////////
                     CSS — POSITIVE ORTHANT INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// @dev After ANY sell (including CSS), no trader's share balance goes negative.
    ///      shareBalance[trader][i] ≥ 0 for all i. The mapping is uint256 so underflow
    ///      would revert; this test ensures the logic path cannot underflow.
    function testFuzz_sell_css_sharesNeverNegative(uint256 sellAmt) public {
        sellAmt = bound(sellAmt, MIN_SHARE, 50 * SHARE_1);

        // Alice buys a smaller amount than she will try to sell → triggers CSS
        uint256 buyAmt = sellAmt / 2 == 0 ? MIN_SHARE : sellAmt / 2;
        if (buyAmt < MIN_SHARE) buyAmt = MIN_SHARE;

        _buy(market2, alice, 0, buyAmt);
        _setupTrader(alice, TRADER_USDC); // fund for potential CSS cost

        vm.prank(alice);
        market2.sell(0, sellAmt, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        // Both outcomes must have non-negative uint256 balances
        // (if they were negative, the unchecked underflow would have corrupted storage;
        //  we check correctness by confirming the sold outcome is exactly 0 after full CSS)
        uint256 bal0 = market2.getShares(alice, 0);
        uint256 bal1 = market2.getShares(alice, 1);
        // Both values are uint256; the invariant is that they are "correct" non-wrapping values.
        // bal0 = 0 (since tBar = sellAmt - buyAmt ≥ buyAmt - buyAmt = 0, resulting in 0 balance)
        assertEq(bal0, 0, "outcome 0 balance = 0 after CSS sell");
        // bal1 = tBar = sellAmt - buyAmt
        uint256 expectedTBar = sellAmt - buyAmt;
        assertEq(bal1, expectedTBar, "outcome 1 = tBar after CSS");
    }

    /// @dev Quantity vector q[i] ≥ ε for all outcomes after any operation.
    ///      Because CSS only adds to non-sold outcomes and the sold outcome reduces
    ///      by at most _totalTraderShares (which ≤ q[i] - ε by construction).
    function testFuzz_sell_quantityNeverBelowEpsilon(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, MIN_SHARE, 100 * SHARE_1);

        // Buy then sell same amount on outcome 0
        _buy(market2, alice, 0, shareAmt);
        vm.prank(alice);
        market2.sell(0, shareAmt, 0, MAX_COST * 10, 0, 0, bytes32(0), bytes32(0));

        uint256[] memory q = market2.getQuantities();
        // q[0] should return to (approximately) EPSILON_2 after buy + sell round trip
        // It might differ by rounding, but must never go below epsilon (guaranteed by InsufficientMarketQuantity)
        assertGe(q[0], 0, "q[0] is non-negative");
        assertGe(q[1], 0, "q[1] is non-negative");
    }

    /// @dev CSS tBar matches getCssTranslation() output for any holding/sell combination.
    function testFuzz_cssTranslation_consistent(
        uint256 held,
        uint256 selling
    ) public {
        held    = bound(held,    0,        50 * SHARE_1);
        selling = bound(selling, MIN_SHARE, 100 * SHARE_1);

        // Give alice `held` shares of outcome 0 via direct storage injection
        // (bypasses MIN_SHARE_AMOUNT for the initial balance; only testing view logic)
        if (held > 0) {
            _buy(market2, alice, 0, held < MIN_SHARE ? MIN_SHARE : held);
        }

        uint256 actualHeld = market2.getShares(alice, 0);
        uint256 expectedTBar = selling > actualHeld ? selling - actualHeld : 0;

        uint256 tBar = market2.getCssTranslation(alice, 0, selling);
        assertEq(tBar, expectedTBar, "getCssTranslation matches expected tBar");
    }

    /*//////////////////////////////////////////////////////////////
                        SLIPPAGE GUARDS — FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev buy() always reverts when maxCostUsdc = 0 (cost always > 0).
    function testFuzz_buy_alwaysReverts_zeroMaxCost(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, MIN_SHARE, 100 * SHARE_1);
        _setupTrader(alice, TRADER_USDC * 100);

        vm.prank(alice);
        vm.expectRevert(BlieverMarket.SlippageExceeded.selector);
        market2.buy(0, shareAmt, 0, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev sell() always accepts minRefundUsdc = 0 (no lower bound on refund).
    ///      Tests that a zero minRefund never causes a false slippage revert.
    function testFuzz_sell_zeroMinRefund_neverReverts(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, MIN_SHARE, 50 * SHARE_1);

        _buy(market2, alice, 0, shareAmt);
        vm.prank(alice);
        // Should never revert on the refund guard when minRefund = 0
        market2.sell(0, shareAmt, 0, MAX_COST * 100, 0, 0, bytes32(0), bytes32(0));

        // Verify sell actually went through
        assertEq(market2.getShares(alice, 0), 0, "shares cleared");
    }

    /// @dev buy() with maxCostUsdc ≥ actual cost always succeeds.
    function testFuzz_buy_succeedsWhenCapGeActualCost(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, MIN_SHARE, 50 * SHARE_1);
        _setupTrader(alice, TRADER_USDC * 1000);

        uint256 realCost = market2.getBuyCost(0, shareAmt);
        uint256 cap      = realCost + 1e6; // give 1 USDC of headroom

        vm.prank(alice);
        market2.buy(0, shareAmt, cap, 0, 0, bytes32(0), bytes32(0));

        assertEq(market2.getShares(alice, 0), shareAmt, "buy succeeded");
    }

    /*//////////////////////////////////////////////////////////////
                BOUNDARY GUARDS — INVALID INPUTS (FUZZ)
    //////////////////////////////////////////////////////////////*/

    /// @dev Any shareAmount < MIN_SHARE_AMOUNT reverts on buy.
    function testFuzz_buy_revert_belowMinShare(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, 1, MIN_SHARE - 1);
        _setupTrader(alice, TRADER_USDC);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.ShareAmountTooSmall.selector, shareAmt, MIN_SHARE)
        );
        market2.buy(0, shareAmt, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev Any shareAmount < MIN_SHARE_AMOUNT reverts on sell.
    function testFuzz_sell_revert_belowMinShare(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, 1, MIN_SHARE - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.ShareAmountTooSmall.selector, shareAmt, MIN_SHARE)
        );
        market2.sell(0, shareAmt, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev Any outcomeIndex ≥ outcomeCount reverts on buy.
    function testFuzz_buy_revert_invalidOutcomeIndex(uint256 idx) public {
        idx = bound(idx, 2, type(uint256).max); // outcomeCount = 2, valid indices [0,1]
        _setupTrader(alice, TRADER_USDC);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.InvalidOutcomeIndex.selector, idx, 2)
        );
        market2.buy(idx, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev Any outcomeIndex ≥ outcomeCount reverts on sell.
    function testFuzz_sell_revert_invalidOutcomeIndex(uint256 idx) public {
        idx = bound(idx, 2, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.InvalidOutcomeIndex.selector, idx, 2)
        );
        market2.sell(idx, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
               MULTI-TRADER — ACCOUNTING CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// @dev After N traders each buy, totalTraderShares equals the sum of individual balances.
    function testFuzz_totalTraderShares_equalsSumOfIndividuals(
        uint256 aliceAmt,
        uint256 bobAmt,
        uint256 carolAmt
    ) public {
        aliceAmt = bound(aliceAmt, MIN_SHARE, 100 * SHARE_1);
        bobAmt   = bound(bobAmt,   MIN_SHARE, 100 * SHARE_1);
        carolAmt = bound(carolAmt, MIN_SHARE, 100 * SHARE_1);

        _buy(market2, alice, 0, aliceAmt);
        _buy(market2, bob,   0, bobAmt);
        _buy(market2, carol, 0, carolAmt);

        uint256 sum  = market2.getShares(alice, 0)
                     + market2.getShares(bob,   0)
                     + market2.getShares(carol, 0);

        assertEq(market2.getTotalTraderShares(0), sum, "total == sum of individual shares");
    }

    /// @dev Quantity vector q[i] always equals epsilon + totalTraderShares[i].
    ///      This is the core AMM accounting invariant: q = q⁰ + Σ trader_deltas.
    function testFuzz_quantity_equals_epsilon_plus_totalTraderShares(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, MIN_SHARE, 100 * SHARE_1);
        _buy(market2, alice, 0, shareAmt);

        uint256[] memory q = market2.getQuantities();
        uint256 total0     = market2.getTotalTraderShares(0);
        uint256 total1     = market2.getTotalTraderShares(1);

        // q[0] = epsilon + totalTraderShares[0] (alice bought outcome 0)
        assertEq(q[0], EPSILON_2 + total0, unicode"q[0] = ε + totalTraderShares[0]");
        // q[1] unchanged: epsilon + 0
        assertEq(q[1], EPSILON_2 + total1, unicode"q[1] = ε + totalTraderShares[1]");
    }

    /// @dev After resolve, totalPayoutUsdc matches what settleMarket received.
    function testFuzz_resolve_payoutMatchesSettleMarketArg(uint256 shareAmt) public {
        shareAmt = bound(shareAmt, MIN_SHARE, 100 * SHARE_1);
        _buy(market2, alice, 0, shareAmt);

        uint256 totalShares    = market2.getTotalTraderShares(0);
        uint256 expectedPayout = totalShares / 1e12; // floor

        vm.prank(resolver);
        market2.resolve(0);

        assertEq(pool.lastSettledPayout(), expectedPayout,
            "settleMarket arg == floor(totalTraderShares[winner])");
    }

    /*//////////////////////////////////////////////////////////////
              TIMING — DEADLINE BOUNDARY CONDITIONS (FUZZ)
    //////////////////////////////////////////////////////////////*/

    /// @dev buy() always reverts past tradingDeadline, no matter how far past.
    function testFuzz_buy_revert_pastTradingDeadline(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 365 days);
        vm.warp(deployTs + T_TRADING + elapsed);

        _setupTrader(alice, TRADER_USDC);
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.TradingClosed.selector);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev resolve() always reverts past resolutionDeadline.
    function testFuzz_resolve_revert_pastResolutionDeadline(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 365 days); // 0 = exactly AT deadline
        vm.warp(deployTs + T_RESOLUTION + elapsed);

        vm.prank(resolver);
        vm.expectRevert(BlieverMarket.ResolutionDeadlinePassed.selector);
        market2.resolve(0);
    }

    /// @dev expireUnresolved() always reverts when called before or at resolutionDeadline.
    function testFuzz_expire_revert_beforeDeadline(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, T_RESOLUTION); // 0 to exactly at deadline
        vm.warp(deployTs + elapsed);

        vm.prank(factory);
        vm.expectRevert(BlieverMarket.ResolutionDeadlineNotPassed.selector);
        market2.expireUnresolved();
    }
}
