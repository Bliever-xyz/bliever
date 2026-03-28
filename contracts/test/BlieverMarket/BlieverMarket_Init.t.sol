// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2}  from "forge-std/Test.sol";
import {Clones}           from "@openzeppelin/contracts/proxy/Clones.sol";

import {BlieverMarket}   from "../../src/BlieverMarket.sol";
import {BlieverMarketBase} from "./BlieverMarketBase.t.sol";

/// @title  BlieverMarket — Initialization Tests
/// @notice Covers every branch of initialize(): happy path storage verification,
///         input validation reverts, double-init guard, event emission, and
///         the master-implementation lock enforced by _disableInitializers().
///
/// @dev    EVM requirement: Cancun (EIP-1153 transient storage for ReentrancyGuardTransient).
///         Run with:  forge test --match-contract BlieverMarket_InitTest --evm-version cancun -vvv
contract BlieverMarket_InitTest is BlieverMarketBase {

    /*//////////////////////////////////////////////////////////////
                         HAPPY PATH — STORAGE STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev All storage variables are written correctly for a 2-outcome market.
    function test_init_stateVars_correct_2outcomes() public view {
        assertEq(market2.pool(),                address(pool),          "pool");
        assertEq(market2.outcomeCount(),        2,                      "outcomeCount");
        assertEq(market2.resolved(),            false,                  "resolved");
        assertEq(market2.winningOutcome(),      0,                      "winningOutcome default");
        assertEq(market2.resolver(),            resolver,               "resolver");
        assertEq(market2.tradingDeadline(),     deployTs + T_TRADING,   "tradingDeadline");
        assertEq(market2.resolutionDeadline(),  deployTs + T_RESOLUTION,"resolutionDeadline");
        assertEq(market2.factory(),             factory,                "factory");
        assertEq(market2.questionId(),          keccak256("q2"),        "questionId");
        assertEq(market2.alpha(),               ALPHA,                  "alpha");
        assertEq(market2.usdc(),                address(usdc),          "usdc cached");
    }

    /// @dev All storage variables are written correctly for a 7-outcome market.
    function test_init_stateVars_correct_7outcomes() public view {
        assertEq(market7.pool(),          address(pool), "pool");
        assertEq(market7.outcomeCount(),  7,             "outcomeCount");
        assertEq(market7.alpha(),         ALPHA,         "alpha");
        assertEq(market7.questionId(),    keccak256("q7"), "questionId");
        assertEq(market7.usdc(),          address(usdc), "usdc cached");
    }

    /// @dev Initial quantity vector q⁰ = [ε, ε] for 2 outcomes.
    function test_init_initialQuantities_2outcomes() public view {
        uint256[] memory q = market2.getQuantities();
        assertEq(q.length, 2,        "q length");
        assertEq(q[0],     EPSILON_2, "q[0] = epsilon");
        assertEq(q[1],     EPSILON_2, "q[1] = epsilon");
    }

    /// @dev Initial quantity vector q⁰ = [ε,...,ε] for 7 outcomes.
    function test_init_initialQuantities_7outcomes() public view {
        uint256[] memory q = market7.getQuantities();
        assertEq(q.length, 7, "q length");
        for (uint256 i = 0; i < 7; ++i) {
            assertEq(q[i], EPSILON_7, string.concat("q[", vm.toString(i), "] = epsilon"));
        }
    }

    /// @dev getInitialQuantities() is a frozen snapshot matching the live vector at init.
    function test_init_initialQuantities_matchesLiveAtStart() public view {
        uint256[] memory qLive = market2.getQuantities();
        uint256[] memory q0    = market2.getInitialQuantities();
        assertEq(qLive.length, q0.length, "length");
        for (uint256 i = 0; i < qLive.length; ++i) {
            assertEq(qLive[i], q0[i], "initial == live before any trades");
        }
    }

    /// @dev USDC address is fetched from pool.asset() and cached during init.
    function test_init_usdcCachedFromPool() public view {
        assertEq(market2.usdcToken(), address(usdc));
    }

    /// @dev Initial prices are symmetric (≈ 1/n each) at uniform epsilon.
    ///      LS-LMSR: Σ prices > 1 always; we verify > 0 and < 1 individually.
    function test_init_prices_symmetric_2outcomes() public view {
        uint256 p0 = market2.getPrice(0);
        uint256 p1 = market2.getPrice(1);
        // At uniform q⁰, both prices must be identical.
        assertEq(p0, p1, "prices equal at symmetric init");
        // Each price is strictly between 0 and 1e18.
        assertGt(p0, 0,    "price > 0");
        assertLt(p0, 1e18, "price < 1 (18-dec)");
    }

    /*//////////////////////////////////////////////////////////////
                         HAPPY PATH — EVENT EMISSION
    //////////////////////////////////////////////////////////////*/

    /// @dev MarketInitialized event is emitted with all correct parameters.
    function test_init_emitsMarketInitialized() public {
        BlieverMarket freshMarket = BlieverMarket(Clones.clone(address(impl)));

        bytes32 qId = keccak256("evtTest");
        vm.expectEmit(true, true, false, true, address(freshMarket));
        emit BlieverMarket.MarketInitialized(
            qId,
            address(pool),
            2,
            ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2
        );

        freshMarket.initialize(
            address(pool),
            qId,
            2,
            ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2,
            resolver,
            factory
        );
    }

    /// @dev Market begins in tradingOpen state immediately after init.
    function test_init_tradingOpenImmediatelyAfterInit() public view {
        (, , bool isTradingOpen, , , ) = market2.getMarketStatus();
        assertTrue(isTradingOpen, "trading must be open right after init");
    }

    /*//////////////////////////////////////////////////////////////
                       REVERT — ADDRESS ZERO INPUTS
    //////////////////////////////////////////////////////////////*/

    function test_init_revert_zeroPool() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        vm.expectRevert(BlieverMarket.ZeroAddress.selector);
        m.initialize(
            address(0), keccak256("z"), 2, ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
    }

    function test_init_revert_zeroResolver() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        vm.expectRevert(BlieverMarket.ZeroAddress.selector);
        m.initialize(
            address(pool), keccak256("z"), 2, ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, address(0), factory
        );
    }

    function test_init_revert_zeroFactory() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        vm.expectRevert(BlieverMarket.ZeroAddress.selector);
        m.initialize(
            address(pool), keccak256("z"), 2, ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, address(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                       REVERT — OUTCOME COUNT
    //////////////////////////////////////////////////////////////*/

    function test_init_revert_outcomeCount_one() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        vm.expectRevert(abi.encodeWithSelector(BlieverMarket.InvalidOutcomeCount.selector, 1));
        m.initialize(
            address(pool), keccak256("z"), 1, ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
    }

    function test_init_revert_outcomeCount_zero() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        vm.expectRevert(abi.encodeWithSelector(BlieverMarket.InvalidOutcomeCount.selector, 0));
        m.initialize(
            address(pool), keccak256("z"), 0, ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
    }

    function test_init_revert_outcomeCount_101() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        vm.expectRevert(abi.encodeWithSelector(BlieverMarket.InvalidOutcomeCount.selector, 101));
        m.initialize(
            address(pool), keccak256("z"), 101, ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
    }

    /*//////////////////////////////////////////////////////////////
                         REVERT — ALPHA
    //////////////////////////////////////////////////////////////*/

    /// @dev alpha below LSMath.MIN_ALPHA (1e12) is rejected.
    function test_init_revert_alpha_tooLow() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        uint256 badAlpha = 1e12 - 1; // just under minimum
        vm.expectRevert(abi.encodeWithSelector(BlieverMarket.InvalidAlpha.selector, badAlpha));
        m.initialize(
            address(pool), keccak256("z"), 2, badAlpha,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
    }

    /// @dev alpha above LSMath.MAX_ALPHA (2e17) is rejected.
    function test_init_revert_alpha_tooHigh() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        uint256 badAlpha = 2e17 + 1; // just above maximum
        vm.expectRevert(abi.encodeWithSelector(BlieverMarket.InvalidAlpha.selector, badAlpha));
        m.initialize(
            address(pool), keccak256("z"), 2, badAlpha,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
    }

    /*//////////////////////////////////////////////////////////////
                         REVERT — EPSILON / DEADLINES
    //////////////////////////////////////////////////////////////*/

    function test_init_revert_zeroEpsilon() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        vm.expectRevert(BlieverMarket.ZeroEpsilon.selector);
        m.initialize(
            address(pool), keccak256("z"), 2, ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            0, resolver, factory
        );
    }

    /// @dev tradingDeadline == block.timestamp is NOT accepted (must be strictly >).
    function test_init_revert_tradingDeadline_atCurrentTime() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        vm.expectRevert(BlieverMarket.InvalidDeadlines.selector);
        m.initialize(
            address(pool), keccak256("z"), 2, ALPHA,
            uint40(block.timestamp),       // NOT in the future
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
    }

    /// @dev tradingDeadline in the past is rejected.
    function test_init_revert_tradingDeadline_inPast() public {
        vm.warp(block.timestamp + 1 days);  // advance time
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        vm.expectRevert(BlieverMarket.InvalidDeadlines.selector);
        m.initialize(
            address(pool), keccak256("z"), 2, ALPHA,
            uint40(block.timestamp) - 1,   // one second in the past
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
    }

    /// @dev resolutionDeadline must be strictly after tradingDeadline.
    function test_init_revert_resolutionDeadline_beforeTrading() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        uint40 tDeadline = uint40(block.timestamp) + T_TRADING;
        vm.expectRevert(BlieverMarket.InvalidDeadlines.selector);
        m.initialize(
            address(pool), keccak256("z"), 2, ALPHA,
            tDeadline,
            tDeadline, // same as trading deadline — NOT allowed
            EPSILON_2, resolver, factory
        );
    }

    /// @dev resolutionDeadline < tradingDeadline is rejected.
    function test_init_revert_resolutionDeadline_beforeTrading_earlyValue() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        uint40 tDeadline = uint40(block.timestamp) + T_TRADING;
        vm.expectRevert(BlieverMarket.InvalidDeadlines.selector);
        m.initialize(
            address(pool), keccak256("z"), 2, ALPHA,
            tDeadline,
            tDeadline - 1, // one second BEFORE trading deadline
            EPSILON_2, resolver, factory
        );
    }

    /*//////////////////////////////////////////////////////////////
                       REVERT — DOUBLE INIT / IMPL LOCK
    //////////////////////////////////////////////////////////////*/

    /// @dev Calling initialize() a second time on the same clone reverts.
    function test_init_revert_doubleInit() public {
        // market2 is already initialized from setUp; second call must fail.
        vm.expectRevert(); // OZ: InvalidInitialization
        market2.initialize(
            address(pool), keccak256("dup"), 2, ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
    }

    /// @dev The master implementation contract cannot be initialized
    ///      (constructor calls _disableInitializers()).
    function test_init_revert_masterImpl_locked() public {
        vm.expectRevert(); // OZ: InvalidInitialization
        impl.initialize(
            address(pool), keccak256("impl"), 2, ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
    }

    /*//////////////////////////////////////////////////////////////
                     BOUNDARY — VALID EXTREME VALUES
    //////////////////////////////////////////////////////////////*/

    /// @dev outcomeCount = 2 (minimum) is accepted.
    function test_init_boundary_minOutcomeCount() public {
        BlieverMarket m = _newClone(2, EPSILON_2, keccak256("min2"));
        assertEq(m.outcomeCount(), 2);
    }

    /// @dev outcomeCount = 100 (maximum) is accepted.
    ///      epsilon for 100 outcomes at 3%: R / (1 + 0.03·100·ln100) ≈ 500e18/14.82 ≈ 33.7e18
    function test_init_boundary_maxOutcomeCount() public {
        uint256 eps100 = 34e18; // approximate for n=100
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        m.initialize(
            address(pool), keccak256("max100"), 100, ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            eps100, resolver, factory
        );
        assertEq(m.outcomeCount(), 100);
    }

    /// @dev alpha = MIN_ALPHA (1e12) is accepted.
    function test_init_boundary_minAlpha() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        m.initialize(
            address(pool), keccak256("minAlpha"), 2, 1e12,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
        assertEq(m.alpha(), 1e12);
    }

    /// @dev alpha = MAX_ALPHA (2e17) is accepted.
    function test_init_boundary_maxAlpha() public {
        BlieverMarket m = BlieverMarket(Clones.clone(address(impl)));
        m.initialize(
            address(pool), keccak256("maxAlpha"), 2, 2e17,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            EPSILON_2, resolver, factory
        );
        assertEq(m.alpha(), 2e17);
    }
}
