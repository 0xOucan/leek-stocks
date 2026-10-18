// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {ETFFactory} from "../src/ETFFactory.sol";
import {IssuanceVault} from "../src/IssuanceVault.sol";
import {LeekStaking} from "../src/LeekStaking.sol";
import {ILeekStaking} from "../src/interfaces/ILeekStaking.sol";

/**
 * @title ConfigureMezoTestnet
 * @notice Phase two: everything that needs the admin key.
 *
 * @dev `DeployMezoTestnet` deploys the factory, the oracles and their first
 *      rounds, hands every role to ADMIN and renounces the deployer's. That
 *      leaves the admin-gated steps - registering each index, deploying each
 *      pair, setting the staking tiers and wiring the vaults - and this is
 *      the script that performs them.
 *
 *      Why two scripts at all: the single script required ADMIN to be the
 *      sender, so the only configuration that could complete left one hot
 *      key as DEFAULT_ADMIN_ROLE on nine contracts with nothing renounced.
 *      That key is what made both reserve drains in test/AdminTheft.t.sol
 *      reachable, and no amount of care in a runbook fixes a script that
 *      cannot express the safe arrangement.
 *
 *      A one-key testnet deployment never reaches this script: phase one
 *      does it all inline when ADMIN is the sender, which keeps the common
 *      path a single command.
 *
 *      Intended invocation, from the multisig or admin key:
 *
 *      FACTORY=0x... GOLOGGLE_ORACLE=0x... AMEZON_ORACLE=0x... \
 *      MEZO_TOKEN=0x... SETTLEMENT_TOKEN=0x... \
 *      forge script script/ConfigureMezoTestnet.s.sol \
 *        --rpc-url mezo_testnet --account <admin> --sender <admin> \
 *        --broadcast --slow
 *
 *      `--slow` because mezod reports a sequence rather than a nonce and
 *      refuses a transaction built from a stale one.
 */
contract ConfigureMezoTestnet is Script {
    uint256 constant MEZO_TESTNET_CHAIN_ID = 31611;

    /* The same values as phase one. Duplicated deliberately rather than
       imported: these are the numbers an admin is agreeing to when they sign,
       and a reviewer should be able to read them here without opening another
       file. The assertions at the end compare what landed against them. */
    uint32 constant MAX_STALENESS = 1 hours;
    uint16 constant FEE_BPS = 50;
    uint16 constant RESERVE_SHARE_BPS = 5000;
    uint256 constant MAX_SHARES = 1_000_000e18;
    uint256 constant STAKING_COOLDOWN = 1 hours;

    uint256 constant TIER_1_STAKE = 100e18;
    uint16 constant TIER_1_DISCOUNT_BPS = 1_000;
    uint256 constant TIER_2_STAKE = 1_000e18;
    uint16 constant TIER_2_DISCOUNT_BPS = 2_500;
    uint256 constant TIER_3_STAKE = 5_000e18;
    uint16 constant TIER_3_DISCOUNT_BPS = 5_000;

    /* Held as fields rather than locals because run() otherwise exceeds the
       EVM's stack: every one of these is an address that has to be read, used
       and logged. A script contract is ephemeral, so there is no storage cost
       that matters and no state anyone else can see. */
    address admin;
    ETFFactory factory;
    IndexOracle gologgleOracle;
    IndexOracle amezonOracle;
    address settlementToken;
    address mezoToken;
    address guardian;
    address treasurer;

    function run() external {
        admin = msg.sender;
        factory = ETFFactory(vm.envAddress("FACTORY"));
        gologgleOracle = IndexOracle(vm.envAddress("GOLOGGLE_ORACLE"));
        amezonOracle = IndexOracle(vm.envAddress("AMEZON_ORACLE"));
        settlementToken = vm.envAddress("SETTLEMENT_TOKEN");
        mezoToken = vm.envAddress("MEZO_TOKEN");

        guardian = vm.envOr("GUARDIAN", admin);
        treasurer = vm.envOr("TREASURER", admin);

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

        uint256 allowed = vm.envOr("ALLOW_CHAIN_ID", uint256(0));
        if (allowed != 0 && allowed == block.chainid) {
            console2.log("!! REHEARSAL on chain", block.chainid);
        } else {
            require(block.chainid == MEZO_TESTNET_CHAIN_ID, "wrong chain: expected Mezo testnet 31611");
        }

        /* Refuse before signing anything, rather than reverting halfway and
           leaving one index registered and the other not. */
        require(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin), "sender is not the factory admin");
        require(address(factory.musd()) == settlementToken, "factory settles in a different token");
        require(gologgleOracle.latestRound() != 0, "GOLOGGLE oracle has no first round");
        require(amezonOracle.latestRound() != 0, "AMEZON oracle has no first round");

        vm.startBroadcast();

        factory.registerIndex(
            "GOLOGGLE", gologgleOracle, MAX_STALENESS, FEE_BPS, RESERVE_SHARE_BPS, MAX_SHARES, guardian, treasurer
        );
        factory.registerIndex(
            "AMEZON", amezonOracle, MAX_STALENESS, FEE_BPS, RESERVE_SHARE_BPS, MAX_SHARES, guardian, treasurer
        );

        (address gologgleShare, address gologgleVault) = factory.deployETF("Gologgle Index", "GOLOGGLE");
        (address amezonShare, address amezonVault) = factory.deployETF("Amezon Index", "AMEZON");

        LeekStaking staking = new LeekStaking(IERC20(mezoToken), IERC20(settlementToken), admin, STAKING_COOLDOWN);

        LeekStaking.Tier[] memory tiers = new LeekStaking.Tier[](3);
        tiers[0] = LeekStaking.Tier(TIER_1_STAKE, TIER_1_DISCOUNT_BPS);
        tiers[1] = LeekStaking.Tier(TIER_2_STAKE, TIER_2_DISCOUNT_BPS);
        tiers[2] = LeekStaking.Tier(TIER_3_STAKE, TIER_3_DISCOUNT_BPS);
        staking.setTiers(tiers);

        IssuanceVault(gologgleVault).setStaking(ILeekStaking(address(staking)));
        IssuanceVault(amezonVault).setStaking(ILeekStaking(address(staking)));

        vm.stopBroadcast();

        _verify(staking, gologgleVault, amezonVault);

        console2.log("GOLOGGLE share    ", gologgleShare);
        console2.log("GOLOGGLE vault    ", gologgleVault);
        console2.log("AMEZON share      ", amezonShare);
        console2.log("AMEZON vault      ", amezonVault);
        console2.log("staking (sMEZO)   ", address(staking));
        console2.log("price of a share  ", IssuanceVault(gologgleVault).price());
    }

    /// @dev Read back what landed, not what was intended.
    function _verify(LeekStaking staking, address gologgleVault, address amezonVault) internal view {
        require(address(IssuanceVault(gologgleVault).staking()) == address(staking), "GOLOGGLE vault not wired");
        require(address(IssuanceVault(amezonVault).staking()) == address(staking), "AMEZON vault not wired");
        require(staking.tierCount() == 3, "tiers not set");
        require(staking.cooldown() == STAKING_COOLDOWN, "cooldown wrong");
        require(staking.totalSupply() == 0, "staking should start empty");
        require(IssuanceVault(gologgleVault).effectiveFeeBps(admin) == FEE_BPS, "a non-staker should pay full fee");
        require(
            IssuanceVault(gologgleVault).hasRole(IssuanceVault(gologgleVault).DEFAULT_ADMIN_ROLE(), admin),
            "vault admin was not handed over"
        );
    }
}
