// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2}   from "forge-std/Test.sol";
import {Clones}           from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20}           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20}            from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {BlieverMarket}        from "../../src/BlieverMarket.sol";
import {BlieverMarketFactory, DeployParams} from "../../src/BlieverMarketFactory.sol";
import {IBlieverV1Pool}       from "../../src/interfaces/IBlieverV1Pool.sol";
import {IDeployableMarket}    from "../../src/interfaces/IDeployableMarket.sol";

/*//////////////////////////////////////////////////////////////
                   MOCK: FACTORY-COMPATIBLE POOL
//////////////////////////////////////////////////////////////*/

/// @dev IBlieverV1Pool mock designed for factory tests.
///      Provides configurable alpha/maxRiskPerMarket and spy counters
///      for registerMarket / deregisterMarket / settleMarket.
///      No role access control — factory tests do not test pool internals.
contract MockFactoryPool is IBlieverV1Pool {

    // ── Configurable pool parameters ────────────────────────────────────────
    uint256 public poolAlpha   = 3e16;   // 3 %  (18-dec fixed-point)
    uint256 public poolMaxRisk = 500e6;  // 500 USDC (6-dec)
    address public poolAsset;

    // ── registerMarket spy ───────────────────────────────────────────────────
    uint256 public registerCalls;
    address public lastRegisteredMarket;
    uint32  public lastRegisteredOutcomes;

    // ── deregisterMarket spy ─────────────────────────────────────────────────
    uint256 public deregisterCalls;
    address public lastDeregisteredMarket;

    // ── settleMarket spy ─────────────────────────────────────────────────────
    uint256 public settleCalls;
    uint256 public lastSettledPayout;

    // ── Fault-injection flag ─────────────────────────────────────────────────
    /// @dev When true, registerMarket() reverts — used for negative-path tests.
    bool public revertOnRegister;

    constructor(address _asset) {
        poolAsset = _asset;
    }

    // ── IBlieverV1Pool ───────────────────────────────────────────────────────

    function asset() external view override returns (address) { return poolAsset; }

    function alpha() external view override returns (uint256) { return poolAlpha; }

    function maxRiskPerMarket() external view override returns (uint256) { return poolMaxRisk; }

    function registerMarket(address market, uint32 nOutcomes) external override {
        if (revertOnRegister) revert("MockPool: registerMarket forced revert");
        registerCalls++;
        lastRegisteredMarket   = market;
        lastRegisteredOutcomes = nOutcomes;
    }

    function deregisterMarket(address market) external override {
        deregisterCalls++;
        lastDeregisteredMarket = market;
    }

    function collectTradeCost(address, uint256, uint256) external override {}

    function distributeRefund(address, uint256, uint256) external override {}

    function settleMarket(uint256 totalPayout) external override {
        settleCalls++;
        lastSettledPayout = totalPayout;
    }

    function claimWinnings(address, uint256) external override {}

    // ── Test utilities ───────────────────────────────────────────────────────

    function setAlpha(uint256 _a) external { poolAlpha = _a; }
    function setMaxRisk(uint256 _r) external { poolMaxRisk = _r; }
    function setRevertOnRegister(bool _flag) external { revertOnRegister = _flag; }
}

/*//////////////////////////////////////////////////////////////
                   MOCK: UMA ADAPTER
//////////////////////////////////////////////////////////////*/

/// @dev Spy that satisfies the factory's single call into the adapter:
///      adapter.initializeQuestion(...).  No oracle logic — keeps factory
///      tests decoupled from UMA mechanics.
contract MockUmaAdapter {
    uint256 public initCalls;
    bytes32 public lastQuestionId;
    address public lastMarket;
    bytes   public lastAncillaryData;
    address public lastRewardToken;
    uint256 public lastReward;
    uint256 public lastBond;
    uint256 public lastLiveness;

    function initializeQuestion(
        bytes32 questionId,
        address market,
        bytes calldata ancillaryData,
        address rewardToken,
        uint256 reward,
        uint256 bond,
        uint256 liveness
    ) external {
        initCalls++;
        lastQuestionId    = questionId;
        lastMarket        = market;
        lastAncillaryData = ancillaryData;
        lastRewardToken   = rewardToken;
        lastReward        = reward;
        lastBond          = bond;
        lastLiveness      = liveness;
    }
}

/*//////////////////////////////////////////////////////////////
                   MOCK: REWARD TOKEN (18-dec ERC-20)
//////////////////////////////////////////////////////////////*/

/// @dev Standard OZ ERC-20 extended with a free mint function.
///      Used to test OO reward-token pull logic in deployMarket.
contract MockRewardToken is ERC20 {
    constructor() ERC20("Mock Reward", "RWRD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/*//////////////////////////////////////////////////////////////
                   MOCK: USDC (6-dec, approval-aware)
//////////////////////////////////////////////////////////////*/

/// @dev Minimal 6-decimal ERC-20 matching real USDC surface needed by factory.
///      Kept identical to BlieverMarketBase.t.sol to avoid contract duplication.
contract MockUSDC {
    string  public name     = "Mock USD Coin";
    string  public symbol   = "USDC";
    uint8   public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount; totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "USDC: insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount,             "USDC: insufficient");
        require(allowance[from][msg.sender] >= amount, "USDC: allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
                    ABSTRACT FACTORY TEST BASE
//////////////////////////////////////////////////////////////*/

/// @notice Shared infrastructure for all BlieverMarketFactory test contracts.
///
///         What is set up in setUp():
///           • MockUSDC — 6-dec stablecoin (pool.asset)
///           • MockFactoryPool — alpha=3e16, maxRisk=500e6; registerMarket / deregisterMarket spies
///           • MockUmaAdapter — initializeQuestion spy
///           • MockRewardToken — ERC-20 for OO reward tests
///           • BlieverMarket (impl) — master implementation (initializers disabled)
///           • BlieverMarketFactory — deployed with admin receiving all three roles
///           • Separate operator + pauser addresses granted their respective roles
///
///         Helper contracts follow the "operator calls deployMarket" pattern used
///         in production.  All deployed clones have:
///             tradingDeadline    = block.timestamp + T_TRADING    (7 days)
///             resolutionDeadline = block.timestamp + T_RESOLUTION (30 days)
abstract contract FactoryTestBase is Test {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant ALPHA         = 3e16;   // 3 % liquidity parameter (18-dec)
    uint256 internal constant MAX_RISK_USDC = 500e6;  // 500 USDC per market (6-dec)

    uint40  internal constant T_TRADING    = 7 days;   // tradingDeadline offset
    uint40  internal constant T_RESOLUTION = 30 days;  // resolutionDeadline offset

    /// @dev Non-empty ancillary data used in all happy-path deployments.
    bytes internal constant ANCILLARY_DATA =
        bytes('{"title":"Will X happen?","res_data":"p1:0,p2:1,p3:0.5"}');

    /*//////////////////////////////////////////////////////////////
                              STATE
    //////////////////////////////////////////////////////////////*/

    MockUSDC            internal usdc;
    MockFactoryPool     internal mockPool;
    MockUmaAdapter      internal mockAdapter;
    MockRewardToken     internal rewardToken;

    BlieverMarket           internal impl;     // master implementation (disabled)
    BlieverMarketFactory    internal factory;

    // ── Named actors ──────────────────────────────────────────────────────
    address internal admin    = makeAddr("admin");    // DEFAULT_ADMIN_ROLE at construction
    address internal operator = makeAddr("operator"); // OPERATOR_ROLE (deployMarket)
    address internal pauser   = makeAddr("pauser");   // PAUSER_ROLE (pause / unpause)
    address internal attacker = makeAddr("attacker"); // unauthorised caller
    address internal anyone   = makeAddr("anyone");   // permissionless caller

    /*//////////////////////////////////////////////////////////////
                              SET UP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        // ── Deploy supporting mocks ───────────────────────────────────────
        usdc        = new MockUSDC();
        mockPool    = new MockFactoryPool(address(usdc));
        mockAdapter = new MockUmaAdapter();
        rewardToken = new MockRewardToken();

        // ── Deploy BlieverMarket master implementation ─────────────────────
        // Constructor disables initializers, so the impl itself is unusable.
        impl = new BlieverMarket();

        // ── Deploy BlieverMarketFactory ────────────────────────────────────
        // admin receives DEFAULT_ADMIN_ROLE, OPERATOR_ROLE, PAUSER_ROLE in constructor.
        factory = new BlieverMarketFactory(
            address(impl),
            address(mockPool),
            address(mockAdapter),
            admin
        );

        // ── Distribute roles so role-boundary tests use dedicated addresses ──
        // Production pattern: admin grants OPERATOR / PAUSER to separate multisigs.
        vm.startPrank(admin);
        factory.grantRole(factory.OPERATOR_ROLE(), operator);
        factory.grantRole(factory.PAUSER_ROLE(),   pauser);
        vm.stopPrank();

        // ── Labels ────────────────────────────────────────────────────────
        vm.label(address(usdc),        "MockUSDC");
        vm.label(address(mockPool),    "MockFactoryPool");
        vm.label(address(mockAdapter), "MockUmaAdapter");
        vm.label(address(rewardToken), "MockRewardToken");
        vm.label(address(impl),        "BlieverMarket_IMPL");
        vm.label(address(factory),     "BlieverMarketFactory");
        vm.label(admin,    "admin");
        vm.label(operator, "operator");
        vm.label(pauser,   "pauser");
        vm.label(attacker, "attacker");
        vm.label(anyone,   "anyone");
    }

    /*//////////////////////////////////////////////////////////////
                            PARAM HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Build valid DeployParams for `nOutcomes` with zero reward.
    ///      questionId must be unique per test to avoid QuestionAlreadyDeployed.
    function _buildParams(
        uint8   nOutcomes,
        bytes32 questionId
    ) internal view returns (DeployParams memory p) {
        p = DeployParams({
            questionId         : questionId,
            ancillaryData      : ANCILLARY_DATA,
            nOutcomes          : nOutcomes,
            tradingDeadline    : uint40(block.timestamp) + T_TRADING,
            resolutionDeadline : uint40(block.timestamp) + T_RESOLUTION,
            rewardToken        : address(0),
            reward             : 0,
            bond               : 0,
            liveness           : 7_200   // 2-hour OO liveness
        });
    }

    /// @dev Build valid DeployParams with a non-zero reward token.
    function _buildParamsWithReward(
        uint8   nOutcomes,
        bytes32 questionId,
        uint256 reward
    ) internal view returns (DeployParams memory p) {
        p = _buildParams(nOutcomes, questionId);
        p.rewardToken = address(rewardToken);
        p.reward      = reward;
    }

    /*//////////////////////////////////////////////////////////////
                            ACTION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploy a market as operator and return the clone address.
    function _deployMarket(
        uint8   nOutcomes,
        bytes32 questionId
    ) internal returns (address market) {
        vm.prank(operator);
        market = factory.deployMarket(_buildParams(nOutcomes, questionId));
    }

    /// @dev Resolve a factory-deployed market (prank as mockAdapter = resolver).
    ///      Must be called BEFORE resolutionDeadline.
    function _resolveMarket(address market, uint8 winner) internal {
        vm.prank(address(mockAdapter));
        BlieverMarket(market).resolve(winner);
    }

    /// @dev Deterministic bytes32 questionId from a human-readable label.
    function _qId(string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encode(label));
    }
}
