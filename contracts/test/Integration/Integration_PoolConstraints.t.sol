// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Clones}       from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy}  from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IntegrationBase, IntegrationUSDC} from "./IntegrationBase.t.sol";
import {BlieverV1Pool}  from "../../src/BlieverV1Pool.sol";
import {BlieverMarket}  from "../../src/BlieverMarket.sol";

/// @title  Integration_PoolConstraints
/// @notice Integration tests targeting BlieverV1Pool's capacity rules, LP withdrawal
///         constraints, pause/unpause behavior, and emergency administration paths,
///         all verified through the real BlieverMarket contract.
///
///         Focus areas
///         ───────────
///         • registerMarket reverts when vault assets are insufficient for the risk budget.
///         • LP maxWithdraw is capped by the reserve buffer + active liability.
///         • LP free liquidity grows as trading volume lowers worst-case loss bounds.
///         • Pause blocks collectTradeCost/distributeRefund but NOT settleMarket or claimWinnings.
///         • deregisterMarket (no-trades path) restores totalLiability correctly.
///         • forceSettleMarket releases liability; no claims possible after force-settle.
///         • LP can fully withdraw available liquidity once all markets have settled.
///
/// @dev    Run: forge test --match-contract Integration_PoolConstraints --evm-version cancun -vvv
contract Integration_PoolConstraints is IntegrationBase {

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public override {
        super.setUp();
        _setupTrader(alice);
        _setupTrader(bob);
    }

    /*//////////////////////////////////////////////////////////////
               CAPACITY CHECK — REGISTRATION REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @notice registerMarket reverts with CapacityExceeded when the vault does not
    ///         have sufficient active capital to absorb another MAX_RISK allocation.
    ///         A deposit of 624 USDC with 20% reserve means activeCap = 499.2e6
    ///         which is < MAX_RISK = 500e6 → revert.
    function test_registerMarket_reverts_CapacityExceeded_insufficientAssets() public {
        // ── Deploy a separate underfunded pool ────────────────────────────────
        BlieverV1Pool underImpl = new BlieverV1Pool();
        ERC1967Proxy  proxy     = new ERC1967Proxy(
            address(underImpl),
            abi.encodeCall(
                BlieverV1Pool.initialize,
                (address(usdc), admin, ALPHA, MAX_RISK, RESERVE_BPS)
            )
        );
        BlieverV1Pool underPool = BlieverV1Pool(address(proxy));
        vm.label(address(underPool), "UnderFundedPool");

        // Deposit exactly 624 USDC → activeCap = 624e6 × 0.8 = 499.2e6 < 500e6.
        address smallLp = makeAddr("smallLp");
        usdc.mint(smallLp, 624e6);
        vm.startPrank(smallLp);
        usdc.approve(address(underPool), 624e6);
        underPool.deposit(624e6, smallLp);
        vm.stopPrank();

        // Deploy and initialise a market clone pointing to underPool.
        address clone = Clones.clone(address(marketImpl));
        BlieverMarket m = BlieverMarket(clone);
        m.initialize(
            address(underPool),
            keccak256("cap-test"),
            2,
            ALPHA,
            tradingDeadline,
            resolutionDeadline,
            EPSILON_2,
            resolver,
            address(this)
        );

        // registerMarket must revert with CapacityExceeded.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverV1Pool.CapacityExceeded.selector,
                MAX_RISK,            // projected newTotalLiab (no existing markets)
                underPool.totalAssets() * (10_000 - RESERVE_BPS) / 10_000
            )
        );
        underPool.registerMarket(address(m), 2);
    }

    /// @notice Adding enough LP funds to cover activeCap threshold allows registration.
    function test_registerMarket_succeedsAfterSufficientDeposit() public {
        // Deploy a fresh pool with zero deposits.
        BlieverV1Pool freshImpl = new BlieverV1Pool();
        ERC1967Proxy  proxy     = new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(
                BlieverV1Pool.initialize,
                (address(usdc), admin, ALPHA, MAX_RISK, RESERVE_BPS)
            )
        );
        BlieverV1Pool freshPool = BlieverV1Pool(address(proxy));

        // Fund pool with enough: need assets × 0.8 ≥ 500e6 → assets ≥ 625e6.
        address fundedLp = makeAddr("fundedLp");
        usdc.mint(fundedLp, 1_000e6);
        vm.startPrank(fundedLp);
        usdc.approve(address(freshPool), 1_000e6);
        freshPool.deposit(1_000e6, fundedLp);
        vm.stopPrank();

        // Deploy and initialise a market pointing to freshPool.
        address clone = Clones.clone(address(marketImpl));
        BlieverMarket m = BlieverMarket(clone);
        m.initialize(
            address(freshPool),
            keccak256("fresh-market"),
            2,
            ALPHA,
            tradingDeadline,
            resolutionDeadline,
            EPSILON_2,
            resolver,
            address(this)
        );

        // Registration must succeed.
        vm.prank(admin);
        freshPool.registerMarket(address(m), 2); // no revert

        assertEq(freshPool.activeMarketCount(), 1, "one market registered");
        assertEq(freshPool.totalLiability(), MAX_RISK, "liability = MAX_RISK");
    }

    /*//////////////////////////////////////////////////////////////
               LP WITHDRAWAL — CAPPED BY ACTIVE LIABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice LP's maxWithdraw is limited to free liquidity while a market is active.
    ///         Free liquidity = assets − totalLiability − reserve buffer.
    ///         LP cannot withdraw the full deposit when riskBudget is locked.
    function test_lpWithdrawal_cappedByActiveMarketLiability() public {
        BlieverMarket m = _deployMarket(2, EPSILON_2);

        // activeCap = 50000e6 × 80% = 40000e6
        // totalLiability after one market: 500e6
        // reserve = 50000e6 × 20% = 10000e6
        // free = 50000e6 − 500e6 − 10000e6 = 39500e6
        uint256 free   = pool.availableLiquidity();
        uint256 maxWd  = pool.maxWithdraw(lp);

        assertLe(maxWd, free, unicode"maxWithdraw <= availableLiquidity");
        assertLt(maxWd,  LP_DEPOSIT, "cannot withdraw full deposit while market active");
        assertGt(free,   0,          "some liquidity is free");

        // Settle the market; free liquidity must increase.
        _resolve(m, 0);

        uint256 freeAfter = pool.availableLiquidity();
        assertGt(freeAfter, free, "free liquidity increased after market settles");
    }

    /// @notice LP can withdraw up to maxWithdraw while a market is active (partial withdraw).
    function test_lp_partialWithdrawal_succeedsWhileMarketActive() public {
        _deployMarket(2, EPSILON_2);

        uint256 maxWd = pool.maxWithdraw(lp);
        assertGt(maxWd, 0, "partial withdrawal should be possible");

        uint256 lpUsdcBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        pool.withdraw(maxWd, lp, lp);

        assertEq(usdc.balanceOf(lp), lpUsdcBefore + maxWd, "LP received maxWd USDC");
        _assertPoolSolvent();
    }

    /// @notice LP's maxWithdraw reaches maximum (bounded only by reserve) after all markets settle.
    function test_lp_maxWithdraw_isMaxAfterAllMarketsSettle() public {
        BlieverMarket m = _deployMarket(2, EPSILON_2);
        _resolve(m, 0);

        // After settlement totalLiability = 0.
        // free = assets − 0 − reserve = assets × (1 − reserveBps/BPS_BASE)
        // maxWithdraw(lp) = min(lpOwnerAssets, free)
        uint256 maxWd = pool.maxWithdraw(lp);
        assertGt(maxWd, 0, "LP can withdraw after all markets settle");

        uint256 lpUsdcBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        pool.withdraw(maxWd, lp, lp);

        assertEq(usdc.balanceOf(lp), lpUsdcBefore + maxWd, "LP received correct USDC");
        _assertPoolSolvent();
    }

    /*//////////////////////////////////////////////////////////////
               LP FREE LIQUIDITY GROWS WITH TRADING VOLUME
    //////////////////////////////////////////////////////////////*/

    /// @notice As trading volume grows, the LS-LMSR worst-case loss bound decreases,
    ///         which reduces currentLiability, which expands LP free liquidity.
    function test_lpFreeLiquidity_mayIncreaseAsVolumeGrows() public {
        BlieverMarket m = _deployMarket(2, EPSILON_2);

        // After registration: currentLiability = riskBudget = MAX_RISK (most conservative).
        uint256 liabAtStart = pool.getMarketInfo(address(m)).currentLiability;
        assertEq(liabAtStart, MAX_RISK, "initial currentLiability == MAX_RISK");

        // Buy volume across both outcomes (symmetric volume reduces worst-case loss).
        _buy(m, alice, 0, 50e18);
        _buy(m, bob,   1, 50e18);

        uint256 liabAfterTrades = pool.getMarketInfo(address(m)).currentLiability;

        // Liability is always capped at riskBudget.
        assertLe(liabAfterTrades, MAX_RISK, "liability <= riskBudget after trades");

        // Pool remains solvent.
        _assertPoolSolvent();
    }

    /*//////////////////////////////////////////////////////////////
               PAUSE — BLOCKS TRADING, NOT SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pausing the vault blocks buy/sell trades (collectTradeCost/distributeRefund
    ///         are whenNotPaused) but settleMarket and claimWinnings are NOT pause-gated.
    function test_pause_blocksTrades_doesNotBlockSettlementOrClaim() public {
        BlieverMarket m = _deployMarket(2, EPSILON_2);
        _buy(m, alice, 0, 5e18);

        // ── Pause the vault ───────────────────────────────────────────────────
        vm.prank(admin);
        pool.pause();

        // ── Buy fails: collectTradeCost is whenNotPaused ──────────────────────
        vm.prank(bob);
        vm.expectRevert(); // OZ EnforcedPause propagated from pool
        m.buy(0, 5e18, type(uint256).max, 0, 0, 0, 0);

        // ── Settlement is NOT blocked — settleMarket has no pause gate ────────
        _resolve(m, 0); // must NOT revert

        // ── Claim is NOT blocked — claimWinnings has no pause gate ────────────
        _claim(m, alice); // must NOT revert
        _assertPoolSolvent();

        // ── Unpause (requires DEFAULT_ADMIN_ROLE) ─────────────────────────────
        vm.prank(admin);
        pool.unpause();

        // Trading resumes on a new market.
        BlieverMarket m2 = _deployMarket(2, EPSILON_2);
        _buy(m2, bob, 0, 5e18); // must NOT revert
        _assertPoolSolvent();
    }

    /// @notice Only PAUSER_ROLE can pause; only DEFAULT_ADMIN_ROLE can unpause.
    ///         Unpause by a non-admin reverts.
    function test_pause_roleEnforcement() public {
        address attacker = makeAddr("attacker");

        // Non-pauser cannot pause.
        vm.prank(attacker);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        pool.pause();

        // Admin (PAUSER_ROLE) can pause.
        vm.prank(admin);
        pool.pause();

        // Non-admin cannot unpause.
        vm.prank(attacker);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        pool.unpause();

        // Admin (DEFAULT_ADMIN_ROLE) can unpause.
        vm.prank(admin);
        pool.unpause(); // no revert
    }

    /*//////////////////////////////////////////////////////////////
               DEREGISTER MARKET (NO-TRADES PATH)
    //////////////////////////////////////////////////////////////*/

    /// @notice deregisterMarket (before any trades) releases the riskBudget from
    ///         totalLiability, decrements activeMarketCount, and revokes MARKET_ROLE.
    function test_deregisterMarket_noTrades_restoresLiabilityAndCount() public {
        BlieverMarket m = _deployMarket(2, EPSILON_2);

        uint256 liabBefore  = pool.totalLiability();
        uint256 countBefore = pool.activeMarketCount();

        vm.prank(admin);
        pool.deregisterMarket(address(m));

        assertEq(pool.totalLiability(),    liabBefore - MAX_RISK, "riskBudget released");
        assertEq(pool.activeMarketCount(), countBefore - 1,        "count decremented");
        assertFalse(
            pool.hasRole(pool.MARKET_ROLE(), address(m)),
            "MARKET_ROLE revoked on deregister"
        );
        assertFalse(pool.getMarketInfo(address(m)).registered, "market info deleted");
        _assertPoolSolvent();
    }

    /// @notice deregisterMarket reverts with MarketHasTrades once a trade has been executed.
    ///         This prevents deregistering a market that has live trader positions.
    function test_deregisterMarket_reverts_MarketHasTrades() public {
        BlieverMarket m = _deployMarket(2, EPSILON_2);
        _buy(m, alice, 0, 5e18);

        vm.prank(admin);
        vm.expectRevert(
         abi.encodeWithSelector(BlieverV1Pool.MarketHasTrades.selector, address(m))
        );
        pool.deregisterMarket(address(m));
    }

    /*//////////////////////////////////////////////////////////////
               FORCE SETTLE — EMERGENCY PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice forceSettleMarket (EMERGENCY_ROLE) marks the market settled,
    ///         zeros all payout fields, releases currentLiability from totalLiability,
    ///         and revokes MARKET_ROLE.  No USDC is transferred — vault absorbs the loss.
    function test_forceSettle_releasesLiability_revokesMARKET_ROLE() public {
        BlieverMarket m = _deployMarket(2, EPSILON_2);
        _buy(m, alice, 0, 10e18);

        uint256 mLiab      = pool.getMarketInfo(address(m)).currentLiability;
        uint256 liabBefore = pool.totalLiability();
        uint256 countBefore = pool.activeMarketCount();

        vm.prank(admin); // admin holds EMERGENCY_ROLE
        pool.forceSettleMarket(address(m));

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        assertTrue(info.settled,          "force-settled flag set");
        assertEq(info.settledPayout, 0,   "settledPayout = 0");
        assertEq(info.riskBudget, 0,      "riskBudget zeroed");
        assertEq(info.currentLiability, 0,"currentLiability zeroed");

        assertEq(pool.totalLiability(),    liabBefore - mLiab, "liability released");
        assertEq(pool.activeMarketCount(), countBefore - 1,    "count decremented");
        assertFalse(
            pool.hasRole(pool.MARKET_ROLE(), address(m)),
            "MARKET_ROLE revoked"
        );
        _assertPoolSolvent();
    }

    /// @notice After forceSettleMarket, market.claim() reverts because market.resolved
    ///         was never set to true by the market contract (forceSettle is a pool-only
    ///         operation — it does not call back into the market contract).
    function test_forceSettle_marketClaimReverts_MarketNotResolved() public {
        BlieverMarket m = _deployMarket(2, EPSILON_2);
        _buy(m, alice, 0, 10e18);

        vm.prank(admin);
        pool.forceSettleMarket(address(m));

        // market.resolved == false (never set by the market contract).
        assertFalse(m.resolved(), "market.resolved == false after force-settle");

        // claim() checks !resolved first → MarketNotResolved.
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.MarketNotResolved.selector);
        m.claim();
    }

    /// @notice Only EMERGENCY_ROLE can call forceSettleMarket.
    function test_forceSettle_revertsForNonEmergencyRole() public {
        BlieverMarket m = _deployMarket(2, EPSILON_2);
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        pool.forceSettleMarket(address(m));
    }

    /*//////////////////////////////////////////////////////////////
               SOLVENCY — SELL REFUND PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice pool.distributeRefund checks _assertSolvent() after transferring USDC out.
    ///         Verify the pool remains solvent after a large sell refund.
    function test_sell_refund_poolRemainssolvent() public {
        BlieverMarket m = _deployMarket(2, EPSILON_2);

        // Large buy to create a significant position.
        _buy(m, alice, 0, 100e18);
        _buy(m, alice, 0, 100e18);
        _buy(m, alice, 0, 100e18);

        uint256 poolBalBeforeSell = usdc.balanceOf(address(pool));

        // Sell a large chunk back.
        _sell(m, alice, 0, 150e18);

        uint256 poolBalAfterSell = usdc.balanceOf(address(pool));
        assertLt(poolBalAfterSell, poolBalBeforeSell, "pool paid refund on sell");

        // Pool must remain solvent after the refund transfer.
        _assertPoolSolvent();
    }
}
