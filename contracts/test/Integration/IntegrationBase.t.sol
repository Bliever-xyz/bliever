// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/*//////////////////////////////////////////////////////////////
                         FOUNDRY
//////////////////////////////////////////////////////////////*/
import {Test, console2} from "forge-std/Test.sol";

/*//////////////////////////////////////////////////////////////
                       OPENZEPPELIN
//////////////////////////////////////////////////////////////*/
import {Clones}      from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20}       from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/*//////////////////////////////////////////////////////////////
                       PROTOCOL
//////////////////////////////////////////////////////////////*/
import {BlieverV1Pool} from "../../src/BlieverV1Pool.sol";
import {BlieverMarket} from "../../src/BlieverMarket.sol";

/*//////////////////////////////////////////////////////////////
                         MOCK USDC
//////////////////////////////////////////////////////////////*/

/// @notice 6-decimal ERC-20 token that mirrors Base-chain USDC for integration tests.
///         Exposes a permissionless `mint()` so test helpers can fund arbitrary addresses
///         without relying on a forked chain state.
contract IntegrationUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/*//////////////////////////////////////////////////////////////
                       INTEGRATION BASE
//////////////////////////////////////////////////////////////*/

/// @title  IntegrationBase
/// @notice Abstract base inherited by every integration test contract.
///         Deploys the full real protocol stack — no mocks — and exposes
///         helper methods that compose the standard interaction flows
///         (deposit LP → register market → trade → resolve → claim).
///
/// @dev    EVM version: Cancun is required because BlieverMarket uses
///         ReentrancyGuardTransient (EIP-1153 TSTORE/TLOAD).
///         Run all integration tests with:
///           forge test --match-path "test/Integration/**" --evm-version cancun -vvv
abstract contract IntegrationBase is Test {

    /*//////////////////////////////////////////////////////////////
                          TEST ADDRESSES
    //////////////////////////////////////////////////////////////*/

    address internal admin    = makeAddr("admin");
    address internal lp       = makeAddr("lp");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal carol    = makeAddr("carol");
    address internal resolver = makeAddr("resolver");
    // `address(this)` plays the role of the MarketFactory in these tests —
    //  it calls expireUnresolved() / pause() / unpause() on market clones.

    /*//////////////////////////////////////////////////////////////
                       PROTOCOL PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @dev LS-LMSR commission parameter α = 3 % (18-dec fixed-point).
    uint256 internal constant ALPHA       = 3e16;

    /// @dev Maximum vault loss per market = 500 USDC (6-dec).
    uint256 internal constant MAX_RISK    = 500e6;

    /// @dev LP withdrawal reserve buffer: 20 % of total assets.
    uint16  internal constant RESERVE_BPS = 2_000;

    /// @dev Initial seed quantity ε for 2-outcome market (18-dec).
    ///      Satisfies C([ε,ε]) / SHARE_TO_USDC ≈ MAX_RISK.
    uint256 internal constant EPSILON_2   = 480e18;

    /// @dev Initial seed quantity ε for 7-outcome market (18-dec).
    ///      Satisfies C([ε,…,ε]₇) / SHARE_TO_USDC ≈ MAX_RISK.
    uint256 internal constant EPSILON_7   = 355e18;

    /// @dev USDC seeded into the pool by the LP in setUp().
    uint256 internal constant LP_DEPOSIT  = 50_000e6;

    /// @dev USDC minted to each trader in _setupTrader().
    uint256 internal constant TRADER_USDC = 2_000e6;

    /// @dev BlieverMarket.MIN_SHARE_AMOUNT (dust guard, 18-dec).
    uint256 internal constant MIN_SHARE   = 1e15;

    /// @dev SHARE_TO_USDC conversion constant (1e18 shares → 1e6 USDC).
    uint256 internal constant SHARE_TO_USDC = 1e12;

    /*//////////////////////////////////////////////////////////////
                       TIME PARAMETERS
    //////////////////////////////////////////////////////////////*/

    uint40 internal tradingDeadline;
    uint40 internal resolutionDeadline;

    /*//////////////////////////////////////////////////////////////
                       DEPLOYED CONTRACTS
    //////////////////////////////////////////////////////////////*/

    IntegrationUSDC internal usdc;
    BlieverV1Pool   internal pool;
    BlieverMarket   internal marketImpl;  // EIP-1167 master — never used directly

    /*//////////////////////////////////////////////////////////////
                             SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        // ── Deadlines (relative to Foundry default block.timestamp) ─────────
        tradingDeadline    = uint40(block.timestamp + 7 days);
        resolutionDeadline = uint40(block.timestamp + 14 days);

        // ── Label all addresses for readable test output ─────────────────────
        vm.label(admin,    "admin");
        vm.label(lp,       "lp");
        vm.label(alice,    "alice");
        vm.label(bob,      "bob");
        vm.label(carol,    "carol");
        vm.label(resolver, "resolver");

        // ── Deploy USDC ───────────────────────────────────────────────────────
        usdc = new IntegrationUSDC();
        vm.label(address(usdc), "USDC");

        // ── Deploy BlieverV1Pool behind a UUPS proxy ──────────────────────────
        BlieverV1Pool poolImpl = new BlieverV1Pool();
        bytes memory initData  = abi.encodeCall(
            BlieverV1Pool.initialize,
            (address(usdc), admin, ALPHA, MAX_RISK, RESERVE_BPS)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(poolImpl), initData);
        pool = BlieverV1Pool(address(proxy));
        vm.label(address(pool), "BlieverV1Pool");

        // ── Deploy BlieverMarket master implementation ────────────────────────
        // Constructor calls _disableInitializers() so the master cannot be used
        // directly; all live markets are EIP-1167 clones of this address.
        marketImpl = new BlieverMarket();
        vm.label(address(marketImpl), "MarketImpl");

        // ── Seed pool with LP liquidity ───────────────────────────────────────
        _lpDeposit(lp, LP_DEPOSIT);
    }

    /*//////////////////////////////////////////////////////////////
                       PROTOCOL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint USDC to `_lp`, approve pool, and call pool.deposit().
    function _lpDeposit(address _lp, uint256 amount) internal {
        usdc.mint(_lp, amount);
        vm.startPrank(_lp);
        usdc.approve(address(pool), amount);
        pool.deposit(amount, _lp);
        vm.stopPrank();
    }

    /// @notice Deploy a fresh EIP-1167 BlieverMarket clone, initialise it,
    ///         and register it with the pool under MARKET_MANAGER_ROLE (admin).
    ///
    ///         Factory role: address(this) — the test contract acts as factory
    ///         so it can call expireUnresolved() / pause() / unpause() directly.
    function _deployMarket(
        uint8   nOutcomes,
        uint256 epsilon
    ) internal returns (BlieverMarket market) {
        address clone = Clones.clone(address(marketImpl));
        market = BlieverMarket(clone);
        vm.label(clone, string.concat("Market-", vm.toString(nOutcomes), "out"));

        // Use a unique questionId per clone to avoid storage collisions.
        bytes32 qId = keccak256(abi.encodePacked(nOutcomes, block.timestamp, clone));

        market.initialize(
            address(pool),
            qId,
            nOutcomes,
            ALPHA,
            tradingDeadline,
            resolutionDeadline,
            epsilon,
            resolver,
            address(this)  // test contract = factory
        );

        vm.prank(admin);
        pool.registerMarket(address(market), uint32(nOutcomes));
    }

    /// @notice Mint TRADER_USDC to `trader` and grant max USDC approval to the pool.
    ///         Traders approve the POOL (not the market) because the vault's
    ///         collectTradeCost() calls safeTransferFrom(trader, vault, cost).
    function _setupTrader(address trader) internal {
        usdc.mint(trader, TRADER_USDC);
        vm.prank(trader);
        usdc.approve(address(pool), type(uint256).max);
    }

    /// @notice Buy `shareAmount` shares of `outcomeIndex` on behalf of `trader`.
    ///         - Mints extra USDC to trader if balance is insufficient.
    ///         - Uses type(uint256).max as maxCostUsdc — slippage guards are tested
    ///           in unit tests; integration tests focus on cross-contract state.
    ///         - Skips permit (v = 0).
    /// @return actualCost  USDC deducted from trader's balance (6-dec).
    function _buy(
        BlieverMarket market,
        address       trader,
        uint256       outcomeIndex,
        uint256       shareAmount
    ) internal returns (uint256 actualCost) {
        uint256 estimatedCost = market.getBuyCost(outcomeIndex, shareAmount);

        // Top-up if needed (e.g. after multiple buys drain TRADER_USDC).
        if (usdc.balanceOf(trader) < estimatedCost) {
            usdc.mint(trader, estimatedCost - usdc.balanceOf(trader) + 1e6);
        }

        uint256 balBefore = usdc.balanceOf(trader);

        vm.prank(trader);
        market.buy(outcomeIndex, shareAmount, type(uint256).max, 0, 0, 0, 0);

        actualCost = balBefore - usdc.balanceOf(trader);
    }

    /// @notice Sell `shareAmount` shares of `outcomeIndex` on behalf of `trader`.
    ///         Handles both standard refund sells and CSS net-cost sells:
    ///         - minRefundUsdc = 0 (accept any refund, including zero).
    ///         - maxCostUsdc   = type(uint256).max (accept any CSS cost).
    ///         - Ensures trader has USDC if getSellEstimate reveals a net cost.
    ///         - Skips permit (v = 0).
    function _sell(
        BlieverMarket market,
        address       trader,
        uint256       outcomeIndex,
        uint256       shareAmount
    ) internal {
        // On the CSS cost path the vault calls collectTradeCost — trader must have USDC.
        (, uint256 costEst) = market.getSellEstimate(trader, outcomeIndex, shareAmount);
        if (costEst > 0 && usdc.balanceOf(trader) < costEst) {
            usdc.mint(trader, costEst);
            // Approval for pool must already exist (set by _setupTrader).
        }

        vm.prank(trader);
        market.sell(outcomeIndex, shareAmount, 0, type(uint256).max, 0, 0, 0, 0);
    }

    /// @notice Call resolve() on `market` from the resolver address.
    function _resolve(BlieverMarket market, uint8 winningOutcome) internal {
        vm.prank(resolver);
        market.resolve(winningOutcome);
    }

    /// @notice Call claim() on `market` from `winner`.
    function _claim(BlieverMarket market, address winner) internal {
        vm.prank(winner);
        market.claim();
    }

    /// @notice Expire an unresolved market past its resolution deadline.
    ///         address(this) = factory, which is what was passed to market.initialize().
    function _expireUnresolved(BlieverMarket market) internal {
        market.expireUnresolved();  // caller = address(this) = factory
    }

    /*//////////////////////////////////////////////////////////////
                       ASSERTION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Assert pool is solvent AND that MarketInfo.currentLiability ≤ riskBudget.
    function _assertPoolSolvent() internal {
        assertTrue(pool.isSolvent(), "pool: isSolvent() returned false");
        assertGe(
            usdc.balanceOf(address(pool)),
            pool.totalLiability(),
            "pool: USDC balance < totalLiability"
        );
    }
}
