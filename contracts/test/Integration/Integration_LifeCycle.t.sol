// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test} from "forge-std/Test.sol";

import {IntegrationBase} from "./IntegrationBase.t.sol";
import {BlieverV1Pool}   from "../../src/BlieverV1Pool.sol";
import {BlieverMarket}   from "../../src/BlieverMarket.sol";

/// @title  Integration_LifeCycle
/// @notice End-to-end integration tests covering the full prediction-market lifecycle:
///         LP deposit → market registration → trading (buy / sell) → resolution → claim.
///
///         Each test uses REAL BlieverV1Pool and BlieverMarket contracts with no mocks.
///         USDC flows, pool accounting, and internal market state are all verified together.
///
///         Parameters
///         ──────────
///         • Binary market  (2 outcomes): EPSILON_2 = 480e18
///         • Multi-outcome  (7 outcomes): EPSILON_7 = 355e18
///         • ALPHA = 3e16 (3 %)  |  MAX_RISK = 500 USDC
///
/// @dev    Run: forge test --match-contract Integration_LifeCycle --evm-version cancun -vvv
contract Integration_LifeCycle is IntegrationBase {

    /*//////////////////////////////////////////////////////////////
                            STATE
    //////////////////////////////////////////////////////////////*/

    BlieverMarket internal market2; // 2-outcome binary market
    BlieverMarket internal market7; // 7-outcome multi-outcome market

    /*//////////////////////////////////////////////////////////////
                            SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public override {
        super.setUp();
        market2 = _deployMarket(2, EPSILON_2);
        market7 = _deployMarket(7, EPSILON_7);

        _setupTrader(alice);
        _setupTrader(bob);
        _setupTrader(carol);
    }

    /*//////////////////////////////////////////////////////////////
           BINARY MARKET (2 OUTCOMES) — FULL LIFECYCLE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Happy path: trader buys winning outcome, resolves, claims USDC.
    ///         Verifies USDC balance changes across trader, pool, and pool accounting fields.
    function test_binary_fullLifeCycle_winnerBuysAndClaims() public {
        // ── Arrange ──────────────────────────────────────────────────────────
        uint256 poolBalBefore  = usdc.balanceOf(address(pool));
        uint256 aliceBalBefore = usdc.balanceOf(alice);

        // ── Act 1: Alice buys 10e18 shares of outcome 0 ──────────────────────
        uint256 cost = _buy(market2, alice, 0, 10e18);

        // Pool received trader's USDC; alice paid exactly `cost`.
        assertEq(usdc.balanceOf(address(pool)), poolBalBefore + cost, "pool gained cost");
        assertEq(usdc.balanceOf(alice), aliceBalBefore - cost,        "alice paid cost");
        assertTrue(pool.getMarketInfo(address(market2)).hasTrades,    "hasTrades set");
        _assertPoolSolvent();

        // ── Act 2: Resolve outcome 0 as winner ───────────────────────────────
        _resolve(market2, 0);

        BlieverV1Pool.MarketInfo memory infoAfterSettle =
            pool.getMarketInfo(address(market2));
        assertTrue(infoAfterSettle.settled,                    "market settled");
        assertEq(infoAfterSettle.currentLiability, 0,         "live liability cleared");
        assertGt(infoAfterSettle.settledPayout, 0,            "non-zero payout authorized");
        assertFalse(pool.isActiveMarket(address(market2)),    "market no longer active");
        _assertPoolSolvent();

        // ── Act 3: Alice claims her payout ───────────────────────────────────
        uint256 expectedPayout = infoAfterSettle.settledPayout;
        uint256 aliceBalPreClaim = usdc.balanceOf(alice);
        uint256 poolBalPreClaim  = usdc.balanceOf(address(pool));

        _claim(market2, alice);

        // Alice received exactly settledPayout.
        assertEq(usdc.balanceOf(alice),          aliceBalPreClaim + expectedPayout, "alice received payout");
        assertEq(usdc.balanceOf(address(pool)),  poolBalPreClaim  - expectedPayout, "pool paid out");
        assertTrue(market2.hasClaimed(alice),    "alice marked as claimed");
        _assertPoolSolvent();

        // MARKET_ROLE auto-revoked when claimedPayout == settledPayout.
        assertFalse(
            pool.hasRole(pool.MARKET_ROLE(), address(market2)),
            "MARKET_ROLE revoked after full claim"
        );
    }

    /// @notice Loser buys the wrong outcome — market resolves in opposite direction;
    ///         loser holds zero winning shares and cannot claim.
    function test_binary_loserBuysWrongOutcome_cannotClaim() public {
        // ── Arrange: Alice backs outcome 1, outcome 0 wins ───────────────────
        _buy(market2, alice, 1, 10e18);
        _resolve(market2, 0); // outcome 1 loses

        uint256 aliceBalAfterResolve = usdc.balanceOf(alice);

        // ── Act / Assert: claim reverts with NoWinningShares ─────────────────
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.NoWinningShares.selector);
        market2.claim();

        // Alice's balance is unchanged — no USDC distributed.
        assertEq(usdc.balanceOf(alice), aliceBalAfterResolve, "loser received nothing");

        // Pool is still solvent; it absorbed Alice's buy cost as LP profit.
        _assertPoolSolvent();
    }

    /// @notice Buy → partial sell → resolve winner → claim remaining shares.
    ///         Confirms that totalLiability tracks correctly after a sell refund
    ///         and the remaining shares entitle the trader to partial payout.
    function test_binary_partialSell_remainingSharesWin() public {
        // ── Buy 10e18 of outcome 0 ───────────────────────────────────────────
        _buy(market2, alice, 0, 10e18);

        uint256 poolBalAfterBuy = usdc.balanceOf(address(pool));

        // ── Sell half the position (5e18 shares) ─────────────────────────────
        _sell(market2, alice, 0, 5e18);

        // Pool returned a refund to Alice; pool balance decreased.
        assertLt(
            usdc.balanceOf(address(pool)), poolBalAfterBuy,
            "pool refunded sell proceeds"
        );
        assertEq(
            market2.getShares(alice, 0), 5e18,
            "alice holds 5e18 remaining shares"
        );
        _assertPoolSolvent();

        // ── Resolve: outcome 0 wins ───────────────────────────────────────────
        _resolve(market2, 0);

        uint256 aliceBalBeforeClaim = usdc.balanceOf(alice);
        _claim(market2, alice);

        // Alice receives payout proportional to her remaining 5e18 shares.
        assertGt(
            usdc.balanceOf(alice), aliceBalBeforeClaim,
            "alice got payout for remaining shares"
        );
        _assertPoolSolvent();
    }

    /// @notice Market is resolved with zero trades — totalPayoutUsdc = 0.
    ///         Pool should release the riskBudget back to free liquidity,
    ///         and MARKET_ROLE is revoked immediately by settleMarket (zero-payout path).
    function test_binary_noTrades_settlesWithZeroPayout() public {
        // Deploy a fresh market — no one trades on it.
        BlieverMarket m = _deployMarket(2, EPSILON_2);

        uint256 liabBefore  = pool.totalLiability();
        uint256 countBefore = pool.activeMarketCount();

        _resolve(m, 0); // resolver calls resolve; hasTrades == false → settledPayout = 0

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        assertTrue(info.settled,         "market settled");
        assertFalse(info.hasTrades,      "confirmed: no trades");
        assertEq(info.settledPayout, 0,  "zero payout");

        // Full riskBudget released from totalLiability.
        assertEq(pool.totalLiability(),    liabBefore - MAX_RISK, "liability fully released");
        assertEq(pool.activeMarketCount(), countBefore - 1,        "active count decremented");

        // MARKET_ROLE must be revoked immediately (pool's zero-payout path in settleMarket).
        assertFalse(
            pool.hasRole(pool.MARKET_ROLE(), address(m)),
            "MARKET_ROLE revoked immediately on zero-payout settlement"
        );
        _assertPoolSolvent();
    }

    /// @notice Three traders back different outcomes — only the winner receives payout.
    ///         Losers hold non-zero shares but of the wrong outcome → NoWinningShares.
    function test_binary_multipleTraders_onlyWinnerClaims() public {
        // Alice: outcome 0 | Bob: outcome 1 | Carol: outcome 0
        _buy(market2, alice, 0, 5e18);
        _buy(market2, bob,   1, 5e18);
        _buy(market2, carol, 0, 5e18);

        _resolve(market2, 0); // outcome 0 wins

        // Alice and Carol (outcome 0) claim successfully.
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 carolBefore = usdc.balanceOf(carol);

        _claim(market2, alice);
        _claim(market2, carol);

        assertGt(usdc.balanceOf(alice), aliceBefore, "alice got payout");
        assertGt(usdc.balanceOf(carol), carolBefore, "carol got payout");

        // Bob (outcome 1) cannot claim — market is settled, his shares are worthless.
        vm.prank(bob);
        vm.expectRevert(BlieverMarket.NoWinningShares.selector);
        market2.claim();

        // Pool remains solvent after all payouts.
        _assertPoolSolvent();
    }

    /// @notice Verify exact USDC net flows:
    ///         Alice's net position = payout − cost (she should profit if payout > cost).
    function test_binary_exactUSDCFlows_endToEnd() public {
        uint256 poolInitial  = usdc.balanceOf(address(pool));
        uint256 aliceInitial = usdc.balanceOf(alice);

        uint256 cost = _buy(market2, alice, 0, 10e18);

        // After buy: pool gained cost, alice lost cost.
        assertEq(usdc.balanceOf(address(pool)), poolInitial + cost, "pool +cost after buy");
        assertEq(usdc.balanceOf(alice),         aliceInitial - cost, "alice -cost after buy");

        _resolve(market2, 0);
        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(market2));
        uint256 payout = info.settledPayout;

        _claim(market2, alice);

        // Net flows must balance: pool net = cost − payout; alice net = payout − cost.
        assertEq(
            usdc.balanceOf(address(pool)),
            poolInitial + cost - payout,
            "pool net balance after claim"
        );
        assertEq(
            usdc.balanceOf(alice),
            aliceInitial - cost + payout,
            "alice net balance after claim"
        );
        _assertPoolSolvent();
    }

    /*//////////////////////////////////////////////////////////////
           7-OUTCOME MARKET — LIFECYCLE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Multi-outcome happy path: three traders back different outcomes;
    ///         correct winner identified and paid out; losers cannot claim.
    function test_7outcome_multipleBuyers_correctWinnerClaims() public {
        // Alice: outcome 0 | Bob: outcome 3 | Carol: outcome 6
        _buy(market7, alice, 0, 10e18);
        _buy(market7, bob,   3, 10e18);
        _buy(market7, carol, 6, 10e18);

        // Resolve: outcome 3 wins → Bob is the winner.
        _resolve(market7, 3);

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(market7));
        assertTrue(info.settled,    "7-outcome market settled");
        assertGt(info.settledPayout, 0, "non-zero payout for outcome 3 buyers");

        // Bob claims.
        uint256 bobBefore = usdc.balanceOf(bob);
        _claim(market7, bob);
        assertGt(usdc.balanceOf(bob), bobBefore, "bob received payout");

        // Alice and Carol cannot claim.
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.NoWinningShares.selector);
        market7.claim();

        vm.prank(carol);
        vm.expectRevert(BlieverMarket.NoWinningShares.selector);
        market7.claim();

        _assertPoolSolvent();
    }

    /// @notice CSS sell: Alice holds 5e18 of outcome 0 but sells 10e18 →
    ///         CSS translates the excess (tBar = 5e18) into shares of outcomes 1–6.
    ///         After CSS, Alice has no outcome-0 shares but holds tBar shares on each
    ///         of the other 6 outcomes.  Resolving outcome 1 lets her claim a payout.
    function test_7outcome_CSSSell_translatesPosition_winnerClaims() public {
        // Alice buys 5e18 of outcome 0.
        _buy(market7, alice, 0, 5e18);
        assertEq(market7.getShares(alice, 0), 5e18, "alice holds 5e18 of outcome 0");

        // Verify CSS translation amount via view function.
        uint256 tBar = market7.getCssTranslation(alice, 0, 10e18);
        assertEq(tBar, 5e18, "tBar = shareAmount − traderBal = 5e18");

        // CSS sell: Alice sells 10e18 of outcome 0 (holds only 5e18 → CSS fires).
        _sell(market7, alice, 0, 10e18);

        // Post-CSS: outcome 0 balance is 0; each other outcome received +tBar.
        assertEq(market7.getShares(alice, 0), 0,    "alice outcome-0 balance zeroed");
        assertEq(market7.getShares(alice, 1), tBar, "alice received tBar on outcome 1");
        assertEq(market7.getShares(alice, 2), tBar, "alice received tBar on outcome 2");
        assertEq(market7.getShares(alice, 6), tBar, "alice received tBar on outcome 6");

        // Pool state is still valid.
        _assertPoolSolvent();

        // Resolve outcome 1 — Alice now has a winning position.
        _resolve(market7, 1);

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        _claim(market7, alice);

        // Alice's payout = floor(tBar / SHARE_TO_USDC) = floor(5e18 / 1e12) = 5e6 USDC
        uint256 expectedPayout = tBar / SHARE_TO_USDC;
        assertEq(
            usdc.balanceOf(alice) - aliceBalBefore,
            expectedPayout,
            "alice payout equals floor(tBar / SHARE_TO_USDC)"
        );
        _assertPoolSolvent();
    }

    /// @notice Unresolved market expired by the factory after resolutionDeadline passes.
    ///         pool.settleMarket(0) is called → zero payout, all riskBudget absorbed by LPs.
    ///         Trader who bought shares cannot claim anything.
    function test_expireUnresolved_zeroPayout_traderCannotClaim() public {
        // Alice buys before deadline.
        _buy(market2, alice, 0, 5e18);

        uint256 liabBefore = pool.totalLiability();

        // Advance past resolution deadline — trading is also closed at this point.
        vm.warp(resolutionDeadline + 1);

        // Factory (address(this)) expires the market.
        _expireUnresolved(market2);

        // Market is marked resolved with winningOutcome = outcomeCount (= 2, invalid index).
        assertTrue(market2.resolved(), "market resolved after expiry");
        assertEq(uint256(market2.winningOutcome()), uint256(market2.outcomeCount()),
            "winningOutcome set to outcomeCount (expiry sentinel)");

        // Pool settled with zero payout → full riskBudget credit stays with vault.
        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(market2));
        assertTrue(info.settled,         "pool: market settled");
        assertEq(info.settledPayout, 0,  "pool: zero payout on expiry");

        // Liability from this market is fully released
        // (market7 is still active so we check the reduction, not absolute 0)
        assertLt(pool.totalLiability(), liabBefore, "totalLiability reduced after expiry");
        _assertPoolSolvent();

        // Alice holds shares of outcome 0, but winningOutcome = 2 → shares[alice][2] = 0
        // → NoWinningShares.
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.NoWinningShares.selector);
        market2.claim();
    }

    /*//////////////////////////////////////////////////////////////
          LIABILITY TRACKING — VERIFY POOL ACCOUNTING ON TRADES
    //////////////////////////////////////////////////////////////*/

    /// @notice currentLiability in the pool's MarketInfo decreases (or stays ≤ riskBudget)
    ///         as trading volume grows, reflecting the LS-LMSR Prop 4.9 bound.
    function test_binary_liabilityBounded_afterMultipleBuys() public {
        BlieverV1Pool.MarketInfo memory infoAtStart =
            pool.getMarketInfo(address(market2));

        assertEq(
            infoAtStart.currentLiability, MAX_RISK,
            "initial currentLiability == riskBudget"
        );

        // Multiple buy trades on the same outcome.
        _buy(market2, alice, 0, 20e18);
        _buy(market2, bob,   0, 20e18);
        _buy(market2, carol, 1, 20e18);

        BlieverV1Pool.MarketInfo memory infoAfterTrades =
            pool.getMarketInfo(address(market2));

        // Belt-and-suspenders cap guarantees currentLiability ≤ riskBudget always.
        assertLe(
            infoAfterTrades.currentLiability,
            infoAfterTrades.riskBudget,
            "currentLiability ≤ riskBudget after buys"
        );
        _assertPoolSolvent();
    }

    /// @notice After buying and then selling all shares back, the trader's share
    ///         balance is zero and the pool is still solvent.
    function test_binary_buyAllSellAll_poolRemainsSolvent() public {
        uint256 shareAmt = 10e18;
        _buy(market2, alice, 0, shareAmt);

        // Sell full position.
        _sell(market2, alice, 0, shareAmt);

        assertEq(market2.getShares(alice, 0), 0, "alice's shares zeroed after full sell");
        _assertPoolSolvent();

        // Market is still active and tradeable.
        assertTrue(pool.isActiveMarket(address(market2)), "market still active");
    }
}
