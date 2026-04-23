// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test, console2}   from "forge-std/Test.sol";
import {Clones}            from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20}            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20}             from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit}       from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {BlieverMarket}    from "../../src/BlieverMarket.sol";
import {IBlieverV1Pool}   from "../../src/interfaces/IBlieverV1Pool.sol";

/*//////////////////////////////////////////////////////////////
                          MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 with 6-decimal (USDC-like) for test use.
///      Does NOT implement EIP-2612 permit; tests that skip permit
///      pass v = 0, which the market handles gracefully.
///      For permit-path tests use MockUSDCPermit below.
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
        balanceOf[to] += amount;
        totalSupply   += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "USDC: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from]             >= amount, "USDC: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "USDC: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @dev ERC-20 with EIP-2612 Permit support (6-decimal, USDC-like).
///      Used for permit tests where v != 0 signatures are required.
///      Extends OZ ERC20Permit so nonces, DOMAIN_SEPARATOR, and permit()
///      are all spec-compliant and usable with vm.sign() in Foundry tests.
contract MockUSDCPermit is ERC20Permit {
    constructor() ERC20("Mock USD Coin", "USDC") ERC20Permit("Mock USD Coin") {}

    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal interface for minting test tokens.
///      Satisfied by both MockUSDC and MockUSDCPermit.
interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @dev Thin spy/stub implementing IBlieverV1Pool.
///      Accepts any ERC-20 address so the same mock works with both
///      MockUSDC (standard tests) and MockUSDCPermit (permit tests).
///      Executes real USDC transfers so that the market's token-flow
///      assertions hold end-to-end, while remaining independent of the
///      full BlieverV1Pool state machine.
contract MockPool is IBlieverV1Pool {
    address public immutable token;  // underlying USDC-compatible token

    // ── Call counters for spy assertions ──────────────────────────────────
    uint256 public collectCalls;
    uint256 public refundCalls;
    uint256 public settleCalls;
    uint256 public claimCalls;

    // ── Last-call arguments (convenient for single-call assertions) ────────
    address public lastTrader;
    uint256 public lastCost;
    uint256 public lastRefund;
    uint256 public lastLiability;
    uint256 public lastSettledPayout;
    address public lastWinner;
    uint256 public lastClaimAmount;

    constructor(address _token) {
        token = _token;
    }

    // ── IBlieverV1Pool ─────────────────────────────────────────────────────

    function asset() external view override returns (address) {
        return token;
    }

    /// @dev Pulls cost token from trader (trader must pre-approve MockPool).
    function collectTradeCost(address trader, uint256 cost, uint256 newLiability) external override {
        collectCalls++;
        lastTrader    = trader;
        lastCost      = cost;
        lastLiability = newLiability;
        if (cost > 0) {
            IERC20(token).transferFrom(trader, address(this), cost);
        }
    }

    /// @dev Pushes refund from pool to trader.
    function distributeRefund(address trader, uint256 refundAmount, uint256 newLiability) external override {
        refundCalls++;
        lastTrader    = trader;
        lastRefund    = refundAmount;
        lastLiability = newLiability;
        if (refundAmount > 0) {
            IERC20(token).transfer(trader, refundAmount);
        }
    }

    /// @dev Records the settled payout; no token movement.
    function settleMarket(uint256 totalPayout) external override {
        settleCalls++;
        lastSettledPayout = totalPayout;
    }

    /// @dev Pushes payout from pool to winner.
    function claimWinnings(address winner, uint256 amount) external override {
        claimCalls++;
        lastWinner      = winner;
        lastClaimAmount = amount;
        if (amount > 0) {
            IERC20(token).transfer(winner, amount);
        }
    }

    // ── Test utility ───────────────────────────────────────────────────────

    /// @dev Inject tokens into the pool so refunds and claims can execute.
    ///      Works for both MockUSDC and MockUSDCPermit (both satisfy IMintable).
    function seed(uint256 amount) external {
        IMintable(token).mint(address(this), amount);
    }

    /// @dev Reset all counters between tests that reuse a single market.
    function resetCounters() external {
        collectCalls = 0;
        refundCalls  = 0;
        settleCalls  = 0;
        claimCalls   = 0;
    }

    function alpha() external pure override returns (uint256) {
        return 3e16; // 3 % — matches BlieverMarketBase ALPHA constant
    }

    function maxRiskPerMarket() external pure override returns (uint256) {
        return 500e6; // 500 USDC — matches BlieverMarketBase MAX_RISK_USDC constant
    }

    function registerMarket(address, uint32) external override {
        // no-op: BlieverMarket never calls this; only the factory does
    }

    function deregisterMarket(address) external override {
        // no-op: BlieverMarket never calls this; only the factory does
    }

}

/*//////////////////////////////////////////////////////////////
                       ABSTRACT BASE TEST
//////////////////////////////////////////////////////////////*/

/// @notice Shared infrastructure for all BlieverMarket test contracts.
///
///         Two live markets are deployed in setUp:
///           • market2 — 2-outcome binary market (canonical prediction market)
///           • market7 — 7-outcome multi-outcome market (CSS stress)
///
///         Epsilon values are pre-computed from the formula:
///           ε = R / (1 + α · n · ln n)
///           where R = maxRiskPerMarket · SHARE_TO_USDC = 500 USDC · 1e12 = 500e18
///
///         NOTE: This base is abstract — Foundry will not collect it as a test suite.
abstract contract BlieverMarketBase is Test {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // ── LS-LMSR parameters ────────────────────────────────────────────────
    uint256 internal constant ALPHA         = 3e16;   // 3 % commission
    uint256 internal constant MAX_RISK_USDC = 500e6;  // 500 USDC (6-dec)

    // ── Epsilon: ε = R / (1 + α·n·ln n), R = 500e18 ──────────────────────
    // n=2: 500e18 / (1 + 0.03·2·ln2) ≈ 500e18 / 1.04159 ≈ 480e18
    uint256 internal constant EPSILON_2 = 480e18;
    // n=7: 500e18 / (1 + 0.03·7·ln7) ≈ 500e18 / 1.40864 ≈ 355e18
    uint256 internal constant EPSILON_7 = 355e18;

    // ── Trade sizes ───────────────────────────────────────────────────────
    uint256 internal constant SHARE_1    = 1e18;   // 1 share (18-dec)
    uint256 internal constant SHARE_10   = 10e18;  // 10 shares
    uint256 internal constant DUST_SHARE = 1e11;   // below MIN_SHARE_AMOUNT (1e15)
    uint256 internal constant MIN_SHARE  = 1e15;   // BlieverMarket.MIN_SHARE_AMOUNT

    // ── USDC amounts ──────────────────────────────────────────────────────
    uint256 internal constant TRADER_USDC  = 1_000e6;    // 1 000 USDC per trader
    uint256 internal constant POOL_SEED    = 100_000e6;  // 100 k USDC in pool
    uint256 internal constant MAX_COST     = 50e6;       // 50 USDC slippage cap

    // ── Timestamps ───────────────────────────────────────────────────────
    uint40  internal constant T_TRADING    = 7 days;     // offset from deployment
    uint40  internal constant T_RESOLUTION = 30 days;    // offset from deployment

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    MockUSDC    internal usdc;
    MockPool    internal pool;
    BlieverMarket internal impl;   // master implementation (initializers disabled)
    BlieverMarket internal market2; // 2-outcome clone
    BlieverMarket internal market7; // 7-outcome clone

    // ── Named actors ──────────────────────────────────────────────────────
    address internal factory  = makeAddr("factory");
    address internal resolver = makeAddr("resolver");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal carol    = makeAddr("carol");
    address internal attacker = makeAddr("attacker");

    // ── Deployment timestamp baseline ─────────────────────────────────────
    uint40  internal deployTs;

    // ── Permit-capable infrastructure ─────────────────────────────────────
    /// @dev Private key for aliceP, required for EIP-712 permit signing.
    ///      Must be a small constant so vm.addr() deterministically gives aliceP.
    uint256 internal constant ALICE_PK = 0xA11CE;

    MockUSDCPermit  internal permitUsdc;  // EIP-2612 capable token
    MockPool        internal permitPool;  // pool backed by permitUsdc
    BlieverMarket   internal market2p;   // 2-outcome clone backed by permitPool
    address         internal aliceP;     // vm.addr(ALICE_PK) — permit signer

    /*//////////////////////////////////////////////////////////////
                               SET UP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        deployTs = uint40(block.timestamp);

        // ── Mocks ──────────────────────────────────────────────────────────
        usdc = new MockUSDC();
        pool = new MockPool(address(usdc));
        pool.seed(POOL_SEED); // pre-fund pool for refunds / claims

        // ── Master implementation (initializers permanently disabled) ──────
        impl = new BlieverMarket();
        vm.label(address(impl),    "BlieverMarket_IMPL");

        // ── 2-outcome market ───────────────────────────────────────────────
        market2 = BlieverMarket(Clones.clone(address(impl)));
        vm.label(address(market2), "Market_2outcome");
        market2.initialize(
            address(pool),
            keccak256("q2"),
            2,                                    // outcomeCount
            ALPHA,
            deployTs + T_TRADING,
            deployTs + T_RESOLUTION,
            EPSILON_2,
            resolver,
            factory
        );

        // ── 7-outcome market ───────────────────────────────────────────────
        market7 = BlieverMarket(Clones.clone(address(impl)));
        vm.label(address(market7), "Market_7outcome");
        market7.initialize(
            address(pool),
            keccak256("q7"),
            7,
            ALPHA,
            deployTs + T_TRADING,
            deployTs + T_RESOLUTION,
            EPSILON_7,
            resolver,
            factory
        );

        // ── Permit-capable market (MockUSDCPermit + separate pool) ─────────
        // Provides a real EIP-2612 token for permit happy-path and revert tests.
        aliceP = vm.addr(ALICE_PK);
        vm.label(aliceP, "alicePermit");

        permitUsdc = new MockUSDCPermit();
        permitPool = new MockPool(address(permitUsdc));
        permitPool.seed(POOL_SEED);

        market2p = BlieverMarket(Clones.clone(address(impl)));
        vm.label(address(market2p), "Market_2outcome_Permit");
        market2p.initialize(
            address(permitPool),
            keccak256("q2p"),
            2,
            ALPHA,
            deployTs + T_TRADING,
            deployTs + T_RESOLUTION,
            EPSILON_2,
            resolver,
            factory
        );

        vm.label(address(permitUsdc), "MockUSDCPermit");
        vm.label(address(permitPool), "MockPoolPermit");

        // ── Label actors ───────────────────────────────────────────────────
        vm.label(address(usdc),    "MockUSDC");
        vm.label(address(pool),    "MockPool");
        vm.label(factory,          "factory");
        vm.label(resolver,         "resolver");
        vm.label(alice,            "alice");
        vm.label(bob,              "bob");
        vm.label(carol,            "carol");
        vm.label(attacker,         "attacker");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Give a trader USDC and approve the pool (mirrors real UX flow).
    function _setupTrader(address trader, uint256 usdcAmount) internal {
        usdc.mint(trader, usdcAmount);
        vm.prank(trader);
        usdc.approve(address(pool), type(uint256).max);
    }

    /// @dev Execute a buy on a market with sensible defaults (v=0 → no permit).
    ///      Returns the actual USDC cost paid.
    function _buy(
        BlieverMarket market,
        address trader,
        uint256 outcomeIdx,
        uint256 shareAmt
    ) internal returns (uint256 costUsdc) {
        // Quote first so we can set a tight but valid maxCostUsdc.
        costUsdc = market.getBuyCost(outcomeIdx, shareAmt);
        uint256 cap = costUsdc == 0 ? 1 : costUsdc * 2; // 2× buffer for slippage

        _setupTrader(trader, cap + 1e6); // ensure trader has enough

        vm.prank(trader);
        market.buy(outcomeIdx, shareAmt, cap, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev Execute a standard (refund-path) sell. Returns refundUsdc.
    function _sell(
        BlieverMarket market,
        address trader,
        uint256 outcomeIdx,
        uint256 shareAmt
    ) internal returns (uint256 refundUsdc) {
        (refundUsdc, ) = market.getSellEstimate(trader, outcomeIdx, shareAmt);
        vm.prank(trader);
        market.sell(outcomeIdx, shareAmt, 0, MAX_COST, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev Resolve a market to a specific winning outcome.
    function _resolve(BlieverMarket market, uint8 winner) internal {
        vm.prank(resolver);
        market.resolve(winner);
    }

    /// @dev Fresh clone from the shared implementation — useful for isolated tests.
    function _newClone(
        uint8  nOutcomes,
        uint256 epsilon,
        bytes32 qId
    ) internal returns (BlieverMarket m) {
        m = BlieverMarket(Clones.clone(address(impl)));
        m.initialize(
            address(pool),
            qId,
            nOutcomes,
            ALPHA,
            uint40(block.timestamp) + T_TRADING,
            uint40(block.timestamp) + T_RESOLUTION,
            epsilon,
            resolver,
            factory
        );
    }

    /// @dev Compute the EIP-1967 Pausable namespaced storage slot.
    ///      Only used for low-level storage inspection in admin tests.
    function _sharesSlot(address trader, uint256 outcomeIdx) internal pure returns (bytes32) {
        // _shares is at sequential mapping slot 9 in BlieverMarket
        bytes32 outer = keccak256(abi.encode(trader, uint256(9)));
        return keccak256(abi.encode(outcomeIdx, outer));
    }

    function _claimedSlot(address trader) internal pure returns (bytes32) {
        // _claimed is at sequential mapping slot 11
        return keccak256(abi.encode(trader, uint256(11)));
    }

    /// @dev Generate an EIP-2612 permit signature for `permitUsdc` using Foundry's vm.sign.
    ///      Computes the EIP-712 digest from the token's current nonce and domain separator,
    ///      then signs with the provided private key.
    ///
    /// @param owner     Address whose allowance is being authorised (must match ownerPk)
    /// @param ownerPk   Corresponding ECDSA private key (must be known in test context)
    /// @param spender   Address approved to spend owner's tokens
    /// @param value     USDC amount to approve (6-dec)
    /// @param deadline  Unix timestamp after which the permit is invalid
    /// @return v  ECDSA signature component v
    /// @return r  ECDSA signature component r
    /// @return s  ECDSA signature component s
    function _permitSignature(
        address owner,
        uint256 ownerPk,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 permitTypeHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(
            permitTypeHash,
            owner,
            spender,
            value,
            permitUsdc.nonces(owner),
            deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            permitUsdc.DOMAIN_SEPARATOR(),
            structHash
        ));
        (v, r, s) = vm.sign(ownerPk, digest);
    }
}
