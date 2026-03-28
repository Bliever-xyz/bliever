// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2}  from "forge-std/Test.sol";

import {BlieverMarket}   from "../../src/BlieverMarket.sol";
import {BlieverMarketBase} from "./BlieverMarketBase.t.sol";

/// @title  BlieverMarket — Trading Tests (Buy + Sell + CSS)
/// @notice Covers:
///           BUY  — happy path, state changes, pool interaction, slippage, guards.
///           SELL — standard (refund), CSS translation (2-outcome + 7-outcome),
///                  share accounting, quantity vector updates, pool interaction.
///
/// @dev    Run: forge test --match-contract BlieverMarket_TradingTest --evm-version cancun -vvv
contract BlieverMarket_TradingTest is BlieverMarketBase {

    /*//////////////////////////////////////////////////////////////
                               BUY — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Basic buy on 2-outcome market: shares credited, quantities updated.
    function test_buy_succeeds_2outcomes_creditsShares() public {
        _setupTrader(alice, TRADER_USDC);

        uint256 costEst = market2.getBuyCost(0, SHARE_1);
        console2.log("buy cost estimate (USDC 6-dec):", costEst);

        vm.prank(alice);
        market2.buy(0, SHARE_1, costEst + 1e6, 0, 0, bytes32(0), bytes32(0));

        // Alice holds exactly SHARE_1 in outcome 0
        assertEq(market2.getShares(alice, 0), SHARE_1, "shares credited");
        assertEq(market2.getShares(alice, 1), 0,       "no shares in outcome 1");
    }

    /// @dev Quantity vector updates after a buy: only the purchased index changes.
    function test_buy_updatesQuantityVector_onlyBoughtOutcome() public {
        _setupTrader(alice, TRADER_USDC);

        uint256[] memory qBefore = market2.getQuantities();

        vm.prank(alice);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        uint256[] memory qAfter = market2.getQuantities();

        assertEq(qAfter[0], qBefore[0] + SHARE_1, "q[0] increased by shareAmount");
        assertEq(qAfter[1], qBefore[1],            "q[1] unchanged");
    }

    /// @dev Buy on 7-outcome market works for every valid outcome index.
    function test_buy_succeeds_7outcomes_allOutcomes() public {
        for (uint256 i = 0; i < 7; ++i) {
            address trader = makeAddr(string.concat("trader_", vm.toString(i)));
            _setupTrader(trader, TRADER_USDC);
            vm.prank(trader);
            market7.buy(i, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
            assertEq(market7.getShares(trader, i), SHARE_1, "shares credited in outcome");
        }
    }

    /// @dev Multiple buys by the same trader accumulate correctly.
    function test_buy_multipleBysSameTrader_accumulates() public {
        _setupTrader(alice, TRADER_USDC);

        vm.prank(alice);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        vm.prank(alice);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        assertEq(market2.getShares(alice, 0), 2 * SHARE_1, "shares accumulate");
    }

    /// @dev totalTraderShares tracks aggregate position across all traders.
    function test_buy_updatesTotalTraderShares() public {
        _setupTrader(alice, TRADER_USDC);
        _setupTrader(bob,   TRADER_USDC);

        vm.prank(alice);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        vm.prank(bob);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        assertEq(market2.getTotalTraderShares(0), 2 * SHARE_1, "total = alice + bob");
    }

    /// @dev Pool.collectTradeCost is called with correct trader and non-zero cost.
    function test_buy_callsPool_collectTradeCost() public {
        _setupTrader(alice, TRADER_USDC);
        pool.resetCounters();

        vm.prank(alice);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        assertEq(pool.collectCalls(), 1,     "collectTradeCost called once");
        assertEq(pool.lastTrader(),   alice,  "trader passed correctly");
        assertGt(pool.lastCost(),     0,      "non-zero cost collected");
    }

    /// @dev Cost collected by pool matches getBuyCost() quote ± 1 (ceiling rounding).
    function test_buy_costMatchesQuote() public {
        _setupTrader(alice, TRADER_USDC);

        uint256 quotedCost = market2.getBuyCost(0, SHARE_1);
        pool.resetCounters();

        vm.prank(alice);
        market2.buy(0, SHARE_1, quotedCost + 1e6, 0, 0, bytes32(0), bytes32(0));

        // Actual cost should be <= quoted (quote was already ceiling-rounded).
        assertLe(pool.lastCost(), quotedCost + 1, "cost <= quote + 1 wei USDC");
        assertGe(pool.lastCost(), quotedCost - 1, "cost >= quote - 1 wei USDC");
    }

    /// @dev Bought event emitted with correct arguments.
    function test_buy_emits_Bought() public {
        _setupTrader(alice, TRADER_USDC);
        uint256 costEst = market2.getBuyCost(0, SHARE_1);

        vm.expectEmit(true, true, false, false, address(market2));
        emit BlieverMarket.Bought(alice, 0, SHARE_1, costEst);

        vm.prank(alice);
        market2.buy(0, SHARE_1, costEst + 1e6, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev Price of bought outcome increases after the trade (AMM property).
    function test_buy_priceIncreases_afterBuy() public {
        uint256 priceBefore = market2.getPrice(0);
        _buy(market2, alice, 0, SHARE_10);
        uint256 priceAfter  = market2.getPrice(0);

        assertGt(priceAfter, priceBefore, "price of bought outcome increases");
    }

    /// @dev Price of NOT-bought outcome decreases after a buy (LS-LMSR property).
    function test_buy_otherOutcomePrice_decreasesAfterBuy() public {
        uint256 priceBefore = market2.getPrice(1);
        _buy(market2, alice, 0, SHARE_10);
        uint256 priceAfter  = market2.getPrice(1);

        assertLt(priceAfter, priceBefore, "price of non-bought outcome decreases");
    }

    /// @dev USDC is actually pulled from trader by the pool (token balance check).
    function test_buy_traderUsdcBalanceDecreases() public {
        _setupTrader(alice, TRADER_USDC);
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        assertLt(usdc.balanceOf(alice), balBefore, "alice paid USDC");
    }

    /*//////////////////////////////////////////////////////////////
                               BUY — REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_buy_revert_dustShareAmount() public {
        _setupTrader(alice, TRADER_USDC);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.ShareAmountTooSmall.selector, MIN_SHARE - 1, MIN_SHARE)
        );
        market2.buy(0, MIN_SHARE - 1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    function test_buy_revert_invalidOutcomeIndex() public {
        _setupTrader(alice, TRADER_USDC);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.InvalidOutcomeIndex.selector, 2, 2)
        );
        market2.buy(2, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0)); // outcomeCount=2, valid=[0,1]
    }

    function test_buy_revert_slippageExceeded() public {
        _setupTrader(alice, TRADER_USDC);
        vm.prank(alice);
        vm.expectRevert(); // SlippageExceeded — maxCostUsdc = 0, actual cost > 0
        market2.buy(0, SHARE_1, 0, 0, 0, bytes32(0), bytes32(0));
    }

    function test_buy_revert_whenPaused() public {
        vm.prank(factory);
        market2.pause();

        _setupTrader(alice, TRADER_USDC);
        vm.prank(alice);
        vm.expectRevert(); // EnforcedPause
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    function test_buy_revert_afterTradingDeadline() public {
        vm.warp(deployTs + T_TRADING + 1); // one second past deadline
        _setupTrader(alice, TRADER_USDC);
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.TradingClosed.selector);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    function test_buy_revert_whenResolved() public {
        _resolve(market2, 0);
        _setupTrader(alice, TRADER_USDC);
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.TradingClosed.selector);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev exactDeadline: block.timestamp == tradingDeadline is rejected.
    function test_buy_revert_atExactTradingDeadline() public {
        vm.warp(deployTs + T_TRADING); // exactly at the deadline
        _setupTrader(alice, TRADER_USDC);
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.TradingClosed.selector);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                        SELL — STANDARD REFUND PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Selling held shares refunds USDC and clears share balance.
    function test_sell_standard_refund_creditsTrader() public {
        _buy(market2, alice, 0, SHARE_1);

        uint256 sharesBefore = market2.getShares(alice, 0);
        uint256 usdcBefore   = usdc.balanceOf(alice);
        pool.resetCounters();

        vm.prank(alice);
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        assertEq(market2.getShares(alice, 0), sharesBefore - SHARE_1, "shares reduced");
        assertGt(usdc.balanceOf(alice), usdcBefore,                   "alice received refund");
        assertEq(pool.refundCalls(),    1,                             "distributeRefund called once");
    }

    /// @dev Selling all held shares zeroes the balance.
    function test_sell_all_shares_zeroes_balance() public {
        _buy(market2, alice, 0, SHARE_1);
        vm.prank(alice);
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
        assertEq(market2.getShares(alice, 0), 0, "balance fully sold");
    }

    /// @dev Quantity vector decreases on the sold outcome after a standard sell.
    function test_sell_updatesQuantityVector() public {
        _buy(market2, alice, 0, SHARE_1);

        uint256[] memory qBefore = market2.getQuantities();
        vm.prank(alice);
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
        uint256[] memory qAfter = market2.getQuantities();

        assertEq(qAfter[0], qBefore[0] - SHARE_1, "q[0] decreased by shareAmount");
        assertEq(qAfter[1], qBefore[1],            "q[1] unchanged on standard sell");
    }

    /// @dev Pool's distributeRefund is called with the seller's address.
    function test_sell_callsPool_distributeRefund() public {
        _buy(market2, alice, 0, SHARE_1);
        pool.resetCounters();

        vm.prank(alice);
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        assertEq(pool.refundCalls(), 1,    "distributeRefund called once");
        assertEq(pool.lastTrader(),  alice, "correct trader address");
    }

    /// @dev Sold event is emitted with zero CSS translation on a standard sell.
    function test_sell_emits_Sold_standardSell() public {
        _buy(market2, alice, 0, SHARE_1);

        vm.expectEmit(true, true, false, false, address(market2));
        emit BlieverMarket.Sold(alice, 0, SHARE_1, 0 /*tBar*/, 0 /*refund placeholder*/, 0);

        vm.prank(alice);
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev Round-trip (buy then sell same amount) refund is always ≤ buy cost.
    ///      The AMM spread ensures the protocol keeps a positive margin.
    function test_sell_roundTrip_refundLessThanCost() public {
        _setupTrader(alice, TRADER_USDC);

        uint256 buyCost = market2.getBuyCost(0, SHARE_1);
        uint256 usdcBefore = usdc.balanceOf(alice);

        // Buy
        vm.prank(alice);
        market2.buy(0, SHARE_1, buyCost + 1e6, 0, 0, bytes32(0), bytes32(0));

        uint256 usdcAfterBuy = usdc.balanceOf(alice);
        uint256 paid = usdcBefore - usdcAfterBuy;

        // Sell
        vm.prank(alice);
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        uint256 received = usdc.balanceOf(alice) - usdcAfterBuy;

        console2.log("paid   (6-dec):", paid);
        console2.log("received (6-dec):", received);
        assertLe(received, paid, "refund <= cost (AMM spread)");
    }

    /*//////////////////////////////////////////////////////////////
                    SELL — CSS (COVERED SHORT SELLING)
    //////////////////////////////////////////////////////////////*/

    /// @dev CSS test: selling an outcome with ZERO holdings triggers full translation.
    ///      The trader has no shares of outcome 0 but tries to sell SHARE_1 of it.
    ///      tBar = SHARE_1 − 0 = SHARE_1 (full translation).
    ///      Result: q[0] unchanged (netReduce=0), q[1] += tBar.
    ///      Trader ends with: 0 shares of outcome 0, +SHARE_1 shares of outcome 1.
    function test_sell_css_zeroHoldings_2outcomes() public {
        // Alice has no position; sell outcome 0 via CSS
        _setupTrader(alice, TRADER_USDC); // may need to pay if CSS causes net cost

        uint256[] memory qBefore = market2.getQuantities();

        vm.prank(alice);
        // minRefund = 0 (may be paying), maxCost = MAX_COST
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        uint256[] memory qAfter = market2.getQuantities();

        // q[0] must NOT decrease (netReduce = shareAmount - tBar = 0)
        assertEq(qAfter[0], qBefore[0],            "q[0] unchanged (netReduce=0)");
        // q[1] must increase by tBar = SHARE_1
        assertEq(qAfter[1], qBefore[1] + SHARE_1,  "q[1] += tBar");

        // Trader's outcome 0 balance: traderBal + tBar - shareAmount = 0 + SHARE_1 - SHARE_1 = 0
        assertEq(market2.getShares(alice, 0), 0,      "outcome 0 balance = 0 after CSS");
        // Trader's outcome 1 balance: += tBar
        assertEq(market2.getShares(alice, 1), SHARE_1, "outcome 1 gained tBar");
    }

    /// @dev CSS test: selling MORE than held — partial CSS translation.
    ///      Alice holds 1 share of outcome 0, tries to sell 3 shares.
    ///      tBar = 3 - 1 = 2. netReduce = 1.
    function test_sell_css_partialHoldings_2outcomes() public {
        _buy(market2, alice, 0, SHARE_1); // alice holds 1 share of outcome 0

        uint256[] memory qBefore = market2.getQuantities();
        _setupTrader(alice, TRADER_USDC); // extra USDC in case CSS costs

        vm.prank(alice);
        market2.sell(0, 3 * SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        uint256[] memory qAfter = market2.getQuantities();

        // tBar = 3 - 1 = 2 * SHARE_1; netReduce = 1 * SHARE_1
        assertEq(qAfter[0], qBefore[0] - SHARE_1,      "q[0] -= netReduce (1 share)");
        assertEq(qAfter[1], qBefore[1] + 2 * SHARE_1,  "q[1] += tBar (2 shares)");

        // Trader outcome 0: traderBal + tBar - shareAmount = 1 + 2 - 3 = 0
        assertEq(market2.getShares(alice, 0), 0,             "outcome 0 balance = 0");
        // Trader outcome 1: 0 + tBar = 2 shares
        assertEq(market2.getShares(alice, 1), 2 * SHARE_1,   "outcome 1 = tBar");
    }

    /// @dev CSS on 7-outcome market: selling outcome 0 without holdings distributes
    ///      tBar to all 6 other outcomes (quantity vector update + share ledger update).
    function test_sell_css_7outcomes_updatesAllOtherOutcomes() public {
        _setupTrader(alice, TRADER_USDC);

        uint256[] memory qBefore = market7.getQuantities();

        vm.prank(alice);
        market7.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        uint256[] memory qAfter = market7.getQuantities();

        // Outcome 0: netReduce = 0 (tBar = SHARE_1 - 0 = SHARE_1), qAfter[0] unchanged
        assertEq(qAfter[0], qBefore[0], "q[0] unchanged");

        // All other outcomes: q[i] += tBar = SHARE_1
        for (uint256 i = 1; i < 7; ++i) {
            assertEq(qAfter[i], qBefore[i] + SHARE_1,
                string.concat("q[", vm.toString(i), "] += tBar"));
        }

        // Alice's outcome shares
        assertEq(market7.getShares(alice, 0), 0,       "outcome 0 = 0 after CSS");
        for (uint256 i = 1; i < 7; ++i) {
            assertEq(market7.getShares(alice, i), SHARE_1,
                string.concat("outcome ", vm.toString(i), " = tBar"));
        }
    }

    /// @dev CSS: getCssTranslation() returns tBar correctly before and after buying.
    function test_sell_getCssTranslation_correctTBar() public {
        // Before buy: zero holdings → tBar = shareAmount
        uint256 tBar0 = market2.getCssTranslation(alice, 0, SHARE_1);
        assertEq(tBar0, SHARE_1, "tBar = shareAmount when no holdings");

        // After buying SHARE_1 of outcome 0: tBar = 0 for same amount
        _buy(market2, alice, 0, SHARE_1);
        uint256 tBar1 = market2.getCssTranslation(alice, 0, SHARE_1);
        assertEq(tBar1, 0, "tBar = 0 when holding exact sell amount");
    }

    /// @dev CSS: tBar is non-zero when selling MORE than held.
    function test_sell_getCssTranslation_partialHoldings() public {
        _buy(market2, alice, 0, SHARE_1); // holds SHARE_1
        uint256 tBar = market2.getCssTranslation(alice, 0, 3 * SHARE_1); // sells 3x
        assertEq(tBar, 2 * SHARE_1, "tBar = 3-1 = 2 shares");
    }

    /*//////////////////////////////////////////////////////////////
                            SELL — REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_sell_revert_dustShareAmount() public {
        _buy(market2, alice, 0, SHARE_1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.ShareAmountTooSmall.selector, MIN_SHARE - 1, MIN_SHARE)
        );
        market2.sell(0, MIN_SHARE - 1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    function test_sell_revert_invalidOutcomeIndex() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.InvalidOutcomeIndex.selector, 2, 2)
        );
        market2.sell(2, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    function test_sell_revert_minRefundSlippage() public {
        _buy(market2, alice, 0, SHARE_1);
        uint256 actualRefund = market2.getSellEstimate(alice, 0, SHARE_1).refundUsdc;

        // Demand more refund than the AMM will return → SlippageExceeded
        vm.prank(alice);
        vm.expectRevert(); // SlippageExceeded
        market2.sell(0, SHARE_1, actualRefund + 1e6, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    function test_sell_revert_whenPaused() public {
        _buy(market2, alice, 0, SHARE_1);

        vm.prank(factory);
        market2.pause();

        vm.prank(alice);
        vm.expectRevert(); // EnforcedPause
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    function test_sell_revert_afterTradingDeadline() public {
        _buy(market2, alice, 0, SHARE_1);

        vm.warp(deployTs + T_TRADING + 1);
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.TradingClosed.selector);
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    function test_sell_revert_whenResolved() public {
        _buy(market2, alice, 0, SHARE_1);
        _resolve(market2, 0);

        vm.prank(alice);
        vm.expectRevert(BlieverMarket.TradingClosed.selector);
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                       SELL — VIEW ESTIMATE CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// @dev getSellEstimate() output is consistent with actual sell outcome.
    function test_getSellEstimate_matchesActualRefund() public {
        _buy(market2, alice, 0, SHARE_1);

        (uint256 estRefund, ) = market2.getSellEstimate(alice, 0, SHARE_1);
        pool.resetCounters();

        vm.prank(alice);
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        // Actual refund sent to alice via pool must match estimate ± 1 (floor rounding)
        assertApproxEqAbs(pool.lastRefund(), estRefund, 1, "actual refund ≈ estimate");
    }

    /// @dev getSellEstimate() returns (0, 0) for zero shareAmount.
    function test_getSellEstimate_zeroAmount_returnsZero() public view {
        (uint256 r, uint256 c) = market2.getSellEstimate(alice, 0, 0);
        assertEq(r, 0, "refund zero");
        assertEq(c, 0, "cost zero");
    }

    /// @dev getBuyCost() returns 0 for zero shareAmount.
    function test_getBuyCost_zeroAmount_returnsZero() public view {
        uint256 cost = market2.getBuyCost(0, 0);
        assertEq(cost, 0);
    }
}
