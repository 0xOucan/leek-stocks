// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LeekStaking
 * @notice Stake MEZO, receive sMEZO, earn the MUSD the index vaults collect.
 *
 * @dev **Where the yield comes from.**
 *
 *      Nowhere new. `IssuanceVault` already charges a fee on every buy and
 *      redeem and splits it: part stays as backing, the remainder is protocol
 *      revenue. That remainder is routed here, so a staker's return is a share
 *      of fees other people actually paid. There is no emission, no minted
 *      reward token and no subsidy, which means the rate can be derived from
 *      two on-chain numbers - MUSD distributed and MEZO staked - and cannot be
 *      inflated by this contract.
 *
 *      It also means the rate is **zero when nobody trades**. That is the
 *      honest property of a revenue share and it is not a defect.
 *
 *      **Why sMEZO is transferable.** A staked position that cannot move is a
 *      locked balance; one that can is a derivative another protocol can hold
 *      as collateral. The cost is that a transfer moves a reward entitlement,
 *      so `_update` settles both sides before any balance changes. Get that
 *      wrong and a transfer either steals the sender's unclaimed rewards or
 *      mints the receiver someone else's.
 *
 *      **Nothing is automatic.** There is no scheduler on a chain, so this
 *      contract never waits for a keeper. `accMusdPerShare` advances inside
 *      the calls people already make for their own reasons - stake, unstake,
 *      claim, transfer - and `notifyReward` is permissionless. If every
 *      operator vanished, stakers could still stake, claim and leave.
 *
 *      **Entitlement is gated by a holding period.** Without one, a position
 *      held for a single instant earned what a position held for a month
 *      earned, because `notifyReward` divides the arriving revenue by
 *      `totalSupply()` as it stands in that one call. The measured result
 *      (test/LeekStaking.flashstake.t.sol) was a one-block staker taking
 *      2497.50 of a 2500 MUSD distribution from somebody who had been staked
 *      the whole time, and the same trick returning an attacker their own
 *      routed fee. The discount was rentable the same way, and worse, because
 *      sMEZO is transferable: one whale position could grant the top tier to
 *      any number of traders, one per transaction.
 *
 *      So `cooldown` seconds must pass after a balance increase before an
 *      account can unstake or earn a discount. Be clear about what that buys:
 *      it converts a free flash attack into a position with capital at risk
 *      for the cooldown, which is the thing a revenue share is supposed to
 *      pay for. It does not make entitlement proportional to time held - a
 *      staker who waits out the cooldown still earns a full share of the next
 *      distribution. Streaming the distribution over a period is the stronger
 *      answer and is not what this does.
 *
 *      A balance *increase* restarts the clock, including one received by
 *      transfer. Topping up would otherwise let a long-standing staker add
 *      size immediately before a distribution, and a transferred receipt
 *      would arrive already eligible, which is the rental.
 *
 *      **Three deliberate simplifications**, each removing a class of bug:
 *
 *      1. **sMEZO is minted 1:1 with the MEZO received.** There is no exchange
 *         rate, so there is no share-price conversion to round, and the ERC-4626
 *         first-depositor inflation attack has no surface here: a donation of
 *         MEZO to this contract does not change what anyone's sMEZO redeems
 *         for. Supply equals stake, always, which is also the invariant.
 *      2. **Rewards are a different token from the stake.** MUSD in, MEZO
 *         staked. Nothing can be double-counted between the two pots.
 *      3. **Reward funding is measured, not declared.** `notifyReward` reads
 *         this contract's own MUSD balance rather than trusting an argument,
 *         so a fee-on-transfer token, a short transfer or a caller that lies
 *         about the amount cannot desynchronise the accounting.
 *
 *      **The empty state is explicit.** Distributing to a zero supply would
 *      either strand the MUSD forever or hand it to whoever staked first.
 *      `notifyReward` reverts with `NoStakers` instead, and the vault checks
 *      `totalSupply()` before routing, so an unstaked period simply leaves the
 *      fee as vault revenue. Nothing is lost and nobody gets a windfall.
 */
contract LeekStaking is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice May change the discount tiers, within `MAX_DISCOUNT_BPS`.
    bytes32 public constant TIER_ADMIN_ROLE = keccak256("TIER_ADMIN_ROLE");


    /**
     * @notice The largest share of a fee a tier may waive. 50%.
     * @dev Capped rather than open-ended because the fee is not only revenue:
     *      part of it is the backing that keeps redemption solvent. A 100%
     *      discount would let a large staker mint and redeem with no
     *      contribution to reserves at all, which moves a cost onto every
     *      other holder. Half is the most this will ever give away, and the
     *      cap is enforced on every write rather than trusted to the setter.
     */
    uint16 public constant MAX_DISCOUNT_BPS = 5_000;

    /// @notice At most this many tiers, so `discountBpsFor` is bounded gas.
    uint256 public constant MAX_TIERS = 8;

    /**
     * @dev Fixed-point scale for `accMusdPerShare`.
     *
     *      1e18 of headroom above the reward token's own precision, so a
     *      small reward against a large stake does not truncate to nothing.
     *      Worth stating plainly: a single distribution smaller than
     *      `totalSupply() / 1e18` MUSD-wei still rounds to zero per share.
     *      The remainder is not lost, it stays in `unallocated` and joins the
     *      next distribution.
     */
    uint256 private constant ACC_PRECISION = 1e18;

    /// @notice The token staked. MEZO on Mezo.
    IERC20 public immutable mezo;

    /// @notice The token paid out. MUSD, the same one the vaults settle in.
    IERC20 public immutable musd;

    /// @notice Cumulative MUSD per staked token, scaled by `ACC_PRECISION`.
    uint256 public accMusdPerShare;

    /**
     * @notice MUSD this contract has credited to stakers and not yet paid out.
     * @dev Held separately from `musd.balanceOf(this)` so that the difference
     *      between the two is exactly the amount a new distribution should
     *      account for. This is what makes the measured funding in
     *      `notifyReward` work without a declared amount.
     */
    uint256 public rewardsOwed;

    /**
     * @notice MUSD that rounded to nothing per share. Telemetry only.
     *
     * @dev **This is not redistributed, and an earlier version of this
     *      comment said it was.** `notifyReward` adds the whole of `incoming`
     *      to `rewardsOwed`, so the part that rounded away is accounted as a
     *      liability and is therefore excluded from every later
     *      `incoming = held - rewardsOwed`. It stays in the contract owed to
     *      nobody in particular, which is exactly what covers the clamp in
     *      `_payout`.
     *
     *      That is deliberate and the conservative direction: crediting it
     *      twice is what made the sum of everyone's `pending` exceed the
     *      revenue that had ever arrived. A reader who "fixes the stranded
     *      dust" on the strength of the old comment reintroduces that bug,
     *      which is why the comment is corrected rather than deleted.
     */
    uint256 public unallocated;

    /// @notice MUSD each account may withdraw right now.
    mapping(address => uint256) public claimable;

    /// @dev `balance * accMusdPerShare / ACC_PRECISION` as of the last settle.
    mapping(address => uint256) private rewardDebt;

    /// @notice Lifetime MUSD distributed to stakers. For an honest rate.
    uint256 public totalDistributed;

    /// @notice Seconds after a balance increase before unstaking or a discount.
    uint256 public immutable cooldown;

    /**
     * @notice The timestamp from which each account may unstake.
     *
     * @dev Extended on an increase **in proportion to how much the balance
     *      grew**, which is the fix for a griefing vector the first version
     *      of this cooldown created.
     *
     *      Resetting the clock outright on any increase meant anybody could
     *      send one wei of sMEZO to a staker who had finished waiting and
     *      restart their full cooldown, repeatably, for dust. The position
     *      was never at risk, but the holder could be kept from leaving
     *      indefinitely by a stranger.
     *
     *      So the extension is `cooldown * value / balanceAfter`:
     *
     *        - a fresh recipient has `value == balanceAfter` and waits the
     *          full cooldown, which is what stops a transferred receipt
     *          arriving already eligible;
     *        - one wei into a large position extends by effectively nothing,
     *          so the grief costs the griefer and buys them nothing;
     *        - doubling a position adds half a cooldown, so adding size
     *          immediately before a distribution is not free.
     *
     *      `max` with the existing value, so an increase can only ever push
     *      the deadline later.
     */
    mapping(address => uint256) public coolingUntil;

    /**
     * @notice A fee discount earned by staking at least `minStake`.
     * @dev Sorted ascending by `minStake` on write, so the lookup can stop at
     *      the first tier it fails and does not need to scan every entry.
     */
    struct Tier {
        uint256 minStake;
        uint16 discountBps;
    }

    Tier[] private tiers;

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event RewardAdded(uint256 amount, uint256 accMusdPerShare, uint256 totalStaked);
    event TiersSet(uint256 count);

    error ZeroAmount();
    error NoStakers();
    error TooManyTiers(uint256 count);
    error DiscountTooHigh(uint16 discountBps);
    error TiersNotAscending(uint256 index);
    error StillCooling(uint256 secondsRemaining);
    error SameToken();
    error SelfTransfer();

    /**
     * @param mezo_ the staked token.
     * @param musd_ the reward token, which must be the token the vaults take
     *        their fees in or stakers earn something no vault produces.
     * @param admin the holder of `DEFAULT_ADMIN_ROLE` and `TIER_ADMIN_ROLE`.
     */
    constructor(IERC20 mezo_, IERC20 musd_, address admin, uint256 cooldown_) ERC20("Staked MEZO", "sMEZO") {
        if (address(mezo_) == address(0) || address(musd_) == address(0) || admin == address(0)) {
            revert ZeroAmount();
        }
        /*
         * The stake and the reward must be different tokens.
         *
         * If they are the same, staked principal is indistinguishable from
         * arriving revenue: stake 1000, call the permissionless
         * `notifyReward`, and `incoming = balanceOf(this) - rewardsOwed` is
         * your own 1000, credited as a reward and claimable. The contract
         * then holds nothing against its sMEZO supply and nobody can
         * unstake. Both fields are immutable, so this check is the only
         * chance to catch it.
         */
        if (mezo_ == musd_) revert SameToken();
        if (cooldown_ == 0) revert ZeroAmount();

        mezo = mezo_;
        musd = musd_;
        cooldown = cooldown_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TIER_ADMIN_ROLE, admin);
    }

    /* ------------------------------------------------------------- staking */

    /**
     * @notice Stake MEZO and receive sMEZO 1:1.
     * @dev The minted amount is the balance actually received, not `amount`.
     *      A fee-on-transfer token would otherwise mint more sMEZO than the
     *      contract holds and break the supply-equals-stake invariant on the
     *      last staker out.
     */
    /*
       reentrancy-balance: the balance is read before and after the transfer
       because the DELTA is the point - a fee-on-transfer MEZO would otherwise
       credit sMEZO for tokens that never arrived (audit L-2, MockFeeToken).
       Slither sees the shape of a stale-balance bug and this is the shape of
       the fix for one. Not reachable: OpenZeppelin's guard is one lock per
       contract and every state-changing function here carries it, so there
       is no sibling to re-enter through. Direction matters too - a reentrant
       withdrawal understates `received` and REVERTS; only a reentrant deposit
       could overstate it, and the only path that deposits holds the lock.
       incorrect-equality: `received == 0` is an amount, not a balance. The
       detector exists for `balanceOf(x) == y`, which a donation breaks. */
    // slither-disable-next-line reentrancy-balance,incorrect-equality
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 before = mezo.balanceOf(address(this));
        mezo.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = mezo.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        // The mint settles rewards through `_update`, so no explicit settle
        // is needed here and adding one would double-count.
        _mint(msg.sender, received);
        emit Staked(msg.sender, received);
    }

    /**
     * @notice Burn sMEZO and take the MEZO back, with any MUSD earned.
     * @dev Rewards are paid out here rather than left for a separate `claim`.
     *      A staker who leaves and has to come back for dust will not come
     *      back, and unclaimed rewards that sit forever make a live mechanism
     *      look dead.
     */
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 until_ = coolingUntil[msg.sender];
        if (block.timestamp < until_) revert StillCooling(until_ - block.timestamp);

        _burn(msg.sender, amount);
        /*
         * The reward leg must not be able to hold the principal hostage.
         *
         * `_payout` makes an external MUSD transfer, and MUSD on Mezo is an
         * upgradeable contract. If it gains a blocklist, a frozen account or
         * a reverting hook, an unconditional payout here means a staker whose
         * address MUSD will not pay cannot retrieve their *MEZO* either -
         * which this contract holds, and which has nothing wrong with it. So
         * a failed payout leaves `claimable` intact for a later `claim` (or
         * for a different address, after transferring the receipt) and the
         * principal still goes back.
         */
        _tryPayout(msg.sender);
        mezo.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Take the MUSD earned so far without touching the stake.
    /*
       `paid == 0` is a payout amount, not a balance: nothing an outsider can
       transfer in changes it. */
    // slither-disable-next-line incorrect-equality
    function claim() external nonReentrant returns (uint256 paid) {
        /*
         * Gated on the same clock as `unstake`.
         *
         * Leaving it ungated meant the reward leg of the flash-stake attack
         * had no time cost at all: an attacker could grow a position, take
         * almost the whole distribution through `claim`, and only the
         * principal had to wait. The entitlement is the thing being bought
         * with time, not the withdrawal.
         *
         * This cannot trap a reward: an increase a staker did not ask for
         * extends the clock in proportion to its size, so dust adds nothing,
         * and the claim survives in `claimable` either way.
         */
        uint256 until_ = coolingUntil[msg.sender];
        if (block.timestamp < until_) revert StillCooling(until_ - block.timestamp);

        _settle(msg.sender);
        paid = _payout(msg.sender);
        if (paid == 0) revert ZeroAmount();
    }

    /* ------------------------------------------------------------- rewards */

    /**
     * @notice Account for MUSD sent to this contract and credit it to stakers.
     *
     * @dev Permissionless and takes no amount. It distributes whatever arrived
     *      since the last call, which is `balanceOf(this) - rewardsOwed`. The
     *      vault calls this in the same transaction as the fee transfer, so in
     *      practice nobody has to poke it; it is open anyway because a
     *      mechanism that needs a privileged caller to pay out is a mechanism
     *      that stops when that caller does.
     *
     *      Reverts on an empty stake rather than distributing: see the
     *      contract notes on the empty state.
     */
    /*
       divide-before-multiply is DELIBERATE and load-bearing here, and
       removing it reintroduces audit finding R2-9. `distributed` has to be
       the amount the FLOORED `perShare` actually credits, so the remainder
       can go to `unallocated` instead of being measured as new revenue on the
       next call and credited twice. Computing it without the round trip
       through the division would make it disagree with what holders can
       claim, which is the bug.
       incorrect-equality: `incoming == 0` is a measured delta, not a
       balance comparison. */
    // slither-disable-next-line divide-before-multiply,incorrect-equality
    function notifyReward() public nonReentrant returns (uint256 distributed) {
        uint256 supply = totalSupply();
        if (supply == 0) revert NoStakers();
        // NoStakers stays a revert rather than a silent no-op: it means the
        // caller sent revenue that has nowhere to go, and the vault checks
        // totalSupply() before routing precisely so it never reaches here.

        uint256 held = musd.balanceOf(address(this));
        /*
         * Saturating, not checked.
         *
         * `held >= rewardsOwed` holds only because `_payout` reduces
         * `rewardsOwed` by exactly what it transfers, which assumes the MUSD
         * balance falls by exactly that much. MUSD is upgradeable, so that is
         * an assumption about future bytecode: a transfer fee, a claw-back or
         * a seizure makes `held` smaller than `rewardsOwed` once, and a
         * checked subtraction then reverts here forever - and because the
         * vault calls this on every trade, that bricked buying and redeeming
         * for everyone. Returning zero degrades instead, and the vault's
         * try/catch is the second line.
         */
        uint256 incoming = held > rewardsOwed ? held - rewardsOwed : 0;
        if (incoming == 0) return 0;

        // Multiply before dividing: the division is where a small reward
        // against a large stake disappears.
        uint256 perShare = (incoming * ACC_PRECISION) / supply;

        /* The whole of `incoming` becomes a liability, not just the part the
           accumulator could represent.
           
           This is the fix for a defect the invariant suite found and two
           earlier attempts papered over. Crediting only `perShare * supply`
           and leaving the remainder outside `rewardsOwed` meant the next call
           computed `incoming` from a balance that still contained that
           remainder - so the dust was offered again, and the accumulator
           credited it a second time. Across a few distributions the sum of
           everyone's `pending` then exceeded the revenue that had ever
           arrived, which is the contract inventing money.
           
           Accounting for all of it is conservative in the safe direction: a
           few wei per distribution are owed to nobody in particular and stay
           in the contract. They are not lost to stakers as a class - they are
           what covers the clamp in `_payout` - and the alternative is an
           over-credit, which is unrecoverable. */
        rewardsOwed += incoming;
        accMusdPerShare += perShare;

        distributed = (perShare * supply) / ACC_PRECISION;
        unallocated += incoming - distributed;
        totalDistributed += distributed;

        emit RewardAdded(distributed, accMusdPerShare, supply);
    }

    /// @notice MUSD `account` could claim right now.
    function pending(address account) external view returns (uint256) {
        return claimable[account] + _accrued(account);
    }

    /* ----------------------------------------------------------- discounts */

    /**
     * @notice The share of a vault fee `account` does not have to pay, in bps.
     * @dev Returns 0 for a non-staker, which is the whole gate: there is no
     *      rule excluding anyone from minting shares, because requiring a
     *      second token to use the protocol would cost more in reach than the
     *      discount could ever earn. The incentive is the discount, not a
     *      locked door.
     */
    function discountBpsFor(address account) external view returns (uint16) {
        /* A position that could be acquired and released inside one
           transaction was a discount for rent, not a discount for holding.
           The receipt being transferable made it worse: the same stake could
           grant the top tier to any number of traders, one per transaction. */
        if (block.timestamp < coolingUntil[account]) return 0;

        uint256 staked = balanceOf(account);
        uint16 discount = 0;
        uint256 length = tiers.length;
        for (uint256 i = 0; i < length; ++i) {
            // Ascending, so the first tier out of reach ends the walk.
            if (staked < tiers[i].minStake) break;
            discount = tiers[i].discountBps;
        }
        return discount;
    }

    /// @notice The tiers, for a front end that should not hardcode them.
    function tierAt(uint256 index) external view returns (uint256 minStake, uint16 discountBps) {
        Tier memory tier = tiers[index];
        return (tier.minStake, tier.discountBps);
    }

    function tierCount() external view returns (uint256) {
        return tiers.length;
    }

    /**
     * @notice Replace the discount tiers.
     * @dev Validated rather than trusted: ascending `minStake`, every discount
     *      within `MAX_DISCOUNT_BPS`, and a bounded count so the lookup cannot
     *      be made expensive enough to grief a buy.
     */
    function setTiers(Tier[] calldata next) external onlyRole(TIER_ADMIN_ROLE) {
        if (next.length > MAX_TIERS) revert TooManyTiers(next.length);

        delete tiers;
        for (uint256 i = 0; i < next.length; ++i) {
            if (next[i].discountBps > MAX_DISCOUNT_BPS) revert DiscountTooHigh(next[i].discountBps);
            if (next[i].minStake == 0) revert ZeroAmount();
            if (i != 0 && next[i].minStake <= next[i - 1].minStake) revert TiersNotAscending(i);
            tiers.push(next[i]);
        }
        emit TiersSet(next.length);
    }

    /* -------------------------------------------------------------- internals */

    /// @dev Rewards earned since this account was last settled.
    function _accrued(address account) private view returns (uint256) {
        return ((balanceOf(account) * accMusdPerShare) / ACC_PRECISION) - rewardDebt[account];
    }

    /**
     * @dev Move earned rewards into `claimable` and reset the debt.
     *      Must run before any balance change, which `_update` guarantees.
     */
    function _settle(address account) private {
        if (account == address(0)) return;
        claimable[account] += _accrued(account);
        rewardDebt[account] = (balanceOf(account) * accMusdPerShare) / ACC_PRECISION;
    }

    /**
     * @dev Pay what is claimable, bounded by what the contract actually holds.
     *
     *      The clamp is not defensive padding, it is load-bearing, and the
     *      invariant suite is what found that out. `accMusdPerShare` is a sum
     *      of truncated per-share quotients, while `rewardsOwed` is a sum of
     *      those quotients truncated a second time on the way back out. The
     *      floor of a sum is not the sum of the floors, so the accumulator can
     *      credit up to one wei more per distribution than was ever accounted
     *      for. Unclamped, the final claimant's transfer reverts on a balance
     *      one wei short and their whole reward becomes unwithdrawable.
     *
     *      So a claim is capped and the unpayable remainder stays claimable
     *      rather than being zeroed: it becomes payable again as soon as the
     *      next distribution arrives. Nobody loses a reward, and the worst
     *      case is a few wei of MUSD arriving one distribution late.
     */
    /**
     * @dev `_payout`, but a failing MUSD transfer is not fatal.
     *
     *      Used by `unstake` only. `claim` keeps the strict version, because
     *      a claim that silently does nothing is worse than one that reverts
     *      and says why.
     */
    /*
       reentrancy-no-eth: the writes after the external call are the FAILURE
       bookkeeping - restoring `rewardsOwed` and crediting `claimable` when
       the token refused - which can only happen after the call because they
       are conditional on its result. The only caller is `unstake`, which is
       nonReentrant.
       incorrect-equality: `owed == 0`, `payable_ == 0` and `ret.length == 0`
       are an amount, an amount and a returndata length. The last one is
       SafeERC20's own tolerance for a token that returns nothing. */
    // slither-disable-next-line reentrancy-no-eth,incorrect-equality
    function _tryPayout(address account) private {
        uint256 owed = claimable[account];
        if (owed == 0) return;

        uint256 available = musd.balanceOf(address(this));
        uint256 payable_ = owed > available ? available : owed;
        if (payable_ == 0) return;

        // State first, so a reverting token cannot leave this half-applied;
        // the whole call reverts and nothing above is kept.
        claimable[account] = owed - payable_;
        /* Record the decrement actually applied. The subtraction saturates,
           so restoring `payable_` unconditionally could add back more than
           was taken and leave a permanent phantom liability - every later
           `incoming = held - rewardsOwed` short by that much, stranding that
           revenue forever. */
        uint256 decremented = rewardsOwed < payable_ ? rewardsOwed : payable_;
        rewardsOwed -= decremented;

        /*
         * `ok` is the success of the CALL, not the ERC-20 return value.
         *
         * A token that returns `false` instead of reverting made `ok` true,
         * so the restore never ran: the staker's `claimable` was zeroed, they
         * received nothing, and the MUSD stayed in the contract to be
         * redistributed to whoever was staked next. The justification for
         * using a low-level call here is precisely that MUSD is upgradeable
         * and its return behaviour is not trusted, so not checking the return
         * was self-defeating. Empty return data with a successful call counts
         * as moved, which is SafeERC20's own tolerance.
         */
        (bool ok, bytes memory ret) = address(musd).call(
            abi.encodeCall(IERC20.transfer, (account, payable_))
        );
        bool moved = ok && (ret.length == 0 || abi.decode(ret, (bool)));

        if (moved) {
            emit Claimed(account, payable_);
        } else {
            // Put it back, by addition rather than assignment, so nothing
            // written during the call window is discarded.
            claimable[account] += payable_;
            rewardsOwed += decremented;
        }
    }

    /*
       `owed == 0` and `paid == 0` are amounts. Both are early returns on
       "there is nothing to do". */
    // slither-disable-next-line incorrect-equality
    function _payout(address account) private returns (uint256 paid) {
        uint256 owed = claimable[account];
        if (owed == 0) return 0;

        uint256 available = musd.balanceOf(address(this));
        paid = owed > available ? available : owed;
        if (paid == 0) return 0;

        claimable[account] = owed - paid;
        rewardsOwed = rewardsOwed > paid ? rewardsOwed - paid : 0;
        musd.safeTransfer(account, paid);
        emit Claimed(account, paid);
    }

    /**
     * @dev Settle both sides of every balance change, then re-base their debt.
     *
     *      This is the whole reason a transferable staking receipt is safe. A
     *      transfer moves future entitlement but must not move past
     *      entitlement, so the sender's earnings are banked into `claimable`
     *      before their balance drops, and the receiver's debt is rebased
     *      after theirs rises so they do not inherit a claim on rewards
     *      distributed before they held anything.
     *
     *      Mint passes `from == address(0)` and burn passes `to == address(0)`;
     *      `_settle` ignores the zero address rather than accruing to it.
     */
    function _update(address from, address to, uint256 value) internal override {
        /*
         * sMEZO must not come to rest here.
         *
         * A transfer to this contract is an ordinary transfer as far as
         * OpenZeppelin is concerned: `totalSupply()` does not change, so every
         * later distribution keeps dividing by it, and `_settle` dutifully
         * accrues a share into `claimable[address(this)]` forever. Nothing can
         * ever pay that - `claim` and `unstake` both key off `msg.sender` and
         * there is no sweep - so the MEZO behind it is locked and a fixed
         * fraction of all future revenue accrues to an address that cannot
         * spend it. The most likely cause is somebody pasting a contract
         * address, so it is refused rather than documented.
         */
        if (to == address(this)) revert SelfTransfer();

        /* A transfer to oneself changes nothing, so it must not extend the
           clock either - otherwise `transfer(self, balance)` is a complete
           self-grief with no counterparty, and the settle below would run
           twice for one account. */
        if (from == to && from != address(0)) {
            super._update(from, to, value);
            return;
        }

        _settle(from);
        _settle(to);
        super._update(from, to, value);
        // Re-base after the move: `_settle` used the old balances.
        if (from != address(0)) rewardDebt[from] = (balanceOf(from) * accMusdPerShare) / ACC_PRECISION;
        if (to != address(0)) {
            rewardDebt[to] = (balanceOf(to) * accMusdPerShare) / ACC_PRECISION;
            /* Extend in proportion to the increase. See `coolingUntil`:
               resetting outright let a stranger block a staker's exit with
               one wei, and not extending at all let a receipt arrive already
               eligible. `balanceAfter` is non-zero here because `value` was
               just added to it. */
            uint256 balanceAfter = balanceOf(to);
            if (balanceAfter != 0) {
                /*
                 * Accumulate the extension; do not take a maximum.
                 *
                 * Taking `max(now + ext_i)` meant every step in one
                 * transaction shared a timestamp, so the result was just the
                 * largest single fraction. Growing a position 144x in 1%
                 * steps waited 35 seconds instead of 3600, and the
                 * flash-stake attack came straight back - the earlier test
                 * passed only because it tried one bulk stake.
                 *
                 * Adding to whichever is later - the stored deadline or now -
                 * makes n small steps strictly worse for an attacker than one
                 * large step, because the fractions sum rather than compete.
                 * The same 1% ladder now costs hours.
                 */
                uint256 base = coolingUntil[to] > block.timestamp ? coolingUntil[to] : block.timestamp;
                coolingUntil[to] = base + (cooldown * value) / balanceAfter;
            }
        }
    }
}
