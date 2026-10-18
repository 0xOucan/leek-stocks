// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LeekStaking} from "../src/LeekStaking.sol";
import {MockMUSD} from "./mocks/MockMUSD.sol";
import {MockFalseToken} from "./mocks/MockFalseToken.sol";

/**
 * Splitting one increase into many small ones must not shorten the wait.
 *
 * The first cooldown reset the clock outright, which let a stranger grief a
 * staker with one wei. The fix made the extension proportional to the
 * increase — and took it as a `max` of instantaneous fractions. Every step in
 * one transaction shares a timestamp, so the max is just the largest single
 * fraction: growing a position 1000x in 1% steps waited 1% of a cooldown
 * rather than a cooldown, and the flash-stake attack came back.
 *
 * The extension accumulates now, so n small steps cost more than one large
 * one rather than less.
 */
contract CooldownSplitTest is Test {
    MockMUSD mezo;
    MockMUSD musd;
    LeekStaking staking;
    address attacker = makeAddr("attacker");
    uint256 constant ONE = 1e18;
    uint256 constant COOLDOWN = 1 hours;

    function setUp() public {
        vm.warp(1_700_000_000);
        mezo = new MockMUSD(18);
        musd = new MockMUSD(18);
        staking = new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), address(this), COOLDOWN);
        mezo.mint(attacker, 1_000_000_000 * ONE);
        vm.prank(attacker);
        mezo.approve(address(staking), type(uint256).max);
    }

    function test_growingAPositionInSmallStepsCostsMoreNotLess() public {
        // A matured base position, the one-off setup the attack reuses.
        vm.prank(attacker);
        staking.stake(1_000 * ONE);
        skip(COOLDOWN);
        assertLe(staking.coolingUntil(attacker), block.timestamp);

        // Now grow it ~100x in 1% steps, all in one transaction.
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 500; ++i) {
            staking.stake(staking.balanceOf(attacker) / 100);
        }
        vm.stopPrank();

        uint256 wait_ = staking.coolingUntil(attacker) - block.timestamp;
        emit log_named_uint("position grown to (whole tokens)", staking.balanceOf(attacker) / ONE);
        emit log_named_uint("seconds that must now elapse    ", wait_);
        emit log_named_uint("one cooldown is                 ", COOLDOWN);

        // Accumulated, so many small steps are worse for the attacker than a
        // single large one. Before this it was ~35 seconds.
        assertGt(wait_, COOLDOWN, "splitting the increase shortened the wait");
    }

    function test_aSingleLargeIncreaseStillCostsAboutOneCooldown() public {
        vm.prank(attacker);
        staking.stake(1_000 * ONE);
        skip(COOLDOWN);

        // Doubling adds half a cooldown, as documented.
        vm.prank(attacker);
        staking.stake(1_000 * ONE);
        assertEq(staking.coolingUntil(attacker) - block.timestamp, COOLDOWN / 2);
    }

    function test_dustStillAddsNothingSoTheGriefStaysClosed() public {
        vm.prank(attacker);
        staking.stake(100_000 * ONE);
        skip(COOLDOWN);

        address griefer = makeAddr("griefer");
        mezo.mint(griefer, 1_000 * ONE);
        vm.startPrank(griefer);
        mezo.approve(address(staking), type(uint256).max);
        staking.stake(1_000 * ONE);
        skip(COOLDOWN);
        staking.transfer(attacker, 1);
        vm.stopPrank();

        assertLe(staking.coolingUntil(attacker), block.timestamp, "dust re-acquired griefing power");
    }
}

/**
 * A reward token that returns false must not destroy a staker's claim.
 */
contract FalseReturnPayoutTest is Test {
    MockMUSD mezo;
    MockFalseToken musd;
    LeekStaking staking;
    address alice = makeAddr("alice");
    uint256 constant ONE = 1e18;
    uint256 constant COOLDOWN = 1 hours;

    function setUp() public {
        vm.warp(1_700_000_000);
        mezo = new MockMUSD(18);
        musd = new MockFalseToken();
        staking = new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), address(this), COOLDOWN);
        mezo.mint(alice, 1_000 * ONE);
        vm.prank(alice);
        mezo.approve(address(staking), type(uint256).max);
    }

    function test_aFalseReturnLeavesTheClaimIntactRatherThanZeroingIt() public {
        vm.prank(alice);
        staking.stake(1_000 * ONE);
        musd.mint(address(staking), 500 * ONE);
        staking.notifyReward();
        assertEq(staking.pending(alice), 500 * ONE);

        skip(COOLDOWN);
        musd.setFailTransfers(true);

        vm.prank(alice);
        staking.unstake(1_000 * ONE);

        // The principal comes back, and the reward is still owed to her
        // rather than silently redistributed to whoever stakes next.
        assertEq(mezo.balanceOf(alice), 1_000 * ONE, "the principal did not come back");
        assertEq(staking.pending(alice), 500 * ONE, "the claim was destroyed by a false return");
        assertEq(musd.balanceOf(alice), 0);
        assertEq(staking.rewardsOwed(), 500 * ONE, "the liability was dropped");

        // And once the token behaves, she can collect.
        musd.setFailTransfers(false);
        vm.prank(alice);
        assertEq(staking.claim(), 500 * ONE);
        assertEq(musd.balanceOf(alice), 500 * ONE);
    }
}
