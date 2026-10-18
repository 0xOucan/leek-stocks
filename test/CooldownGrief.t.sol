// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LeekStaking} from "../src/LeekStaking.sol";
import {MockMUSD} from "./mocks/MockMUSD.sol";

/**
 * The cooldown must not become a weapon.
 *
 * The first version of the holding period reset outright on any balance
 * increase, so anybody could send one wei of sMEZO to a staker who had
 * finished waiting and restart their whole cooldown - repeatably, for dust.
 * The position was never at risk; the holder simply could not leave. The
 * extension is proportional to the increase now, so a wei buys the griefer
 * nothing while a fresh receipt still waits in full.
 */
contract CooldownGriefTest is Test {
    MockMUSD mezo;
    MockMUSD musd;
    LeekStaking staking;
    address alice = makeAddr("alice");
    address griefer = makeAddr("griefer");
    uint256 constant ONE = 1e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        mezo = new MockMUSD(18);
        musd = new MockMUSD(18);
        staking = new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), address(this), 1 hours);
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? alice : griefer;
            mezo.mint(who, 1_000 * ONE);
            vm.prank(who);
            mezo.approve(address(staking), type(uint256).max);
        }
    }

    function test_oneWeiCannotResetAnotherStakersCooldown() public {
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(griefer);
        staking.stake(1 * ONE);
        skip(1 hours);

        // Alice has waited out the cooldown and can leave.
        // The griefer sends her one wei of sMEZO.
        vm.prank(griefer);
        staking.transfer(alice, 1);

        // She can still leave: the extension was cooldown * 1 / (100e18 + 1),
        // which truncates to zero.
        assertLe(staking.coolingUntil(alice), block.timestamp, "one wei moved the deadline");
        vm.prank(alice);
        staking.unstake(100 * ONE);
        assertEq(staking.balanceOf(alice), 1, "only the griefer's wei should remain");
    }

    function test_repeatedDustCannotAccumulateIntoALock() public {
        vm.prank(alice);
        staking.stake(100 * ONE);
        vm.prank(griefer);
        staking.stake(100 * ONE);
        skip(1 hours);

        // A hundred attempts, which is the realistic shape of the grief.
        for (uint256 i = 0; i < 100; ++i) {
            vm.prank(griefer);
            staking.transfer(alice, 1);
        }
        assertLe(staking.coolingUntil(alice), block.timestamp, "dust accumulated into a lock");

        vm.prank(alice);
        staking.unstake(100 * ONE);
    }

    function test_aFreshRecipientStillWaitsTheFullCooldown() public {
        // The other half: the proportional extension must not weaken the
        // rental defence.
        vm.prank(alice);
        staking.stake(100 * ONE);
        skip(1 hours);

        address renter = makeAddr("renter");
        vm.prank(alice);
        staking.transfer(renter, 100 * ONE);

        assertEq(staking.coolingUntil(renter), block.timestamp + 1 hours, "a fresh position did not cool in full");
        vm.prank(renter);
        vm.expectRevert(abi.encodeWithSelector(LeekStaking.StillCooling.selector, 1 hours));
        staking.unstake(100 * ONE);
    }

    function test_doublingAPositionAddsHalfACooldown() public {
        vm.prank(alice);
        staking.stake(100 * ONE);
        skip(1 hours);
        vm.prank(alice);
        staking.stake(100 * ONE);

        // cooldown * 100e18 / 200e18 = half.
        assertEq(staking.coolingUntil(alice), block.timestamp + 30 minutes);
    }
}
