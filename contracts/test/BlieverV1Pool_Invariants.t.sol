// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/*//////////////////////////////////////////////////////////////
                        FOUNDRY IMPORTS
//////////////////////////////////////////////////////////////*/
import {Test}         from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CommonBase}   from "forge-std/Base.sol";
import {StdCheats}    from "forge-std/StdCheats.sol";
import {StdUtils}     from "forge-std/StdUtils.sol";

/*//////////////////////////////////////////////////////////////
                       OPENZEPPELIN IMPORTS
//////////////////////////////////////////////////////////////*/
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/*//////////////////////////////////////////////////////////////
                     CONTRACT UNDER TEST
//////////////////////////////////////////////////////////////*/
import {BlieverV1Pool} from "../src/BlieverV1Pool.sol";

/*//////////////////////////////////////////////////////////////
                          TEST MOCKS
//////////////////////////////////////////////////////////////*/
import {MockUSDC}   from "./mocks/MockUSDC.sol";
import {MockMarket} from "./mocks/MockMarket.sol";


/*//////////////////////////////////////////////////////////////
                    POOL HANDLER CONTRACT
//////////////////////////////////////////////////////////////*/

/// @notice Stateful fuzzing handler for BlieverV1Pool.
///         The invariant fuzzer calls handler functions in random order
///         with random (but bounded) inputs. After every sequence the
///         invariant_ checks in BlieverV1Pool_InvariantTest run.
///
///         Handler responsibilities:
///           • Keep every call within valid business-logic bounds.
///           • Maintain ghost variables that mirror expected protocol state.
///           • Track all registered markets for invariant verification.
contract PoolHandler is CommonBase, StdCheats, StdUtils {

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MAX_RISK    = 50_000e6;
    uint16  internal constant RESERVE_BPS = 2_000;
    uint256 internal constant BPS_BASE    = 10_000;

    // Maximum markets the handler will attempt to keep live at once.
    // Stays well inside activeCap so registration succeeds consistently.
    uint256 internal constant MAX_HANDLER_MARKETS = 4;

    /*//////////////////////////////////////////////////////////////
                          STATE
    //////////////////////////////////////////////////////////////*/

    BlieverV1Pool public pool;
    MockUSDC      public usdc;
    address       public admin;

    // All MockMarket instances ever deployed by this handler.
    // Includes settled markets so invariant checks can iterate them.
    MockMarket[] public allMarkets;

    // Simple LP set — just two addresses for deposit/withdraw coverage.
    address internal lp1 = address(uint160(uint256(keccak256("lp1"))));
    address internal lp2 = address(uint160(uint256(keccak256("lp2"))));

    // ── Ghost variables ───────────────────────────────────────────────────────
    // These shadow expected protocol values for invariant assertions.
    // They are updated synchronously with every mutating handler call.

    /// @dev Expected sum of currentLiability across all active (unsettled) markets.
    uint256 public ghost_expectedTotalLiability;

    /// @dev Number of markets currently registered and not yet settled.
    uint256 public ghost_activeMarketCount;

    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _pool, address _usdc, address _admin) {
        pool  = BlieverV1Pool(_pool);
        usdc  = MockUSDC(_usdc);
        admin = _admin;

        // Pre-fund LP addresses so deposits are always possible
        usdc.mint(lp1, 1_000_000e6);
        usdc.mint(lp2, 1_000_000e6);

        vm.prank(lp1); usdc.approve(address(pool), type(uint256).max);
        vm.prank(lp2); usdc.approve(address(pool), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    HANDLER — DEPOSIT / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @dev LP deposits USDC into the vault.
    function depositLiquidity(uint256 amount, bool useLP1) external {
        amount = bound(amount, 1e6, 200_000e6); // 1 USDC … 200K USDC
        address who = useLP1 ? lp1 : lp2;

        // Ensure wallet has sufficient balance
        if (usdc.balanceOf(who) < amount) {
            usdc.mint(who, amount);
        }

        vm.prank(who);
        try pool.deposit(amount, who) {} catch {}
        // No ghost update needed — totalAssets is tracked by the vault itself.
    }

    /// @dev LP withdraws USDC from the vault (up to maxWithdraw).
    function withdrawLiquidity(uint256 fraction, bool useLP1) external {
        address who = useLP1 ? lp1 : lp2;
        uint256 maxW = pool.maxWithdraw(who);
        if (maxW == 0) return;

        uint256 amount = bound(fraction, 1, maxW);
        vm.prank(who);
        try pool.withdraw(amount, who, who) {} catch {}
    }

    /*//////////////////////////////////////////////////////////////
              HANDLER — MARKET MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev Register a new market (if under the handler's soft cap).
    function registerMarket() external {
        if (ghost_activeMarketCount >= MAX_HANDLER_MARKETS) return;

        MockMarket m = new MockMarket(address(pool));

        vm.prank(admin);
        try pool.registerMarket(address(m), 2) {
            allMarkets.push(m);
            ghost_expectedTotalLiability += MAX_RISK;
            ghost_activeMarketCount      += 1;
        } catch {}
    }

    /// @dev Deregister a registered market that has no trades yet.
    function deregisterMarket(uint256 marketIdx) external {
        if (allMarkets.length == 0) return;
        marketIdx = bound(marketIdx, 0, allMarkets.length - 1);
        MockMarket m = allMarkets[marketIdx];

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        if (!info.registered || info.settled || info.hasTrades) return;

        uint256 liabBefore = info.currentLiability;
        vm.prank(admin);
        try pool.deregisterMarket(address(m)) {
            ghost_expectedTotalLiability -= liabBefore;
            ghost_activeMarketCount      -= 1;
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                 HANDLER — TRADE FLOW
    //////////////////////////////////////////////////////////////*/

    /// @dev Push a trade through a registered-unsettled market.
    ///      Trader always approves the vault directly.
    ///      USDC mint/approve stays inside the cost > 0 guard; doCollectTrade and
    ///      ghost update are outside it so zero-cost liability changes are exercised.
    function collectTrade(
        uint256 marketIdx,
        uint256 cost,
        uint256 newLiabilityFraction // 0–100 maps to 0 %–100 % of riskBudget
    ) external {
        if (allMarkets.length == 0) return;
        marketIdx = bound(marketIdx, 0, allMarkets.length - 1);
        MockMarket m = allMarkets[marketIdx];

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        if (!info.registered || info.settled) return;

        cost                 = bound(cost, 0, 2_000e6);   // 0 – 2K USDC trade cost
        newLiabilityFraction = bound(newLiabilityFraction, 0, 100);
        uint256 newLiab = (info.riskBudget * newLiabilityFraction) / 100;

        address _trader = address(uint160(uint256(keccak256("trader"))));
        if (cost > 0) {
            usdc.mint(_trader, cost);
            vm.prank(_trader);
            usdc.approve(address(pool), cost);
        }

        uint256 oldLiab = info.currentLiability;
        try m.doCollectTrade(_trader, cost, newLiab) {
            // Sync ghost: delta update mirrors vault's own delta logic
            if (newLiab < oldLiab) {
                ghost_expectedTotalLiability -= (oldLiab - newLiab);
            } else if (newLiab > oldLiab) {
                ghost_expectedTotalLiability += (newLiab - oldLiab);
            }
        } catch {}
    }

    /// @dev Push a sell-refund through a registered-unsettled market.
    ///      refundAmount is bounded to (vault_balance − totalLiability) so the call
    ///      never triggers VaultInsolvent — solvency violations are exercised in the
    ///      unit suite. The ghost delta update mirrors the vault's own capped-delta logic.
    function distributeRefund(
        uint256 marketIdx,
        uint256 refundAmount,
        uint256 newLiabilityFraction
    ) external {
        if (allMarkets.length == 0) return;
        marketIdx = bound(marketIdx, 0, allMarkets.length - 1);
        MockMarket m = allMarkets[marketIdx];

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        if (!info.registered || info.settled) return;

        // Safe upper bound on refundAmount: never exceed vault surplus above liability
        uint256 vaultBal   = usdc.balanceOf(address(pool));
        uint256 liab       = pool.totalLiability();
        uint256 surplus    = vaultBal > liab ? vaultBal - liab : 0;
        uint256 maxRefund  = surplus < 500e6 ? surplus : 500e6;
        refundAmount       = bound(refundAmount, 0, maxRefund);

        newLiabilityFraction = bound(newLiabilityFraction, 0, 100);
        uint256 newLiab      = (info.riskBudget * newLiabilityFraction) / 100;
        uint256 oldLiab      = info.currentLiability;

        address _trader = address(uint160(uint256(keccak256("trader"))));

        try m.doDistributeRefund(_trader, refundAmount, newLiab) {
            // Sync ghost: same capped-delta logic as the vault
            uint256 capped = newLiab > info.riskBudget ? info.riskBudget : newLiab;
            if (capped < oldLiab) {
                ghost_expectedTotalLiability -= (oldLiab - capped);
            } else if (capped > oldLiab) {
                ghost_expectedTotalLiability += (capped - oldLiab);
            }
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
             HANDLER — SETTLEMENT FLOW
    //////////////////////////////////////////////////////////////*/

    /// @dev Settle a registered market with a fraction of its riskBudget as payout.
    function settleMarket(uint256 marketIdx, uint256 payoutFraction) external {
        if (allMarkets.length == 0) return;
        marketIdx = bound(marketIdx, 0, allMarkets.length - 1);
        MockMarket m = allMarkets[marketIdx];

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        if (!info.registered || info.settled) return;

        payoutFraction = bound(payoutFraction, 0, 100);
        uint256 payout = (info.riskBudget * payoutFraction) / 100;
        uint256 liabBefore = info.currentLiability;

        try m.doSettle(payout) {
            ghost_expectedTotalLiability -= liabBefore; // settleMarket releases currentLiability
            ghost_activeMarketCount      -= 1;
        } catch {}
    }

    /// @dev Force-settle a registered market via the emergency path.
    function forceSettle(uint256 marketIdx) external {
        if (allMarkets.length == 0) return;
        marketIdx = bound(marketIdx, 0, allMarkets.length - 1);
        MockMarket m = allMarkets[marketIdx];

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        if (!info.registered || info.settled) return;

        uint256 liabBefore = info.currentLiability;

        vm.prank(admin);
        try pool.forceSettleMarket(address(m)) {
            ghost_expectedTotalLiability -= liabBefore;
            ghost_activeMarketCount      -= 1;
        } catch {}
    }

    /// @dev Claim all outstanding winnings for a settled market.
    function claimWinnings(uint256 marketIdx) external {
        if (allMarkets.length == 0) return;
        marketIdx = bound(marketIdx, 0, allMarkets.length - 1);
        MockMarket m = allMarkets[marketIdx];

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        if (!info.settled) return;

        uint256 remaining = info.settledPayout - info.claimedPayout;
        if (remaining == 0) return;

        address _winner = address(uint160(uint256(keccak256("winner"))));
        try m.doClaim(_winner, remaining) {} catch {}
    }

    /*//////////////////////////////////////////////////////////////
                       HELPER VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the number of all (including settled) markets ever tracked.
    function allMarketsLength() external view returns (uint256) {
        return allMarkets.length;
    }

    /// @dev Computes the on-chain sum of currentLiability across active markets.
    ///      Used inside invariants to cross-check ghost variables.
    function computeOnChainLiabilitySum() external view returns (uint256 sum) {
        for (uint i; i < allMarkets.length; i++) {
            BlieverV1Pool.MarketInfo memory info =
                pool.getMarketInfo(address(allMarkets[i]));
            if (info.registered && !info.settled) {
                sum += info.currentLiability;
            }
        }
    }

    /// @dev On-chain active market count from handler's tracked set.
    function computeOnChainActiveCount() external view returns (uint256 count) {
        for (uint i; i < allMarkets.length; i++) {
            if (pool.isActiveMarket(address(allMarkets[i]))) count++;
        }
    }
}


/*//////////////////////////////////////////////////////////////
                   INVARIANT TEST CONTRACT
//////////////////////////////////////////////////////////////*/

/// @notice Five protocol-level invariants for BlieverV1Pool.
///
///  These invariants should hold after ANY sequence of valid (and some invalid)
///  handler calls. The fuzzer exercises the handler randomly and checks these
///  assertions after each call.
///
///  Invariant 1 — SOLVENCY:
///    USDC balance ≥ totalLiability at all times.
///
///  Invariant 2 — LIABILITY SUM:
///    totalLiability == Σ currentLiability_i for all active markets.
///
///  Invariant 3 — ACTIVE MARKET COUNT:
///    activeMarketCount == number of registered, unsettled markets tracked
///    by the handler.
///
///  Invariant 4 — PAYOUT BOUNDS:
///    For every settled market: claimedPayout ≤ settledPayout ≤ riskBudget
///    (no over-claiming; no payout beyond the LS-LMSR loss bound).
///
///  Invariant 5 — CURRENT LIABILITY BOUND:
///    For every active market: currentLiability ≤ riskBudget
///    (Proposition 4.9 enforcement via vault's cap logic).
///
contract BlieverV1Pool_InvariantTest is StdInvariant, Test {

    // ── Protocol under test ──────────────────────────────────────────────────
    BlieverV1Pool internal pool;
    MockUSDC      internal usdc;
    PoolHandler   internal handler;

    // ── Shared admin ─────────────────────────────────────────────────────────
    address internal admin = address(uint160(uint256(keccak256("admin"))));

    // ── Default init parameters ───────────────────────────────────────────────
    uint256 internal constant ALPHA    = 3e16;
    uint256 internal constant MAX_RISK = 50_000e6;

    /*//////////////////////////////////////////////////////////////
                           SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // 1. Deploy mock USDC
        usdc = new MockUSDC();

        // 2. Deploy UUPS proxy
        BlieverV1Pool impl = new BlieverV1Pool();
        bytes memory initData = abi.encodeCall(
            BlieverV1Pool.initialize,
            (address(usdc), admin, ALPHA, MAX_RISK, uint16(2_000))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        pool = BlieverV1Pool(address(proxy));

        // 3. Seed vault with initial LP liquidity so capacity checks pass
        address seedLP = address(uint160(uint256(keccak256("seedLP"))));
        usdc.mint(seedLP, 2_000_000e6);
        vm.startPrank(seedLP);
        usdc.approve(address(pool), 2_000_000e6);
        pool.deposit(2_000_000e6, seedLP);
        vm.stopPrank();

        // 4. Deploy handler
        handler = new PoolHandler(address(pool), address(usdc), admin);

        // 5. Tell the fuzzer to target the handler only
        targetContract(address(handler));

        // 6. Labels for trace clarity
        vm.label(address(pool),    "BlieverV1Pool");
        vm.label(address(usdc),    "MockUSDC");
        vm.label(address(handler), "PoolHandler");
        vm.label(admin,            "admin");
    }

    /*//////////////////////////////////////////////////////////////
               INVARIANT 1 — SOLVENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice The vault's raw USDC balance must always cover all live market liabilities.
    ///         Violation = vault cannot honour worst-case LP loss.
    function invariant_solvency() public view {
        uint256 balance = usdc.balanceOf(address(pool));
        uint256 liab    = pool.totalLiability();
        assertGe(balance, liab,
            "INVARIANT VIOLATED: USDC balance < totalLiability (vault insolvent)");
    }

    /*//////////////////////////////////////////////////////////////
           INVARIANT 2 — LIABILITY SUM CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice pool.totalLiability must equal the on-chain sum of currentLiability
    ///         across all active (registered, unsettled) markets tracked by the handler.
    ///
    ///         Two independent checks run in parallel:
    ///           1. on-chain cross-check: vault sum vs. handler iteration of the mapping
    ///           2. ghost cross-check: vault value vs. handler's separately-maintained
    ///              delta counter — catches bugs where both the vault and on-chain iteration
    ///              are wrong in the same way (e.g. same bad delta path affects both).
    function invariant_totalLiabilityEqualsSum() public view {
        uint256 onChainSum = handler.computeOnChainLiabilitySum();
        assertEq(pool.totalLiability(), onChainSum,
            "INVARIANT VIOLATED: totalLiability != on-chain sum of active currentLiabilities");
        assertEq(pool.totalLiability(), handler.ghost_expectedTotalLiability(),
            "INVARIANT VIOLATED: totalLiability != ghost_expectedTotalLiability");
    }

    /*//////////////////////////////////////////////////////////////
          INVARIANT 3 — ACTIVE MARKET COUNT
    //////////////////////////////////////////////////////////////*/

    /// @notice pool.activeMarketCount must match the count of registered+unsettled
    ///         markets in the handler's tracked set.
    ///         Ghost counter provides a second independent verification path.
    function invariant_activeMarketCountConsistent() public view {
        uint256 onChainCount = handler.computeOnChainActiveCount();
        assertEq(pool.activeMarketCount(), onChainCount,
            "INVARIANT VIOLATED: activeMarketCount != on-chain count");
        assertEq(pool.activeMarketCount(), handler.ghost_activeMarketCount(),
            "INVARIANT VIOLATED: activeMarketCount != ghost_activeMarketCount");
    }

    /*//////////////////////////////////////////////////////////////
          INVARIANT 4 — PAYOUT BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice For every market the handler has ever registered:
    ///           claimedPayout ≤ settledPayout  (no double-claiming)
    ///           settledPayout ≤ riskBudget      (LS-LMSR Proposition 4.9)
    ///         Note: after forceSettle riskBudget = 0 and settledPayout = 0,
    ///         so the inequality still holds.
    function invariant_payoutBounds() public view {
        uint256 len = handler.allMarketsLength();
        for (uint i; i < len; i++) {
            MockMarket m = handler.allMarkets(i);
            BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));

            if (info.settled) {
                assertLe(info.claimedPayout, info.settledPayout,
                    "INVARIANT VIOLATED: claimedPayout > settledPayout (over-claim)");
                assertLe(info.settledPayout, info.riskBudget,
                    "INVARIANT VIOLATED: settledPayout > riskBudget (exceeded LS-LMSR bound)");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
         INVARIANT 5 — CURRENT LIABILITY BOUND
    //////////////////////////////////////////////////////////////*/

    /// @notice For every active (registered, unsettled) market:
    ///         currentLiability ≤ riskBudget.
    ///
    ///         The vault's cap logic in collectTradeCost enforces this even when
    ///         a misbehaving market contract reports an overbudget value.
    function invariant_currentLiabilityBounded() public view {
        uint256 len = handler.allMarketsLength();
        for (uint i; i < len; i++) {
            MockMarket m = handler.allMarkets(i);
            BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));

            if (info.registered && !info.settled) {
                assertLe(info.currentLiability, info.riskBudget,
                    "INVARIANT VIOLATED: currentLiability > riskBudget (cap logic failed)");
            }
        }
    }
}
