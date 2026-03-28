// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2}  from "forge-std/Test.sol";

import {BlieverMarket}   from "../../src/BlieverMarket.sol";
import {BlieverMarketBase} from "./BlieverMarketBase.t.sol";

/// @title  BlieverMarket — Resolution Tests
/// @notice Covers the full post-trading lifecycle:
///           RESOLVE        — resolver calls resolve(), vault is notified, trading closes.
///           CLAIM          — winner redeems shares, dust path, double-claim guard.
///           EXPIRE         — factory settles unresolved market after deadline with zero payout.
///
/// @dev    Run: forge test --match-contract BlieverMarket_ResolutionTest --evm-version cancun -vvv
contract BlieverMarket_ResolutionTest is BlieverMarketBase {

    /*//////////////////////////////////////////////////////////////
                          RESOLVE — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev resolve() sets resolved=true and winningOutcome, then calls pool.settleMarket.
    function test_resolve_succeeds_setsState() public {
        pool.resetCounters();
        vm.prank(resolver);
        market2.resolve(1); // outcome 1 wins

        assertTrue(market2.resolved(),           "market resolved");
        assertEq(market2.winningOutcome(), 1,    "winning outcome stored");
        assertEq(pool.settleCalls(),       1,    "settleMarket called once");
    }

    /// @dev totalPayoutUsdc passed to settleMarket equals floor(totalTraderShares / SHARE_TO_USDC).
    ///      When no traders bought, totalTraderShares = 0 → settleMarket(0).
    function test_resolve_settleMarket_zeroWhenNoTraders() public {
        vm.prank(resolver);
        market2.resolve(0);

        assertEq(pool.lastSettledPayout(), 0, "zero payout when no traders");
    }

    /// @dev totalPayoutUsdc is floor(totalTraderShares[winning]) when traders exist.
    function test_resolve_settleMarket_correctPayoutWithTraders() public {
        // Alice buys 1 share of outcome 0 → totalTraderShares[0] = 1e18
        _buy(market2, alice, 0, SHARE_1);

        uint256 totalShares    = market2.getTotalTraderShares(0);
        uint256 expectedPayout = totalShares / 1e12; // floor to USDC 6-dec

        vm.prank(resolver);
        market2.resolve(0);

        assertEq(pool.lastSettledPayout(), expectedPayout, "payout = floor(totalShares / 1e12)");
    }

    /// @dev MarketResolved event is emitted with correct parameters.
    function test_resolve_emits_MarketResolved() public {
        _buy(market2, alice, 0, SHARE_1);
        uint256 expectedPayout = market2.getTotalTraderShares(0) / 1e12;

        vm.expectEmit(true, false, false, true, address(market2));
        emit BlieverMarket.MarketResolved(0, expectedPayout);

        vm.prank(resolver);
        market2.resolve(0);
    }

    /// @dev After resolve(), buy and sell are blocked (TradingClosed).
    function test_resolve_closesTrading() public {
        vm.prank(resolver);
        market2.resolve(0);

        _setupTrader(alice, TRADER_USDC);
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.TradingClosed.selector);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev resolve() is NOT gated by pause — markets must always be settleable.
    function test_resolve_notPauseGated() public {
        vm.prank(factory);
        market2.pause();

        vm.prank(resolver);
        market2.resolve(1); // should succeed despite pause

        assertTrue(market2.resolved(), "market resolved even when paused");
    }

    /*//////////////////////////////////////////////////////////////
                          RESOLVE — REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_resolve_revert_notResolver() public {
        vm.prank(attacker);
        vm.expectRevert(BlieverMarket.NotResolver.selector);
        market2.resolve(0);
    }

    function test_resolve_revert_alreadyResolved() public {
        _resolve(market2, 0);
        vm.prank(resolver);
        vm.expectRevert(BlieverMarket.MarketAlreadyResolved.selector);
        market2.resolve(0);
    }

    /// @dev resolve() reverts if called after resolutionDeadline.
    function test_resolve_revert_afterResolutionDeadline() public {
        vm.warp(deployTs + T_RESOLUTION + 1); // past the resolution deadline
        vm.prank(resolver);
        vm.expectRevert(BlieverMarket.ResolutionDeadlinePassed.selector);
        market2.resolve(0);
    }

    /// @dev resolve() reverts at exactly resolutionDeadline.
    function test_resolve_revert_atExactResolutionDeadline() public {
        vm.warp(deployTs + T_RESOLUTION);
        vm.prank(resolver);
        vm.expectRevert(BlieverMarket.ResolutionDeadlinePassed.selector);
        market2.resolve(0);
    }

    function test_resolve_revert_invalidOutcomeIndex() public {
        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(BlieverMarket.InvalidOutcomeIndex.selector, 2, 2)
        );
        market2.resolve(2); // outcomeCount=2, valid [0,1]
    }

    /*//////////////////////////////////////////////////////////////
                           CLAIM — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Winner claims USDC equal to floor(shares / 1e12).
    function test_claim_succeeds_winner() public {
        _buy(market2, alice, 0, SHARE_1); // alice: 1 share of outcome 0
        _resolve(market2, 0);             // outcome 0 wins

        uint256 aliceShares   = market2.getShares(alice, 0);
        uint256 expectedPayout = aliceShares / 1e12;

        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        market2.claim();

        assertEq(usdc.balanceOf(alice) - usdcBefore, expectedPayout, "alice receives correct USDC");
        assertTrue(market2.hasClaimed(alice),                          "claimed flag set");
    }

    /// @dev WinningsClaimed event emitted with correct arguments.
    function test_claim_emits_WinningsClaimed() public {
        _buy(market2, alice, 0, SHARE_1);
        _resolve(market2, 0);

        uint256 aliceShares    = market2.getShares(alice, 0);
        uint256 expectedPayout = aliceShares / 1e12;

        vm.expectEmit(true, true, false, true, address(market2));
        emit BlieverMarket.WinningsClaimed(alice, 0, aliceShares, expectedPayout);

        vm.prank(alice);
        market2.claim();
    }

    /// @dev pool.claimWinnings is called with winner's address and correct amount.
    function test_claim_callsPool_claimWinnings() public {
        _buy(market2, alice, 0, SHARE_1);
        _resolve(market2, 0);
        pool.resetCounters();

        vm.prank(alice);
        market2.claim();

        assertEq(pool.claimCalls(),    1,     "claimWinnings called once");
        assertEq(pool.lastWinner(),    alice, "correct winner address");
        assertGt(pool.lastClaimAmount(), 0,   "non-zero payout");
    }

    /// @dev Multiple winners claim independently; each gets their proportional share.
    function test_claim_multiple_winners_independentPayouts() public {
        // Alice buys 1 share of outcome 0; Bob buys 2 shares of outcome 0
        _buy(market2, alice, 0, SHARE_1);
        _buy(market2, bob,   0, 2 * SHARE_1);
        _resolve(market2, 0);

        uint256 alicePayout = market2.getShares(alice, 0) / 1e12;
        uint256 bobPayout   = market2.getShares(bob,   0) / 1e12;

        // Alice claims
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market2.claim();
        assertEq(usdc.balanceOf(alice) - aliceBefore, alicePayout, "alice's payout correct");

        // Bob claims
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        market2.claim();
        assertEq(usdc.balanceOf(bob) - bobBefore, bobPayout, "bob's payout correct");
    }

    /// @dev Non-winning-outcome holders get NoWinningShares; only outcome 0 winners can claim.
    function test_claim_loser_gets_noWinningShares() public {
        _buy(market2, alice, 0, SHARE_1); // alice holds outcome 0
        _buy(market2, bob,   1, SHARE_1); // bob holds outcome 1
        _resolve(market2, 0); // outcome 0 wins

        // Bob (holds outcome 1 shares, not the winning outcome) cannot claim
        vm.prank(bob);
        vm.expectRevert(BlieverMarket.NoWinningShares.selector);
        market2.claim();
    }

    /// @dev claim() is NOT gated by pause.
    function test_claim_notPauseGated() public {
        _buy(market2, alice, 0, SHARE_1);
        _resolve(market2, 0);

        vm.prank(factory);
        market2.pause();

        vm.prank(alice);
        market2.claim(); // must succeed despite pause
        assertTrue(market2.hasClaimed(alice));
    }

    /// @dev Dust path: shares < 1e12 → payoutUsdc = 0, DustForfeited emitted, no pool call.
    function test_claim_dust_emits_DustForfeited_noPoolCall() public {
        // Resolve with no prior buys (totalPayout = 0)
        vm.prank(resolver);
        market2.resolve(0);

        // Inject dust shares directly into alice's slot (bypasses MIN_SHARE_AMOUNT)
        // Storage layout: _shares is mapping slot 9
        bytes32 dustSlot = _sharesSlot(alice, 0);
        vm.store(address(market2), dustSlot, bytes32(uint256(DUST_SHARE))); // 1e11 < 1e12

        pool.resetCounters();

        vm.expectEmit(true, true, false, true, address(market2));
        emit BlieverMarket.DustForfeited(alice, 0, DUST_SHARE);

        vm.prank(alice);
        market2.claim();

        assertTrue(market2.hasClaimed(alice),  "claimed flag set on dust");
        assertEq(pool.claimCalls(),    0,       "claimWinnings NOT called for dust");
    }

    /*//////////////////////////////////////////////////////////////
                           CLAIM — REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_claim_revert_notResolved() public {
        _buy(market2, alice, 0, SHARE_1);
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.MarketNotResolved.selector);
        market2.claim();
    }

    function test_claim_revert_alreadyClaimed() public {
        _buy(market2, alice, 0, SHARE_1);
        _resolve(market2, 0);

        vm.prank(alice);
        market2.claim(); // first claim succeeds

        vm.prank(alice);
        vm.expectRevert(BlieverMarket.AlreadyClaimed.selector);
        market2.claim(); // second claim reverts
    }

    function test_claim_revert_noWinningShares() public {
        // Alice holds outcome 1 shares; outcome 0 wins
        _buy(market2, alice, 1, SHARE_1);
        _resolve(market2, 0);

        vm.prank(alice);
        vm.expectRevert(BlieverMarket.NoWinningShares.selector);
        market2.claim();
    }

    /// @dev Trader with zero shares in winning outcome (never bought any) cannot claim.
    function test_claim_revert_neverBoughtWinningOutcome() public {
        _resolve(market2, 0);
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.NoWinningShares.selector);
        market2.claim();
    }

    /*//////////////////////////////////////////////////////////////
                        EXPIRE UNRESOLVED — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev expireUnresolved() settles the market after resolutionDeadline passes.
    ///      pool.settleMarket(0) is called → LPs absorb the full risk budget.
    function test_expire_succeeds_setsResolvedTrue() public {
        vm.warp(deployTs + T_RESOLUTION + 1); // past resolution deadline
        pool.resetCounters();

        vm.prank(factory);
        market2.expireUnresolved();

        assertTrue(market2.resolved(),            "resolved flag set");
        assertEq(pool.settleCalls(),  1,           "settleMarket called");
        assertEq(pool.lastSettledPayout(), 0,      "settleMarket(0) — zero payout");
    }

    /// @dev After expiry, winningOutcome = outcomeCount (out of range) so no one can claim.
    function test_expire_winningOutcome_equalsOutcomeCount() public {
        vm.warp(deployTs + T_RESOLUTION + 1);
        vm.prank(factory);
        market2.expireUnresolved();

        // winningOutcome = outcomeCount = 2 (no trader holds shares at index 2)
        assertEq(market2.winningOutcome(), 2, "winningOutcome = outcomeCount after expire");
    }

    /// @dev MarketExpired event is emitted with factory address, timestamp, and TIMEOUT reason.
    function test_expire_emits_MarketExpired() public {
        vm.warp(deployTs + T_RESOLUTION + 1);

        vm.expectEmit(true, false, false, true, address(market2));
        emit BlieverMarket.MarketExpired(
            factory,
            uint40(block.timestamp),
            BlieverMarket.ExpiryReason.TIMEOUT
        );

        vm.prank(factory);
        market2.expireUnresolved();
    }

    /// @dev expireUnresolved() is NOT gated by pause.
    function test_expire_notPauseGated() public {
        vm.prank(factory);
        market2.pause();

        vm.warp(deployTs + T_RESOLUTION + 1);
        vm.prank(factory);
        market2.expireUnresolved(); // succeeds even when paused
        assertTrue(market2.resolved());
    }

    /// @dev After expiry, no trader can claim (NoWinningShares — all balances at index outcomeCount are 0).
    function test_expire_noClaims_possible() public {
        _buy(market2, alice, 0, SHARE_1); // alice has shares of outcome 0

        vm.warp(deployTs + T_RESOLUTION + 1);
        vm.prank(factory);
        market2.expireUnresolved();

        // Alice's shares at winningOutcome(=2) are 0 → NoWinningShares
        vm.prank(alice);
        vm.expectRevert(BlieverMarket.NoWinningShares.selector);
        market2.claim();
    }

    /*//////////////////////////////////////////////////////////////
                      EXPIRE UNRESOLVED — REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_expire_revert_notFactory() public {
        vm.warp(deployTs + T_RESOLUTION + 1);
        vm.prank(attacker);
        vm.expectRevert(BlieverMarket.NotFactory.selector);
        market2.expireUnresolved();
    }

    function test_expire_revert_alreadyResolved() public {
        _resolve(market2, 0); // resolve normally first
        vm.warp(deployTs + T_RESOLUTION + 1);

        vm.prank(factory);
        vm.expectRevert(BlieverMarket.MarketAlreadyResolved.selector);
        market2.expireUnresolved();
    }

    /// @dev Cannot expire BEFORE resolutionDeadline has passed.
    function test_expire_revert_deadlineNotPassed() public {
        // Still within the resolution window
        vm.warp(deployTs + T_RESOLUTION - 1); // one second before deadline
        vm.prank(factory);
        vm.expectRevert(BlieverMarket.ResolutionDeadlineNotPassed.selector);
        market2.expireUnresolved();
    }

    /// @dev Cannot expire AT exactly resolutionDeadline.
    function test_expire_revert_atExactResolutionDeadline() public {
        vm.warp(deployTs + T_RESOLUTION);
        vm.prank(factory);
        vm.expectRevert(BlieverMarket.ResolutionDeadlineNotPassed.selector);
        market2.expireUnresolved();
    }

    /*//////////////////////////////////////////////////////////////
                    COMBINED LIFECYCLE — END-TO-END
    //////////////////////////////////////////////////////////////*/

    /// @dev Full lifecycle: buy → resolve → claim.
    ///      Alice buys outcome 0; outcome 0 wins; Alice claims 1 USDC per share.
    function test_lifecycle_buy_resolve_claim() public {
        // Setup
        _setupTrader(alice, TRADER_USDC);
        _setupTrader(bob,   TRADER_USDC);

        // Buy
        vm.prank(alice);
        market2.buy(0, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));
        vm.prank(bob);
        market2.buy(1, SHARE_1, MAX_COST, 0, 0, bytes32(0), bytes32(0));

        uint256 aliceShares = market2.getShares(alice, 0);
        uint256 alicePayout = aliceShares / 1e12;

        // Resolve — outcome 0 wins
        _resolve(market2, 0);

        // Alice (winner) claims
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market2.claim();
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, alicePayout, "alice payout correct");

        // Bob (loser) cannot claim
        vm.prank(bob);
        vm.expectRevert(BlieverMarket.NoWinningShares.selector);
        market2.claim();
    }

    /// @dev getMarketStatus() reflects state changes at each lifecycle stage.
    function test_getMarketStatus_reflectsLifecycle() public {
        // Stage 1: tradingOpen
        (, , bool tradingOpen1, , , ) = market2.getMarketStatus();
        assertTrue(tradingOpen1, "initially trading open");

        // Stage 2: after tradingDeadline
        vm.warp(deployTs + T_TRADING + 1);
        (, , bool tradingOpen2, , , ) = market2.getMarketStatus();
        assertFalse(tradingOpen2, "trading closed after deadline");

        // Stage 3: after resolve
        vm.prank(resolver);
        market2.resolve(0);
        (bool r3, uint8 wo3, bool tradingOpen3, , , ) = market2.getMarketStatus();
        assertTrue(r3,            "resolved");
        assertEq(wo3, 0,          "winningOutcome = 0");
        assertFalse(tradingOpen3, "trading closed after resolve");
    }
}
