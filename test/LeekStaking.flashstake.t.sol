// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {ETFFactory} from "../src/ETFFactory.sol";
import {ETFShare} from "../src/ETFShare.sol";
import {IssuanceVault} from "../src/IssuanceVault.sol";
import {LeekStaking} from "../src/LeekStaking.sol";
import {ILeekStaking} from "../src/interfaces/ILeekStaking.sol";
import {MockMUSD} from "./mocks/MockMUSD.sol";

/**
 * The flash-stake attacks, now refused.
 *
 * `notifyReward` divides the arriving revenue by `totalSupply()` as it stands
 * in that one call, and nothing imposes a lock, a cooldown or a minimum
 * holding age. So a position held for one instant earns what a position held
 * for a month earns, and both of the attacks below follow from that single
 * fact rather than from any arithmetic slip.
 *
 * Each of these was demonstrated against the previous code - a one-block
 * staker took 2497.50 of a 2500 MUSD distribution, and the self-serving
 * variant returned the attacker 1248.75 MUSD of their own fee. The numbers
 * are in the commit that added this file. They now assert the refusal, so
 * they fail again if the cooldown is removed.
 *
 * What the cooldown does NOT do, stated here because the tests below would
 * otherwise imply it: entitlement is still not proportional to time held. A
 * staker who waits out the cooldown earns a full share of the next
 * distribution. The cooldown converts a free attack into a position with
 * capital at risk for its duration; streaming a distribution over a period
 * is the stronger answer and is not what this is.
 */
contract FlashStaker {
    LeekStaking immutable staking;
    IssuanceVault immutable vault;
    IERC20 immutable mezo;
    IERC20 immutable musd;

    constructor(LeekStaking staking_, IssuanceVault vault_, IERC20 mezo_, IERC20 musd_) {
        staking = staking_;
        vault = vault_;
        mezo = mezo_;
        musd = musd_;
    }

    /// Stake, trade, unstake - one transaction, no flash loan even needed.
    function tradeAtOwnExpense(uint256 mezoAmount, uint256 musdAmount) external returns (uint256 clawedBack) {
        mezo.approve(address(staking), mezoAmount);
        staking.stake(mezoAmount);

        musd.approve(address(vault), musdAmount);
        uint256 musdBefore = musd.balanceOf(address(this));
        vault.buy(musdAmount, 0);

        staking.unstake(mezoAmount);
        // Whatever MUSD came back beyond the shares bought is the fee the
        // attacker paid returning to them as "revenue".
        clawedBack = musd.balanceOf(address(this)) + musdAmount - musdBefore;
    }

    /// Hold the position only across somebody else's distribution.
    function enter(uint256 mezoAmount) external {
        mezo.approve(address(staking), mezoAmount);
        staking.stake(mezoAmount);
    }

    function exit(uint256 mezoAmount) external returns (uint256 harvested) {
        uint256 before = musd.balanceOf(address(this));
        staking.unstake(mezoAmount);
        harvested = musd.balanceOf(address(this)) - before;
    }
}

contract FlashStakeTest is Test {
    MockMUSD musd;
    MockMUSD mezo;
    IndexOracle oracle;
    ETFFactory factory;
    ETFShare share;
    IssuanceVault vault;
    LeekStaking staking;

    address admin = makeAddr("admin");
    address publisher = makeAddr("publisher");
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address honest = makeAddr("honestStaker");
    address alice = makeAddr("alice");

    uint256 constant ONE = 1e18;

    /// The oracle-independent holding period the staking contract enforces.
    uint256 constant COOLDOWN = 1 hours;
    function setUp() public {
        vm.warp(1_700_000_000);
        musd = new MockMUSD(18);
        mezo = new MockMUSD(18);
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

        staking = new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), admin, COOLDOWN);
        vm.prank(admin);
        vault.setStaking(ILeekStaking(address(staking)));

        // An honest staker who has been here all along.
        mezo.mint(honest, 100_000 * ONE);
        vm.startPrank(honest);
        mezo.approve(address(staking), type(uint256).max);
        staking.stake(100_000 * ONE);
        vm.stopPrank();

        musd.mint(alice, 2_000_000e18);
        vm.prank(alice);
        musd.approve(address(vault), type(uint256).max);
    }

    function test_theOneBlockStakerCannotLeaveWithTheDistribution() public {
        FlashStaker attacker = new FlashStaker(staking, vault, IERC20(address(mezo)), IERC20(address(musd)));
        // 1000x the honest stake. No flash loan is modelled because none is
        // needed: any capital that exists for one block is enough.
        mezo.mint(address(attacker), 100_000_000 * ONE);

        // 1. Attacker enters, seeing Alice's buy in the mempool.
        attacker.enter(100_000_000 * ONE);

        // 2. Alice's trade lands and routes its fee to the stakers.
        vm.prank(alice);
        vault.buy(1_000_000e18, 0);

        uint256 routed = staking.totalDistributed();
        assertGt(routed, 0, "no revenue was routed, the test proves nothing");

        // 3. The exit is refused: the position is still cooling.
        vm.expectRevert(abi.encodeWithSelector(LeekStaking.StillCooling.selector, 1 hours));
        attacker.exit(100_000_000 * ONE);

        // The capital is committed for the cooldown, which is the point. The
        // attacker can still leave afterwards and will still hold the credited
        // share - this makes the attack cost capital and time, it does not
        // make it impossible.
        skip(1 hours);
        uint256 taken = attacker.exit(100_000_000 * ONE);
        emit log_named_decimal_uint("revenue routed by Alice's trade", routed, 18);
        emit log_named_decimal_uint("taken after waiting the cooldown", taken, 18);
        assertGt(taken, 0, "the position earned nothing at all, which is not the intent");
    }

    function test_theSameTransactionStakeTradeUnstakeIsImpossible() public {
        LeekStaking.Tier[] memory tiers = new LeekStaking.Tier[](1);
        tiers[0] = LeekStaking.Tier(1_000 * ONE, 5_000); // the cap, 50% off
        vm.prank(admin);
        staking.setTiers(tiers);

        FlashStaker attacker = new FlashStaker(staking, vault, IERC20(address(mezo)), IERC20(address(musd)));
        mezo.mint(address(attacker), 100_000_000 * ONE);
        musd.mint(address(attacker), 1_000_000e18);

        // Full fee for a wallet that holds nothing.
        assertEq(vault.effectiveFeeBps(alice), 50);

        // The whole sequence in one transaction - stake, buy, unstake - now
        // reverts on the unstake, so the fee cannot be recovered within the
        // transaction that paid it. And the buy inside it pays the FULL fee,
        // because the discount is gated on the same cooldown.
        vm.expectRevert(abi.encodeWithSelector(LeekStaking.StillCooling.selector, 1 hours));
        attacker.tradeAtOwnExpense(100_000_000 * ONE, 1_000_000e18);
    }

    function test_aJustReceivedPositionGrantsNoDiscount() public {
        LeekStaking.Tier[] memory tiers = new LeekStaking.Tier[](1);
        tiers[0] = LeekStaking.Tier(1_000 * ONE, 5_000);
        vm.prank(admin);
        staking.setTiers(tiers);

        address renter = makeAddr("renter");
        assertEq(vault.effectiveFeeBps(renter), 50, "a wallet holding nothing should pay full fee");

        // One whale position, lent out. The receipt is transferable, so the
        // same 1000 MEZO can grant the top tier to any number of traders, one
        // per transaction.
        mezo.mint(honest, 1_000 * ONE);
        vm.startPrank(honest);
        staking.stake(1_000 * ONE);
        staking.transfer(renter, 1_000 * ONE);
        vm.stopPrank();

        // The receipt arrived this instant, so the clock restarted on arrival
        // and the renter pays full fee. This is what stops one whale position
        // granting the top tier to a different trader every transaction.
        assertEq(vault.effectiveFeeBps(renter), 50, "a just-received position still granted a discount");

        // And the lender lost the discount by sending it away, as they should.
        assertEq(vault.effectiveFeeBps(honest), 50);

        // After the cooldown the renter genuinely holds it and does qualify.
        skip(1 hours);
        assertEq(vault.effectiveFeeBps(renter), 25, "a held position should qualify");
    }
}
