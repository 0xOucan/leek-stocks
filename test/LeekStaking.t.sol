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

    function setUp() public {
        mezo = new MockMUSD(18);
        musd = new MockMUSD(18);
        staking = new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), admin);

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
        _stake(alice, 100 * ONE);
        _stake(bob, 100 * ONE);
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

    function test_distributingNothingReverts() public {
        _stake(alice, 100 * ONE);
        vm.expectRevert(LeekStaking.NothingToDistribute.selector);
        staking.notifyReward();
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
        LeekStaking s = new LeekStaking(IERC20(address(fot)), IERC20(address(musd)), admin);
        fot.mint(alice, 1_000 * ONE);
        vm.startPrank(alice);
        fot.approve(address(s), type(uint256).max);
        s.stake(100 * ONE);
        vm.stopPrank();

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
        _stake(alice, 100 * ONE);
        assertEq(staking.discountBpsFor(alice), 1_000);

        mezo.mint(alice, 5_000 * ONE);
        _stake(alice, 900 * ONE);
        assertEq(staking.discountBpsFor(alice), 2_500);

        _stake(alice, 4_000 * ONE);
        assertEq(staking.discountBpsFor(alice), 5_000);
    }

    function test_oneWeiBelowATierDoesNotEarnIt() public {
        _threeTiers();
        _stake(alice, 100 * ONE - 1);
        assertEq(staking.discountBpsFor(alice), 0);
    }

    function test_sendingTheReceiptAwaySendsTheDiscountWithIt() public {
        // A consequence of transferability worth asserting rather than
        // discovering: the discount follows the balance, not the staker.
        _threeTiers();
        _stake(alice, 100 * ONE);
        vm.prank(alice);
        staking.transfer(bob, 100 * ONE);
        assertEq(staking.discountBpsFor(alice), 0);
        assertEq(staking.discountBpsFor(bob), 1_000);
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
        new LeekStaking(IERC20(address(0)), IERC20(address(musd)), admin);
        vm.expectRevert(LeekStaking.ZeroAmount.selector);
        new LeekStaking(IERC20(address(mezo)), IERC20(address(0)), admin);
        vm.expectRevert(LeekStaking.ZeroAmount.selector);
        new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), address(0));
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

        /* Proportionality is asserted only where it is measurable.
           
           The tolerance is 1e-4 relative, and each holder's `pending` is a
           floored quantity, so the comparison is meaningless unless both
           pendings are large enough that one wei of truncation sits well
           inside that tolerance. Gating on the stakes or on the revenue - my
           first two attempts - gates on the wrong quantity: what matters is
           the size of the result, not of the inputs, because a large stake
           and a large revenue can still produce a small per-holder pending
           when the supply is larger still. 1e6 wei gives 1e-6 relative
           error against a 1e-4 tolerance, two orders of margin.
           
           Solvency above is asserted unconditionally at every magnitude, and
           it is the property that actually protects anybody; this one is a
           statement about fairness in the range where fairness is
           expressible. */
        uint256 pendingAlice = staking.pending(alice);
        uint256 pendingBob = staking.pending(bob);
        if (pendingAlice >= 1e6 && pendingBob >= 1e6) {
            assertApproxEqRel(
                (pendingAlice * 1e18) / pendingBob,
                (aliceStake * 1e18) / bobStake,
                1e14 // 0.01%
            );
        }
    }

    function testFuzz_stakeThenUnstakeReturnsTheWholeStake(uint256 amount) public {
        amount = bound(amount, 1, 1_000 * ONE);
        _stake(alice, amount);
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
}
