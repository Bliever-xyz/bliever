// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import "./BlieverMarketFactoryBase.t.sol";

/// @title  BlieverMarketFactory — Constructor Tests
/// @notice Validates that the factory constructor:
///           • Stores all three immutables correctly
///           • Grants DEFAULT_ADMIN_ROLE, OPERATOR_ROLE, and PAUSER_ROLE to admin
///           • Reverts on zero-address for any of the four constructor parameters
///           • Reverts when implementation is an EOA (no code)
///           • Leaves marketCount == 0 and paused == false on fresh deployment
contract BlieverMarketFactory_Constructor is FactoryTestBase {

    /*//////////////////////////////////////////////////////////////
                         IMMUTABLES & INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function test_constructor_implementation_isSet() public view {
        assertEq(
            factory.implementation(),
            address(impl),
            "implementation immutable mismatch"
        );
    }

    function test_constructor_pool_isSet() public view {
        assertEq(
            address(factory.pool()),
            address(mockPool),
            "pool immutable mismatch"
        );
    }

    function test_constructor_adapter_isSet() public view {
        assertEq(
            address(factory.adapter()),
            address(mockAdapter),
            "adapter immutable mismatch"
        );
    }

    function test_constructor_marketCount_isZero() public view {
        assertEq(factory.marketCount(), 0, "marketCount should start at 0");
    }

    function test_constructor_paused_isFalse() public view {
        assertFalse(factory.paused(), "factory should not be paused at construction");
    }

    /*//////////////////////////////////////////////////////////////
                              ROLE GRANTS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_admin_hasDefaultAdminRole() public view {
        assertTrue(
            factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin),
            "admin must hold DEFAULT_ADMIN_ROLE"
        );
    }

    function test_constructor_admin_hasOperatorRole() public view {
        assertTrue(
            factory.hasRole(factory.OPERATOR_ROLE(), admin),
            "admin must hold OPERATOR_ROLE"
        );
    }

    function test_constructor_admin_hasPauserRole() public view {
        assertTrue(
            factory.hasRole(factory.PAUSER_ROLE(), admin),
            "admin must hold PAUSER_ROLE"
        );
    }

    function test_constructor_strangerHasNoRoles() public view {
        assertFalse(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), attacker));
        assertFalse(factory.hasRole(factory.OPERATOR_ROLE(),      attacker));
        assertFalse(factory.hasRole(factory.PAUSER_ROLE(),        attacker));
    }

    /*//////////////////////////////////////////////////////////////
                        ZERO-ADDRESS REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_reverts_zeroImplementation() public {
        vm.expectRevert(BlieverMarketFactory.BlieverMarketFactory__ZeroAddress.selector);
        new BlieverMarketFactory(
            address(0),
            address(mockPool),
            address(mockAdapter),
            admin
        );
    }

    function test_constructor_reverts_zeroPool() public {
        vm.expectRevert(BlieverMarketFactory.BlieverMarketFactory__ZeroAddress.selector);
        new BlieverMarketFactory(
            address(impl),
            address(0),
            address(mockAdapter),
            admin
        );
    }

    function test_constructor_reverts_zeroAdapter() public {
        vm.expectRevert(BlieverMarketFactory.BlieverMarketFactory__ZeroAddress.selector);
        new BlieverMarketFactory(
            address(impl),
            address(mockPool),
            address(0),
            admin
        );
    }

    function test_constructor_reverts_zeroAdmin() public {
        vm.expectRevert(BlieverMarketFactory.BlieverMarketFactory__ZeroAddress.selector);
        new BlieverMarketFactory(
            address(impl),
            address(mockPool),
            address(mockAdapter),
            address(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                   IMPLEMENTATION MUST HAVE CODE
    //////////////////////////////////////////////////////////////*/

    function test_constructor_reverts_implementationIsEOA() public {
        address eoa = makeAddr("eoa_not_a_contract");
        // eoa has zero code length — must trigger NotAContract
        vm.expectRevert(
            abi.encodeWithSelector(
                BlieverMarketFactory.BlieverMarketFactory__NotAContract.selector,
                eoa
            )
        );
        new BlieverMarketFactory(
            eoa,
            address(mockPool),
            address(mockAdapter),
            admin
        );
    }

    /// @dev Passing a mock pool address (which IS a contract) as the implementation
    ///      succeeds the code-length check — verifies the guard is specifically
    ///      about bytecode existence, not contract type validation.
    function test_constructor_acceptsAnyContractAsImpl() public {
        // Any address with code must NOT trigger NotAContract
        BlieverMarketFactory f = new BlieverMarketFactory(
            address(mockPool),   // has code ✓, wrong type but guard doesn't check that
            address(mockPool),
            address(mockAdapter),
            admin
        );
        assertEq(f.implementation(), address(mockPool));
    }

    /*//////////////////////////////////////////////////////////////
                      CONSTANTS SANITY CHECK
    //////////////////////////////////////////////////////////////*/

    function test_constants_MIN_OUTCOMES() public view {
        assertEq(factory.MIN_OUTCOMES(), 2);
    }

    function test_constants_MAX_OUTCOMES() public view {
        assertEq(factory.MAX_OUTCOMES(), 7);
    }

    function test_constants_OPERATOR_ROLE_selector() public view {
        assertEq(factory.OPERATOR_ROLE(), keccak256("OPERATOR_ROLE"));
    }

    function test_constants_PAUSER_ROLE_selector() public view {
        assertEq(factory.PAUSER_ROLE(), keccak256("PAUSER_ROLE"));
    }
}
