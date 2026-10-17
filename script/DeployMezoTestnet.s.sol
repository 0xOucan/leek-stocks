// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {ETFFactory} from "../src/ETFFactory.sol";
import {IssuanceVault} from "../src/IssuanceVault.sol";

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

    /// @dev The real MUSD on Mezo testnet, 18 decimals, verified source.
    ///      Overridable with SETTLEMENT_TOKEN only so a fork or a local chain
    ///      can run the same script.
    address constant DEFAULT_SETTLEMENT_TOKEN = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;

    /// @dev Finding L-5: MUSD is upgradeable and the vault caches `decimals()`
    ///      at construction, so the live value is asserted here, before
    ///      anything is deployed against it, rather than trusted.
    uint8 constant EXPECTED_MUSD_DECIMALS = 18;

    /* -------------------------------------------------------- oracle parameters */

    uint8 constant FEED_DECIMALS = 8; // Chainlink's USD convention
    uint16 constant MAX_DEVIATION_BPS = 2000; // 20% per round, immutable once set
    uint32 constant MAX_STALENESS = 1 hours;

    /* --------------------------------------------------------- vault parameters */

    uint16 constant FEE_BPS = 50; // 0.5%, against MAX_FEE_BPS of 500
    uint256 constant MAX_SHARES = 1_000_000e18; // finding H-1's only bound on exposure

    /* ------------------------------------------------------------- the indices */

    string constant GOLOGGLE_SYMBOL = "GOLOGGLE";
    string constant GOLOGGLE_NAME = "Gologgle Index";
    string constant GOLOGGLE_FEED = "GOLOGGLE / MUSD";
    /// @dev Finding L-1: the first round is exempt from the deviation bound,
    ///      so it is the one answer a publisher sets freely. It is a constant
    ///      here, published in this same reviewed step, and it should be read
    ///      off the explorer before anything consumes the feed.
    int256 constant GOLOGGLE_FIRST_ANSWER = 200e8; // 200 MUSD per share

    string constant AMEZON_SYMBOL = "AMEZON";
    string constant AMEZON_NAME = "Amezon Index";
    string constant AMEZON_FEED = "AMEZON / MUSD";
    int256 constant AMEZON_FIRST_ANSWER = 180e8;

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
        publisher = vm.envOr("PUBLISHER", deployer);
        guardian = vm.envOr("GUARDIAN", deployer);
        treasurer = vm.envOr("TREASURER", deployer);

        require(block.chainid == MEZO_TESTNET_CHAIN_ID, "wrong chain: expected Mezo testnet 31611");
        // L-5, enforced rather than written on a checklist.
        require(
            IERC20Metadata(settlementToken).decimals() == EXPECTED_MUSD_DECIMALS,
            "settlement token decimals are not 18: the vault would misprice by a power of ten"
        );

        if (admin == deployer && publisher == deployer && guardian == deployer && treasurer == deployer) {
            console2.log("WARNING: one key holds admin, publisher, guardian and treasurer. Testnet only.");
        }

        vm.startBroadcast();

        ETFFactory factory = new ETFFactory(IERC20(settlementToken), admin);

        IndexOracle gologgleOracle =
            _deployOracleAndPublishFirstRound(GOLOGGLE_FEED, GOLOGGLE_FIRST_ANSWER, deployer);
        IndexOracle amezonOracle = _deployOracleAndPublishFirstRound(AMEZON_FEED, AMEZON_FIRST_ANSWER, deployer);

        // registerIndex is admin-gated, so a deployment whose admin is a
        // separate key stops here and the admin finishes it. Said out loud
        // instead of silently reverting.
        require(admin == deployer, "ADMIN is not the sender: the admin must call registerIndex/deployETF itself");

        factory.registerIndex(GOLOGGLE_SYMBOL, gologgleOracle, MAX_STALENESS, FEE_BPS, MAX_SHARES, guardian, treasurer);
        factory.registerIndex(AMEZON_SYMBOL, amezonOracle, MAX_STALENESS, FEE_BPS, MAX_SHARES, guardian, treasurer);

        (address gologgleShare, address gologgleVault) = factory.deployETF(GOLOGGLE_NAME, GOLOGGLE_SYMBOL);
        (address amezonShare, address amezonVault) = factory.deployETF(AMEZON_NAME, AMEZON_SYMBOL);

        vm.stopBroadcast();

        console2.log("settlement token  ", settlementToken);
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
            feedDescription, FEED_DECIMALS, MAX_DEVIATION_BPS, MAX_STALENESS, deployer, deployer, deployer
        );
        oracle.publish(firstAnswer);

        if (publisher != deployer) oracle.grantRole(oracle.PUBLISHER_ROLE(), publisher);
        if (guardian != deployer) oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);
        if (admin != deployer) oracle.grantRole(oracle.DEFAULT_ADMIN_ROLE(), admin);

        if (publisher != deployer) oracle.renounceRole(oracle.PUBLISHER_ROLE(), deployer);
        if (guardian != deployer) oracle.renounceRole(oracle.GUARDIAN_ROLE(), deployer);
        // Last, since renouncing admin first would strip the ability to grant.
        if (admin != deployer) oracle.renounceRole(oracle.DEFAULT_ADMIN_ROLE(), deployer);
    }
}
