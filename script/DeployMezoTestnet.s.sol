// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {ETFFactory} from "../src/ETFFactory.sol";
import {IssuanceVault} from "../src/IssuanceVault.sol";
import {LeekStaking} from "../src/LeekStaking.sol";
import {ILeekStaking} from "../src/interfaces/ILeekStaking.sol";

/// @dev Just enough of MUSD to tell the real one from the impostors.
interface IMusdMintList {
    function mintList(address) external view returns (bool);
}

/**
 * @title DeployMezoTestnet
 * @notice One oracle per index, its first round published in the same
 *         transaction batch, one factory, and a registered-then-deployed pair
 *         for each parody index.
 *
 * @dev Intended invocation - the keystore account prompts for its password
 *      interactively, so no key and no password ever reaches a command line,
 *      a shell history or this repository:
 *
 *      forge script script/DeployMezoTestnet.s.sol \
 *        --rpc-url mezo_testnet --account monad-deployer \
 *        --sender <address> --broadcast
 *
 *      Drop `--broadcast` to simulate. Gas on Mezo is paid in BTC, 18
 *      decimals, so the sender needs test BTC rather than ETH.
 *
 *      Every address and parameter is a constant below or an environment
 *      variable read in one place, because a value buried mid-function is a
 *      value nobody re-reads before a deployment.
 *
 *      **The indices are parody.** GOLOGGLE and AMEZON name no real company,
 *      track nothing, and are backed by nothing. See the README.
 */
contract DeployMezoTestnet is Script {
    /* ------------------------------------------------------ the chain and token */

    /// @dev Mezo testnet. Guards against broadcasting at the wrong RPC alias.
    uint256 constant MEZO_TESTNET_CHAIN_ID = 31611;

    /**
     * @dev The MUSD `BorrowerOperations` can mint, which is the only one a
     *      user can obtain by borrowing.
     *
     *      This constant used to be 0x118917a4..., the address Mezo's public
     *      docs give for testnet MUSD and the one its own MUSD/BTC pool
     *      holds. That contract returns **false** for
     *      `mintList(BorrowerOperations)`. A deployment using it settles in a
     *      token nobody can borrow and nobody can repay a trove with: the
     *      symbol, the decimals and the balance all look correct and every
     *      trade reverts. The live deployment escaped it only because
     *      SETTLEMENT_TOKEN was passed by hand, which is not a safeguard.
     *
     *      Overridable with SETTLEMENT_TOKEN so a fork or a local chain can
     *      run the same script, and asserted in `run()` on Mezo testnet.
     */
    address constant DEFAULT_SETTLEMENT_TOKEN = 0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af;

    /// @dev Mezo's native borrow entry point, the authority on which MUSD is real.
    address constant BORROWER_OPERATIONS = 0xa14cbA6DD12D537A8decc7dd3c4aC413B8711eba;

    /// @dev MEZO on Mezo, the same precompile-range address on both networks.
    address constant DEFAULT_MEZO = 0x7B7c000000000000000000000000000000000001;

    /// @dev Finding L-5: MUSD is upgradeable and the vault caches `decimals()`
    ///      at construction, so the live value is asserted here, before
    ///      anything is deployed against it, rather than trusted.
    uint8 constant EXPECTED_MUSD_DECIMALS = 18;

    /* -------------------------------------------------------- oracle parameters */

    uint8 constant FEED_DECIMALS = 8; // Chainlink's USD convention
    uint16 constant MAX_DEVIATION_BPS = 2000; // 20% per round, immutable once set
    uint32 constant MAX_STALENESS = 1 hours;
    /**
     * @dev Seconds between rounds, enforced by the oracle.
     *
     *      Short enough not to interfere with the feed, which attempts a
     *      publish every 60s, and long enough that a burst of rounds cannot
     *      share a block. That atomicity is the whole attack: five rounds in
     *      one transaction compound the 20% bound to 2.49x and let the same
     *      transaction buy before and redeem after. Any non-zero interval
     *      breaks it; 30s also gives a guardian minutes rather than one
     *      block to react to a ratchet.
     */
    uint32 constant MIN_ROUND_INTERVAL = 30 seconds;

    /**
     * @dev The cumulative bound, audit finding R4-6.
     *
     *      The per-round bound plus the interval gave 20% every 30 seconds,
     *      which is four rounds - two minutes - to double the price, and
     *      `MAX_STALENESS` is an hour so nothing goes stale while it happens.
     *      A guardian who was not already watching had no brake.
     *
     *      20% per hour in total, however many in-bound rounds it takes.
     *      Doubling now costs 11,010 seconds, a little over three hours, as
     *      measured by test/Ratchet.t.sol. Chosen equal to
     *      `MAX_DEVIATION_BPS` so one round may still use the whole window
     *      budget - a genuine market gap gets through in one step - while a
     *      sequence of them cannot.
     */
    uint32 constant DEVIATION_WINDOW = 1 hours;
    uint16 constant MAX_WINDOW_DEVIATION_BPS = 2_000;

    /* --------------------------------------------------------- vault parameters */

    uint16 constant FEE_BPS = 50; // 0.5%, against MAX_FEE_BPS of 500
    /* Half of every fee stays in reserves instead of reaching the treasury.
       The backstop that mitigates H-1 has to be funded by something other than
       goodwill, because fund() pays its caller nothing (H-1a). */
    uint16 constant RESERVE_SHARE_BPS = 5000;
    uint256 constant MAX_SHARES = 1_000_000e18; // finding H-1's only bound on exposure

    /* -------------------------------------------------------- staking tiers */

    /*
     * Stake MEZO, pay less fee, and earn the rest of the fee others pay.
     *
     * The thresholds are set to what is obtainable on Mezo TESTNET, not to
     * what a mainnet schedule would use, and the difference is large enough
     * to be worth stating.
     *
     * They were 100 / 1,000 / 5,000 MEZO, which reads like a real schedule
     * and was checked against nothing. The deployer account holds **100
     * MEZO**, so the top two tiers were unreachable and the bottom one cost
     * the entire balance: the headline integration would have demoed at its
     * weakest setting, with no MEZO left over for a second wallet, and a
     * judge clicking through would have seen a 10% discount and an
     * unexplained table of two tiers nobody can buy. A tier schedule nobody
     * on the chain can reach is a schedule that has not been tested.
     *
     * 1 / 10 / 50 makes all three reachable from one balance and still leaves
     * half of it spare. The DISCOUNTS are unchanged, because those are the
     * economic claim; only the thresholds move, because those are a function
     * of what a testnet faucet hands out.
     *
     * The top tier is LeekStaking's own MAX_DISCOUNT_BPS and is capped there
     * in two contracts independently: part of every fee is the reserve
     * top-up that keeps redemption solvent, so no stake may waive all of it.
     */
    /**
     * @dev Seconds a stake must sit before it can be unstaked or earn a
     *      discount. One hour on testnet: long enough that acquiring and
     *      releasing a position inside one transaction is impossible, which
     *      is the attack, and short enough that a tester can see both sides
     *      of it in a sitting.
     */
    uint256 constant STAKING_COOLDOWN = 1 hours;

    uint256 constant TIER_1_STAKE = 1e18;
    uint16 constant TIER_1_DISCOUNT_BPS = 1_000; // 10% off the fee
    uint256 constant TIER_2_STAKE = 10e18;
    uint16 constant TIER_2_DISCOUNT_BPS = 2_500;
    uint256 constant TIER_3_STAKE = 50e18;
    uint16 constant TIER_3_DISCOUNT_BPS = 5_000; // the cap

    /* ------------------------------------------------------------- the indices */

    string constant GOLOGGLE_SYMBOL = "GOLOGGLE";
    string constant GOLOGGLE_NAME = "Gologgle Index";
    string constant GOLOGGLE_FEED = "GOLOGGLE / MUSD";
    /**
     * @dev The opening price, which must be the index's own base value.
     *
     *      Finding L-1: the first round is exempt from the deviation bound,
     *      so it is the one answer a publisher sets freely. Every round after
     *      it is capped at MAX_DEVIATION_BPS, which makes a wrong opening
     *      price expensive rather than harmless.
     *
     *      This was 200e8 while both indices are based at 100, and the live
     *      feed had to walk down to the truth at 20% a round:
     *
     *          round 1  200.00   <- this constant
     *          round 2  160.00
     *          round 3  128.00
     *          round 4  102.40
     *          round 5   99.71   <- the index's actual value
     *
     *      For four rounds the vault priced a share at up to twice what the
     *      basket was worth, and anybody buying in that window overpaid by
     *      that factor. Both indices use baseValue 100 in
     *      feed/src/indices.ts, so the opening answer is 100.
     */
    int256 constant GOLOGGLE_FIRST_ANSWER = 100e8; // the index's base value

    string constant AMEZON_SYMBOL = "AMEZON";
    string constant AMEZON_NAME = "Amezon Index";
    string constant AMEZON_FEED = "AMEZON / MUSD";
    /// @dev Same reasoning as GOLOGGLE_FIRST_ANSWER. Was 180e8.
    int256 constant AMEZON_FIRST_ANSWER = 100e8;

    /* ------------------------------------------------------------ role holders */

    // Resolved in run(). Each defaults to the deployer, which is
    // *** TESTNET ONLY ***: findings M-1 and M-2 are precisely about one key
    // holding all of this. A single-key deployment means the same key that
    // pushes prices can also pause the feed, raise the share cap and withdraw
    // fees, which is every centralisation risk in the audit report at once.
    // For anything with value behind it: four distinct addresses, the guardian
    // a multisig, and the admin not the publisher.
    address admin;
    address publisher;
    address guardian;
    address treasurer;

    function run() external {
        address deployer = msg.sender;
        address settlementToken = vm.envOr("SETTLEMENT_TOKEN", DEFAULT_SETTLEMENT_TOKEN);
        admin = vm.envOr("ADMIN", deployer);
        /*
         * The other three default to the ADMIN, not to the deployer, whenever
         * ADMIN is someone else.
         *
         * They used to default to the deployer unconditionally, and because
         * every grant/renounce pair below is conditional on the holder
         * differing from the deployer, a two-phase deployment with only ADMIN
         * set left the deployer holding PUBLISHER_ROLE and GUARDIAN_ROLE on
         * both oracles. The whole point of the split is to disarm that key.
         *
         * An operator who genuinely wants the deployer to keep publishing
         * says so by passing PUBLISHER=<deployer> explicitly.
         */
        address fallbackHolder = admin == deployer ? deployer : admin;
        publisher = vm.envOr("PUBLISHER", fallbackHolder);
        guardian = vm.envOr("GUARDIAN", fallbackHolder);
        treasurer = vm.envOr("TREASURER", fallbackHolder);

        /*
         * Not defaulted to the same address.
         *
         * Both used to default to the ADMIN, and the factory's comment has
         * claimed "separate keys" since the first version while nothing
         * enforced it. `registerIndex` now rejects guardian == treasurer
         * outright, because `emergencyUnsetStaking` was delegated to the
         * guardian on the explicit argument that unsetting "cannot take
         * value: the treasury share simply accrues to feesAccrued, where only
         * TREASURER_ROLE can reach it" - an argument that is only true when
         * the two differ. Caught here with a usable message rather than as a
         * bare custom-error revert mid-broadcast.
         */
        require(
            guardian != treasurer,
            "GUARDIAN and TREASURER must differ: one key that can detach staking and also take the fees defeats the split. Set both explicitly."
        );

        /*
         * The chain guard, with a named escape for a rehearsal.
         *
         * Refusing every chain but Mezo testnet meant the script that deploys
         * production was not the script anybody could test: an end-to-end run
         * on a local Anvil had to reimplement it, mirroring these constants by
         * hand, which is precisely the drift the guard was meant to prevent.
         * So the default is still a hard refusal, and ALLOW_CHAIN_ID is the
         * only way past it - set deliberately, per run, and logged loudly, so
         * a rehearsal cannot be mistaken for the real thing and a slip of the
         * --rpc-url cannot quietly deploy somewhere else.
         */
        uint256 allowed = vm.envOr("ALLOW_CHAIN_ID", uint256(0));
        if (allowed != 0 && allowed == block.chainid) {
            console2.log("!! REHEARSAL: deploying to chain", block.chainid);
            console2.log("!! ALLOW_CHAIN_ID was set. This is not Mezo testnet.");
        } else {
            require(
                block.chainid == MEZO_TESTNET_CHAIN_ID,
                "wrong chain: expected Mezo testnet 31611 (set ALLOW_CHAIN_ID to rehearse elsewhere)"
            );
        }
        // L-5, enforced rather than written on a checklist.
        require(
            IERC20Metadata(settlementToken).decimals() == EXPECTED_MUSD_DECIMALS,
            "settlement token decimals are not 18: the vault would misprice by a power of ten"
        );
        /*
         * And the token has to be the MUSD a user can actually get.
         *
         * Five contracts on Mezo testnet report MUSD with 18 decimals, so the
         * decimals check above passes for all of them and tells us nothing
         * about which one this is. Only one returns true for
         * mintList(BorrowerOperations), and settling in any of the others
         * deploys a market whose users cannot obtain the settlement token.
         * Checked only on Mezo testnet, since a local chain's mock has no
         * mintList at all.
         */
        if (block.chainid == MEZO_TESTNET_CHAIN_ID) {
            require(
                IMusdMintList(settlementToken).mintList(BORROWER_OPERATIONS),
                "settlement token is not mintable by BorrowerOperations: nobody could borrow it"
            );
        }

        if (admin == deployer && publisher == deployer && guardian == deployer && treasurer == deployer) {
            console2.log("WARNING: one key holds admin, publisher, guardian and treasurer. Testnet only.");
        }

        vm.startBroadcast();

        ETFFactory factory = new ETFFactory(IERC20(settlementToken), admin);

        IndexOracle gologgleOracle =
            _deployOracleAndPublishFirstRound(GOLOGGLE_FEED, GOLOGGLE_FIRST_ANSWER, deployer);
        IndexOracle amezonOracle = _deployOracleAndPublishFirstRound(AMEZON_FEED, AMEZON_FIRST_ANSWER, deployer);

        /*
         * Everything from here is admin-gated, so with a separate admin this
         * script deploys and stops.
         *
         * It used to `require(admin == deployer)`, which aborted the run
         * instead - and that had a consequence worth spelling out, because it
         * is the opposite of what the code looked like it did. The hand-over
         * branches above (`if (admin != deployer) grantRole/renounceRole`)
         * execute, and then the require reverts the whole broadcast. So the
         * branches were dead code in every run that *completed*, and the only
         * completing configuration was one hot key holding
         * DEFAULT_ADMIN_ROLE on the factory, both vaults, both share tokens,
         * both oracles and the staking contract, with nothing ever
         * renounced. That single key is what made the two reserve drains in
         * test/AdminTheft.t.sol reachable.
         *
         * Now a separate admin is a supported, two-phase deployment: this
         * phase deploys and hands over, and ConfigureMezoTestnet.s.sol is
         * what the admin runs next.
         */
        if (admin != deployer) {
            vm.stopBroadcast();

            /* Asserted, not asserted-in-a-comment. The whole point of the
               two-phase split is that the deployer walks away with nothing,
               and a script that prints that claim without checking it is how
               the previous version came to have dead hand-over code. */
            /*
             * Unconditional, every role, both oracles.
             *
             * The previous version wrapped the publisher check in
             * `if (publisher != deployer)` - which is exactly never true in
             * the case where the deployer kept the role - and did not check
             * GUARDIAN_ROLE at all, while printing "the deployer holds no
             * roles on the oracles" underneath. An assertion that cannot fire
             * in the failing case is worse than no assertion, because it
             * reads as coverage.
             */
            _assertDeployerDisarmed(gologgleOracle, deployer);
            _assertDeployerDisarmed(amezonOracle, deployer);

            require(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin), "admin does not administer the factory");
            require(
                !factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), deployer),
                "deployer still administers the factory"
            );

            console2.log("");
            console2.log("=== PHASE 1 COMPLETE. The admin must now run phase 2. ===");
            console2.log("factory          ", address(factory));
            console2.log("GOLOGGLE oracle  ", address(gologgleOracle));
            console2.log("AMEZON oracle    ", address(amezonOracle));
            console2.log("settlement token ", settlementToken);
            console2.log("");
            console2.log("The deployer holds no role on either oracle or on the factory, asserted above.");
            console2.log("Run, as ADMIN:");
            console2.log("  FACTORY=<factory> GOLOGGLE_ORACLE=<...> AMEZON_ORACLE=<...> \\");
            console2.log("  forge script script/ConfigureMezoTestnet.s.sol --rpc-url mezo_testnet \\");
            console2.log("    --account <admin> --sender <admin> --broadcast --slow");
            return;
        }

        factory.registerIndex(
            GOLOGGLE_SYMBOL, gologgleOracle, MAX_STALENESS, FEE_BPS, RESERVE_SHARE_BPS, MAX_SHARES, guardian, treasurer
        );
        factory.registerIndex(
            AMEZON_SYMBOL, amezonOracle, MAX_STALENESS, FEE_BPS, RESERVE_SHARE_BPS, MAX_SHARES, guardian, treasurer
        );

        (address gologgleShare, address gologgleVault) = factory.deployETF(GOLOGGLE_NAME, GOLOGGLE_SYMBOL);
        (address amezonShare, address amezonVault) = factory.deployETF(AMEZON_NAME, AMEZON_SYMBOL);

        /*
         * Staking, deployed after the vaults because it earns from them.
         *
         * The reverse order is impossible: the vaults are deployed by the
         * factory and take no staking address, so the link is made with
         * setStaking. Until that call lands each vault behaves exactly as
         * before, accruing the treasury share of every fee to feesAccrued -
         * which is also the state the vaults fall back to if nobody is
         * staked.
         *
         * Split into its own function because `run()` ran out of stack: the
         * locals here are each a deployed address that has to be logged, and
         * "stack too deep" is not a reason to log fewer of them.
         */
        LeekStaking staking = _deployStakingAndWire(settlementToken, gologgleVault, amezonVault);

        vm.stopBroadcast();

        _verifyWiring(staking, gologgleVault, amezonVault, deployer);

        console2.log("settlement token  ", settlementToken);
        console2.log("staking (sMEZO)   ", address(staking));
        console2.log("factory           ", address(factory));
        console2.log("GOLOGGLE oracle   ", address(gologgleOracle));
        console2.log("GOLOGGLE share    ", gologgleShare);
        console2.log("GOLOGGLE vault    ", gologgleVault);
        console2.log("AMEZON oracle     ", address(amezonOracle));
        console2.log("AMEZON share      ", amezonShare);
        console2.log("AMEZON vault      ", amezonVault);
        console2.log("price of a share  ", IssuanceVault(gologgleVault).price());
    }

    /**
     * @dev Deploys with the sender as temporary admin and publisher so the
     *      first round lands in the same broadcast as the constructor
     *      (finding L-1: an unpublished feed is a feed whose opening price a
     *      later, unreviewed transaction chooses). The configured holders are
     *      then granted their roles and the deployer renounces everything it
     *      held, so no standing power is left behind when the keys differ.
     */
    function _deployOracleAndPublishFirstRound(string memory feedDescription, int256 firstAnswer, address deployer)
        internal
        returns (IndexOracle oracle)
    {
        oracle = new IndexOracle(
            feedDescription,
            FEED_DECIMALS,
            MAX_DEVIATION_BPS,
            MAX_STALENESS,
            MIN_ROUND_INTERVAL,
            DEVIATION_WINDOW,
            MAX_WINDOW_DEVIATION_BPS,
            deployer,
            deployer,
            deployer
        );
        oracle.publish(firstAnswer);

        /* Grant first, renounce second, admin last of all - renouncing admin
           before the other grants would strip the ability to make them. These
           branches used to be unreachable in any completing run; see the note
           in run(). */
        if (publisher != deployer) oracle.grantRole(oracle.PUBLISHER_ROLE(), publisher);
        if (guardian != deployer) oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);
        if (admin != deployer) oracle.grantRole(oracle.DEFAULT_ADMIN_ROLE(), admin);

        /* Renounce each role the deployer is not the configured holder of.
           These are the same conditions as the grants above, which is the
           point: a role granted elsewhere must not also stay here. */
        if (publisher != deployer) oracle.renounceRole(oracle.PUBLISHER_ROLE(), deployer);
        if (guardian != deployer) oracle.renounceRole(oracle.GUARDIAN_ROLE(), deployer);
        if (admin != deployer) oracle.renounceRole(oracle.DEFAULT_ADMIN_ROLE(), deployer);
    }

    /**
     * @dev Assert the deployer walks away from an oracle with nothing.
     *
     *      One helper for both oracles and all three roles, so a role cannot
     *      be left out of one of two near-identical blocks - which is how
     *      GUARDIAN_ROLE went unchecked.
     */
    function _assertDeployerDisarmed(IndexOracle oracle, address deployer) internal view {
        require(!oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), deployer), "deployer still administers an oracle");
        require(!oracle.hasRole(oracle.PUBLISHER_ROLE(), deployer), "deployer can still publish");
        require(!oracle.hasRole(oracle.GUARDIAN_ROLE(), deployer), "deployer can still pause the feed");
        require(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin), "admin does not administer the oracle");
    }

    /**
     * @dev Deploy the staking contract, set its tiers and point both vaults
     *      at it. Broadcast must already be open.
     */
    function _deployStakingAndWire(address settlementToken, address gologgleVault, address amezonVault)
        internal
        returns (LeekStaking staking)
    {
        address mezoToken = vm.envOr("MEZO_TOKEN", DEFAULT_MEZO);
        console2.log("MEZO token        ", mezoToken);

        staking = new LeekStaking(IERC20(mezoToken), IERC20(settlementToken), admin, STAKING_COOLDOWN);

        LeekStaking.Tier[] memory tiers = new LeekStaking.Tier[](3);
        tiers[0] = LeekStaking.Tier(TIER_1_STAKE, TIER_1_DISCOUNT_BPS);
        tiers[1] = LeekStaking.Tier(TIER_2_STAKE, TIER_2_DISCOUNT_BPS);
        tiers[2] = LeekStaking.Tier(TIER_3_STAKE, TIER_3_DISCOUNT_BPS);
        staking.setTiers(tiers);

        IssuanceVault(gologgleVault).setStaking(ILeekStaking(address(staking)));
        IssuanceVault(amezonVault).setStaking(ILeekStaking(address(staking)));
    }

    /**
     * @dev Read the deployment back off the chain.
     *
     *      A script that logs what it intended rather than what landed is how
     *      a half-wired system ships looking complete. Each of these is a
     *      call the broadcast made; a mismatch aborts rather than printing a
     *      summary nobody will re-check.
     */
    function _verifyWiring(LeekStaking staking, address gologgleVault, address amezonVault, address deployer)
        internal
        view
    {
        require(address(IssuanceVault(gologgleVault).staking()) == address(staking), "GOLOGGLE vault not wired");
        require(address(IssuanceVault(amezonVault).staking()) == address(staking), "AMEZON vault not wired");
        require(staking.tierCount() == 3, "tiers not set");
        // A non-staker must pay the base fee: the discount is an incentive,
        // never a gate, and a tier that fired for an empty balance would mean
        // everyone trades at a discount and reserves are never topped up.
        require(
            IssuanceVault(gologgleVault).effectiveFeeBps(deployer) == FEE_BPS,
            "a non-staker should pay the full fee"
        );
        require(staking.totalSupply() == 0, "staking should start empty");
    }
}
