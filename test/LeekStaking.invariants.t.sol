// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LeekStaking} from "../src/LeekStaking.sol";
import {MockMUSD} from "./mocks/MockMUSD.sol";

/**
 * Drives the staking contract through random sequences of real actions.
 *
 * The handler bounds every input to something a user could actually do and
 * returns early when an action is impossible, rather than letting the fuzzer
 * spend its runs on reverts. Each function tracks what it put in and took
 * out, so the invariants can be stated against sums the handler knows
 * independently of the contract's own accounting - which is the point. An
 * invariant that reads the same storage the code wrote proves nothing.
 */
contract Handler is Test {
    uint256 constant COOLDOWN = 1 hours;
    LeekStaking public staking;
    MockMUSD public mezo;
    MockMUSD public musd;

    address[] public actors;

    uint256 public totalStakedIn;
    uint256 public totalStakedOut;
    uint256 public totalRevenueIn;
    uint256 public totalClaimedOut;

    constructor(LeekStaking staking_, MockMUSD mezo_, MockMUSD musd_) {
        staking = staking_;
        mezo = mezo_;
        musd = musd_;
        for (uint256 i = 0; i < 4; ++i) {
            address actor = address(uint160(0xA11CE + i));
            actors.push(actor);
            mezo_.mint(actor, 1_000_000e18);
            vm.prank(actor);
            mezo_.approve(address(staking_), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, mezo.balanceOf(actor));
        if (amount == 0) return;
        vm.prank(actor);
        staking.stake(amount);
        totalStakedIn += amount;
    }

    /**
     * Let time pass.
     *
     * Without this the cooldown means `unstake` always reverts, so every
     * sequence the fuzzer explores is deposits only - no exits, no claims
     * after an exit - and the invariants would pass against a state space
     * missing half the contract. A handler that silently cannot reach a
     * function is worse than one that fails.
     */
    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 hours));
    }

    function unstake(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 held = staking.balanceOf(actor);
        if (held == 0) return;
        // Return early rather than revert when the position is still cooling,
        // so the fuzzer is not spending runs on a known-impossible action.
        if (block.timestamp < staking.coolingUntil(actor)) return;
        amount = bound(amount, 1, held);
        // unstake() pays out any earned MUSD as well as returning the stake,
        // so the revenue tally has to count it. Missing this made the
        // conservation invariant fail against the handler, not the contract.
        uint256 musdBefore = musd.balanceOf(actor);
        vm.prank(actor);
        staking.unstake(amount);
        totalClaimedOut += musd.balanceOf(actor) - musdBefore;
        totalStakedOut += amount;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = staking.balanceOf(from);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        vm.prank(from);
        staking.transfer(to, amount);
    }

    function claim(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        if (staking.pending(actor) == 0) return;
        vm.prank(actor);
        uint256 paid = staking.claim();
        totalClaimedOut += paid;
    }

    /// The vault's side: fee revenue arriving and being accounted for.
    function earnRevenue(uint256 amount) external {
        if (staking.totalSupply() == 0) return; // the vault checks this too
        amount = bound(amount, 1, 10_000e18);
        musd.mint(address(staking), amount);
        staking.notifyReward();
        totalRevenueIn += amount;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract LeekStakingInvariants is Test {
    uint256 constant COOLDOWN = 1 hours;

    LeekStaking staking;
    MockMUSD mezo;
    MockMUSD musd;
    Handler handler;

    function setUp() public {
        mezo = new MockMUSD(18);
        musd = new MockMUSD(18);
        staking = new LeekStaking(IERC20(address(mezo)), IERC20(address(musd)), address(this), COOLDOWN);
        handler = new Handler(staking, mezo, musd);
        targetContract(address(handler));
    }

    /**
     * Every sMEZO in existence is one MEZO this contract holds.
     *
     * The receipt is minted 1:1 from the amount received, so this is exact
     * rather than approximate. If it ever drifts, the last staker out cannot
     * withdraw - the failure is someone else's money, not a rounding nit.
     */
    function invariant_supplyEqualsStakeHeld() public view {
        assertEq(staking.totalSupply(), mezo.balanceOf(address(staking)));
    }

    /// And it agrees with what the handler independently put in and took out.
    function invariant_supplyMatchesNetDeposits() public view {
        assertEq(staking.totalSupply(), handler.totalStakedIn() - handler.totalStakedOut());
    }

    /**
     * The contract can always pay what it says it owes.
     *
     * `rewardsOwed` is its own claim about its liability; the MUSD balance is
     * the truth. Owing more than it holds is insolvency, and it would be
     * reached by rounding in the wrong direction.
     */
    function invariant_canAlwaysPayWhatItOwes() public view {
        assertLe(staking.rewardsOwed(), musd.balanceOf(address(staking)));
    }

    /**
     * Nobody is credited more than the revenue that has ever arrived.
     *
     * Deliberately not `sum(pending) <= balance`. That is false by one wei per
     * distribution and the suite proved it: `accMusdPerShare` accumulates
     * truncated quotients, so the floor of the sum can exceed the sum of the
     * floors. `_payout` clamps for exactly that reason and the shortfall
     * clears on the next distribution. What must hold is the real property -
     * the contract cannot invent revenue - and that is asserted here against
     * the handler's own tally rather than against the contract's arithmetic.
     */
    function invariant_nobodyIsOwedMoreThanEverArrived() public view {
        uint256 owed;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            owed += staking.pending(handler.actors(i));
        }
        /* The bound carries one wei per holder, and the figure is derived
           rather than tuned.
           
           `pending` is `floor(balance * acc / PREC) - rewardDebt`, where the
           debt was itself floored when it was set. Subtracting a quantity that
           rounded down inflates the difference, by strictly less than one wei
           per holder. So the aggregate can exceed true entitlement by at most
           the number of holders, and never by more however long the sequence
           runs. Raising this bound to make a failure go away would be hiding
           exactly the class of bug the suite exists to find: conservation
           (`invariant_revenueIsNeitherCreatedNorDestroyed`) is exact, and what
           is actually transferred is clamped by `_payout`, so an over-credit
           of a few wei cannot leave the contract. */
        assertLe(owed, handler.totalRevenueIn() - handler.totalClaimedOut() + handler.actorCount());
    }

    /// A claim never reverts for want of balance, which is what the clamp buys.
    function invariant_aClaimableBalanceIsPayable() public {
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            if (staking.pending(actor) == 0) continue;
            vm.prank(actor);
            staking.claim();
        }
    }

    /**
     * Revenue is conserved: what came in is held, paid out, or dust.
     *
     * This is the one that would catch an accumulator that credits twice. Both
     * sides are computed from the handler's own tallies, so it is not reading
     * back the contract's arithmetic.
     */
    function invariant_revenueIsNeitherCreatedNorDestroyed() public view {
        assertEq(handler.totalRevenueIn(), musd.balanceOf(address(staking)) + handler.totalClaimedOut());
    }

    /// Nobody can be owed a reward while no reward has ever been distributed.
    function invariant_noRewardsWithoutRevenue() public view {
        if (handler.totalRevenueIn() != 0) return;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            assertEq(staking.pending(handler.actors(i)), 0);
        }
    }

    /// An empty pool holds no stake and owes nothing it cannot cover.
    function invariant_anEmptyPoolIsClean() public view {
        if (staking.totalSupply() != 0) return;
        assertEq(mezo.balanceOf(address(staking)), 0);
    }
}
