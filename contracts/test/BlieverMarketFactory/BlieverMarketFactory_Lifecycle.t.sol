// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import "./BlieverMarketFactoryBase.t.sol";

/// @title  BlieverMarketFactory — Lifecycle Tests
/// @notice Tests for all post-deployment market lifecycle operations:
///
///         expireUnresolved  — permissionless expiry after resolutionDeadline
///         pauseMarket       — PAUSER_ROLE halts trading on a clone
///         unpauseMarket     — PAUSER_ROLE resumes trading on a clone
///         deregisterMarket  — DEFAULT_ADMIN_ROLE removes a market from the pool
///         factory pause     — global PAUSER_ROLE pause blocks only deployMarket
///
///         All lifecycle functions require _assertDeployedMarket to pass,
///         meaning arbitrary contract addresses are rejected.
contract BlieverMarketFactory_Lifecycle is FactoryTestBase {

    /*//////////////////////////////////////////////////////////////
                       SHARED DEPLOYMENT HELPER
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploys a 2-outcome binary market and returns its address.
    ///      Each call uses a unique label to guarantee distinct questionIds.
    function _freshMarket(string memory label) internal returns (address) {
        return _deployMarket(2, _qId(label));
    }

    /*//////////////////////////////////////////////////////////////
                       expireUnresolved — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_expireUnresolved_success_emitsEvent() public {
        address market = _freshMarket("expire_event");

        // Warp past resolutionDeadline
        vm.warp(block.timestamp + T_RESOLUTION + 1);

        bytes32 expectedQId = IDeployableMarket(market).questionId();

        vm.expectEmit(true, true, false, false, address(factory));
        emit BlieverMarketFactory.MarketExpiredByFactory(
            market,
            expectedQId,
            uint40(block.timestamp)
        );

        vm.prank(anyone);
        factory.expireUnresolved(market);
    }

    function test_expireUnresolved_callsPoolSettleWithZeroPayout() public {
        address market = _freshMarket("expire_pool");
        vm.warp(block.timestamp + T_RESOLUTION + 1);

        factory.expireUnresolved(market);

        assertEq(mockPool.settleCalls(), 1, "pool.settleMarket must be called once");
        assertEq(mockPool.lastSettledPayout(), 0, "settle payout must be zero on expiry");
    }

    function test_expireUnresolved_setsMarketResolved() public {
        address market = _freshMarket("expire_resolved");
        vm.warp(block.timestamp + T_RESOLUTION + 1);

        factory.expireUnresolved(market);

        // After expiry the clone itself marks resolved = true
        assertTrue(IDeployableMarket(market).resolved(), "clone must be resolved after expiry");
    }

    function test_expireUnresolved_isPermissionless() public {
        address market = _freshMarket("expire_permissionless");
        vm.warp(block.timestamp + T_RESOLUTION + 1);

        // attacker (no role) can call it — must succeed
        vm.prank(attacker);
        factory.expireUnresolved(market);

        assertTrue(factory.isDeployedMarket(market));
    }

    function test_expireUnresolved_exactlyOnDeadlinePlusOne() public {
        address market = _freshMarket("expire_exact");
        uint40  deadline = IDeployableMarket(market).resolutionDeadline();

        vm.warp(deadline + 1);
        factory.expireUnresolved(market); // must succeed at deadline + 1

        assertTrue(IDeployableMarket(market).resolved());
    }

    /*//////////////////////////////////////////////////////////////
                       expireUnresolved — REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_expireUnresolved_reverts_beforeDeadline() public {
        address market   = _freshMarket("expire_before_dl");
        uint40  deadline = IDeployableMarket(market).resolutionDeadline();

        // At exactly the deadline — still not allowed (strictly <=)
        vm.warp(deadline);

        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__ResolutionDeadlineNotPassed.selector,
                deadline,
                uint40(block.timestamp)
            )
        );
        factory.expireUnresolved(market);
    }

    function test_expireUnresolved_reverts_alreadyResolved() public {
        address market = _freshMarket("expire_already");

        // Resolve market normally BEFORE its resolution deadline
        // warp to after trading deadline but before resolution deadline
        vm.warp(block.timestamp + T_TRADING + 1);
        _resolveMarket(market, 0);   // resolver = mockAdapter

        // Now warp past resolution deadline and attempt to expire
        vm.warp(block.timestamp + T_RESOLUTION + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__MarketAlreadyResolved.selector,
                market
            )
        );
        factory.expireUnresolved(market);
    }

    function test_expireUnresolved_reverts_notDeployedMarket() public {
        address random = makeAddr("not_a_factory_market");

        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__NotDeployedMarket.selector,
                random
            )
        );
        factory.expireUnresolved(random);
    }

    function test_expireUnresolved_reverts_calledTwice() public {
        address market = _freshMarket("expire_double");
        vm.warp(block.timestamp + T_RESOLUTION + 1);

        factory.expireUnresolved(market); // first call succeeds

        // Second call: market is now resolved
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__MarketAlreadyResolved.selector,
                market
            )
        );
        factory.expireUnresolved(market);
    }

    /*//////////////////////////////////////////////////////////////
                       pauseMarket / unpauseMarket
    //////////////////////////////////////////////////////////////*/

    function test_pauseMarket_success_emitsEvent() public {
        address market = _freshMarket("pause_event");

        vm.expectEmit(true, false, false, false, address(factory));
        emit BlieverMarketFactory.MarketPausedByFactory(market);

        vm.prank(pauser);
        factory.pauseMarket(market);
    }

    function test_pauseMarket_cloneIsPaused() public {
        address market = _freshMarket("pause_state");

        vm.prank(pauser);
        factory.pauseMarket(market);

        // Pausable.paused() is exposed by PausableUpgradeable
        assertTrue(BlieverMarket(market).paused(), "clone must be paused");
    }

    function test_pauseMarket_reverts_notPauser() public {
        address market = _freshMarket("pause_acl");

        vm.prank(attacker);
        vm.expectRevert(); // AccessControl: missing PAUSER_ROLE
        factory.pauseMarket(market);
    }

    function test_pauseMarket_reverts_notDeployedMarket() public {
        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__NotDeployedMarket.selector,
                attacker
            )
        );
        factory.pauseMarket(attacker);
    }

    function test_unpauseMarket_success_emitsEvent() public {
        address market = _freshMarket("unpause_event");

        vm.prank(pauser);
        factory.pauseMarket(market);

        vm.expectEmit(true, false, false, false, address(factory));
        emit BlieverMarketFactory.MarketUnpausedByFactory(market);

        vm.prank(pauser);
        factory.unpauseMarket(market);
    }

    function test_unpauseMarket_cloneIsNotPaused() public {
        address market = _freshMarket("unpause_state");

        vm.prank(pauser);
        factory.pauseMarket(market);
        assertTrue(BlieverMarket(market).paused());

        vm.prank(pauser);
        factory.unpauseMarket(market);
        assertFalse(BlieverMarket(market).paused(), "clone must be unpaused");
    }

    function test_unpauseMarket_reverts_notPauser() public {
        address market = _freshMarket("unpause_acl");

        vm.prank(pauser);
        factory.pauseMarket(market);

        vm.prank(attacker);
        vm.expectRevert();
        factory.unpauseMarket(market);
    }

    function test_unpauseMarket_reverts_notDeployedMarket() public {
        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__NotDeployedMarket.selector,
                attacker
            )
        );
        factory.unpauseMarket(attacker);
    }

    /*//////////////////////////////////////////////////////////////
                       deregisterMarket
    //////////////////////////////////////////////////////////////*/

    function test_deregisterMarket_success_emitsEvent() public {
        address market = _freshMarket("dereg_event");

        vm.expectEmit(true, false, false, false, address(factory));
        emit BlieverMarketFactory.MarketDeregisteredByFactory(market);

        vm.prank(admin);
        factory.deregisterMarket(market);
    }

    function test_deregisterMarket_callsPoolDeregister() public {
        address market = _freshMarket("dereg_pool");

        vm.prank(admin);
        factory.deregisterMarket(market);

        assertEq(mockPool.deregisterCalls(), 1, "pool.deregisterMarket must be called once");
        assertEq(
            mockPool.lastDeregisteredMarket(),
            market,
            "pool.deregisterMarket must receive clone address"
        );
    }

    function test_deregisterMarket_reverts_notAdmin() public {
        address market = _freshMarket("dereg_acl");

        // operator has OPERATOR_ROLE but NOT DEFAULT_ADMIN_ROLE
        vm.prank(operator);
        vm.expectRevert();
        factory.deregisterMarket(market);
    }

    function test_deregisterMarket_reverts_notPauser() public {
        address market = _freshMarket("dereg_pauser_acl");

        vm.prank(pauser);
        vm.expectRevert();
        factory.deregisterMarket(market);
    }

    function test_deregisterMarket_reverts_notDeployedMarket() public {
        address stranger = makeAddr("stranger_market");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__NotDeployedMarket.selector,
                stranger
            )
        );
        factory.deregisterMarket(stranger);
    }

    /*//////////////////////////////////////////////////////////////
                       FACTORY-LEVEL PAUSE / UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_factoryPause_blocksDeployMarket() public {
        vm.prank(pauser);
        factory.pause();
        assertTrue(factory.paused());

        vm.prank(operator);
        vm.expectRevert(); // EnforcedPause
        factory.deployMarket(_buildParams(2, _qId("fp_blocked")));
    }

    function test_factoryUnpause_allowsDeployMarket() public {
        vm.prank(pauser);
        factory.pause();

        vm.prank(pauser);
        factory.unpause();
        assertFalse(factory.paused());

        // deployMarket must succeed after unpause
        address market = _deployMarket(2, _qId("fp_unblocked"));
        assertTrue(factory.isDeployedMarket(market));
    }

    function test_factoryPause_reverts_notPauser() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.pause();
    }

    function test_factoryUnpause_reverts_notPauser() public {
        vm.prank(pauser);
        factory.pause();

        vm.prank(attacker);
        vm.expectRevert();
        factory.unpause();
    }

    /// @dev Factory-level pause must NOT affect lifecycle operations (expireUnresolved,
    ///      pauseMarket, etc.) — only deployMarket is whenNotPaused guarded.
    function test_factoryPause_doesNotBlockExpireUnresolved() public {
        address market = _freshMarket("fp_no_block_expire");

        // Pause factory
        vm.prank(pauser);
        factory.pause();

        // Warp past resolution deadline
        vm.warp(block.timestamp + T_RESOLUTION + 1);

        // expireUnresolved is NOT whenNotPaused guarded — must succeed
        factory.expireUnresolved(market);
        assertTrue(IDeployableMarket(market).resolved());
    }

    function test_factoryPause_doesNotBlockPauseMarket() public {
        address market = _freshMarket("fp_no_block_pause");

        vm.prank(pauser);
        factory.pause();

        // pauseMarket is NOT whenNotPaused guarded
        vm.prank(pauser);
        factory.pauseMarket(market);   // must succeed

        assertTrue(BlieverMarket(market).paused());
    }

    function test_factoryPause_doesNotBlockDeregisterMarket() public {
        address market = _freshMarket("fp_no_block_dereg");

        vm.prank(pauser);
        factory.pause();

        // deregisterMarket is NOT whenNotPaused guarded
        vm.prank(admin);
        factory.deregisterMarket(market);  // must succeed

        assertEq(mockPool.deregisterCalls(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                    _assertDeployedMarket — GUARD COVERAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev A market cloned directly (bypassing the factory) is not registered
    ///      in isDeployedMarket and must be rejected by all lifecycle functions.
    function test_assertDeployedMarket_rejectsExternalClone() public {
        // Deploy a raw clone that was NOT created by the factory
        address externalClone = Clones.clone(address(impl));

        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__NotDeployedMarket.selector,
                externalClone
            )
        );
        vm.prank(pauser);
        factory.pauseMarket(externalClone);
    }
}
