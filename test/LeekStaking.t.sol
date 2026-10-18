// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {LeekStaking} from "../src/LeekStaking.sol";
import {MockMUSD} from "./mocks/MockMUSD.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";

/**
 * What decides whether this staking contract is honest.
 *
 * Not the getters, and not that `stake` increases a balance. The properties
 * that matter are the ones where being wrong silently moves someone else's
 * money: that a distribution reaches only the people staked at the time, that
 * a transfer of sMEZO carries future entitlement but not past entitlement,
 * that the contract can always pay what it says it owes, and that MUSD
 * arriving with nobody staked is neither stranded nor handed to whoever
 * happens to arrive next.
 */
contract LeekStakingTest is Test {
    MockMUSD mezo;
    MockMUSD musd;
    LeekStaking staking;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant ONE = 1e18;

    /// The oracle-independent holding period the staking contract enforces.
    uint256 constant COOLDOWN = 1 hours;
    function setUp() public {
        mezo = new MockMUSD(18);
        musd = new MockMUSD(18);
        staking = new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), admin, COOLDOWN);

        for (uint256 i = 0; i < 3; ++i) {
            address who = [alice, bob, carol][i];
            mezo.mint(who, 1_000 * ONE);
            vm.prank(who);
            mezo.approve(address(staking), type(uint256).max);
        }
    }

    /// Put MUSD in and account for it, the way the vault will.
    function _fund(uint256 amount) internal {
        musd.mint(address(staking), amount);
        staking.notifyReward();
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.stake(amount);
    }

    /**
     * Stake and wait out the cooldown.
     *
     * Most tests here are about reward arithmetic or discount tiers, not
     * about the holding period, and a stake that cannot be unstaked makes
     * those tests assert the cooldown by accident. The cooldown has its own
     * tests at the bottom of this file.
     */
    function _stakeAndWait(address who, uint256 amount) internal {
        _stake(who, amount);
        skip(1 hours);
    }

    /* ------------------------------------------------------- distribution */

    function test_revenueSplitsByStake() public {
        _stake(alice, 100 * ONE);
        _stake(bob, 300 * ONE);

        _fund(40 * ONE);

        // 1:3, so 10 and 30.
        assertEq(staking.pending(alice), 10 * ONE);
        assertEq(staking.pending(bob), 30 * ONE);
    }

    function test_aStakerWhoArrivesAfterwardsEarnsNothingFromThePast() public {
        _stake(alice, 100 * ONE);
        _fund(10 * ONE);

        _stake(bob, 100 * ONE);

        // The whole point of the accumulator. Bob was not staked when that
        // revenue was earned, so none of it is his.
        assertEq(staking.pending(bob), 0);
        assertEq(staking.pending(alice), 10 * ONE);

        _fund(10 * ONE);
        assertEq(staking.pending(alice), 15 * ONE);
        assertEq(staking.pending(bob), 5 * ONE);
    }

    function test_unstakingStopsFutureEarningsButKeepsPastOnes() public {
        _stakeAndWait(alice, 100 * ONE);
        _stakeAndWait(bob, 100 * ONE);
        _fund(10 * ONE);

        // Alice leaves. Her 5 MUSD is paid out with the stake, not forfeited.
        uint256 before = musd.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(100 * ONE);
        assertEq(musd.balanceOf(alice) - before, 5 * ONE);
        assertEq(mezo.balanceOf(alice), 1_000 * ONE);

        // The next distribution is entirely Bob's.
        _fund(10 * ONE);
        assertEq(staking.pending(alice), 0);
        assertEq(staking.pending(bob), 15 * ONE);
    }

    function test_claimLeavesTheStakeEarning() public {
        _stake(alice, 100 * ONE);
        _fund(10 * ONE);

        vm.prank(alice);
        staking.claim();
        assertEq(musd.balanceOf(alice), 10 * ONE);
        assertEq(staking.balanceOf(alice), 100 * ONE);

        _fund(10 * ONE);
        assertEq(staking.pending(alice), 10 * ONE);
    }

    function test_claimingTwicePaysOnce() public {
        _stake(alice, 100 * ONE);
        _fund(10 * ONE);

        vm.prank(alice);
        staking.claim();
        vm.prank(alice);
        vm.expectRevert(LeekStaking.ZeroAmount.selector);
        staking.claim();
        assertEq(musd.balanceOf(alice), 10 * ONE);
    }

    /* ----------------------------------------------- the transferable part */

    function test_transferCarriesFutureEarningsButNotPastOnes() public {
        _stake(alice, 100 * ONE);
        _fund(10 * ONE);

        // Alice has earned 10. Moving the position must not move that.
        vm.prank(alice);
        staking.transfer(bob, 100 * ONE);

        assertEq(staking.pending(alice), 10 * ONE, "the sender lost earnings she had already made");
        assertEq(staking.pending(bob), 0, "the receiver inherited earnings from before he held anything");

        // From here the position earns for Bob.
        _fund(10 * ONE);
        assertEq(staking.pending(alice), 10 * ONE);
        assertEq(staking.pending(bob), 10 * ONE);
    }

    function test_aSelfTransferChangesNothing() public {
        _stake(alice, 100 * ONE);
        _fund(10 * ONE);

        vm.prank(alice);
        staking.transfer(alice, 40 * ONE);

        assertEq(staking.balanceOf(alice), 100 * ONE);
        assertEq(staking.pending(alice), 10 * ONE);
    }

    function test_aPartialTransferSplitsFutureEarningsOnly() public {
        _stake(alice, 100 * ONE);
        _fund(10 * ONE);

        vm.prank(alice);
        staking.transfer(bob, 25 * ONE);

        _fund(10 * ONE);
        // 75/25 of the second distribution, plus all of the first for Alice.
        assertEq(staking.pending(alice), 10 * ONE + 7.5 * 1e18);
        assertEq(staking.pending(bob), 2.5 * 1e18);
    }

    /* --------------------------------------------------- the empty state */

    function test_revenueWithNobodyStakedIsRefusedRatherThanStranded() public {
        musd.mint(address(staking), 10 * ONE);
        vm.expectRevert(LeekStaking.NoStakers.selector);
        staking.notifyReward();
    }

    function test_aFirstStakerDoesNotInheritAWindfall() public {
        // MUSD that arrived while nobody was staked is still unaccounted, so
        // the revert above is what keeps the vault from routing it. Once
        // someone stakes, that balance would be distributable - which is why
        // the vault checks totalSupply() before it ever sends.
        musd.mint(address(staking), 10 * ONE);
        _stake(alice, 100 * ONE);
        assertEq(staking.pending(alice), 0, "a stake alone must not credit anything");
    }

    function test_distributingNothingIsANoOpRatherThanARevert() public {
        /* It used to revert. A revert here is fine on its own, but the vault
           calls notifyReward on every trade, so any revert in this function
           is a revert in buy() and redeem() - and the one that mattered was
           the unchecked `held - rewardsOwed`, which an upgraded MUSD could
           make permanent. Both are no-ops now, and the vault additionally
           wraps the call. */
        _stake(alice, 100 * ONE);
        assertEq(staking.notifyReward(), 0);
        assertEq(staking.accMusdPerShare(), 0);
        assertEq(staking.pending(alice), 0);
    }

    /* ----------------------------------------------------------- rounding */

    function test_aRewardTooSmallToSplitIsKeptNotLost() public {
        // A huge stake and one wei: perShare truncates to zero.
        _stake(alice, 1_000 * ONE);
        musd.mint(address(staking), 1);
        uint256 distributed = staking.notifyReward();

        assertEq(distributed, 0);
        assertEq(staking.unallocated(), 1, "the dust left the accounting");
        assertEq(staking.accMusdPerShare(), 0);

        // It joins the next one rather than vanishing.
        musd.mint(address(staking), 10 * ONE);
        staking.notifyReward();
        assertEq(staking.pending(alice), 10 * ONE + 1 - (10 * ONE + 1) % 1_000);
    }

    function test_theContractNeverOwesMoreThanItHolds() public {
        _stake(alice, 3 * ONE);
        _stake(bob, 7 * ONE);
        _fund(1e18 + 7); // deliberately indivisible by the supply

        uint256 owed = staking.pending(alice) + staking.pending(bob);
        assertLe(owed, musd.balanceOf(address(staking)), "rounding created a claim the contract cannot pay");
    }

    /* ------------------------------------------- fee-on-transfer staking */

    function test_sMezoIsMintedFromWhatArrivedNotWhatWasAsked() public {
        MockFeeToken fot = new MockFeeToken(100); // 1%
        LeekStaking s = new LeekStaking(IERC20(address(fot)), IERC20(address(musd)), admin, COOLDOWN);
        fot.mint(alice, 1_000 * ONE);
        vm.startPrank(alice);
        fot.approve(address(s), type(uint256).max);
        s.stake(100 * ONE);
        vm.stopPrank();
        skip(1 hours);

        // 1% was taken in flight, so 99 arrived and 99 sMEZO must exist.
        assertEq(s.totalSupply(), 99 * ONE);
        assertEq(fot.balanceOf(address(s)), 99 * ONE);

        // And the last staker out can actually leave.
        vm.prank(alice);
        s.unstake(99 * ONE);
        assertEq(s.totalSupply(), 0);
    }

    /* ---------------------------------------------------------- discounts */

    function _threeTiers() internal {
        LeekStaking.Tier[] memory t = new LeekStaking.Tier[](3);
        t[0] = LeekStaking.Tier(100 * ONE, 1_000);
        t[1] = LeekStaking.Tier(1_000 * ONE, 2_500);
        t[2] = LeekStaking.Tier(5_000 * ONE, 5_000);
        vm.prank(admin);
        staking.setTiers(t);
    }

    function test_aNonStakerGetsNoDiscountAndIsNotBlocked() public {
        _threeTiers();
        assertEq(staking.discountBpsFor(alice), 0);
    }

    function test_theDiscountIsTheHighestTierReached() public {
        _threeTiers();
        _stakeAndWait(alice, 100 * ONE);
        assertEq(staking.discountBpsFor(alice), 1_000);

        mezo.mint(alice, 5_000 * ONE);
        _stakeAndWait(alice, 900 * ONE);
        assertEq(staking.discountBpsFor(alice), 2_500);

        _stakeAndWait(alice, 4_000 * ONE);
        assertEq(staking.discountBpsFor(alice), 5_000);
    }

    function test_oneWeiBelowATierDoesNotEarnIt() public {
        _threeTiers();
        _stakeAndWait(alice, 100 * ONE - 1);
        assertEq(staking.discountBpsFor(alice), 0);
    }

    function test_sendingTheReceiptAwayMovesTheDiscountButResetsItsClock() public {
        // Two consequences of transferability, both worth asserting rather
        // than discovering: the discount follows the balance and not the
        // staker, and it arrives un-earned.
        _threeTiers();
        _stakeAndWait(alice, 100 * ONE);
        assertEq(staking.discountBpsFor(alice), 1_000);

        vm.prank(alice);
        staking.transfer(bob, 100 * ONE);

        // Alice gave it away.
        assertEq(staking.discountBpsFor(alice), 0);
        // Bob has it but has not held it, so he does not qualify yet. This is
        // what stops one position being rented to a different trader every
        // transaction.
        assertEq(staking.discountBpsFor(bob), 0, "a just-received position qualified immediately");

        skip(1 hours);
        assertEq(staking.discountBpsFor(bob), 1_000, "a held position should qualify");
    }

    function test_aDiscountOverTheCapIsRefused() public {
        LeekStaking.Tier[] memory t = new LeekStaking.Tier[](1);
        t[0] = LeekStaking.Tier(1 * ONE, 5_001);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LeekStaking.DiscountTooHigh.selector, 5_001));
        staking.setTiers(t);
    }

    function test_unsortedTiersAreRefused() public {
        LeekStaking.Tier[] memory t = new LeekStaking.Tier[](2);
        t[0] = LeekStaking.Tier(1_000 * ONE, 1_000);
        t[1] = LeekStaking.Tier(100 * ONE, 2_000);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LeekStaking.TiersNotAscending.selector, 1));
        staking.setTiers(t);
    }

    function test_onlyTheTierAdminSetsTiers() public {
        LeekStaking.Tier[] memory t = new LeekStaking.Tier[](1);
        t[0] = LeekStaking.Tier(1 * ONE, 1_000);
        // Read the role before the prank: TIER_ADMIN_ROLE() is a call, and it
        // would otherwise consume the prank and leave setTiers running as this
        // test contract - which reports a different address and passes for the
        // wrong reason.
        bytes32 role = staking.TIER_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        staking.setTiers(t);
    }

    /* ------------------------------------------------------------ rejects */

    function test_zeroIsRejectedEverywhere() public {
        vm.startPrank(alice);
        vm.expectRevert(LeekStaking.ZeroAmount.selector);
        staking.stake(0);
        vm.expectRevert(LeekStaking.ZeroAmount.selector);
        staking.unstake(0);
        vm.stopPrank();
    }

    function test_aZeroAddressConstructorArgumentIsRefused() public {
        vm.expectRevert(LeekStaking.ZeroAmount.selector);
        new LeekStaking(IERC20(address(0)), IERC20(address(musd)), admin, COOLDOWN);
        vm.expectRevert(LeekStaking.ZeroAmount.selector);
        new LeekStaking(IERC20(address(mezo)), IERC20(address(0)), admin, COOLDOWN);
        vm.expectRevert(LeekStaking.ZeroAmount.selector);
        new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), address(0), COOLDOWN);
    }

    /* --------------------------------------------------------------- fuzz */

    function testFuzz_twoStakersSplitRevenueByStakeAndNeverOverdraw(
        uint256 aliceStake,
        uint256 bobStake,
        uint256 revenue
    ) public {
        aliceStake = bound(aliceStake, 1, 1_000 * ONE);
        bobStake = bound(bobStake, 1, 1_000 * ONE);
        revenue = bound(revenue, 1, 1_000_000 * ONE);

        _stake(alice, aliceStake);
        _stake(bob, bobStake);
        musd.mint(address(staking), revenue);
        staking.notifyReward();

        uint256 owed = staking.pending(alice) + staking.pending(bob);
        /* Solvency holds at every size, including stakes of a few wei, and it
           is the property that matters: a claim the contract cannot pay is
           money taken from whoever withdraws last. */
        assertLe(owed, musd.balanceOf(address(staking)));

        /* Proportionality, compared without dividing.
           
           This assertion has been wrong three times, each time because I
           gated it on the magnitude of the wrong quantity: first the stakes,
           then the revenue, then each holder's pending balance. All three
           miss the real problem, which is that forming a RATIO throws away
           precision whenever the ratio itself is small - at a ratio of 3416
           there are four significant digits and one wei of truncation is
           0.03%, outside any sane tolerance.
           
           Cross-multiplying removes the division, so there is nothing to
           gate and nothing to tune:
           
               pendingAlice / pendingBob  ==  aliceStake / bobStake
           becomes
               pendingAlice * bobStake    ==  pendingBob * aliceStake
           
           The tolerance that remains covers only the per-holder floor in
           `pending`, which is one wei against products of this size. */
        /* And a floor on each holder's pending, because cross-multiplying
           fixed the wrong half.
           
           The division in the ratio was one source of error; `pending` itself
           is the other, and the bigger one. It is `floor(balance * acc / P)`,
           so a holder whose share works out to 192 wei carries a 0.3%
           truncation of its own no matter how the comparison is then
           written. Below this floor the two quantities are not imprecise,
           they are not measurable. 1e6 wei leaves 1e-6 relative error against
           a 1e-5 tolerance.
           
           Solvency above is asserted at every magnitude, including these, and
           it is the property that protects anybody. */
        uint256 pendingAlice = staking.pending(alice);
        uint256 pendingBob = staking.pending(bob);
        if (pendingAlice >= 1e6 && pendingBob >= 1e6) {
            assertApproxEqRel(
                pendingAlice * bobStake,
                pendingBob * aliceStake,
                1e13 // 0.001%
            );
        }
    }

    function testFuzz_stakeThenUnstakeReturnsTheWholeStake(uint256 amount) public {
        amount = bound(amount, 1, 1_000 * ONE);
        _stakeAndWait(alice, amount);
        vm.prank(alice);
        staking.unstake(amount);
        assertEq(mezo.balanceOf(alice), 1_000 * ONE);
        assertEq(staking.totalSupply(), 0);
    }

    function testFuzz_aTransferConservesTotalPending(uint256 amount, uint256 revenue) public {
        _stake(alice, 500 * ONE);
        revenue = bound(revenue, 1e6, 1_000 * ONE);
        musd.mint(address(staking), revenue);
        staking.notifyReward();

        amount = bound(amount, 1, 500 * ONE);
        uint256 before = staking.pending(alice) + staking.pending(bob);
        vm.prank(alice);
        staking.transfer(bob, amount);
        uint256 afterwards = staking.pending(alice) + staking.pending(bob);

        // A transfer must not create or destroy a claim on revenue.
        assertEq(before, afterwards);
    }

    /* ------------------------------------------------------- the cooldown */

    function test_unstakingBeforeTheCooldownIsRefused() public {
        _stake(alice, 100 * ONE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LeekStaking.StillCooling.selector, COOLDOWN));
        staking.unstake(100 * ONE);
    }

    function test_unstakingIsAllowedTheInstantTheCooldownElapses() public {
        _stake(alice, 100 * ONE);
        skip(COOLDOWN - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LeekStaking.StillCooling.selector, 1));
        staking.unstake(100 * ONE);

        skip(1);
        vm.prank(alice);
        staking.unstake(100 * ONE);
        assertEq(staking.balanceOf(alice), 0);
    }

    function test_aTopUpExtendsTheClockInProportionToItsSize() public {
        /* Not a full restart, which is the distinction that matters.
           
           Restarting outright let a stranger block a staker's exit with one
           wei (test/CooldownGrief.t.sol). The extension is
           `cooldown * value / balanceAfter`, so adding 1 MUSD to 100 adds
           3600 * 1e18 / 101e18 = 35 seconds: enough that adding size before a
           distribution is not free, little enough that dust is not a weapon. */
        _stake(alice, 100 * ONE);
        skip(COOLDOWN);
        _stake(alice, 1 * ONE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LeekStaking.StillCooling.selector, 35));
        staking.unstake(100 * ONE);

        // And after those 35 seconds she can leave.
        skip(35);
        vm.prank(alice);
        staking.unstake(100 * ONE);
    }

    function test_claimingDoesNotNeedTheCooldown() public {
        // The cooldown is on the principal, not on earnings: a staker who
        // leaves rewards unclaimed should not be pushed into unstaking to
        // collect them.
        _stake(alice, 100 * ONE);
        _fund(10 * ONE);
        vm.prank(alice);
        uint256 paid = staking.claim();
        assertEq(paid, 10 * ONE);
    }

    function test_theStakeAndRewardTokenCannotBeTheSame() public {
        // Unrecoverable if missed: both fields are immutable, and with one
        // token the permissionless notifyReward credits staked principal as
        // revenue and the principal walks out as a claim.
        vm.expectRevert(LeekStaking.SameToken.selector);
        new LeekStaking(IERC20(address(musd)), IERC20(address(musd)), admin, COOLDOWN);
    }

    function test_aZeroCooldownIsRefused() public {
        vm.expectRevert(LeekStaking.ZeroAmount.selector);
        new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), admin, 0);
    }

    function test_theReceiptCannotBeParkedInTheStakingContract() public {
        // It would accrue a share of all future revenue to an address that
        // can never claim it, and lock the MEZO behind it.
        _stakeAndWait(alice, 100 * ONE);
        vm.prank(alice);
        vm.expectRevert(LeekStaking.SelfTransfer.selector);
        staking.transfer(address(staking), 100 * ONE);
    }

    function test_unstakeReturnsThePrincipalEvenIfTheRewardCannotBePaid() public {
        // MUSD is upgradeable; if it ever refuses to pay an address, that
        // must not trap the staker's MEZO, which this contract holds and
        // which has nothing wrong with it.
        _stake(alice, 100 * ONE);
        _fund(10 * ONE);
        skip(COOLDOWN);

        // Drain the reward token so the payout cannot be made at all.
        // The balance is read BEFORE the prank: an argument expression is
        // evaluated after it and would consume it, leaving this transfer to
        // run as the test contract. That has caught me three times in this
        // repository now.
        uint256 held = musd.balanceOf(address(staking));
        vm.prank(address(staking));
        musd.transfer(bob, held);

        vm.prank(alice);
        staking.unstake(100 * ONE);

        assertEq(mezo.balanceOf(alice), 1_000 * ONE, "the principal did not come back");
        // The claim survives for later rather than being silently zeroed.
        assertEq(staking.pending(alice), 10 * ONE, "the unpaid reward was lost");
    }
}
