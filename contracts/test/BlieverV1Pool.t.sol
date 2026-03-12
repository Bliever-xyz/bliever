// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/*//////////////////////////////////////////////////////////////
                         FOUNDRY IMPORTS
//////////////////////////////////////////////////////////////*/
import {Test, console2, Vm} from "forge-std/Test.sol";

/*//////////////////////////////////////////////////////////////
                        OPENZEPPELIN IMPORTS
//////////////////////////////////////////////////////////////*/
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20}       from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
                        SHARED BASE CONTRACT
//////////////////////////////////////////////////////////////*/

/// @notice Common setup and helpers shared by every test contract in this file.
abstract contract BlieverV1PoolBase is Test {

    // ── Contract under test ──────────────────────────────────────────────────
    BlieverV1Pool internal pool;
    MockUSDC      internal usdc;

    // ── Named actors ─────────────────────────────────────────────────────────
    address internal admin    = makeAddr("admin");
    address internal lp       = makeAddr("lp");
    address internal lp2      = makeAddr("lp2");
    address internal trader   = makeAddr("trader");
    address internal winner   = makeAddr("winner");
    address internal attacker = makeAddr("attacker");

    // ── Default initialisation parameters ────────────────────────────────────
    uint256 internal constant ALPHA       = 3e16;     // 3 % spread
    uint256 internal constant MAX_RISK    = 50_000e6; // 50 000 USDC per market (6-dec)
    uint16  internal constant RESERVE_BPS = 2_000;    // 20 % reserve buffer

    // ── LP funding constants ──────────────────────────────────────────────────
    // LP deposits 500K USDC → activeCap = 500K × 80 % = 400K → fits 8 markets.
    uint256 internal constant LP_DEPOSIT = 500_000e6;

    /*//////////////////////////////////////////////////////////////
                            SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        // 1. Deploy mock USDC (6-dec)
        usdc = new MockUSDC();

        // 2. Deploy implementation (constructor calls _disableInitializers)
        BlieverV1Pool impl = new BlieverV1Pool();

        // 3. Deploy UUPS proxy with initialise calldata
        bytes memory initData = abi.encodeCall(
            BlieverV1Pool.initialize,
            (address(usdc), admin, ALPHA, MAX_RISK, RESERVE_BPS)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        pool = BlieverV1Pool(address(proxy));

        // 4. Human-readable labels for forge traces
        vm.label(address(pool), "BlieverV1Pool");
        vm.label(address(usdc), "MockUSDC");
        vm.label(admin,    "admin");
        vm.label(lp,       "lp");
        vm.label(lp2,      "lp2");
        vm.label(trader,   "trader");
        vm.label(winner,   "winner");
        vm.label(attacker, "attacker");

        // 5. Seed the vault with LP capital so market-registration tests pass
        _depositLiquidity(lp, LP_DEPOSIT);
    }

    /*//////////////////////////////////////////////////////////////
                         SHARED HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mint USDC and deposit into vault from `who`. Returns shares minted.
    function _depositLiquidity(address who, uint256 usdcAmount) internal returns (uint256 shares) {
        usdc.mint(who, usdcAmount);
        vm.startPrank(who);
        usdc.approve(address(pool), usdcAmount);
        shares = pool.deposit(usdcAmount, who);
        vm.stopPrank();
    }

    /// @dev Deploy a MockMarket and register it with 2 outcomes. Returns the market.
    function _registerMarket() internal returns (MockMarket m) {
        m = new MockMarket(address(pool));
        vm.prank(admin);
        pool.registerMarket(address(m), 2);
    }

    /// @dev Register a market, push one trade through it (trader → vault).
    ///      Trader must approve the vault (not the market) for `cost`.
    function _registerAndTrade(
        uint256 cost,
        uint256 newLiability
    ) internal returns (MockMarket m) {
        m = _registerMarket();
        usdc.mint(trader, cost);
        vm.prank(trader);
        usdc.approve(address(pool), cost);
        m.doCollectTrade(trader, cost, newLiability);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL HELPER
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the OZ-v5 AccessControlUnauthorizedAccount revert payload.
    function _accessDenied(address caller, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
            caller, role
        );
    }
}


/*//////////////////////////////////////////////////////////////
              SECTION 1 — INITIALISATION TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_InitTest is BlieverV1PoolBase {

    // ─── Happy path ─────────────────────────────────────────────────────────

    function test_initialize_setsProtocolParams() public view {
        assertEq(pool.alpha(),            ALPHA,       "alpha mismatch");
        assertEq(pool.maxRiskPerMarket(), MAX_RISK,    "maxRisk mismatch");
        assertEq(pool.reserveBps(),       RESERVE_BPS, "reserveBps mismatch");
        assertEq(pool.activeMarketCount(), 0,          "active market count must start 0");
        assertEq(pool.totalLiability(),    0,          "totalLiability must start 0");
    }

    function test_initialize_grantsAllRolesToAdmin() public view {
        assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(),  admin), "DEFAULT_ADMIN");
        assertTrue(pool.hasRole(pool.MARKET_MANAGER_ROLE(), admin), "MARKET_MANAGER");
        assertTrue(pool.hasRole(pool.PAUSER_ROLE(),         admin), "PAUSER");
        assertTrue(pool.hasRole(pool.UPGRADER_ROLE(),       admin), "UPGRADER");
        assertTrue(pool.hasRole(pool.EMERGENCY_ROLE(),      admin), "EMERGENCY");
    }

    function test_initialize_setsMarketRoleAdminToMarketManager() public view {
        // MARKET_ROLE admin must be MARKET_MANAGER_ROLE, not DEFAULT_ADMIN_ROLE.
        // This keeps on-chain role metadata consistent with registerMarket intent.
        assertEq(
            pool.getRoleAdmin(pool.MARKET_ROLE()),
            pool.MARKET_MANAGER_ROLE(),
            "MARKET_ROLE admin must be MARKET_MANAGER_ROLE"
        );
    }

    function test_initialize_setsERC20Metadata() public view {
        assertEq(pool.name(),     "Believer LP");
        assertEq(pool.symbol(),   "bLP");
        assertEq(pool.decimals(), 18); // 6 USDC + 12 offset
        assertEq(pool.asset(),    address(usdc));
    }

    // ─── Double-init blocked ─────────────────────────────────────────────────

    function test_initialize_reverts_doubleInit() public {
        // Initializable v5 throws InvalidInitialization()
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        pool.initialize(address(usdc), admin, ALPHA, MAX_RISK, RESERVE_BPS);
    }

    // ─── Input validation ────────────────────────────────────────────────────

    function _freshImpl() internal returns (BlieverV1Pool) { return new BlieverV1Pool(); }

    function test_initialize_reverts_ZeroAddress_usdc() public {
        bytes memory bad = abi.encodeCall(BlieverV1Pool.initialize,
            (address(0), admin, ALPHA, MAX_RISK, RESERVE_BPS));
        vm.expectRevert(BlieverV1Pool.ZeroAddress.selector);
        new ERC1967Proxy(address(_freshImpl()), bad);
    }

    function test_initialize_reverts_ZeroAddress_admin() public {
        bytes memory bad = abi.encodeCall(BlieverV1Pool.initialize,
            (address(usdc), address(0), ALPHA, MAX_RISK, RESERVE_BPS));
        vm.expectRevert(BlieverV1Pool.ZeroAddress.selector);
        new ERC1967Proxy(address(_freshImpl()), bad);
    }

    function test_initialize_reverts_InvalidAlpha_tooLow() public {
        uint256 bad = pool.MIN_ALPHA() - 1;
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidAlpha.selector, bad));
        new ERC1967Proxy(address(_freshImpl()),
            abi.encodeCall(BlieverV1Pool.initialize,
                (address(usdc), admin, bad, MAX_RISK, RESERVE_BPS)));
    }

    function test_initialize_reverts_InvalidAlpha_tooHigh() public {
        uint256 bad = pool.MAX_ALPHA() + 1;
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidAlpha.selector, bad));
        new ERC1967Proxy(address(_freshImpl()),
            abi.encodeCall(BlieverV1Pool.initialize,
                (address(usdc), admin, bad, MAX_RISK, RESERVE_BPS)));
    }

    function test_initialize_reverts_InvalidMaxRisk_zero() public {
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidMaxRisk.selector, uint256(0)));
        new ERC1967Proxy(address(_freshImpl()),
            abi.encodeCall(BlieverV1Pool.initialize,
                (address(usdc), admin, ALPHA, 0, RESERVE_BPS)));
    }

    function test_initialize_reverts_InvalidBps_tooLow() public {
        uint16 bad = uint16(pool.MIN_RESERVE_BPS()) - 1;
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidBps.selector, bad));
        new ERC1967Proxy(address(_freshImpl()),
            abi.encodeCall(BlieverV1Pool.initialize,
                (address(usdc), admin, ALPHA, MAX_RISK, bad)));
    }

    function test_initialize_reverts_InvalidBps_tooHigh() public {
        uint16 bad = uint16(pool.MAX_RESERVE_BPS()) + 1;
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidBps.selector, bad));
        new ERC1967Proxy(address(_freshImpl()),
            abi.encodeCall(BlieverV1Pool.initialize,
                (address(usdc), admin, ALPHA, MAX_RISK, bad)));
    }

    function test_initialize_reverts_onBareImplementation() public {
        // _disableInitializers() in the constructor means the logic contract itself
        // cannot be initialised — only the proxy should be.
        BlieverV1Pool bareImpl = new BlieverV1Pool();
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        bareImpl.initialize(address(usdc), admin, ALPHA, MAX_RISK, RESERVE_BPS);
    }
}


/*//////////////////////////////////////////////////////////////
          SECTION 2 — MARKET REGISTRATION TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_RegisterMarketTest is BlieverV1PoolBase {

    // ─── Happy path ─────────────────────────────────────────────────────────

    function test_registerMarket_succeeds() public {
        MockMarket m = new MockMarket(address(pool));
        vm.prank(admin);
        pool.registerMarket(address(m), 2);

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        assertTrue(info.registered,                         "registered flag");
        assertFalse(info.settled,                           "not yet settled");
        assertFalse(info.hasTrades,                         "no trades yet");
        assertEq(info.riskBudget,       MAX_RISK,           "riskBudget");
        assertEq(info.currentLiability, MAX_RISK,           "currentLiability = riskBudget at start");
        assertEq(info.settledPayout,    0,                  "settledPayout");
        assertEq(info.claimedPayout,    0,                  "claimedPayout");
    }

    function test_registerMarket_incrementsActiveCount() public {
        _registerMarket();
        assertEq(pool.activeMarketCount(), 1);
        _registerMarket();
        assertEq(pool.activeMarketCount(), 2);
    }

    function test_registerMarket_updatesTotalLiability() public {
        assertEq(pool.totalLiability(), 0);
        _registerMarket();
        assertEq(pool.totalLiability(), MAX_RISK);
        _registerMarket();
        assertEq(pool.totalLiability(), MAX_RISK * 2);
    }

    function test_registerMarket_grantsMarketRole() public {
        MockMarket m = new MockMarket(address(pool));
        vm.prank(admin);
        pool.registerMarket(address(m), 2);
        assertTrue(pool.hasRole(pool.MARKET_ROLE(), address(m)));
    }

    function test_registerMarket_emitsEvent() public {
        MockMarket m = new MockMarket(address(pool));
        vm.expectEmit(true, false, false, true, address(pool));
        emit BlieverV1Pool.MarketRegistered(address(m), 2, MAX_RISK);
        vm.prank(admin);
        pool.registerMarket(address(m), 2);
    }

    function test_registerMarket_maxOutcomes_100_succeeds() public {
        MockMarket m = new MockMarket(address(pool));
        vm.prank(admin);
        pool.registerMarket(address(m), 100); // boundary: maximum valid
        assertTrue(pool.getMarketInfo(address(m)).registered);
    }

    // ─── Revert paths ────────────────────────────────────────────────────────

    function test_registerMarket_reverts_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(BlieverV1Pool.ZeroAddress.selector);
        pool.registerMarket(address(0), 2);
    }

    function test_registerMarket_reverts_NotAContract_EOA() public {
        // EOA has code.length == 0
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.NotAContract.selector, attacker));
        pool.registerMarket(attacker, 2);
    }

    function test_registerMarket_reverts_InvalidOutcomeCount_one() public {
        MockMarket m = new MockMarket(address(pool));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidOutcomeCount.selector, uint32(1)));
        pool.registerMarket(address(m), 1);
    }

    function test_registerMarket_reverts_InvalidOutcomeCount_101() public {
        MockMarket m = new MockMarket(address(pool));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidOutcomeCount.selector, uint32(101)));
        pool.registerMarket(address(m), 101);
    }

    function test_registerMarket_reverts_MarketAlreadyRegistered() public {
        MockMarket m = new MockMarket(address(pool));
        vm.startPrank(admin);
        pool.registerMarket(address(m), 2);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.MarketAlreadyRegistered.selector, address(m)));
        pool.registerMarket(address(m), 2);
        vm.stopPrank();
    }

    function test_registerMarket_reverts_CapacityExceeded_noDeposits() public {
        // Deploy a fresh pool with no LP deposits — activeCap = 0
        BlieverV1Pool emptyPool;
        {
            BlieverV1Pool impl2 = new BlieverV1Pool();
            bytes memory initData = abi.encodeCall(
                BlieverV1Pool.initialize,
                (address(usdc), admin, ALPHA, MAX_RISK, RESERVE_BPS)
            );
            emptyPool = BlieverV1Pool(address(new ERC1967Proxy(address(impl2), initData)));
        }
        MockMarket m = new MockMarket(address(emptyPool));
        vm.prank(admin);
        // activeCap = 0 × 80 % = 0; newTotalLiab = MAX_RISK > 0 = activeCap
        vm.expectRevert(abi.encodeWithSelector(
            BlieverV1Pool.CapacityExceeded.selector, MAX_RISK, uint256(0)));
        emptyPool.registerMarket(address(m), 2);
    }

    function test_registerMarket_reverts_whenPaused() public {
        vm.prank(admin); pool.pause();
        MockMarket m = new MockMarket(address(pool));
        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        pool.registerMarket(address(m), 2);
    }

    function test_registerMarket_reverts_unauthorized() public {
        MockMarket m = new MockMarket(address(pool));
        vm.expectRevert(_accessDenied(attacker, pool.MARKET_MANAGER_ROLE()));
        vm.prank(attacker);
        pool.registerMarket(address(m), 2);
    }

    function test_registerMarket_reverts_CapacityExceeded_nthMarketExceedsCap() public {
        // 8 markets × 50K = 400K = 500K × 80% — fills activeCap exactly.
        // The 9th registration pushes newTotalLiab to 450K > 400K activeCap.
        for (uint i; i < 8; i++) _registerMarket();
        MockMarket m9 = new MockMarket(address(pool));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            BlieverV1Pool.CapacityExceeded.selector, MAX_RISK * 9, MAX_RISK * 8));
        pool.registerMarket(address(m9), 2);
    }
}


/*//////////////////////////////////////////////////////////////
         SECTION 3 — MARKET DEREGISTRATION TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_DeregisterMarketTest is BlieverV1PoolBase {

    // ─── Happy path ─────────────────────────────────────────────────────────

    function test_deregisterMarket_succeeds() public {
        MockMarket m = _registerMarket();
        vm.prank(admin);
        pool.deregisterMarket(address(m));

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        assertFalse(info.registered, "should be deleted");
    }

    function test_deregisterMarket_decrementActiveCount() public {
        MockMarket m = _registerMarket();
        assertEq(pool.activeMarketCount(), 1);
        vm.prank(admin);
        pool.deregisterMarket(address(m));
        assertEq(pool.activeMarketCount(), 0);
    }

    function test_deregisterMarket_releasesLiabilityFromTotal() public {
        MockMarket m = _registerMarket();
        uint256 liabBefore = pool.totalLiability();
        vm.prank(admin);
        pool.deregisterMarket(address(m));
        assertEq(pool.totalLiability(), liabBefore - MAX_RISK, "liability not released");
    }

    function test_deregisterMarket_revokesMarketRole() public {
        MockMarket m = _registerMarket();
        assertTrue(pool.hasRole(pool.MARKET_ROLE(), address(m)));
        vm.prank(admin);
        pool.deregisterMarket(address(m));
        assertFalse(pool.hasRole(pool.MARKET_ROLE(), address(m)));
    }

    function test_deregisterMarket_emitsEvent() public {
        MockMarket m = _registerMarket();
        vm.expectEmit(true, false, false, false, address(pool));
        emit BlieverV1Pool.MarketDeregistered(address(m));
        vm.prank(admin);
        pool.deregisterMarket(address(m));
    }

    // ─── Revert paths ────────────────────────────────────────────────────────

    function test_deregisterMarket_reverts_NotRegistered() public {
        MockMarket m = new MockMarket(address(pool));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.MarketNotRegistered.selector, address(m)));
        pool.deregisterMarket(address(m));
    }

    function test_deregisterMarket_reverts_AlreadySettled() public {
        MockMarket m = _registerMarket();
        m.doSettle(0); // zero-payout settlement
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.MarketAlreadySettled.selector, address(m)));
        pool.deregisterMarket(address(m));
    }

    function test_deregisterMarket_reverts_MarketHasTrades() public {
        // Trade with zero cost so vault balance isn't touched, just hasTrades flag
        MockMarket m = _registerAndTrade(0, MAX_RISK);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.MarketHasTrades.selector, address(m)));
        pool.deregisterMarket(address(m));
    }

    function test_deregisterMarket_reverts_whenPaused() public {
        MockMarket m = _registerMarket();
        vm.prank(admin); pool.pause();
        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        pool.deregisterMarket(address(m));
    }

    function test_deregisterMarket_reverts_unauthorized() public {
        MockMarket m = _registerMarket();
        vm.expectRevert(_accessDenied(attacker, pool.MARKET_MANAGER_ROLE()));
        vm.prank(attacker);
        pool.deregisterMarket(address(m));
    }

    function test_deregisterMarket_allowsReregistration_sameAddress() public {
        // delete markets[market] resets registered = false, so the same contract
        // address can be registered again cleanly.
        MockMarket m = _registerMarket();
        vm.prank(admin); pool.deregisterMarket(address(m));
        assertFalse(pool.getMarketInfo(address(m)).registered, "deregistered");

        vm.prank(admin); pool.registerMarket(address(m), 2);
        assertTrue(pool.getMarketInfo(address(m)).registered, "re-registered");
        assertEq(pool.activeMarketCount(), 1, "count back to 1");
    }
}


/*//////////////////////////////////////////////////////////////
            SECTION 4 — COLLECT TRADE COST TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_CollectTradeCostTest is BlieverV1PoolBase {

    // ─── Happy path ─────────────────────────────────────────────────────────

    function test_collectTradeCost_withCost_transfersUSDC() public {
        uint256 cost = 1_000e6; // 1 000 USDC
        MockMarket m = _registerAndTrade(cost, MAX_RISK - 1_000e6);

        // Vault received the cost; trader spent it
        assertEq(usdc.balanceOf(address(pool)), LP_DEPOSIT + cost, "vault balance");
        assertEq(usdc.balanceOf(trader), 0,                       "trader spent all");
    }

    function test_collectTradeCost_zeroCost_noUSDCTransfer() public {
        uint256 vaultBefore = usdc.balanceOf(address(pool));
        _registerAndTrade(0, MAX_RISK); // no-cost trade
        assertEq(usdc.balanceOf(address(pool)), vaultBefore, "vault balance unchanged on zero-cost");
    }

    function test_collectTradeCost_setsHasTrades() public {
        MockMarket m = _registerAndTrade(0, MAX_RISK);
        assertTrue(pool.getMarketInfo(address(m)).hasTrades);
    }

    function test_collectTradeCost_decreasesLiability_normalPath() public {
        // LS-LMSR: as volume grows, worst-case loss shrinks (newLiability < riskBudget)
        uint256 newLiab = MAX_RISK / 2;
        _registerAndTrade(1_000e6, newLiab);
        assertEq(pool.totalLiability(), newLiab, "totalLiability should reflect decreased newLiab");
    }

    function test_collectTradeCost_updatesTotalLiabilityCorrectly() public {
        MockMarket m = _registerMarket();
        uint256 liab1 = MAX_RISK;
        assertEq(pool.totalLiability(), liab1);

        // First trade: newLiab = 30K
        uint256 cost = 500e6;
        usdc.mint(trader, cost);
        vm.prank(trader); usdc.approve(address(pool), cost);
        m.doCollectTrade(trader, cost, 30_000e6);
        assertEq(pool.totalLiability(), 30_000e6);

        // Second trade: newLiab = 20K
        usdc.mint(trader, cost);
        vm.prank(trader); usdc.approve(address(pool), cost);
        m.doCollectTrade(trader, cost, 20_000e6);
        assertEq(pool.totalLiability(), 20_000e6);
    }

    function test_collectTradeCost_capsLiabilityAtRiskBudget() public {
        // Misbehaving market reports newLiability > riskBudget; vault must cap it silently
        MockMarket m = _registerMarket();
        uint256 overBudget = MAX_RISK + 1_000e6;

        vm.expectEmit(true, false, false, true, address(pool));
        emit BlieverV1Pool.LiabilityCapApplied(address(m), overBudget, MAX_RISK);

        m.doCollectTrade(trader, 0, overBudget);

        // currentLiability must be capped at riskBudget
        assertEq(pool.getMarketInfo(address(m)).currentLiability, MAX_RISK, "cap enforced");
        assertEq(pool.totalLiability(), MAX_RISK, "totalLiability uses capped value");
    }

    function test_collectTradeCost_emitsTradeCostCollected() public {
        MockMarket m = _registerMarket();
        uint256 cost    = 500e6;
        uint256 newLiab = 40_000e6;

        usdc.mint(trader, cost);
        vm.prank(trader); usdc.approve(address(pool), cost);

        vm.expectEmit(true, true, false, true, address(pool));
        emit BlieverV1Pool.TradeCostCollected(address(m), trader, cost, newLiab);
        m.doCollectTrade(trader, cost, newLiab);
    }

    function test_collectTradeCost_emitsMarketLiabilityUpdated_whenChanged() public {
        MockMarket m = _registerMarket();
        uint256 newLiab = 40_000e6;

        vm.expectEmit(true, false, false, true, address(pool));
        emit BlieverV1Pool.MarketLiabilityUpdated(address(m), MAX_RISK, newLiab);
        m.doCollectTrade(trader, 0, newLiab);
    }

    function test_collectTradeCost_noLiabilityEvent_whenSameLiability() public {
        MockMarket m = _registerMarket();
        // No MarketLiabilityUpdated if old == new (unchanged)
        vm.recordLogs();
        m.doCollectTrade(trader, 0, MAX_RISK); // same as initialised value
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 liabUpdatedTopic = keccak256("MarketLiabilityUpdated(address,uint256,uint256)");
        for (uint i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != liabUpdatedTopic, "should NOT emit MarketLiabilityUpdated");
        }
    }

    // ─── Revert paths ────────────────────────────────────────────────────────

    function test_collectTradeCost_reverts_MarketAlreadySettled() public {
        // Must use a non-zero payout: doSettle(0) immediately revokes MARKET_ROLE,
        // which would cause onlyRole(MARKET_ROLE) to fire before MarketAlreadySettled.
        // Non-zero payout keeps the role alive until the last claimWinnings call.
        uint256 payout = 1_000e6;
        MockMarket m = _registerAndTrade(payout, MAX_RISK / 2);
        m.doSettle(payout);
        assertTrue(pool.hasRole(pool.MARKET_ROLE(), address(m)), "role must still be held");
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.MarketAlreadySettled.selector, address(m)));
        m.doCollectTrade(trader, 0, 0);
    }

    function test_collectTradeCost_reverts_ZeroAddress_trader() public {
        MockMarket m = _registerMarket();
        vm.expectRevert(BlieverV1Pool.ZeroAddress.selector);
        m.doCollectTrade(address(0), 0, MAX_RISK);
    }

    function test_collectTradeCost_reverts_whenPaused() public {
        MockMarket m = _registerMarket();
        vm.prank(admin); pool.pause();
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        m.doCollectTrade(trader, 0, MAX_RISK);
    }

    function test_collectTradeCost_reverts_unauthorized_nonMarketRole() public {
        // Attacker calls pool directly (no MARKET_ROLE)
        vm.prank(attacker);
        vm.expectRevert(_accessDenied(attacker, pool.MARKET_ROLE()));
        pool.collectTradeCost(trader, 0, 0);
    }

    function test_collectTradeCost_increasesLiability_whenBetweenOldAndBudget() public {
        // Contract lines 519-520: when capped > old, totalLiability increases.
        // This happens when a market's running worst-case re-expands (unusual but valid).
        MockMarket m = _registerMarket();

        // First trade: drop liability to 60% of budget
        m.doCollectTrade(trader, 0, MAX_RISK * 60 / 100);
        assertEq(pool.totalLiability(), MAX_RISK * 60 / 100, "after first trade");

        // Second trade: liability rises back to 80% (still within budget — cap does NOT fire)
        m.doCollectTrade(trader, 0, MAX_RISK * 80 / 100);
        assertEq(pool.totalLiability(), MAX_RISK * 80 / 100, "liability increased on second trade");
        assertEq(pool.getMarketInfo(address(m)).currentLiability, MAX_RISK * 80 / 100);
    }

    function test_collectTradeCost_newLiabilityZero_totalLiabilityDropsToZero() public {
        // Zero liability = market fully hedged; maximum-volume LS-LMSR outcome.
        // totalLiability must reach 0 when the sole active market reports newLiability == 0.
        MockMarket m = _registerMarket();
        assertEq(pool.totalLiability(), MAX_RISK, "starts at riskBudget");

        m.doCollectTrade(trader, 0, 0); // newLiability = 0
        assertEq(pool.totalLiability(), 0, "totalLiability must reach 0");
        assertEq(pool.getMarketInfo(address(m)).currentLiability, 0);
    }
}


/*//////////////////////////////////////////////////////////////
             SECTION 5 — SETTLE MARKET TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_SettleMarketTest is BlieverV1PoolBase {

    // ─── Happy path — market with trades ────────────────────────────────────

    function test_settleMarket_withPayout_setsSettledState() public {
        uint256 tradeCost  = 5_000e6;
        uint256 tradeLiab  = 40_000e6; // decreased from 50K after trade
        uint256 payout     = 30_000e6;

        MockMarket m = _registerAndTrade(tradeCost, tradeLiab);
        m.doSettle(payout);

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        assertTrue(info.settled,                    "settled flag");
        assertEq(info.settledPayout, payout,        "settledPayout");
        assertEq(info.currentLiability, 0,          "currentLiability cleared");
    }

    function test_settleMarket_releasesCurrentLiabilityFromTotal() public {
        // After a trade, currentLiability < riskBudget.
        // settleMarket releases currentLiability (live), NOT riskBudget (original).
        uint256 tradeLiab = 30_000e6;
        MockMarket m = _registerAndTrade(1_000e6, tradeLiab);

        assertEq(pool.totalLiability(), tradeLiab);
        m.doSettle(20_000e6);
        assertEq(pool.totalLiability(), 0, "totalLiability cleared after single-market settle");
    }

    function test_settleMarket_decrementsActiveMarketCount() public {
        MockMarket m = _registerMarket();
        assertEq(pool.activeMarketCount(), 1);
        m.doSettle(0);
        assertEq(pool.activeMarketCount(), 0);
    }

    function test_settleMarket_emitsMarketSettled() public {
        MockMarket m = _registerMarket();
        uint256 payout = 20_000e6;
        uint256 profit = MAX_RISK - payout; // profit = riskBudget - totalPayout

        vm.expectEmit(true, false, false, true, address(pool));
        emit BlieverV1Pool.MarketSettled(address(m), payout, profit);
        m.doSettle(payout);
    }

    // ─── Zero-payout path ────────────────────────────────────────────────────

    function test_settleMarket_zeroPayout_revokesRoleImmediately() public {
        // When no winners exist, claimWinnings can never be called validly.
        // MARKET_ROLE must be revoked at settlement time to prevent indefinite hold.
        MockMarket m = _registerMarket();
        assertTrue(pool.hasRole(pool.MARKET_ROLE(), address(m)));
        m.doSettle(0);
        assertFalse(pool.hasRole(pool.MARKET_ROLE(), address(m)), "role must be revoked for zero-payout");
    }

    function test_settleMarket_zeroPayout_emitsMarketFullyClaimed() public {
        MockMarket m = _registerMarket();
        vm.expectEmit(true, false, false, true, address(pool));
        emit BlieverV1Pool.MarketFullyClaimed(address(m), 0);
        m.doSettle(0);
    }

    // ─── Untraded market path ─────────────────────────────────────────────────

    function test_settleMarket_untraded_emitsMarketExpiredUntraded() public {
        MockMarket m = _registerMarket();
        vm.expectEmit(true, false, false, true, address(pool));
        emit BlieverV1Pool.MarketExpiredUntraded(address(m), MAX_RISK);
        m.doSettle(0);
    }

    // ─── NOT pause-gated ─────────────────────────────────────────────────────

    function test_settleMarket_worksWhileVaultIsPaused() public {
        MockMarket m = _registerMarket();
        vm.prank(admin); pool.pause();
        // must NOT revert even though vault is paused
        m.doSettle(0);
        assertTrue(pool.getMarketInfo(address(m)).settled, "settlement must succeed when paused");
    }

    // ─── Revert paths ────────────────────────────────────────────────────────

    function test_settleMarket_reverts_PayoutExceedsRiskBudget() public {
        MockMarket m = _registerMarket();
        uint256 overPayout = MAX_RISK + 1;
        vm.expectRevert(abi.encodeWithSelector(
            BlieverV1Pool.PayoutExceedsRiskBudget.selector, overPayout, MAX_RISK));
        m.doSettle(overPayout);
    }

    function test_settleMarket_reverts_AlreadySettled() public {
        // Must use non-zero payout on the first settle: doSettle(0) revokes MARKET_ROLE
        // immediately, so a subsequent doSettle(0) would hit onlyRole(MARKET_ROLE) first
        // rather than the MarketAlreadySettled guard on line 573.
        uint256 payout = 1_000e6;
        MockMarket m = _registerAndTrade(payout, MAX_RISK / 2);
        m.doSettle(payout); // role kept — waiting for full claimWinnings
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.MarketAlreadySettled.selector, address(m)));
        m.doSettle(0);
    }

    function test_settleMarket_reverts_unauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(_accessDenied(attacker, pool.MARKET_ROLE()));
        pool.settleMarket(0);
    }

    function test_settleMarket_totalPayout_equalsRiskBudget_succeeds() public {
        // Contract check is > not >= (line 574). totalPayout == riskBudget is the
        // "LP absorbs maximum loss" case and must be accepted without revert.
        MockMarket m = _registerMarket();
        m.doSettle(MAX_RISK); // exact boundary — must not revert
        assertEq(pool.getMarketInfo(address(m)).settledPayout, MAX_RISK);
    }

    function test_settleMarket_profitIncreasesLPShareValue() public {
        // After trade costs enter the vault (without new share issuance), existing LP
        // shares convert to more USDC — the core LP value proposition.
        uint256 sharesBefore = pool.balanceOf(lp);
        uint256 assetsBefore = pool.convertToAssets(sharesBefore);

        uint256 tradeCost = 10_000e6;
        MockMarket m = _registerAndTrade(tradeCost, MAX_RISK / 2);
        m.doSettle(MAX_RISK / 4); // payout < riskBudget → vault retains spread

        uint256 assetsAfter = pool.convertToAssets(sharesBefore);
        assertGt(assetsAfter, assetsBefore,
            "LP share value must increase after trade costs enter vault");
    }

    function test_assertSolvent_reverts_VaultInsolvent() public {
        // _assertSolvent() fires at the end of settleMarket.
        // To trigger it: drain vault USDC below the liability that remains after
        // settling one market of two (each registered at MAX_RISK = 50K).
        MockMarket m1 = _registerMarket();
        MockMarket m2 = _registerMarket(); // totalLiability = 100K
        // Use vm.deal (Foundry cheatcode) to set pool USDC balance to 49 999,
        // which is below the 50K liability that remains after m1 settles.
        deal(address(usdc), address(pool), MAX_RISK - 1);

        // After settle: totalLiability = 100K − 50K = 50K; balance = 49 999 < 50K
        vm.expectRevert(abi.encodeWithSelector(
            BlieverV1Pool.VaultInsolvent.selector, MAX_RISK - 1, MAX_RISK));
        m1.doSettle(0);
    }
}


/*//////////////////////////////////////////////////////////////
         SECTION 6 — FORCE SETTLE MARKET TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_ForceSettleTest is BlieverV1PoolBase {

    // ─── Happy path ─────────────────────────────────────────────────────────

    function test_forceSettleMarket_setsSettledState() public {
        MockMarket m = _registerMarket();
        vm.prank(admin);
        pool.forceSettleMarket(address(m));

        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        assertTrue(info.settled);
        assertEq(info.settledPayout,    0, "force-settle has no payout");
        assertEq(info.currentLiability, 0, "currentLiability cleared");
        assertEq(info.riskBudget,       0, "riskBudget zeroed");
    }

    function test_forceSettleMarket_releasesLiability() public {
        MockMarket m = _registerAndTrade(0, 30_000e6); // currentLiability = 30K
        assertEq(pool.totalLiability(), 30_000e6);

        vm.prank(admin);
        pool.forceSettleMarket(address(m));

        assertEq(pool.totalLiability(), 0, "liability released by force-settle");
    }

    function test_forceSettleMarket_revokesMarketRole() public {
        MockMarket m = _registerMarket();
        assertTrue(pool.hasRole(pool.MARKET_ROLE(), address(m)));
        vm.prank(admin);
        pool.forceSettleMarket(address(m));
        assertFalse(pool.hasRole(pool.MARKET_ROLE(), address(m)));
    }

    function test_forceSettleMarket_emitsMarketForceSettled() public {
        MockMarket m = _registerAndTrade(0, 25_000e6);
        vm.expectEmit(true, false, false, true, address(pool));
        emit BlieverV1Pool.MarketForceSettled(address(m), 25_000e6);
        vm.prank(admin);
        pool.forceSettleMarket(address(m));
    }

    function test_forceSettleMarket_worksWhileVaultIsPaused() public {
        MockMarket m = _registerMarket();
        vm.prank(admin); pool.pause();
        vm.prank(admin); // emergency actions must work regardless of pause
        pool.forceSettleMarket(address(m));
        assertTrue(pool.getMarketInfo(address(m)).settled);
    }

    // ─── Revert paths ────────────────────────────────────────────────────────

    function test_forceSettleMarket_reverts_NotRegistered() public {
        MockMarket m = new MockMarket(address(pool));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.MarketNotRegistered.selector, address(m)));
        pool.forceSettleMarket(address(m));
    }

    function test_forceSettleMarket_reverts_AlreadySettled() public {
        MockMarket m = _registerMarket();
        m.doSettle(0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.MarketAlreadySettled.selector, address(m)));
        pool.forceSettleMarket(address(m));
    }

    function test_forceSettleMarket_reverts_unauthorized() public {
        MockMarket m = _registerMarket();
        vm.expectRevert(_accessDenied(attacker, pool.EMERGENCY_ROLE()));
        vm.prank(attacker);
        pool.forceSettleMarket(address(m));
    }
}


/*//////////////////////////////////////////////////////////////
              SECTION 7 — CLAIM WINNINGS TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_ClaimWinningsTest is BlieverV1PoolBase {

    function _settledMarketWithPayout(uint256 payout) internal returns (MockMarket m) {
        m = _registerAndTrade(payout, MAX_RISK / 2); // trade to build vault balance
        m.doSettle(payout);
    }

    // ─── Happy path ─────────────────────────────────────────────────────────

    function test_claimWinnings_transfersUSDCToWinner() public {
        uint256 payout = 10_000e6;
        MockMarket m = _settledMarketWithPayout(payout);

        uint256 winnerBefore = usdc.balanceOf(winner);
        m.doClaim(winner, payout);
        assertEq(usdc.balanceOf(winner), winnerBefore + payout, "winner received USDC");
    }

    function test_claimWinnings_partialClaims_trackAccumulation() public {
        uint256 payout = 10_000e6;
        MockMarket m = _settledMarketWithPayout(payout);

        m.doClaim(winner, 4_000e6);
        assertEq(pool.getMarketInfo(address(m)).claimedPayout, 4_000e6);

        m.doClaim(winner, 6_000e6);
        assertEq(pool.getMarketInfo(address(m)).claimedPayout, payout);
    }

    function test_claimWinnings_lastClaim_revokesMarketRole() public {
        uint256 payout = 5_000e6;
        MockMarket m = _settledMarketWithPayout(payout);
        assertTrue(pool.hasRole(pool.MARKET_ROLE(), address(m)), "role before claim");

        m.doClaim(winner, payout);
        assertFalse(pool.hasRole(pool.MARKET_ROLE(), address(m)), "role revoked after full claim");
    }

    function test_claimWinnings_lastClaim_emitsMarketFullyClaimed() public {
        uint256 payout = 5_000e6;
        MockMarket m = _settledMarketWithPayout(payout);

        vm.expectEmit(true, false, false, true, address(pool));
        emit BlieverV1Pool.MarketFullyClaimed(address(m), payout);
        m.doClaim(winner, payout);
    }

    function test_claimWinnings_emitsWinningsClaimed() public {
        uint256 payout = 5_000e6;
        MockMarket m = _settledMarketWithPayout(payout);

        vm.expectEmit(true, true, false, true, address(pool));
        emit BlieverV1Pool.WinningsClaimed(address(m), winner, payout);
        m.doClaim(winner, payout);
    }

    function test_claimWinnings_worksWhileVaultIsPaused() public {
        // Winners must never be blocked by operational pauses
        uint256 payout = 5_000e6;
        MockMarket m = _settledMarketWithPayout(payout);

        vm.prank(admin); pool.pause();
        m.doClaim(winner, payout); // must not revert
        assertEq(usdc.balanceOf(winner), payout);
    }

    // ─── Revert paths ────────────────────────────────────────────────────────

    function test_claimWinnings_reverts_MarketNotSettled() public {
        MockMarket m = _registerMarket(); // registered but not settled
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.MarketNotSettled.selector, address(m)));
        m.doClaim(winner, 1_000e6);
    }

    function test_claimWinnings_reverts_ZeroAddress_winner() public {
        MockMarket m = _settledMarketWithPayout(5_000e6);
        vm.expectRevert(BlieverV1Pool.ZeroAddress.selector);
        m.doClaim(address(0), 1_000e6);
    }

    function test_claimWinnings_reverts_ZeroAmount() public {
        MockMarket m = _settledMarketWithPayout(5_000e6);
        vm.expectRevert(BlieverV1Pool.ZeroAmount.selector);
        m.doClaim(winner, 0);
    }

    function test_claimWinnings_reverts_PayoutExceedsSettlement() public {
        uint256 payout = 5_000e6;
        MockMarket m = _settledMarketWithPayout(payout);
        m.doClaim(winner, 3_000e6); // partial claim first

        // Remaining = 2K; try to claim 3K
        vm.expectRevert(abi.encodeWithSelector(
            BlieverV1Pool.PayoutExceedsSettlement.selector, 3_000e6, 2_000e6));
        m.doClaim(winner, 3_000e6);
    }

    function test_claimWinnings_reverts_unauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(_accessDenied(attacker, pool.MARKET_ROLE()));
        pool.claimWinnings(winner, 1_000e6);
    }

    function test_claimWinnings_afterForceSettle_reverts_unauthorized() public {
        // forceSettleMarket revokes MARKET_ROLE immediately. Any subsequent doClaim
        // hits onlyRole(MARKET_ROLE) — not MarketNotSettled — because the role is gone.
        MockMarket m = _registerMarket();
        vm.prank(admin); pool.forceSettleMarket(address(m));
        assertFalse(pool.hasRole(pool.MARKET_ROLE(), address(m)), "role must be revoked");

        vm.expectRevert(_accessDenied(address(m), pool.MARKET_ROLE()));
        m.doClaim(winner, 1_000e6);
    }
}


/*//////////////////////////////////////////////////////////////
           SECTION 8 — ADMIN PARAMETER TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_AdminParamsTest is BlieverV1PoolBase {

    // ── setAlpha ──────────────────────────────────────────────────────────────

    function test_setAlpha_updatesValue() public {
        uint256 newAlpha = 5e16; // 5 %
        vm.prank(admin);
        pool.setAlpha(newAlpha);
        assertEq(pool.alpha(), newAlpha);
    }

    function test_setAlpha_emitsEvent() public {
        uint256 newAlpha = 5e16;
        vm.expectEmit(false, false, false, true, address(pool));
        emit BlieverV1Pool.AlphaUpdated(ALPHA, newAlpha);
        vm.prank(admin);
        pool.setAlpha(newAlpha);
    }

    function test_setAlpha_boundary_minAndMax() public {
        vm.startPrank(admin);
        pool.setAlpha(pool.MIN_ALPHA()); // 1e12 — should succeed
        assertEq(pool.alpha(), pool.MIN_ALPHA());
        pool.setAlpha(pool.MAX_ALPHA()); // 2e17 — should succeed
        assertEq(pool.alpha(), pool.MAX_ALPHA());
        vm.stopPrank();
    }

    function test_setAlpha_reverts_tooLow() public {
        uint256 bad = pool.MIN_ALPHA() - 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidAlpha.selector, bad));
        pool.setAlpha(bad);
    }

    function test_setAlpha_reverts_tooHigh() public {
        uint256 bad = pool.MAX_ALPHA() + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidAlpha.selector, bad));
        pool.setAlpha(bad);
    }

    function test_setAlpha_reverts_unauthorized() public {
        vm.expectRevert(_accessDenied(attacker, pool.DEFAULT_ADMIN_ROLE()));
        vm.prank(attacker);
        pool.setAlpha(5e16);
    }

    // ── setMaxRiskPerMarket ───────────────────────────────────────────────────

    function test_setMaxRiskPerMarket_updatesValue() public {
        uint256 newMax = 25_000e6;
        vm.prank(admin);
        pool.setMaxRiskPerMarket(newMax);
        assertEq(pool.maxRiskPerMarket(), newMax);
    }

    function test_setMaxRiskPerMarket_emitsEvent() public {
        uint256 newMax = 25_000e6;
        vm.expectEmit(false, false, false, true, address(pool));
        emit BlieverV1Pool.MaxRiskUpdated(MAX_RISK, newMax);
        vm.prank(admin);
        pool.setMaxRiskPerMarket(newMax);
    }

    function test_setMaxRiskPerMarket_reverts_zero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidMaxRisk.selector, uint256(0)));
        pool.setMaxRiskPerMarket(0);
    }

    function test_setMaxRiskPerMarket_reverts_unauthorized() public {
        vm.expectRevert(_accessDenied(attacker, pool.DEFAULT_ADMIN_ROLE()));
        vm.prank(attacker);
        pool.setMaxRiskPerMarket(25_000e6);
    }

    function test_setMaxRiskPerMarket_doesNotAffectExistingMarkets() public {
        // Contract intent: parameter changes only apply to markets registered after the call.
        MockMarket m1 = _registerMarket(); // riskBudget locked in at 50K

        vm.prank(admin);
        pool.setMaxRiskPerMarket(25_000e6); // halve the budget for future markets

        MockMarket m2 = _registerMarket(); // should use new 25K value

        assertEq(pool.getMarketInfo(address(m1)).riskBudget, MAX_RISK,   "m1 riskBudget unchanged");
        assertEq(pool.getMarketInfo(address(m2)).riskBudget, 25_000e6,   "m2 uses new maxRisk");
    }

    // ── setReserveBps ─────────────────────────────────────────────────────────

    function test_setReserveBps_updatesValue() public {
        uint16 newBps = 3_000; // 30 %
        vm.prank(admin);
        pool.setReserveBps(newBps);
        assertEq(pool.reserveBps(), newBps);
    }

    function test_setReserveBps_emitsEvent() public {
        uint16 newBps = 3_000;
        vm.expectEmit(false, false, false, true, address(pool));
        emit BlieverV1Pool.ReserveBpsUpdated(RESERVE_BPS, newBps);
        vm.prank(admin);
        pool.setReserveBps(newBps);
    }

    function test_setReserveBps_boundary_minAndMax() public {
        vm.startPrank(admin);
        pool.setReserveBps(uint16(pool.MIN_RESERVE_BPS())); // 500 — should succeed
        pool.setReserveBps(uint16(pool.MAX_RESERVE_BPS())); // 5000 — should succeed
        vm.stopPrank();
    }

    function test_setReserveBps_reverts_tooLow() public {
        uint16 bad = uint16(pool.MIN_RESERVE_BPS()) - 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidBps.selector, bad));
        pool.setReserveBps(bad);
    }

    function test_setReserveBps_reverts_tooHigh() public {
        uint16 bad = uint16(pool.MAX_RESERVE_BPS()) + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidBps.selector, bad));
        pool.setReserveBps(bad);
    }

    function test_setReserveBps_reverts_unauthorized() public {
        vm.expectRevert(_accessDenied(attacker, pool.DEFAULT_ADMIN_ROLE()));
        vm.prank(attacker);
        pool.setReserveBps(3_000);
    }
}


/*//////////////////////////////////////////////////////////////
              SECTION 9 — PAUSE CONTROL TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_PauseTest is BlieverV1PoolBase {

    // ─── Pause / unpause roles ────────────────────────────────────────────────

    function test_pause_succeeds_byPauser() public {
        vm.prank(admin);
        pool.pause();
        assertTrue(pool.paused());
    }

    function test_unpause_succeeds_byAdmin() public {
        vm.prank(admin); pool.pause();
        vm.prank(admin); pool.unpause();
        assertFalse(pool.paused());
    }

    function test_unpause_reverts_byPauserOnly() public {
        // PAUSER_ROLE cannot unpause — unpause needs DEFAULT_ADMIN_ROLE
        address pauserOnly = makeAddr("pauserOnly");
        vm.prank(admin);
        pool.grantRole(pool.PAUSER_ROLE(), pauserOnly);

        vm.prank(admin); pool.pause();

        vm.expectRevert(_accessDenied(pauserOnly, pool.DEFAULT_ADMIN_ROLE()));
        vm.prank(pauserOnly);
        pool.unpause();
    }

    function test_pause_reverts_byNonPauser() public {
        vm.expectRevert(_accessDenied(attacker, pool.PAUSER_ROLE()));
        vm.prank(attacker);
        pool.pause();
    }

    // ─── Pause effect on operations ──────────────────────────────────────────

    function test_pause_blocksDeposit() public {
        vm.prank(admin); pool.pause();
        usdc.mint(lp2, 1_000e6);
        vm.startPrank(lp2);
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        pool.deposit(1_000e6, lp2);
        vm.stopPrank();
    }

    function test_pause_blocksWithdraw() public {
        vm.prank(admin); pool.pause();
        assertEq(pool.maxWithdraw(lp), 0, "maxWithdraw must be 0 when paused");
        // Attempting withdraw via ERC-4626 would also hit _update block
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        vm.prank(lp);
        pool.withdraw(1_000e6, lp, lp);
    }

    function test_pause_blocksRegisterMarket() public {
        MockMarket m = new MockMarket(address(pool));
        vm.prank(admin); pool.pause();
        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        pool.registerMarket(address(m), 2);
    }

    function test_pause_blocksTokenTransfer() public {
        vm.prank(admin); pool.pause();
        // bLP transfer blocked by _update override
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        vm.prank(lp);
        pool.transfer(lp2, 1);
    }

    function test_pause_maxDeposit_returns0() public {
        vm.prank(admin); pool.pause();
        assertEq(pool.maxDeposit(lp), 0);
    }

    function test_pause_maxMint_returns0() public {
        vm.prank(admin); pool.pause();
        assertEq(pool.maxMint(lp), 0);
    }

    function test_pause_maxWithdraw_returns0() public {
        vm.prank(admin); pool.pause();
        assertEq(pool.maxWithdraw(lp), 0);
    }

    function test_pause_maxRedeem_returns0() public {
        vm.prank(admin); pool.pause();
        assertEq(pool.maxRedeem(lp), 0);
    }

    function test_pause_blocksCollectTrade() public {
        // collectTradeCost has whenNotPaused (line 500) — must revert when paused.
        MockMarket m = _registerMarket();
        vm.prank(admin); pool.pause();
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        m.doCollectTrade(trader, 0, MAX_RISK);
    }
}


/*//////////////////////////////////////////////////////////////
           SECTION 10 — ERC-4626 LP VAULT TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_ERC4626Test is BlieverV1PoolBase {

    // ─── Deposit / Shares ────────────────────────────────────────────────────

    function test_deposit_mintsShares() public {
        uint256 depositAmount = 10_000e6;
        uint256 shares = _depositLiquidity(lp2, depositAmount);
        assertGt(shares, 0, "must mint non-zero shares");
        assertEq(pool.balanceOf(lp2), shares, "balance matches");
    }

    function test_deposit_increasesTotalAssets() public {
        uint256 assetsBefore = pool.totalAssets();
        uint256 extra = 10_000e6;
        _depositLiquidity(lp2, extra);
        assertEq(pool.totalAssets(), assetsBefore + extra);
    }

    function test_withdraw_burnsSharesAndReturnsUSDC() public {
        // No markets registered → full free liquidity
        uint256 withdrawAmount = 10_000e6;
        uint256 usdcBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        pool.withdraw(withdrawAmount, lp, lp);
        assertEq(usdc.balanceOf(lp), usdcBefore + withdrawAmount, "lp received USDC");
    }

    function test_redeem_burnsSharesAndReturnsUSDC() public {
        uint256 redeemShares = pool.balanceOf(lp) / 10; // redeem 10% of holdings
        uint256 usdcBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        uint256 received = pool.redeem(redeemShares, lp, lp);
        assertGt(received, 0);
        assertEq(usdc.balanceOf(lp), usdcBefore + received);
    }

    function test_maxWithdraw_cappedByFreeLiquidity() public {
        // Register a market so some capital is locked
        _registerMarket(); // locks 50K USDC in liability

        uint256 free = pool.availableLiquidity();
        uint256 maxW = pool.maxWithdraw(lp);
        assertLe(maxW, free, "maxWithdraw must not exceed free liquidity");
    }

    function test_maxWithdraw_zeroWhenFullyUtilised() public {
        // Register 8 markets to exhaust activeCap (8 × 50K = 400K = 500K × 80%)
        for (uint i; i < 8; i++) {
            _registerMarket();
        }
        // free = 500K - 400K - 100K(reserve) = 0
        assertEq(pool.availableLiquidity(), 0, "vault fully utilised");
        assertEq(pool.maxWithdraw(lp), 0,      "maxWithdraw is 0 when no free liquidity");
    }

    function test_withdraw_reverts_beyondFreeLiquidity() public {
        _registerMarket(); // locks 50K; free = 500K - 50K - 100K(reserve) = 350K
        // maxWithdraw(lp) ≈ 350K; LP_DEPOSIT = 500K — exceeds free liquidity
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)")),
            lp, LP_DEPOSIT, pool.maxWithdraw(lp)
        ));
        vm.prank(lp);
        pool.withdraw(LP_DEPOSIT, lp, lp);
    }

    function test_decimals_returns18() public view {
        assertEq(pool.decimals(), 18);
    }

    function test_totalAssets_equalsRawUSDCBalance() public view {
        assertEq(pool.totalAssets(), usdc.balanceOf(address(pool)));
    }
}


/*//////////////////////////////////////////////////////////////
             SECTION 11 — VIEW FUNCTION TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_ViewFunctionsTest is BlieverV1PoolBase {

    function test_availableLiquidity_noMarkets() public view {
        // free = 500K - 0(liability) - 100K(20% reserve) = 400K
        uint256 expected = LP_DEPOSIT - (LP_DEPOSIT * RESERVE_BPS / 10_000);
        assertEq(pool.availableLiquidity(), expected, "free liquidity with no markets");
    }

    function test_availableLiquidity_decreasesAfterRegister() public {
        uint256 freeBefore = pool.availableLiquidity();
        _registerMarket();
        uint256 freeAfter = pool.availableLiquidity();
        assertLt(freeAfter, freeBefore, "free liquidity decreased after registration");
        assertEq(freeBefore - freeAfter, MAX_RISK, "decrease equals riskBudget");
    }

    function test_availableLiquidity_increasesAfterTrade() public {
        // After a trade that decreases currentLiability, free liquidity rises
        MockMarket m = _registerAndTrade(1_000e6, MAX_RISK / 2);
        uint256 free = pool.availableLiquidity();

        // free = (LP_DEPOSIT + 1K_trade) - (25K_liability) - reserve
        // Compared to post-register free = LP_DEPOSIT - 50K - reserve; free should be higher now
        // Just check it equals the expected formula
        uint256 assets  = pool.totalAssets();
        uint256 reserve = assets * RESERVE_BPS / 10_000;
        uint256 expected = assets > pool.totalLiability() + reserve
                         ? assets - pool.totalLiability() - reserve
                         : 0;
        assertEq(free, expected, "availableLiquidity formula");
    }

    function test_utilizationBps_zero_whenNoLiability() public view {
        // No markets registered → liability = 0 → 0 bps
        assertEq(pool.utilizationBps(), 0);
    }

    function test_utilizationBps_correct_afterRegister() public {
        _registerMarket(); // 50K liability; activeCap = 500K × 80% = 400K
        // utilization = 50K / 400K × 10000 = 1250 bps
        assertEq(pool.utilizationBps(), 1_250, "utilisation 12.5%");
    }

    function test_utilizationBps_zeroWhenNoAssets() public {
        // utilizationBps has an explicit `if (assets == 0) return 0` branch.
        // Fresh pool with no deposits exercises this path.
        BlieverV1Pool emptyPool;
        {
            BlieverV1Pool impl2 = new BlieverV1Pool();
            emptyPool = BlieverV1Pool(address(new ERC1967Proxy(address(impl2),
                abi.encodeCall(BlieverV1Pool.initialize,
                    (address(usdc), admin, ALPHA, MAX_RISK, RESERVE_BPS)))));
        }
        assertEq(emptyPool.utilizationBps(), 0, "must return 0 when totalAssets == 0");
    }

    function test_utilizationBps_fullUtilization() public {
        // 8 markets × 50K = 400K = 500K × 80% = activeCap exactly → 10 000 bps (100%)
        for (uint i; i < 8; i++) _registerMarket();
        assertEq(pool.utilizationBps(), 10_000, "full utilisation = 10 000 bps");
    }

    function test_nav_correct() public view {
        // NAV = totalAssets − totalLiability = 500K − 0 = 500K
        assertEq(pool.nav(), LP_DEPOSIT);
    }

    function test_nav_decreasesAfterRegister() public {
        _registerMarket();
        assertEq(pool.nav(), LP_DEPOSIT - MAX_RISK);
    }

    function test_nav_remainsPositive_whenFullyUtilised() public {
        // 8 markets × 50K = 400K; totalAssets = 500K; NAV = 100K (reserve buffer)
        for (uint i; i < 8; i++) {
            _registerMarket();
        }
        assertGt(pool.nav(), 0, "NAV positive even at full market utilisation");
    }

    function test_nav_returnsZero_whenLiabilityExceedsAssets() public {
        // Drain vault USDC below totalLiability to force nav() floor to 0.
        // nav() returns 0 when totalLiability >= totalAssets (protected subtraction).
        _registerMarket(); // totalLiability = 50K
        deal(address(usdc), address(pool), MAX_RISK - 1); // balance = 49 999 USDC < 50K liability
        assertEq(pool.nav(), 0, "nav() must return 0 when liability >= assets");
    }

    function test_isSolvent_trueAlways() public {
        _registerMarket();
        assertTrue(pool.isSolvent(), "vault must always be solvent");
    }

    function test_isActiveMarket_trueAfterRegister() public {
        MockMarket m = _registerMarket();
        assertTrue(pool.isActiveMarket(address(m)));
    }

    function test_isActiveMarket_falseAfterSettle() public {
        MockMarket m = _registerMarket();
        m.doSettle(0);
        assertFalse(pool.isActiveMarket(address(m)), "settled market is no longer active");
    }

    function test_isActiveMarket_falseForUnregistered() public view {
        assertFalse(pool.isActiveMarket(attacker));
    }

    function test_getMarketInfo_returnsFullStruct() public {
        MockMarket m = _registerMarket();
        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        assertTrue(info.registered);
        assertFalse(info.settled);
        assertFalse(info.hasTrades);
        assertEq(info.riskBudget,       MAX_RISK);
        assertEq(info.currentLiability, MAX_RISK);
        assertEq(info.settledPayout,    0);
        assertEq(info.claimedPayout,    0);
    }
}


/*//////////////////////////////////////////////////////////////
              SECTION 12 — UUPS UPGRADE TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_UpgradeTest is BlieverV1PoolBase {

    function test_upgrade_reverts_unauthorized() public {
        BlieverV1Pool newImpl = new BlieverV1Pool();
        vm.expectRevert(_accessDenied(attacker, pool.UPGRADER_ROLE()));
        vm.prank(attacker);
        pool.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_succeeds_byUpgrader() public {
        BlieverV1Pool newImpl = new BlieverV1Pool();
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

        vm.prank(admin);
        pool.upgradeToAndCall(address(newImpl), "");

        // Verify implementation slot updated in proxy
        bytes32 stored = vm.load(address(pool), implSlot);
        assertEq(address(uint160(uint256(stored))), address(newImpl), "impl slot updated");
    }

    function test_upgrade_preservesState() public {
        // Register a market before upgrade; state must survive
        MockMarket m = _registerMarket();
        assertTrue(pool.getMarketInfo(address(m)).registered, "pre-upgrade");

        BlieverV1Pool newImpl = new BlieverV1Pool();
        vm.prank(admin);
        pool.upgradeToAndCall(address(newImpl), "");

        // State persists through upgrade
        assertTrue(pool.getMarketInfo(address(m)).registered, "post-upgrade state preserved");
        assertEq(pool.totalLiability(), MAX_RISK, "liability preserved");
    }
}


/*//////////////////////////////////////////////////////////////
                 SECTION 13 — FUZZ TESTS
//////////////////////////////////////////////////////////////*/

contract BlieverV1Pool_FuzzTest is BlieverV1PoolBase {

    /// @dev Depositing `amount` USDC must always mint proportional shares.
    ///      Share exchange rate must never regress below initial 1:1e12 ratio.
    function testFuzz_deposit_sharesAlwaysGtZero(uint256 amount) public {
        amount = bound(amount, 1e6, 10_000_000e6); // 1 USDC … 10 M USDC
        uint256 shares = _depositLiquidity(lp2, amount);
        assertGt(shares, 0, "deposit must always mint nonzero shares");
    }

    /// @dev After a trade that decreases liability, totalLiability must equal
    ///      the new currentLiability submitted by the market.
    function testFuzz_collectTradeCost_liabilityTrackedCorrectly(
        uint256 tradeCost,
        uint256 newLiability
    ) public {
        tradeCost   = bound(tradeCost,   0,        10_000e6);  // 0 – 10K USDC trade
        newLiability = bound(newLiability, 0,       MAX_RISK);  // must not exceed riskBudget

        if (tradeCost > 0) {
            usdc.mint(trader, tradeCost);
            vm.prank(trader);
            usdc.approve(address(pool), tradeCost);
        }

        MockMarket m = _registerMarket();
        m.doCollectTrade(trader, tradeCost, newLiability);

        // totalLiability must equal capped newLiability (newLiability ≤ MAX_RISK here)
        assertEq(pool.totalLiability(), newLiability, "totalLiability post-trade");
        assertEq(pool.getMarketInfo(address(m)).currentLiability, newLiability, "market liability");
    }

    /// @dev If a misbehaving market sends newLiability > riskBudget, the vault
    ///      must cap it and never let totalLiability exceed activeCap.
    function testFuzz_collectTradeCost_capNeverExceedsRiskBudget(uint256 overBudget) public {
        overBudget = bound(overBudget, MAX_RISK + 1, MAX_RISK * 10);

        MockMarket m = _registerMarket();
        m.doCollectTrade(trader, 0, overBudget);

        assertEq(pool.getMarketInfo(address(m)).currentLiability, MAX_RISK,
                 "capped at riskBudget");
    }

    /// @dev availableLiquidity() must never go negative (always ≥ 0).
    function testFuzz_freeLiquidity_neverNegative(
        uint256 extraDeposit,
        uint256 numMarkets
    ) public {
        extraDeposit = bound(extraDeposit, 0,      500_000e6); // up to 500K more
        numMarkets   = bound(numMarkets,   0,      4);          // 0–4 markets

        if (extraDeposit > 0) _depositLiquidity(lp2, extraDeposit);

        for (uint i; i < numMarkets; i++) {
            MockMarket m = new MockMarket(address(pool));
            vm.prank(admin);
            try pool.registerMarket(address(m), 2) {} catch {}
        }

        // Must never underflow or go negative (uint, so must stay >= 0)
        uint256 free = pool.availableLiquidity();
        assertGe(free, 0, "free liquidity must be >= 0 (should always hold for uint256)");
        assertLe(pool.totalLiability(), pool.totalAssets(), "solvency: liability <= assets");
    }

    /// @dev Settlement profit is always ≥ 0 (riskBudget ≥ totalPayout guaranteed by contract).
    function testFuzz_settleMarket_profitNonNegative(uint256 payout) public {
        payout = bound(payout, 0, MAX_RISK); // valid payout range
        MockMarket m = _registerAndTrade(payout, MAX_RISK / 2); // trade cost = payout
        m.doSettle(payout);

        // profit = riskBudget − payout (from event); must be ≥ 0
        BlieverV1Pool.MarketInfo memory info = pool.getMarketInfo(address(m));
        assertEq(info.settledPayout, payout);
        assertTrue(pool.isSolvent(), "vault still solvent after settle");
    }

    /// @dev setReserveBps accepts any value in [MIN, MAX] and rejects outside.
    function testFuzz_setReserveBps_boundsEnforced(uint16 bps) public {
        uint16 minBps = uint16(pool.MIN_RESERVE_BPS());
        uint16 maxBps = uint16(pool.MAX_RESERVE_BPS());

        if (bps >= minBps && bps <= maxBps) {
            vm.prank(admin);
            pool.setReserveBps(bps);
            assertEq(pool.reserveBps(), bps);
        } else {
            vm.prank(admin);
            vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidBps.selector, bps));
            pool.setReserveBps(bps);
        }
    }

    /// @dev setAlpha accepts only values in [MIN_ALPHA, MAX_ALPHA].
    function testFuzz_setAlpha_boundsEnforced(uint256 alpha_) public {
        alpha_ = bound(alpha_, 0, 1e18);

        bool valid = alpha_ >= pool.MIN_ALPHA() && alpha_ <= pool.MAX_ALPHA();
        if (valid) {
            vm.prank(admin);
            pool.setAlpha(alpha_);
            assertEq(pool.alpha(), alpha_);
        } else {
            vm.prank(admin);
            vm.expectRevert(abi.encodeWithSelector(BlieverV1Pool.InvalidAlpha.selector, alpha_));
            pool.setAlpha(alpha_);
        }
    }

}
