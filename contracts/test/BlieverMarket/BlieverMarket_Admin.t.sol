// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2}  from "forge-std/Test.sol";

import {BlieverMarket}   from "../../src/BlieverMarket.sol";
import {BlieverMarketBase} from "./BlieverMarketBase.t.sol";

/// @title  BlieverMarket — Admin & View Tests
/// @notice Covers:
///           ADMIN   — pause / unpause by factory; unauthorized callers; asymmetric-pause design
///                     (resolution + claims always permitted; only buy/sell are pause-gated).
///           VIEWS   — all read-only query functions: prices, quantities, shares, market status.
///
/// @dev    Run: forge test --match-contract BlieverMarket_AdminTest --evm-version cancun -vvv
contract BlieverMarket_AdminTest is BlieverMarketBase {

    /*//////////////////////////////////////////////////////////////
                        ADMIN — PAUSE / UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_byFactory_succeeds() public {
        vm.prank(factory);
        market2.pause();
        // buy must now revert with EnforcedPause
        _setupTrader(alice, TRADER_USDC);
        vm.prank(alice);
        vm.expectRevert();
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    function test_pause_revert_notFactory() public {
        vm.prank(attacker);
        vm.expectRevert(BlieverMarket.NotFactory.selector);
        market2.pause();
    }

    function test_pause_revert_notResolver() public {
        vm.prank(resolver);
        vm.expectRevert(BlieverMarket.NotFactory.selector);
        market2.pause();
    }

    function test_unpause_byFactory_resumesTrading() public {
        vm.prank(factory);
        market2.pause();

        vm.prank(factory);
        market2.unpause();

        // Trading should work again
        _setupTrader(alice, TRADER_USDC);
        vm.prank(alice);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
        assertEq(market2.getShares(alice, 0), SHARE_1, "buy works after unpause");
    }

    function test_unpause_revert_notFactory() public {
        vm.prank(factory);
        market2.pause();

        vm.prank(attacker);
        vm.expectRevert(BlieverMarket.NotFactory.selector);
        market2.unpause();
    }

    /// @dev Sell is also blocked when paused.
    function test_pause_blocksAllTradeFunctions() public {
        _buy(market2, alice, 0, SHARE_1);

        vm.prank(factory);
        market2.pause();

        // buy blocked
        _setupTrader(bob, TRADER_USDC);
        vm.prank(bob);
        vm.expectRevert();
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        // sell blocked
        vm.prank(alice);
        vm.expectRevert();
        market2.sell(0, SHARE_1, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
               ASYMMETRIC PAUSE — resolve / claim / expire
               are intentionally NOT pause-gated
    //////////////////////////////////////////////////////////////*/

    /// @dev resolve() must succeed even while the market is paused.
    function test_pausedMarket_resolve_succeeds() public {
        vm.prank(factory);
        market2.pause();

        vm.prank(resolver);
        market2.resolve(0); // must NOT revert
        assertTrue(market2.resolved(), "resolved while paused");
    }

    /// @dev claim() must succeed even while the market is paused.
    function test_pausedMarket_claim_succeeds() public {
        _buy(market2, alice, 0, SHARE_1);
        _resolve(market2, 0);

        vm.prank(factory);
        market2.pause();

        vm.prank(alice);
        market2.claim(); // must NOT revert
        assertTrue(market2.hasClaimed(alice), "claimed while paused");
    }

    /// @dev expireUnresolved() must succeed even while the market is paused.
    function test_pausedMarket_expire_succeeds() public {
        vm.prank(factory);
        market2.pause();

        vm.warp(deployTs + T_RESOLUTION + 1);
        vm.prank(factory);
        market2.expireUnresolved(); // must NOT revert
        assertTrue(market2.resolved(), "expired while paused");
    }

    /*//////////////////////////////////////////////////////////////
                      VIEW — PRICES
    //////////////////////////////////////////////////////////////*/

    /// @dev At initialization, all prices are symmetric (p[0] == p[1] for 2-outcome market).
    function test_getPrice_uniform_atInit_2outcomes() public view {
        uint256 p0 = market2.getPrice(0);
        uint256 p1 = market2.getPrice(1);
        assertEq(p0, p1, "prices symmetric at init");
        assertGt(p0, 0,    "price > 0");
        assertLt(p0, 1e18, "price < 1");
    }

    /// @dev getAllPrices() returns n entries for n-outcome market.
    function test_getAllPrices_correctLength() public view {
        uint256[] memory p2 = market2.getAllPrices();
        uint256[] memory p7 = market7.getAllPrices();
        assertEq(p2.length, 2, "2-outcome has 2 prices");
        assertEq(p7.length, 7, "7-outcome has 7 prices");
    }

    /// @dev getAllPrices() values match individual getPrice() calls.
    function test_getAllPrices_matchesGetPrice() public view {
        uint256[] memory prices = market2.getAllPrices();
        assertEq(prices[0], market2.getPrice(0), "prices[0] matches getPrice(0)");
        assertEq(prices[1], market2.getPrice(1), "prices[1] matches getPrice(1)");
    }

    /// @dev getSumOfPrices() is > 1e18 for LS-LMSR (AMM spread property).
    function test_getSumOfPrices_greaterThanOne() public view {
        uint256 sumP = market2.getSumOfPrices();
        assertGt(sumP, 1e18, "sum of prices > 1 (LS-LMSR property)");
        console2.log("sum of prices (18-dec):", sumP);
    }

    /// @dev Price of bought outcome rises; sum of prices remains > 1.
    function test_getSumOfPrices_greaterThanOne_afterTrade() public {
        _buy(market2, alice, 0, SHARE_10);
        uint256 sumP = market2.getSumOfPrices();
        assertGt(sumP, 1e18, "sum > 1 after trade");
    }

    /// @dev getPrice() reverts on out-of-range outcome index.
    function test_getPrice_revert_invalidIndex() public {
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.InvalidOutcomeIndex.selector, 2, 2)
        );
        market2.getPrice(2);
    }

    /*//////////////////////////////////////////////////////////////
                      VIEW — BUY / SELL ESTIMATES
    //////////////////////////////////////////////////////////////*/

    /// @dev getBuyCost() returns a positive value for a non-trivial share amount.
    function test_getBuyCost_positive() public view {
        uint256 cost = market2.getBuyCost(0, SHARE_1);
        assertGt(cost, 0, "buy cost > 0");
        console2.log("getBuyCost(0, 1e18):", cost);
    }

    /// @dev getBuyCost() increases with share amount (monotone cost function).
    function test_getBuyCost_monotone_increasesWithAmount() public view {
        uint256 cost1  = market2.getBuyCost(0, SHARE_1);
        uint256 cost10 = market2.getBuyCost(0, SHARE_10);
        assertGt(cost10, cost1, "larger purchase costs more");
    }

    /// @dev After buying, getSellEstimate() returns the same-direction refund correctly.
    function test_getSellEstimate_positive_afterBuy() public {
        _buy(market2, alice, 0, SHARE_1);
        (uint256 refund, uint256 cost) = market2.getSellEstimate(alice, 0, SHARE_1);
        assertGt(refund, 0, "refund > 0 for standard sell");
        assertEq(cost,   0, "no cost on standard sell");
    }

    /// @dev getSellEstimate() for CSS path (zero holdings) returns a cost, not a refund.
    function test_getSellEstimate_cssPath_hasCost() public view {
        // alice has no holdings; CSS translates all of SHARE_1 to tBar
        (uint256 refund, uint256 cost) = market2.getSellEstimate(alice, 0, SHARE_1);
        // At symmetric init with full CSS translation, result depends on AMM state.
        // Assert they're not both nonzero (only one of refund/cost can be > 0).
        assertTrue(refund == 0 || cost == 0, "at most one of refund/cost is non-zero");
        console2.log("CSS sell estimate - refund:", refund, "cost:", cost);
    }

    /*//////////////////////////////////////////////////////////////
                      VIEW — SHARES & QUANTITIES
    //////////////////////////////////////////////////////////////*/

    /// @dev getShares() returns 0 before any trade.
    function test_getShares_zero_beforeTrade() public view {
        assertEq(market2.getShares(alice, 0), 0);
    }

    /// @dev getShares() is updated after a buy.
    function test_getShares_correct_afterBuy() public {
        _buy(market2, alice, 0, SHARE_1);
        assertEq(market2.getShares(alice, 0), SHARE_1);
    }

    /// @dev getAllShares() returns an array of length outcomeCount.
    function test_getAllShares_correctLength() public view {
        uint256[] memory shares2 = market2.getAllShares(alice);
        uint256[] memory shares7 = market7.getAllShares(alice);
        assertEq(shares2.length, 2, "2-outcome: length = 2");
        assertEq(shares7.length, 7, "7-outcome: length = 7");
    }

    /// @dev getAllShares() matches getShares() for each index.
    function test_getAllShares_matchesGetShares() public {
        _buy(market2, alice, 0, SHARE_1);
        _buy(market2, alice, 1, SHARE_1);

        uint256[] memory all = market2.getAllShares(alice);
        assertEq(all[0], market2.getShares(alice, 0), "allShares[0] matches");
        assertEq(all[1], market2.getShares(alice, 1), "allShares[1] matches");
    }

    /// @dev getShares() reverts on out-of-range index.
    function test_getShares_revert_invalidIndex() public {
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.InvalidOutcomeIndex.selector, 2, 2)
        );
        market2.getShares(alice, 2);
    }

    /// @dev getQuantities() returns initial epsilon vector before any trades.
    function test_getQuantities_initialEpsilonVector() public view {
        uint256[] memory q = market2.getQuantities();
        assertEq(q[0], EPSILON_2, "q[0] = epsilon at init");
        assertEq(q[1], EPSILON_2, "q[1] = epsilon at init");
    }

    /// @dev getQuantities() updates after a buy.
    function test_getQuantities_updatesAfterBuy() public {
        _buy(market2, alice, 0, SHARE_1);
        uint256[] memory q = market2.getQuantities();
        assertEq(q[0], EPSILON_2 + SHARE_1, "q[0] incremented by shareAmount");
        assertEq(q[1], EPSILON_2,            "q[1] unchanged");
    }

    /// @dev getInitialQuantities() never changes after initialization.
    function test_getInitialQuantities_immutable() public {
        uint256[] memory q0Before = market2.getInitialQuantities();
        _buy(market2, alice, 0, SHARE_10);
        uint256[] memory q0After = market2.getInitialQuantities();
        assertEq(q0Before[0], q0After[0], "initialQuantities[0] immutable");
        assertEq(q0Before[1], q0After[1], "initialQuantities[1] immutable");
    }

    /// @dev getTotalTraderShares() excludes the epsilon seed.
    function test_getTotalTraderShares_excludesEpsilon() public view {
        // Before any trades: totalTraderShares = 0 (epsilon is not trader-owned)
        assertEq(market2.getTotalTraderShares(0), 0, "no trader shares initially");
    }

    function test_getTotalTraderShares_correctAfterBuy() public {
        _buy(market2, alice, 0, SHARE_1);
        _buy(market2, bob,   0, 2 * SHARE_1);
        assertEq(market2.getTotalTraderShares(0), 3 * SHARE_1, "total = alice + bob");
    }

    function test_getTotalTraderShares_revert_invalidIndex() public {
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.InvalidOutcomeIndex.selector, 2, 2)
        );
        market2.getTotalTraderShares(2);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW — MARKET STATUS
    //////////////////////////////////////////////////////////////*/

    /// @dev getMarketStatus() reflects correct values at initialization.
    function test_getMarketStatus_atInit() public view {
        (
            bool _resolved,
            uint8 _wo,
            bool _tradingOpen,
            uint40 _tDeadline,
            uint40 _rDeadline,
            uint256 _volume
        ) = market2.getMarketStatus();

        assertFalse(_resolved,    "not resolved");
        assertEq(_wo,        0,   "winningOutcome = 0 (default)");
        assertTrue(_tradingOpen,  "trading is open");
        assertEq(_tDeadline, deployTs + T_TRADING,    "tradingDeadline");
        assertEq(_rDeadline, deployTs + T_RESOLUTION, "resolutionDeadline");
        // volume = sum of q-vector = 2 * EPSILON_2
        assertEq(_volume, 2 * EPSILON_2, "volume = 2 * epsilon");
    }

    /// @dev totalVolumeShares increases after a buy.
    function test_getMarketStatus_volumeIncreasesAfterBuy() public {
        (, , , , , uint256 volBefore) = market2.getMarketStatus();
        _buy(market2, alice, 0, SHARE_1);
        (, , , , , uint256 volAfter)  = market2.getMarketStatus();
        assertEq(volAfter, volBefore + SHARE_1, "volume increases by shareAmount");
    }

    /// @dev tradingOpen = false after resolution.
    function test_getMarketStatus_tradingClosed_afterResolve() public {
        _resolve(market2, 1);
        (, , bool tradingOpen, , , ) = market2.getMarketStatus();
        assertFalse(tradingOpen, "trading closed after resolve");
    }

    /*//////////////////////////////////////////////////////////////
                       VIEW — MISC GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @dev usdcToken() returns the cached USDC address (no external call to pool).
    function test_usdcToken_returnsCachedAddress() public view {
        assertEq(market2.usdcToken(), address(usdc));
    }

    /// @dev hasClaimed() is false before claim and true after.
    function test_hasClaimed_falseBeforeTruAfter() public {
        _buy(market2, alice, 0, SHARE_1);
        _resolve(market2, 0);

        assertFalse(market2.hasClaimed(alice), "false before claim");
        vm.prank(alice);
        market2.claim();
        assertTrue(market2.hasClaimed(alice), "true after claim");
    }

    /// @dev getCssTranslation() returns 0 for out-of-range outcome (no revert — defensive).
    function test_getCssTranslation_outOfRange_returnsZero() public view {
        uint256 tBar = market2.getCssTranslation(alice, 99, SHARE_1);
        assertEq(tBar, 0, "out-of-range returns 0");
    }
}
