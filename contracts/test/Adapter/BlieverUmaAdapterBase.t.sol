// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2}     from "forge-std/Test.sol";
import {Clones}              from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy}        from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BlieverUmaAdapter}   from "../../src/BlieverUmaAdapter.sol";
import {QuestionData}         from "../../src/interfaces/IBlieverUmaAdapter.sol";
import {AncillaryDataLib}    from "../../src/libraries/AncillaryDataLib.sol";
import {MultiValueDecoder}   from "../../src/libraries/MultiValueDecoder.sol";

import {MockOptimisticOracleV2} from "../mocks/MockOptimisticOracleV2.sol";
import {MockBlieverMarket}      from "../mocks/MockBlieverMarket.sol";
import {MockRewardToken}        from "../mocks/MockRewardToken.sol";

/*//////////////////////////////////////////////////////////////
                  MULTI-VALUE ENCODING HELPERS
//////////////////////////////////////////////////////////////*/

/// @dev Encode a single winning outcome into a UMIP-183 MULTIPLE_VALUES int256.
///      outcome i → slot i bits [i*32, i*32+31] = 1, all others = 0.
library EncodeOutcome {
    function encode(uint8 outcomeIdx) internal pure returns (int256) {
        return int256(uint256(1) << (32 * uint256(outcomeIdx)));
    }
}

/*//////////////////////////////////////////////////////////////
                   ABSTRACT BASE TEST CONTRACT
//////////////////////////////////////////////////////////////*/

/// @title  BlieverUmaAdapterBase
/// @notice Shared infrastructure for all BlieverUmaAdapter test contracts.
///
///         Provides:
///           • One deployed adapter proxy (admin, factory, emergency roles)
///           • One MockOptimisticOracleV2 registered as the oracle
///           • One MockRewardToken for reward flows
///           • Helpers _initQuestion() and _buildQuestionId() to reduce boilerplate
///
/// @dev    Abstract — Foundry does not collect this as a test suite.
abstract contract BlieverUmaAdapterBase is Test {
    using EncodeOutcome for uint8;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DEFAULT_REWARD     = 100e18;
    uint256 internal constant DEFAULT_BOND       = 200e18;
    uint256 internal constant DEFAULT_LIVENESS   = 7200; // 2 hours
    uint8   internal constant OUTCOME_COUNT_2    = 2;
    uint8   internal constant OUTCOME_COUNT_7    = 7;
    uint40  internal constant RESOLUTION_DL      = 30 days;

    // Raw ancillary data for binary & multi-outcome markets
    bytes internal constant ANC_DATA_2 = bytes(
        '{"title":"Will X happen?","description":"Resolution: YES or NO","labels":["YES","NO"]}'
    );
    bytes internal constant ANC_DATA_7 = bytes(
        '{"title":"Who wins?","description":"Outcome labels","labels":["A","B","C","D","E","F","G"]}'
    );

    /*//////////////////////////////////////////////////////////////
                               ROLES
    //////////////////////////////////////////////////////////////*/

    address internal admin     = makeAddr("admin");
    address internal factory   = makeAddr("factory");
    address internal emergency = makeAddr("emergency");
    address internal alice     = makeAddr("alice");
    address internal bob       = makeAddr("bob");
    address internal attacker  = makeAddr("attacker");

    /*//////////////////////////////////////////////////////////////
                         DEPLOYED CONTRACTS
    //////////////////////////////////////////////////////////////*/

    BlieverUmaAdapter       internal adapter;
    MockOptimisticOracleV2  internal mockOO;
    MockRewardToken         internal rewardToken;

    // Two market mocks — binary (2) and multi-outcome (7)
    MockBlieverMarket       internal market2;
    MockBlieverMarket       internal market7;

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        // ── Deploy oracle mock ────────────────────────────────────────────
        mockOO = new MockOptimisticOracleV2();
        vm.label(address(mockOO), "MockOptimisticOracleV2");

        // ── Deploy reward token ───────────────────────────────────────────
        rewardToken = new MockRewardToken();
        vm.label(address(rewardToken), "MockRewardToken");

        // ── Deploy adapter (UUPS proxy) ───────────────────────────────────
        BlieverUmaAdapter impl = new BlieverUmaAdapter();
        bytes memory initData  = abi.encodeCall(
            BlieverUmaAdapter.initialize,
            (address(mockOO), admin, factory, emergency)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        adapter = BlieverUmaAdapter(address(proxy));
        vm.label(address(adapter), "BlieverUmaAdapter");

        // ── Deploy market mocks with placeholder questionIds ──────────────
        // Real questionIds are set in _initQuestion() after computing the hash.
        market2 = new MockBlieverMarket(bytes32(0), OUTCOME_COUNT_2, uint40(block.timestamp) + RESOLUTION_DL);
        market7 = new MockBlieverMarket(bytes32(0), OUTCOME_COUNT_7, uint40(block.timestamp) + RESOLUTION_DL);
        vm.label(address(market2), "MockMarket_2outcome");
        vm.label(address(market7), "MockMarket_7outcome");

        // ── Label roles ───────────────────────────────────────────────────
        vm.label(admin,     "admin");
        vm.label(factory,   "factory");
        vm.label(emergency, "emergency");
        vm.label(alice,     "alice");
        vm.label(bob,       "bob");
        vm.label(attacker,  "attacker");

        // ── Seed factory with reward tokens for initializeQuestion calls ──
        rewardToken.mint(factory, DEFAULT_REWARD * 100);
    }

    /*//////////////////////////////////////////////////////////////
                         SHARED HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Compute the full ancillary data and questionId as initializeQuestion does.
    ///      Caller: factory (msg.sender when factory calls initializeQuestion).
    function _buildQuestionId(bytes memory rawAncData)
        internal
        view
        returns (bytes32 questionId, bytes memory fullAncData)
    {
        fullAncData = AncillaryDataLib._appendAncillaryData(factory, rawAncData);
        questionId  = keccak256(fullAncData);
    }

    /// @dev Initialize a question for `market` via the adapter as `factory`.
    ///      Sets the market's questionId to match, gives factory approval.
    ///      Returns the computed questionId.
    function _initQuestion(
        MockBlieverMarket market,
        bytes memory      rawAncData,
        uint256           reward,
        uint256           bond,
        uint256           liveness
    ) internal returns (bytes32 questionId) {
        bytes memory fullAncData;
        (questionId, fullAncData) = _buildQuestionId(rawAncData);

        // Sync the market mock's questionId to match what the adapter will compute.
        market.setQuestionId(questionId);

        // Approve adapter as spender for the reward token.
        if (reward > 0) {
            vm.prank(factory);
            rewardToken.approve(address(adapter), type(uint256).max);
        }

        vm.prank(factory);
        adapter.initializeQuestion(
            questionId,
            address(market),
            rawAncData,
            address(rewardToken),
            reward,
            bond,
            liveness
        );
    }

    /// @dev Convenience: initializeQuestion with default reward/bond/liveness.
    function _initQuestion(MockBlieverMarket market, bytes memory rawAncData)
        internal
        returns (bytes32 questionId)
    {
        return _initQuestion(market, rawAncData, DEFAULT_REWARD, DEFAULT_BOND, DEFAULT_LIVENESS);
    }

    /// @dev Convenience: initializeQuestion with zero reward.
    function _initQuestionNoReward(MockBlieverMarket market, bytes memory rawAncData)
        internal
        returns (bytes32 questionId)
    {
        return _initQuestion(market, rawAncData, 0, DEFAULT_BOND, DEFAULT_LIVENESS);
    }

    /// @dev Simulate the OO calling priceDisputed on the adapter.
    ///      Uses the current question's ancillaryData from the adapter storage.
    function _simulateDispute(bytes32 questionId) internal {
        QuestionData memory qd = adapter.getQuestion(questionId);
        vm.prank(address(mockOO));
        adapter.priceDisputed(
            adapter.MULTIPLE_VALUES_IDENTIFIER(),
            qd.requestTimestamp,
            qd.ancillaryData,
            0
        );
    }

    /// @dev Flag a question and advance time past the safety period.
    function _flagAndWait(bytes32 questionId) internal {
        vm.prank(emergency);
        adapter.flag(questionId);
        vm.warp(block.timestamp + adapter.SAFETY_PERIOD() + 1);
    }
}
