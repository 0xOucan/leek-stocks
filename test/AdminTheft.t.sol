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
 * Two paths that USED to empty the reserve pot, now refused.
 *
 * Both exist because of one fact about OpenZeppelin's AccessControl that none
 * of these contracts overrides: `getRoleAdmin` defaults to
 * DEFAULT_ADMIN_ROLE for every role, and nothing calls `_setRoleAdmin`. So a
 * DEFAULT_ADMIN_ROLE holder can grant itself any other role on that same
 * contract. The role separation these contracts document - the key that
 * pushes prices cannot pause the feed, the treasurer cannot touch reserves -
 * is real between *distinct* keys and nominal against the admin.
 *
 * Both were demonstrated against the previous code; the numbers are in the
 * commit that added this file. These tests now assert the refusal, so they
 * fail again if either guard is removed.
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

    /* Cached in setUp, not read inline.
     *
     * `share.MINTER_ROLE()` is a call, so writing
     *     vm.expectRevert(); share.grantRole(MINTER, admin);
     * applies the expectation to the getter, which does not revert, and the
     * test fails with "next call did not revert as expected" while the
     * contract is behaving correctly. Same trap as vm.prank being eaten by a
     * view call. */
    bytes32 MINTER;
    bytes32 BURNER;

    function setUp() public {
        vm.warp(1_700_000_000);
        musd = new MockMUSD(18);
        oracle = new IndexOracle("GOLOGGLE / MUSD", 8, 2000, 1 hours, 30, 1 hours, 2000, admin, publisher, guardian);
        vm.prank(publisher);
        oracle.publish(100e8);

        factory = new ETFFactory(IERC20(address(musd)), admin);
        vm.prank(admin);
        factory.registerIndex("GOLOGGLE", oracle, 1 hours, 50, 5000, 1_000_000e18, guardian, treasury);
        vm.prank(admin);
        (address s, address v) = factory.deployETF("Gologgle Index", "GOLOGGLE");
        share = ETFShare(s);
        vault = IssuanceVault(v);

        MINTER = share.MINTER_ROLE();
        BURNER = share.BURNER_ROLE();

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
    function test_theShareAdminCannotGrantItselfTheMinterRole() public {
        uint256 reservesBefore = vault.reserves();
        assertGt(reservesBefore, 99_000e18, "the victim's MUSD is not in the vault");

        // MINTER_ROLE administers itself, so DEFAULT_ADMIN_ROLE cannot grant
        // it and the holder set is whatever the constructor established. This
        // was the first step of the drain.
        vm.prank(admin);
        vm.expectRevert();
        share.grantRole(MINTER, admin);

        vm.prank(admin);
        vm.expectRevert();
        share.grantRole(BURNER, admin);

        // The vault is still the only minter and burner, and the reserves are
        // untouched.
        assertTrue(share.hasRole(MINTER, address(vault)));
        assertFalse(share.hasRole(MINTER, admin));
        assertEq(vault.reserves(), reservesBefore);
    }

    function test_mintIsBoundedByTheCapWhoeverCallsIt() public {
        // The second half of the fix: even a legitimate minter cannot exceed
        // the cap, so the bound does not depend on the caller checking it.
        uint256 cap = share.maxSupply();
        assertEq(cap, vault.maxShares(), "the share and the vault disagree on the cap");

        // Every read hoisted: an argument expression evaluated after
        // vm.expectRevert consumes the expectation.
        uint256 supply = share.totalSupply();
        uint256 overTheCap = cap + 1 - supply;

        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(ETFShare.CapExceeded.selector, cap + 1, cap));
        share.mint(admin, overTheCap);

        // And exactly at the cap is allowed, so the bound is a cap and not an
        // off-by-one that forbids the last share.
        vm.prank(address(vault));
        share.mint(admin, cap - supply);
        assertEq(share.totalSupply(), cap);
    }

    function test_theDrainIsNoLongerReachableEndToEnd() public {
        uint256 reservesBefore = vault.reserves();

        vm.startPrank(admin);
        // Every step of the original sequence, each expected to fail.
        vm.expectRevert();
        share.grantRole(MINTER, admin);
        vm.expectRevert();
        share.mint(admin, 1000e18);
        vm.stopPrank();

        assertEq(vault.reserves(), reservesBefore, "reserves moved");
        assertEq(musd.balanceOf(admin), 0, "the admin took MUSD");
    }

    function _unusedOldDrain() internal {
        uint256 reservesBefore = vault.reserves();
        vm.startPrank(admin);
        share.grantRole(MINTER, admin);

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

    /**
     * The 20% deviation bound is per round, and nothing requires time between
     * rounds. So it compounds per transaction rather than per hour, and the
     * guardian cannot react inside a single block.
     */
    function test_aBurstOfRoundsInOneBlockIsRefused() public {
        vm.startPrank(publisher);
        // The first round of the burst is fine: it is 20% and the interval has
        // elapsed since setUp.
        vm.warp(block.timestamp + 30);
        oracle.publish(120e8);
        // The second in the same block is not, which is what breaks the
        // atomic buy-pump-redeem.
        vm.expectRevert(abi.encodeWithSelector(IndexOracle.TooSoon.selector, 0, 30));
        oracle.publish(144e8);
        vm.stopPrank();
    }

    function test_anAnswerLargeEnoughToBrickTheFeedIsRefused() public {
        // Round 1 is exempt from the deviation bound, so before MAX_ANSWER
        // this was the one value with no bound at all: a first answer of 1e75
        // made every later publish overflow `previous * 10_000` forever, with
        // no way to reset a round.
        vm.prank(publisher);
        vm.warp(block.timestamp + 30);
        vm.expectRevert(abi.encodeWithSelector(IndexOracle.AnswerTooLarge.selector, int256(1e75)));
        oracle.publish(1e75);
    }

    function test_theFeedStillPublishesAtItsNormalCadence() public {
        // The guard must not break the real feed, which attempts a publish
        // every 60 seconds.
        vm.startPrank(publisher);
        for (uint256 i = 0; i < 5; ++i) {
            vm.warp(block.timestamp + 60);
            oracle.publish(100e8 + int256(i) * 1e8);
        }
        vm.stopPrank();
        assertEq(vault.price(), 104e18);
    }

    function _unusedOldPump() internal {
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

    function test_theMintAndBurnRolesAreTheOnesTakenAwayFromTheAdmin() public {
        /* Honest about what is and is not fixed.
         *
         * The admin can still self-grant PUBLISHER, GUARDIAN and TREASURER:
         * those roles still default to DEFAULT_ADMIN_ROLE as their own
         * administrator, and taking that away would leave no way to rotate a
         * lost publisher key. What matters is that none of them can print
         * shares or move reserves, so the worst an admin reaches is the fee
         * stream and the pause switch - which is the centralisation the
         * README already documents and the deploy brief tells an operator to
         * split across keys.
         *
         * MINTER and BURNER are different in kind, because they mint value
         * from nothing, and those are now frozen.
         */
        vm.startPrank(admin);
        vm.expectRevert();
        share.grantRole(MINTER, admin);
        vm.expectRevert();
        share.grantRole(BURNER, admin);

        // Still grantable, deliberately.
        oracle.grantRole(oracle.PUBLISHER_ROLE(), admin);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), admin);
        vault.grantRole(vault.TREASURER_ROLE(), admin);
        vault.grantRole(vault.GUARDIAN_ROLE(), admin);
        vm.stopPrank();

        assertFalse(share.hasRole(MINTER, admin));
        assertFalse(share.hasRole(BURNER, admin));
        assertTrue(oracle.hasRole(oracle.PUBLISHER_ROLE(), admin));
        assertTrue(vault.hasRole(vault.TREASURER_ROLE(), admin));
        // So "the key that pushes prices cannot pause the feed" holds only
        // between distinct non-admin keys.
        assertTrue(oracle.hasRole(oracle.GUARDIAN_ROLE(), admin));
    }
}
