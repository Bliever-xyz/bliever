// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {IntegrationBase} from "./IntegrationBase.t.sol";
import {BlieverV1Pool}   from "../../src/BlieverV1Pool.sol";
import {BlieverMarket}   from "../../src/BlieverMarket.sol";

/// @title  Integration_MultiMarket
/// @notice Integration tests covering concurrent operation of multiple markets
///         within the same BlieverV1Pool vault.
///
///         Focus areas
///         ───────────
///         • Pool accounting (totalLiability, activeMarketCount) stays accurate
///           while trades happen across multiple live markets simultaneously.
///         • Trading on market A does not corrupt market B's MarketInfo.
///         • LP free liquidity and NAV reflect all active markets correctly.
///         • Pool solvency invariant holds throughout any sequence of interleaved
///           trade, settle, and claim calls across markets.
///
/// @dev    Run: forge test --match-contract Integration_MultiMarket --evm-version cancun -vvv
contract Integration_MultiMarket is IntegrationBase {

    /*//////////////////////////////////////////////////////////////
                              STATE
    //////////////////////////////////////////////////////////////*/

    BlieverMarket internal marketA; // 2-outcome binary market
    BlieverMarket internal marketB; // 7-outcome multi-outcome market

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public override {
        super.setUp();
        marketA = _deployMarket(2, EPSILON_2);
        marketB = _deployMarket(7, EPSILON_7);

        _setupTrader(alice);
        _setupTrader(bob);
        _setupTrader(carol);
    }

    /*//////////////////////////////////////////////////////////////
                 POOL ACCOUNTING — TWO ACTIVE MARKETS
    //////////////////////////////////////////////////////////////*/

    /// @notice On registration, each market adds exactly MAX_RISK to totalLiability
    ///         and increments activeMarketCount by 1.
    function test_twoMarkets_poolAccountingOnRegistration() public {
        assertEq(pool.activeMarketCount(), 2,           "two markets registered");
        assertEq(pool.totalLiability(), 2 * MAX_RISK, unicode"totalLiability = 2 × MAX_RISK");
        assertTrue(pool.isActiveMarket(address(marketA)), "market A active");
        assertTrue(pool.isActiveMarket(address(marketB)), "market B active");
        _assertPoolSolvent();
    }

    /// @notice Trades on market A update market A's MarketInfo fields but leave
    ///         market B's MarketInfo completely unchanged (isolated accounting).
    function test_twoMarkets_tradeOnA_doesNotAffectBMarketInfo() public {
        BlieverV1Pool.MarketInfo memory bBefore =
            pool.getMarketInfo(address(marketB));

        // Trade on A only.
        _buy(marketA, alice, 0, 20e18);
        _buy(marketA, bob,   1, 20e18);

        BlieverV1Pool.MarketInfo memory bAfter =
            pool.getMarketInfo(address(marketB));

        // Market B's accounting is completely isolated.
        assertEq(bAfter.currentLiability, bBefore.currentLiability,
            "market B currentLiability unchanged");
        assertEq(bAfter.riskBudget,       bBefore.riskBudget,
            "market B riskBudget unchanged");
        assertEq(bAfter.hasTrades,        bBefore.hasTrades,
            "market B hasTrades flag unchanged");
        _assertPoolSolvent();
    }

    /// @notice totalLiability is the correct sum of both markets' currentLiabilities.
    ///         After trading on both markets, the pool's single totalLiability value
    ///         equals the sum of the two per-market values.
    function test_twoMarkets_totalLiabilityEqualsSum() public {
        _buy(marketA, alice, 0, 15e18);
        _buy(marketB, bob,   2, 15e18);
        _buy(marketB, carol, 5, 15e18);

        BlieverV1Pool.MarketInfo memory aInfo =
            pool.getMarketInfo(address(marketA));
        BlieverV1Pool.MarketInfo memory bInfo =
            pool.getMarketInfo(address(marketB));

        uint256 expectedTotal = aInfo.currentLiability + bInfo.currentLiability;
        assertEq(
            pool.totalLiability(), expectedTotal,
            "totalLiability == sum of per-market currentLiabilities"
        );
        _assertPoolSolvent();
    }

    /*//////////////////////////////////////////////////////////////
             SEQUENTIAL SETTLEMENT — ACCOUNTING CORRECTNESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle market A while market B is still active.
    ///         Verifies: activeMarketCount goes to 1, totalLiability decreases
    ///         by A's currentLiability, and market B remains fully tradeable.
    function test_twoMarkets_settleA_keepsBActive() public {
        _buy(marketA, alice, 0, 10e18);
        _buy(marketB, bob,   3, 10e18);

        uint256 aLiabBeforeSettle =
            pool.getMarketInfo(address(marketA)).currentLiability;
        uint256 totalLiabBeforeSettle = pool.totalLiability();

        // Settle A.
        _resolve(marketA, 0);

        assertEq(pool.activeMarketCount(), 1, "only B remains active");
        assertFalse(pool.isActiveMarket(address(marketA)), "A no longer active");
        assertTrue(pool.isActiveMarket(address(marketB)),  "B still active");
        assertEq(
            pool.totalLiability(),
            totalLiabBeforeSettle - aLiabBeforeSettle,
            "totalLiability reduced by A's live liability at settle"
        );

        // Claims on A still work normally after B is active.
        _claim(marketA, alice);

        // Market B is still tradeable.
        _buy(marketB, carol, 1, 5e18);
        _assertPoolSolvent();
    }

    /// @notice Settle both markets sequentially; after both are done:
    ///         totalLiability == 0 and activeMarketCount == 0.
    function test_twoMarkets_sequentialFullLifecycle_poolCleanAfter() public {
        // Trades on A.
        _buy(marketA, alice, 0, 10e18);
        _buy(marketA, bob,   1, 5e18);

        // Trades on B.
        _buy(marketB, carol, 3, 10e18);

        // Settle A (outcome 0); Alice claims, Bob cannot.
        _resolve(marketA, 0);
        _claim(marketA, alice);

        vm.prank(bob);
        vm.expectRevert(BlieverMarket.NoWinningShares.selector);
        marketA.claim();

        // Settle B (outcome 3); Carol claims.
        _resolve(marketB, 3);
        _claim(marketB, carol);

        // ── Post-settlement assertions ────────────────────────────────────────
        assertEq(pool.activeMarketCount(), 0, "no active markets remain");
        assertEq(pool.totalLiability(),    0, "zero total liability after both settle");
        assertFalse(pool.isActiveMarket(address(marketA)), "A inactive");
        assertFalse(pool.isActiveMarket(address(marketB)), "B inactive");
        _assertPoolSolvent();
    }

    /*//////////////////////////////////////////////////////////////
             CONCURRENT SOLVENCY INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// @notice Solvency holds at every step during heavily interleaved trading on
    ///         both markets, including buys, sells, settles, and claims.
    function test_twoMarkets_solvencyInvariant_throughoutConcurrentTrading() public {
        // ── Interleaved trades ────────────────────────────────────────────────
        _buy(marketA, alice, 0, 15e18);
        _assertPoolSolvent();                                          // checkpoint S1

        _buy(marketB, bob, 2, 20e18);
        _assertPoolSolvent();                                          // S2

        _sell(marketA, alice, 0, 7e18);
        _assertPoolSolvent();                                          // S3

        _buy(marketB, carol, 5, 10e18);
        _assertPoolSolvent();                                          // S4

        _buy(marketA, bob, 1, 5e18);
        _assertPoolSolvent();                                          // S5

        // ── Settle A while B is still live ────────────────────────────────────
        _resolve(marketA, 0);
        _assertPoolSolvent();                                          // S6

        _claim(marketA, alice);   // Alice still has shares (8e18 remaining after partial sell)
        _assertPoolSolvent();                                          // S7

        // ── More trading on B ─────────────────────────────────────────────────
        _buy(marketB, alice, 3, 5e18);
        _assertPoolSolvent();                                          // S8

        // ── Settle B ─────────────────────────────────────────────────────────
        _resolve(marketB, 2);
        _assertPoolSolvent();                                          // S9

        _claim(marketB, bob);
        _assertPoolSolvent();                                          // S10

        // Final state: pool holds LP capital + net spread; fully solvent.
        assertEq(pool.activeMarketCount(), 0, "all markets settled");
        assertEq(pool.totalLiability(),    0, "zero liability at end");
    }

    /*//////////////////////////////////////////////////////////////
             LP WITHDRAWAL INTERACTION WITH TWO MARKETS
    //////////////////////////////////////////////////////////////*/

    /// @notice LP's maxWithdraw increases as markets settle because each settlement
    ///         releases riskBudget from totalLiability, expanding free liquidity.
    function test_twoMarkets_lpWithdrawal_increasesAsMarketsSettle() public {
        uint256 freeWhileBothActive = pool.availableLiquidity();
        uint256 lpMaxWhileBothActive = pool.maxWithdraw(lp);

        // Settle A (no trades — zero payout, full riskBudget freed).
        _resolve(marketA, 0);

        uint256 freeAfterA = pool.availableLiquidity();
        uint256 lpMaxAfterA = pool.maxWithdraw(lp);

        assertGt(freeAfterA,   freeWhileBothActive, "free liquidity increased after A settles");
        assertGt(lpMaxAfterA,  lpMaxWhileBothActive, "LP maxWithdraw increased after A settles");

        // Settle B (no trades — zero payout, full riskBudget freed).
        _resolve(marketB, 0);

        uint256 freeAfterBoth = pool.availableLiquidity();
        uint256 lpMaxAfterBoth = pool.maxWithdraw(lp);

        assertGt(freeAfterBoth, freeAfterA,  "free liquidity increased after B settles");
        assertGt(lpMaxAfterBoth, lpMaxAfterA, "LP maxWithdraw increased after B settles");
        _assertPoolSolvent();
    }

    /// @notice LP cannot withdraw more than availableLiquidity while both markets
    ///         are active (totalLiability + reserve floor constrain the withdrawal).
    function test_twoMarkets_lpWithdrawal_cappedWhileMarketsActive() public {
        uint256 free     = pool.availableLiquidity();
        uint256 maxWd    = pool.maxWithdraw(lp);

        // LP cannot withdraw more than the free liquidity ceiling.
        assertLe(maxWd, free, "maxWithdraw <= availableLiquidity");

        // LP cannot withdraw the full deposit while markets are active.
        assertLt(maxWd, LP_DEPOSIT, "cannot withdraw full LP deposit while markets active");

        // Withdrawing exactly `maxWd` succeeds.
        if (maxWd > 0) {
            vm.prank(lp);
            pool.withdraw(maxWd, lp, lp);
            _assertPoolSolvent();
        }
    }

    /*//////////////////////////////////////////////////////////////
             POOL NAV REFLECTS MARKET SPREAD INCOME
    //////////////////////////////////////////////////////////////*/

    /// @notice After trading on both markets, pool NAV (totalAssets − totalLiability)
    ///         is strictly greater than the initial NAV because the vault earns spread.
    ///         The vault's profit = Σ (riskBudget_i − settledPayout_i) ≥ 0 per market.
    function test_twoMarkets_navIncreases_afterProfitableSettlement() public {
        // NAV at start: LP_DEPOSIT − 2 × MAX_RISK (both markets' riskBudgets as liability).
        uint256 navBefore = pool.nav();

        // Traders buy on both markets.
        _buy(marketA, alice, 0, 5e18);
        _buy(marketB, bob,   4, 5e18);

        // Settle both: Alice loses (outcome 1 wins), Bob loses (outcome 0 wins).
        // Both traders' USDC stays in the vault → LP profit.
        _resolve(marketA, 1); // Alice bought outcome 0 — loses
        _resolve(marketB, 0); // Bob bought outcome 4 — loses

        uint256 navAfter = pool.nav();

        // Both markets settled with zero payout (losers only) — vault absorbed the spread.
        assertGt(navAfter, navBefore, "NAV increased after profitable settlement");
        assertEq(pool.activeMarketCount(), 0, "all markets settled");
        _assertPoolSolvent();
    }
}
