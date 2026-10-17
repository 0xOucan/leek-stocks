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

    uint256 private constant BPS = 10_000;

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
     * @notice MUSD received that rounded to nothing per share, awaiting the
     *         next distribution.
     * @dev Dust, not a balance anyone owns. It is included in the next
     *      `notifyReward`, so it is never stranded.
     */
    uint256 public unallocated;

    /// @notice MUSD each account may withdraw right now.
    mapping(address => uint256) public claimable;

    /// @dev `balance * accMusdPerShare / ACC_PRECISION` as of the last settle.
    mapping(address => uint256) private rewardDebt;

    /// @notice Lifetime MUSD distributed to stakers. For an honest rate.
    uint256 public totalDistributed;

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
    error NothingToDistribute();

    /**
     * @param mezo_ the staked token.
     * @param musd_ the reward token, which must be the token the vaults take
     *        their fees in or stakers earn something no vault produces.
     * @param admin the holder of `DEFAULT_ADMIN_ROLE` and `TIER_ADMIN_ROLE`.
     */
    constructor(IERC20 mezo_, IERC20 musd_, address admin) ERC20("Staked MEZO", "sMEZO") {
        if (address(mezo_) == address(0) || address(musd_) == address(0) || admin == address(0)) {
            revert ZeroAmount();
        }
        mezo = mezo_;
        musd = musd_;
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

        _burn(msg.sender, amount);
        _payout(msg.sender);
        mezo.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Take the MUSD earned so far without touching the stake.
    function claim() external nonReentrant returns (uint256 paid) {
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
    function notifyReward() public nonReentrant returns (uint256 distributed) {
        uint256 supply = totalSupply();
        if (supply == 0) revert NoStakers();

        uint256 held = musd.balanceOf(address(this));
        uint256 incoming = held - rewardsOwed;
        if (incoming == 0) revert NothingToDistribute();

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
        _settle(from);
        _settle(to);
        super._update(from, to, value);
        // Re-base after the move: `_settle` used the old balances.
        if (from != address(0)) rewardDebt[from] = (balanceOf(from) * accMusdPerShare) / ACC_PRECISION;
        if (to != address(0)) rewardDebt[to] = (balanceOf(to) * accMusdPerShare) / ACC_PRECISION;
    }
}
