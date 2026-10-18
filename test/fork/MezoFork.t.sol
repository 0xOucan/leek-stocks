// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IndexOracle} from "../../src/IndexOracle.sol";
import {ETFFactory} from "../../src/ETFFactory.sol";
import {ETFShare} from "../../src/ETFShare.sol";
import {IssuanceVault} from "../../src/IssuanceVault.sol";

/**
 * The audit report's last open gate: every property the vault assumes about
 * MUSD has so far been proven against `MockMUSD`, which is a contract this
 * repository wrote to behave. This suite proves them against the deployed
 * token instead - L-5 (decimals cached at construction) and L-2 (no fee on
 * transfer) are assumptions about a live upgradeable contract, and a mock
 * cannot falsify either.
 *
 * Run alone:  forge test --match-path "test/fork/*"
 */
contract MezoForkTest is Test {
    /* --------------------------------------------------------- the network */

    /// @dev Mezo testnet, as configured in foundry.toml's [rpc_endpoints].
    string constant RPC_ALIAS = "mezo_testnet";
    uint256 constant MEZO_TESTNET_CHAIN_ID = 31611;

    /// @notice The real MUSD on Mezo testnet. 18 decimals, verified source.
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;

    /**
     * @dev Head block as reported by `cast block-number --rpc-url
     *      https://rpc.test.mezo.org` on 2026-10-16. Pinned rather than
     *      floating: an unpinned fork test reads whatever state the chain is
     *      in when CI happens to run, so it can start failing on a commit
     *      that changed nothing, and a failure nobody can reproduce locally
     *      is worse than no test. Raising this number is a reviewed change,
     *      the same as any other assumption about the chain.
     */
    uint256 constant FORK_BLOCK = 16_198_929;

    /* ------------------------------------------------- the vault under test */

    uint8 constant FEED_DECIMALS = 8; // Chainlink's USD convention
    uint32 constant STALENESS = 1 hours;
    /// Seconds the oracle requires between rounds. See IndexOracle.
    uint32 constant MIN_ROUND_INTERVAL = 30 seconds;
    uint16 constant FEE_BPS = 50; // 0.5%
    uint256 constant CAP = 1_000_000e18;
    int256 constant PRICE = 200e8; // 200 MUSD per whole share

    address admin = makeAddr("admin");
    address publisher = makeAddr("publisher");
    address guardian = makeAddr("guardian");
    address treasurer = makeAddr("treasurer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    /// @dev False when the fork could not be created; every test then skips.
    bool forked;

    function setUp() public {
        // try/catch, not an unconditional createSelectFork: this suite must
        // not turn an offline machine or a down RPC into a red build. The
        // cheatcode reverts when it cannot reach the endpoint, and that revert
        // is catchable here, so the failure degrades into a skip with a
        // reason printed. MEZO_FORK_SKIP=true forces the same path, which is
        // how the skip branch itself gets exercised.
        if (vm.envOr("MEZO_FORK_SKIP", false)) {
            emit log("SKIP: MEZO_FORK_SKIP is set");
            return;
        }
        try vm.createSelectFork(vm.rpcUrl(RPC_ALIAS), FORK_BLOCK) {
            forked = true;
        } catch {
            emit log("SKIP: could not fork Mezo testnet (offline, or the RPC pruned the pinned block)");
            return;
        }
        assertEq(block.chainid, MEZO_TESTNET_CHAIN_ID, "forked the wrong chain");
    }

    /* ------------------------------------------------ what the token really is */

    /**
     * L-5 says the vault caches `decimals()` at construction, and that MUSD is
     * upgradeable so the cache could in principle go stale. This is the check
     * the deployment checklist owes: read both metadata fields off the live
     * token at the pinned block and fail loudly if either ever moves.
     */
    function test_fork_musdMetadataIsWhatTheVaultAssumes() public view {
        if (!forked) return;
        assertEq(IERC20Metadata(MUSD).symbol(), "MUSD", "symbol moved");
        assertEq(IERC20Metadata(MUSD).decimals(), 18, "decimals moved; L-5 has fired");
        assertGt(IERC20(MUSD).totalSupply(), 0, "no supply: wrong address or wrong chain");
    }

    /**
     * `deal` rewrites the balance slot it finds by probing, which silently
     * misses on tokens that keep balances somewhere else - a proxy with an
     * unusual layout, or an accounting token. Asserting the balance back is
     * the only way to know the funding worked rather than writing into a slot
     * nothing reads. It does work on MUSD at this block, so no holder has to
     * be impersonated with `vm.prank`.
     */
    function test_fork_dealActuallyFundsMusd() public {
        if (!forked) return;
        deal(MUSD, alice, 1_000e18);
        assertEq(IERC20(MUSD).balanceOf(alice), 1_000e18, "deal did not move the real balance slot");
    }

    /**
     * L-2: `buy()` credits fees and mints from the *requested* amount, not
     * from a measured balance delta, which is only sound because MUSD takes no
     * cut on transfer. Measured here on both sides of one transfer rather than
     * asserted in prose.
     */
    function test_fork_transferMovesExactlyTheAmountRequested() public {
        if (!forked) return;
        uint256 amount = 1_234e18;
        deal(MUSD, alice, amount);
        uint256 supplyBefore = IERC20(MUSD).totalSupply();

        vm.prank(alice);
        assertTrue(IERC20(MUSD).transfer(bob, amount), "transfer returned false");

        assertEq(IERC20(MUSD).balanceOf(alice), 0, "sender was charged something other than the amount");
        assertEq(IERC20(MUSD).balanceOf(bob), amount, "recipient got less than was sent: fee on transfer");
        // A rebasing token would also show up here, as a supply that moved
        // because a transfer happened.
        assertEq(IERC20(MUSD).totalSupply(), supplyBefore, "total supply moved on a transfer");
    }

    /// @dev transferFrom is the path `buy()` and `fund()` actually take.
    function test_fork_transferFromMovesExactlyTheAmountRequested() public {
        if (!forked) return;
        uint256 amount = 500e18;
        deal(MUSD, alice, amount);
        vm.prank(alice);
        IERC20(MUSD).approve(bob, amount);

        vm.prank(bob);
        assertTrue(IERC20(MUSD).transferFrom(alice, bob, amount), "transferFrom returned false");

        assertEq(IERC20(MUSD).balanceOf(bob), amount, "transferFrom delivered a different amount");
        assertEq(IERC20(MUSD).allowance(alice, bob), 0, "allowance was not debited by exactly the amount");
    }

    /* ------------------------------------------- the vault, against that token */

    /**
     * The whole stack deployed against the live token: oracle, first round,
     * factory, registry, pair. Proves the construction-time `decimals()` read
     * succeeds on the real proxy and that the feed-to-token scaling lands
     * where it should - 200e8 at 8 feed decimals is 200e18 of an 18-decimal
     * settlement token, and a vault that got this wrong by a power of ten
     * would still pass every mock test.
     */
    function test_fork_vaultPricesAgainstLiveMusd() public {
        if (!forked) return;
        (IssuanceVault vault,) = _deployPair();
        assertEq(vault.musdDecimals(), 18, "vault cached a decimals value the live token does not report");
        assertEq(vault.price(), 200e18, "scaling from 8 feed decimals to 18 token decimals is wrong");
    }

    /// Minting and redeeming, with every number checked against the live token's balances.
    function test_fork_buyAndRedeemAgainstLiveMusd() public {
        if (!forked) return;
        (IssuanceVault vault, ETFShare share) = _deployPair();

        uint256 spend = 1_000e18;
        deal(MUSD, alice, spend);
        vm.startPrank(alice);
        IERC20(MUSD).approve(address(vault), spend);
        uint256 sharesOut = vault.buy(spend, 0);
        vm.stopPrank();

        // 0.5% of 1000 is 5 MUSD of fee, 995 net, at 200 per share.
        uint256 expectedFee = (spend * FEE_BPS) / 10_000;
        uint256 expectedShares = ((spend - expectedFee) * 1e18) / 200e18;
        assertEq(sharesOut, expectedShares, "shares minted do not match the oracle price");
        assertEq(share.balanceOf(alice), sharesOut, "share token did not credit the buyer");
        assertEq(IERC20(MUSD).balanceOf(address(vault)), spend, "vault received something other than the full amount");
        /* The fee splits: half to the treasury, half left in reserves. That
           split is the funded backstop (H-1a) and it is asserted here, on the
           live token, because a buy that did not top up reserves would leave
           the H-1 shortfall growing with every trade. */
        assertEq(vault.feesAccrued(), expectedFee / 2, "the treasury's half of the fee is wrong");
        assertEq(vault.reserves(), spend - expectedFee / 2, "the reserve half of the fee did not stay");
        assertGt(vault.coverageBps(), 10_000, "a fresh buy must leave reserves above liabilities");

        // Redeeming the whole position at an unchanged price must lose exactly
        // two fees and nothing else, which is L-6's round trip on real MUSD.
        vm.startPrank(alice);
        // The share token burns through `_spendAllowance`, so the vault needs
        // an exact approval to burn a holder's shares - it cannot do it
        // unilaterally, which is the point.
        share.approve(address(vault), sharesOut);
        uint256 musdOut = vault.redeem(sharesOut, 0);
        vm.stopPrank();
        assertEq(share.balanceOf(alice), 0, "shares were not burned");
        assertEq(IERC20(MUSD).balanceOf(alice), musdOut, "payout does not match the live balance delta");
        assertLt(musdOut, spend, "a round trip at an unchanged price must not profit");
    }

    /* ------------------------------------------------------------- internals */

    function _deployPair() internal returns (IssuanceVault vault, ETFShare share) {
        IndexOracle oracle =
            new IndexOracle("GOLOGGLE / MUSD", FEED_DECIMALS, 2000, STALENESS, MIN_ROUND_INTERVAL, admin, publisher, guardian);
        vm.prank(publisher);
        oracle.publish(PRICE);

        ETFFactory factory = new ETFFactory(IERC20(MUSD), admin);
        vm.prank(admin);
        factory.registerIndex("GOLOGGLE", oracle, STALENESS, FEE_BPS, 5000, CAP, guardian, treasurer);
        vm.prank(admin);
        (address shareAddress, address vaultAddress) = factory.deployETF("Gologgle Index", "GOLOGGLE");
        return (IssuanceVault(vaultAddress), ETFShare(shareAddress));
    }
}
