// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ILeekStaking} from "./interfaces/ILeekStaking.sol";
import {ETFShare} from "./ETFShare.sol";

/**
 * @title IssuanceVault
 * @notice Buys and redeems one index's shares against MUSD, at the oracle price.
 *
 * @dev **Read this before using it for anything real.**
 *
 *      This is a *synthetic* issuer, not an ERC-4626 vault, and the difference
 *      is deliberate. In ERC-4626 a share is a claim on the assets held, so
 *      the share price is `assets / supply` and the vault is solvent by
 *      construction. Here a share's price comes from an index the vault does
 *      not hold, so the two can diverge: if the index rises, the MUSD paid in
 *      by buyers is less than the MUSD owed to redeemers. Calling this a 4626
 *      vault would import a solvency guarantee it does not have.
 *
 *      Three things follow, and they are limits rather than features:
 *
 *      1. **Redemption is paid from reserves and reverts when short.** It does
 *         not pay partially and does not silently round down. `reserves()` and
 *         `liabilities()` are public so the shortfall is visible before anyone
 *         commits, and `InsufficientReserves` names both numbers.
 *      2. **Total exposure is capped** (`maxShares`), so the gap an index rally
 *         can open is bounded by something the deployer chose rather than by
 *         how much was sold.
 *      3. **A backstop may be funded** with `fund()`, by anyone, which is how
 *         a treasury makes redeemers whole. Nothing obliges it to.
 *
 *      On a testnet with parody indices this is an honest demonstration of
 *      issuance, pricing and hardware-confirmed signing. It is not a product
 *      anyone should put money in, and the README says so in those words.
 *
 *      Oracle handling follows the oracle checklist: `decimals()` is read
 *      rather than assumed, the answer must be positive, `startedAt` must be
 *      non-zero, `answeredInRound` must not be behind `roundId`, the answer
 *      must be fresher than `maxStaleness`, and a reverting feed takes the
 *      call down rather than being caught and ignored.
 */
contract IssuanceVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    /// @notice Largest fee the deployer may set, in basis points. 5%.
    uint16 public constant MAX_FEE_BPS = 500;
    /**
     * @notice Most of a fee a staking discount may ever waive. 50%.
     * @dev Mirrors LeekStaking's own cap and is enforced here as well, so the
     *      vault's fee floor does not depend on a contract the admin can
     *      repoint. Part of every fee is the reserve top-up that keeps
     *      redemption solvent, and a 100% discount would let a large staker
     *      trade without contributing to it at all.
     */
    uint16 public constant MAX_DISCOUNT_BPS = 5_000;

    /**
     * @notice Gas forwarded to a staking read, and to its accounting call.
     *
     * @dev Bounded because `try/catch` is not a defence against a callee that
     *      burns gas. Solidity forwards all but 1/64 of what is left, so a
     *      hostile target reached from `effectiveFeeBps` - which both `buy`
     *      and `redeem` call near their start, before any state change - left
     *      roughly 4.7k gas of a 300k limit to finish a trade needing over
     *      100k. Every trade reverted out-of-gas, with no error selector and
     *      nothing in the logs, and the guardian's unwire could be undone by
     *      the admin in the next block.
     *
     *      An explicit stipend caps that at a bounded, catchable waste. The
     *      values are generous against the real contract: `discountBpsFor`
     *      walks at most 8 tiers (~40k measured) and `notifyReward` writes
     *      five slots (~30k measured).
     */
    /**
     * @notice How long after an emergency unset `setStaking` stays shut.
     *
     * @dev The guardian's rescue was undoable in the next block. Nothing in
     *      `setStaking` looked at whether it was re-pointing the vault at the
     *      contract a guardian had just detached, so the admin simply called
     *      it again - and again, as often as the guardian unset it. The
     *      guardian's power was therefore not a power at all, which is the
     *      opposite of what the previous round's fix claimed to deliver.
     *
     *      A fixed delay rather than a governance timelock, because the
     *      asymmetry is the whole point: detaching is instant and
     *      re-attaching waits. 24 hours is long enough to read a log and
     *      short enough that an honest redeploy is not blocked for a week.
     *      Unsetting to zero stays available throughout, so the lock can
     *      never trap the vault in a bad configuration.
     */
    uint256 public constant STAKING_RELOCK_DELAY = 24 hours;

    uint256 private constant STAKING_READ_GAS = 120_000;
    uint256 private constant STAKING_WRITE_GAS = 300_000;
    uint256 private constant BPS = 10_000;
    uint256 private constant SHARE_ONE = 1e18;

    /// @notice The settlement token. MUSD on Mezo.
    IERC20 public immutable musd;
    /**
     * @notice MUSD's own decimals, read at construction, never assumed.
     * @dev Cached rather than read per call. MUSD is an upgradeable contract,
     *      so in principle its decimals could change under a cached copy;
     *      in practice an ERC-20 that changes decimals breaks every
     *      integrator at once, and reading it on every price call would cost
     *      an external call per trade. The cache is the deliberate choice and
     *      the audit report records it.
     */
    uint8 public immutable musdDecimals;
    /// @notice The index price feed.
    AggregatorV3Interface public immutable oracle;
    /// @notice The feed's decimals, read at construction.
    uint8 public immutable oracleDecimals;
    /// @notice Age past which a price is refused outright.
    uint32 public immutable maxStaleness;
    /// @notice The share token this vault issues.
    ETFShare public share;

    /// @notice Fee on buy and on redeem, in basis points.
    uint16 public feeBps;
    /**
     * @notice Share of every fee that stays in reserves, in basis points.
     *
     * @dev The backstop, made a mechanism instead of a hope. `fund()` pays its
     *      caller nothing, so a design that relies on someone calling it
     *      relies on goodwill: a contract only advances when somebody is paid
     *      to advance it, and nobody is paid to advance that one. This cut is
     *      taken from the fee before the treasury sees it, so every trade
     *      makes the shortfall in H-1 smaller without anyone deciding to be
     *      generous. It is on the fee, never on the principal, so a buyer's
     *      own money is never quietly diverted.
     */
    uint16 public reserveShareBps;
    /// @notice Hard cap on shares outstanding.
    uint256 public maxShares;
    /// @notice MUSD collected as fees, excluded from reserves.
    uint256 public feesAccrued;
    /// @notice True while buying and redeeming are halted.
    bool public paused;

    /**
     * @notice Where the treasury share of each fee goes, if anywhere.
     *
     * @dev Zero disables the whole mechanism and the fee accrues to
     *      `feesAccrued` exactly as before, which is the state every vault
     *      deploys in. Settable rather than immutable because the staking
     *      contract is deployed after the vaults it earns from, and a vault
     *      that had to know its address at construction could never be the
     *      first thing deployed.
     */
    ILeekStaking public staking;

    /// @notice Timestamp before which `setStaking` cannot point anywhere but zero.
    uint256 public stakingLockedUntil;

    event Bought(address indexed buyer, uint256 musdIn, uint256 fee, uint256 sharesOut, uint256 price);
    event Redeemed(address indexed holder, uint256 sharesIn, uint256 fee, uint256 musdOut, uint256 price);
    event Funded(address indexed from, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event FeeSet(uint16 feeBps);
    event StakingSet(address staking);
    event RevenueRouted(uint256 amount);
    /// @notice MUSD reached the staking contract but was not accounted there.
    event RevenueStranded(uint256 amount);
    /// @notice The guardian detached the staking contract during an incident.
    event StakingEmergencyUnset();
    event StakingRelockUntil(uint256 timestamp);
    event ReserveShareSet(uint16 reserveShareBps);
    event ReservesTopped(uint256 amount, uint256 reservesAfter);
    event MaxSharesSet(uint256 maxShares);
    event Paused(address indexed guardian);
    event Unpaused(address indexed guardian);

    error ZeroAddress();
    error ZeroAmount();
    error VaultPaused();
    error FeeTooHigh(uint16 feeBps);
    error NotAContract(address target);
    error ShortTransfer(uint256 expected, uint256 received);
    error NotPaused();
    error StakingLocked(uint256 secondsRemaining);
    error CapAboveShareSupply(uint256 requested, uint256 shareMaxSupply);
    error ShareTooHigh(uint16 reserveShareBps);
    error ShareAlreadySet();
    error CapExceeded(uint256 supplyAfter, uint256 cap);
    error Slippage(uint256 got, uint256 wanted);
    error InsufficientReserves(uint256 owed, uint256 available);
    error StalePrice(uint256 updatedAt, uint32 maxStaleness);
    error BadPrice(int256 answer);
    error IncompleteRound(uint80 roundId, uint80 answeredInRound, uint256 startedAt);

    constructor(
        IERC20 musd_,
        AggregatorV3Interface oracle_,
        uint32 maxStaleness_,
        uint16 feeBps_,
        uint16 reserveShareBps_,
        uint256 maxShares_,
        address admin,
        address guardian,
        address treasurer
    ) {
        if (address(musd_) == address(0) || address(oracle_) == address(0)) revert ZeroAddress();
        if (admin == address(0) || guardian == address(0) || treasurer == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        if (reserveShareBps_ > BPS) revert ShareTooHigh(reserveShareBps_);
        if (maxStaleness_ == 0 || maxShares_ == 0) revert ZeroAmount();

        musd = musd_;
        musdDecimals = IERC20Metadata(address(musd_)).decimals();
        oracle = oracle_;
        oracleDecimals = oracle_.decimals();
        maxStaleness = maxStaleness_;
        feeBps = feeBps_;
        reserveShareBps = reserveShareBps_;
        maxShares = maxShares_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(TREASURER_ROLE, treasurer);
    }

    /// @notice Set once, by the factory, immediately after deployment.
    function setShare(ETFShare share_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(share) != address(0)) revert ShareAlreadySet();
        if (address(share_) == address(0)) revert ZeroAddress();
        share = share_;
    }

    /* ------------------------------------------------------------- pricing */

    /**
     * @notice The index price, in MUSD units per whole share.
     * @dev Scaled from the feed's decimals to MUSD's, multiplying before
     *      dividing so a feed with more decimals than the token does not
     *      truncate to zero on the way.
     */
    function price() public view returns (uint256) {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        if (answer <= 0) revert BadPrice(answer);
        if (startedAt == 0 || answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound, startedAt);
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice(updatedAt, maxStaleness);

        uint256 raw = uint256(answer);
        if (oracleDecimals == musdDecimals) return raw;
        if (oracleDecimals < musdDecimals) return raw * (10 ** (musdDecimals - oracleDecimals));
        return raw / (10 ** (oracleDecimals - musdDecimals));
    }

    /**
     * @notice MUSD held on behalf of shareholders, excluding accrued fees.
     * @dev Reads `balanceOf` rather than an internal counter, so MUSD sent
     *      here directly counts as reserves. That is a donation, and the only
     *      thing it can do is make redeemers better off: nothing mints
     *      against this number, so it cannot be used to inflate a share price
     *      or dilute a holder. `fund()` exists so that a deliberate top-up is
     *      observable in an event rather than being a bare transfer.
     */
    function reserves() public view returns (uint256) {
        uint256 balance = musd.balanceOf(address(this));
        return balance > feesAccrued ? balance - feesAccrued : 0;
    }

    /// @notice MUSD owed if every share were redeemed at the current price.
    function liabilities() public view returns (uint256) {
        return (share.totalSupply() * price()) / SHARE_ONE;
    }

    /* ---------------------------------------------------------------- buying */

    /**
     * @param musdAmount MUSD to spend, fee inclusive.
     * @param minShares the fewest shares the caller will accept.
     * @dev Checks, then state, then the external pull last but one: the MUSD
     *      transfer and the mint are both after every validation, and the only
     *      untrusted call is to MUSD itself.
     */
    /*
       The same balance-delta measurement as LeekStaking.stake, and for the
       same reason: minting shares against MUSD that never arrived would
       under-fund liabilities from the first trade and compound with volume
       (audit L-2). `buy`, `redeem`, `fund` and `withdrawFees` all carry the
       one contract-wide reentrancy lock, so there is no path back in. */
    // slither-disable-next-line reentrancy-balance
    function buy(uint256 musdAmount, uint256 minShares) external nonReentrant returns (uint256 sharesOut) {
        if (paused) revert VaultPaused();
        if (musdAmount == 0) revert ZeroAmount();

        uint256 p = price();
        // The caller's own fee, so a staker's discount applies to their trade
        // and to nobody else's. Read once and reused for the split below.
        uint16 fee_ = effectiveFeeBps(msg.sender);
        uint256 fee = (musdAmount * fee_) / BPS;
        uint256 net = musdAmount - fee;
        sharesOut = (net * SHARE_ONE) / p;
        if (sharesOut == 0) revert ZeroAmount();
        if (sharesOut < minShares) revert Slippage(sharesOut, minShares);

        uint256 supplyAfter = share.totalSupply() + sharesOut;
        if (supplyAfter > maxShares) revert CapExceeded(supplyAfter, maxShares);

        /* Both halves come from the undivided product rather than from `fee`,
           so the split does not compound the fee's own truncation. The
           treasury's half is the remainder, which keeps the two halves
           summing to exactly `fee` with no wei stranded in neither pot. */
        uint256 toReserves = (musdAmount * fee_ * reserveShareBps) / (BPS * BPS);

        /*
         * Price the shares off what arrived, not off what was asked for.
         *
         * MUSD is upgradeable. If it ever charges a transfer fee, this
         * contract receives less than `musdAmount` while minting shares
         * computed from the full `musdAmount`, so `reserves()` under-funds
         * `liabilities()` from the very first trade and the gap compounds
         * with volume. LeekStaking.stake already measures its own delta for
         * exactly this reason; the technique was in the codebase and not
         * applied at the one place where MUSD is the token being pulled.
         *
         * In the normal case `received == musdAmount` and this costs one
         * extra balance read.
         */
        uint256 balanceBefore = musd.balanceOf(address(this));
        musd.safeTransferFrom(msg.sender, address(this), musdAmount);
        uint256 balanceAfter = musd.balanceOf(address(this));
        /* Guarded, so a balance that somehow fell across the transfer - a
           negative rebase, a hook - reverts with ShortTransfer naming the
           problem rather than panicking 0x11 on an underflow. */
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received < musdAmount) revert ShortTransfer(musdAmount, received);

        share.mint(msg.sender, sharesOut);
        if (toReserves != 0) emit ReservesTopped(toReserves, reserves());

        emit Bought(msg.sender, musdAmount, fee, sharesOut, p);
        /* Last, after the mint and after the event: routing makes an external
           call into the staking contract, so it goes at the end of the
           checks-effects-interactions order rather than in the middle of
           issuing shares. `nonReentrant` already holds. */
        _routeRevenue(fee - toReserves);
    }

    /**
     * @notice Point the treasury share of each fee at a staking contract.
     * @dev Zero unsets it, which is the safe fallback: revenue goes back to
     *      `feesAccrued` and nothing else changes. No validation of the target
     *      beyond that, deliberately - a wrong address here would be caught by
     *      the first buy reverting, which is louder than a check that passes
     *      on any contract exposing three functions.
     */
    function setStaking(ILeekStaking next) external onlyRole(DEFAULT_ADMIN_ROLE) {
        /*
         * A minimum of validation, which the previous version deliberately
         * omitted on the argument that "a wrong address here would be caught
         * by the first buy reverting". That was the bug, not the safeguard:
         * the first buy reverting means every buy and every *redeem* reverts,
         * so holders cannot exit, and the only remedy was this same admin
         * function. An EOA or an undeployed address is the likely mistake, so
         * it is rejected outright.
         *
         * This cannot validate behaviour, only existence - a chosen hostile
         * contract is specified not to revert. The real protections are the
         * try/catch on every call into it below, the independent discount
         * clamp, and `emergencyUnsetStaking` for the guardian.
         */
        if (address(next) != address(0) && address(next).code.length == 0) revert NotAContract(address(next));
        /*
         * The guardian's detach holds for STAKING_RELOCK_DELAY. Setting to
         * zero stays allowed inside the window - that direction only ever
         * returns the vault to pre-staking behaviour, and forbidding it would
         * mean a lock could pin a hostile contract in place if one were ever
         * attached between the unset and the window closing.
         */
        if (address(next) != address(0) && block.timestamp < stakingLockedUntil) {
            revert StakingLocked(stakingLockedUntil - block.timestamp);
        }
        staking = next;
        emit StakingSet(address(next));
    }

    /**
     * @notice Detach the staking contract, restoring pre-staking behaviour.
     *
     * @dev The guardian's other power is `pause`, which stops trading. This
     *      one restores it, and that asymmetry was the gap: a staking
     *      contract that reverts froze buying and redeeming without ever
     *      setting `paused`, so no Paused event fired, monitoring saw
     *      nothing, and `unpause` did nothing. The only remedy lived with
     *      DEFAULT_ADMIN_ROLE - which on a one-key deployment is the same
     *      address whose mistake caused it.
     *
     *      Safe to hand to the guardian because unsetting cannot take value:
     *      the treasury share simply accrues to `feesAccrued` again, where
     *      only TREASURER_ROLE can reach it.
     */
    function emergencyUnsetStaking() external onlyRole(GUARDIAN_ROLE) {
        /*
         * Only while paused, so detaching staking is part of a declared
         * incident rather than a standing power.
         *
         * The earlier version argued this was safe to delegate "because
         * unsetting cannot take value: the treasury share simply accrues to
         * feesAccrued, where only TREASURER_ROLE can reach it". That argument
         * assumed guardian != treasurer, and nothing enforced it - both
         * default to the admin in the deploy scripts. One address holding
         * both could unset staking, let trading continue normally while every
         * staker's rewards quietly stopped growing, and then withdraw the
         * accumulated fees. The only trace was a StakingSet(0) event.
         *
         * Requiring `paused` does not stop a determined holder of both roles,
         * but it makes the step loud: trading halts, Paused fires, and the
         * two events sit together in the log. `registerIndex` now also
         * refuses guardian == treasurer outright.
         */
        if (!paused) revert NotPaused();
        staking = ILeekStaking(address(0));
        stakingLockedUntil = block.timestamp + STAKING_RELOCK_DELAY;
        emit StakingRelockUntil(stakingLockedUntil);
        emit StakingEmergencyUnset();
        emit StakingSet(address(0));
    }

    /**
     * @notice The fee `account` actually pays, after any staking discount.
     *
     * @dev A view, so a front end quotes the same number the trade will
     *      charge. The discount is read from the staking contract rather than
     *      stored here, so a stake made one block ago counts.
     *
     *      Bounded twice over: the staking contract caps a tier at half the
     *      fee, and this clamps anything larger regardless. Trusting the other
     *      contract's cap alone would make the vault's own fee floor depend on
     *      whatever address the admin last pointed at.
     */
    function effectiveFeeBps(address account) public view returns (uint16) {
        uint16 base = feeBps;
        if (address(staking) == address(0) || base == 0) return base;

        /*
         * A discount that cannot be read is a discount nobody gets, not a
         * trade nobody can make.
         *
         * A low-level staticcall with an explicit gas stipend, not a typed
         * `try`. Two reasons, both found by re-auditing the first attempt:
         *
         *   1. A typed `try … returns (uint16)` decodes the return data of a
         *      *successful* call outside the catch frame, so a callee that
         *      returns nothing - or short data - reverts uncatchably. The
         *      catch was dead for a whole class of misbehaving callee.
         *   2. `try` forwards all available gas, so a callee that burns it
         *      left too little to finish the trade. This is called before any
         *      state change in both `buy` and `redeem`, so that froze
         *      everything including exits.
         *
         * Anything other than exactly 32 bytes of successful return data is
         * treated as "no discount available".
         */
        (bool ok, bytes memory data) = address(staking).staticcall{gas: STAKING_READ_GAS}(
            abi.encodeCall(ILeekStaking.discountBpsFor, (account))
        );
        if (!ok || data.length != 32) return base;

        uint256 raw = abi.decode(data, (uint256));
        uint16 discount = raw > MAX_DISCOUNT_BPS ? MAX_DISCOUNT_BPS : uint16(raw);
        // Multiply before dividing; the result is at most `base`, so the
        // narrowing cast cannot truncate.
        return uint16(base - (uint256(base) * discount) / BPS);
    }

    /**
     * @dev Hand `amount` of MUSD to the stakers, or keep it as fee revenue.
     *
     *      Routed only when there is a staking contract, the amount is
     *      non-zero and somebody is actually staked. That last condition is
     *      the empty-state decision: `notifyReward` refuses a distribution to
     *      a zero supply rather than stranding the MUSD or handing it to
     *      whoever stakes first, so the vault must not send it in that case.
     *      An unstaked period simply leaves the fee as revenue here.
     */
    function _routeRevenue(uint256 amount) private {
        if (amount == 0) return;

        ILeekStaking target = staking;
        if (address(target) == address(0)) {
            feesAccrued += amount;
            return;
        }

        /*
         * Every call into the staking contract is guarded, and every failure
         * falls back to the behaviour this vault had before staking existed.
         *
         * Routing fee revenue is a nice-to-have; letting a holder redeem is
         * not. Three of five audit domains independently found that this
         * function could revert a trade - via a mis-pointed `setStaking`, via
         * `NoStakers`, via `NothingToDistribute`, or via an unchecked
         * subtraction inside `notifyReward` - and in every case the
         * consequence was that nobody could exit the vault.
         */
        /* Same treatment as the discount read: bounded, and tolerant of a
           callee that returns the wrong shape. */
        (bool supplyOk, bytes memory supplyData) =
            address(target).staticcall{gas: STAKING_READ_GAS}(abi.encodeCall(ILeekStaking.totalSupply, ()));
        if (!supplyOk || supplyData.length != 32) {
            feesAccrued += amount;
            return;
        }
        uint256 supply = abi.decode(supplyData, (uint256));
        // The empty-state decision: `notifyReward` refuses a distribution to
        // a zero supply rather than stranding it or handing it to whoever
        // stakes first, so an unstaked period leaves the fee as revenue here.
        if (supply == 0) {
            feesAccrued += amount;
            return;
        }

        /*
         * The one place in this contract that does not use SafeERC20,
         * because SafeERC20's helpers are internal and a revert inside
         * `safeTransfer` cannot be caught - and catching it is the entire
         * point: MUSD is upgradeable, and a blocklist on the staking address
         * would otherwise halt every trade including exits.
         *
         * This was a typed `try … returns (bool)`, with a comment claiming
         * it checked the return value "which is what SafeERC20 would have
         * done". It did the opposite. SafeERC20 *tolerates* empty return
         * data - the pre-2020 USDT shape - while a typed try reverts
         * uncatchably on it, because the decode of a successful call happens
         * outside the catch frame. test/TryCatchDecode.t.sol demonstrates
         * both halves.
         *
         * So: a low-level call, and SafeERC20's own tolerance rebuilt
         * explicitly. Empty return data with a successful call means moved.
         */
        (bool callOk, bytes memory transferData) =
            address(musd).call(abi.encodeCall(IERC20.transfer, (address(target), amount)));
        bool moved = callOk && (transferData.length == 0 || abi.decode(transferData, (bool)));
        if (!moved) {
            feesAccrued += amount;
            return;
        }

        (bool notifyOk,) =
            address(target).call{gas: STAKING_WRITE_GAS}(abi.encodeCall(ILeekStaking.notifyReward, ()));
        if (notifyOk) {
            emit RevenueRouted(amount);
        } else {
            /* The MUSD has already left this contract, so it cannot be
               credited to `feesAccrued` - that would count it twice. It is
               not lost: it sits in the staking contract's balance and the
               next successful distribution picks it up, because
               `notifyReward` measures its own balance rather than trusting an
               argument. Emitted so the gap is visible rather than silent. */
            emit RevenueStranded(amount);
        }
    }

    /* -------------------------------------------------------------- redeeming */

    /**
     * @param shares shares to burn.
     * @param minMusd the least MUSD the caller will accept.
     * @dev Reverts rather than paying partially when reserves are short; see
     *      the contract notes. The share burn happens before the payout, so a
     *      token that re-enters on transfer finds the supply already reduced.
     */
    /*
       `_routeRevenue` credits `feesAccrued` after its bounded calls because
       that credit is the FALLBACK for the calls not having worked - it exists
       precisely for that case and cannot precede it. nonReentrant holds
       throughout. */
    // slither-disable-next-line reentrancy-no-eth
    function redeem(uint256 shares, uint256 minMusd) public nonReentrant returns (uint256 musdOut) {
        if (paused) revert VaultPaused();
        if (shares == 0) revert ZeroAmount();

        uint256 p = price();
        uint16 fee_ = effectiveFeeBps(msg.sender);
        uint256 gross = (shares * p) / SHARE_ONE;
        // The fee comes from the undivided product rather than from `gross`,
        // so the two divisions do not compound: dividing by SHARE_ONE first
        // and then taking a fee of the result truncates twice, and slither's
        // divide-before-multiply detector is right to say so. The widest
        // operands this contract permits - shares bounded by maxShares and a
        // price in token units - are many orders below uint256's ceiling.
        uint256 fee = (shares * p * fee_) / (SHARE_ONE * BPS);
        musdOut = gross - fee;
        if (musdOut == 0) revert ZeroAmount();
        if (musdOut < minMusd) revert Slippage(musdOut, minMusd);

        uint256 available = reserves();
        if (gross > available) revert InsufficientReserves(gross, available);

        // Same treatment as in buy(): the undivided product, so the two
        // divisions do not stack.
        uint256 toReserves = (shares * p * fee_ * reserveShareBps) / (SHARE_ONE * BPS * BPS);
        share.burnFrom(msg.sender, shares);
        musd.safeTransfer(msg.sender, musdOut);
        if (toReserves != 0) emit ReservesTopped(toReserves, reserves());

        emit Redeemed(msg.sender, shares, fee, musdOut, p);
        _routeRevenue(fee - toReserves);
    }

    /**
     * @notice Redeem in one transaction, authorising the share burn by signature.
     *
     * @dev Two transactions to sell was the sharpest edge in the walkthrough:
     *      a tester approves, waits, then redeems, and on a chain whose
     *      receipts lag by minutes the gap reads as the first one having
     *      failed. `ETFShare` is an `ERC20Permit`, so the authorisation can
     *      travel as a signature in the same transaction instead.
     *
     *      The permit is submitted by this contract rather than by the caller
     *      so that the allowance it creates is consumed by `redeem` in the
     *      same call and cannot be left standing. A permit that has already
     *      been used - a replay, or a second attempt after a first succeeded -
     *      reverts inside `ERC20Permit` on the nonce, which is the behaviour
     *      wanted: it does not silently continue with whatever allowance
     *      happens to exist.
     *
     *      It also matters for the hardware wallet this project exists to
     *      exercise: a permit is EIP-712 typed data, which the device signs
     *      and displays, rather than a second blind approval.
     */
    function redeemWithPermit(
        uint256 shares,
        uint256 minMusd,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 musdOut) {
        /*
         * A failed permit is not fatal, because the commonest cause is
         * somebody else having already submitted it.
         *
         * `ETFShare.permit` is public, so anyone watching the mempool can
         * lift (v, r, s) from a pending `redeemWithPermit` and submit the
         * permit directly first. That consumes the nonce, and an
         * unconditional call here then reverted the whole redemption - the
         * user paid gas for nothing, while the allowance they needed had just
         * been created for them. So: attempt it, and let `redeem` and
         * `_spendAllowance` be the authority on whether the approval is
         * actually there. If it is not, `burnFrom` reverts with the right
         * error instead of a confusing nonce failure.
         */
        try share.permit(msg.sender, address(this), shares, deadline, v, r, s) {} catch {}
        return redeem(shares, minMusd);
    }

    /* ------------------------------------------------------------ management */

    /// @notice Add MUSD to reserves without minting shares. The backstop.
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // The amount in the event is what the reserves actually gained, so a
        // donation cannot be over-reported by a fee-charging token.
        uint256 balanceBefore = musd.balanceOf(address(this));
        musd.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = musd.balanceOf(address(this));
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        emit Funded(msg.sender, received);
    }

    /**
     * @notice Withdraw accrued fees.
     * @dev Fees only. Shareholder reserves are not reachable by any role, which
     *      is the one centralisation risk this contract does not carry.
     */
    function withdrawFees(address to, uint256 amount) external nonReentrant onlyRole(TREASURER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > feesAccrued) revert ZeroAmount();
        feesAccrued -= amount;
        musd.safeTransfer(to, amount);
        emit FeesWithdrawn(to, amount);
    }

    function setFeeBps(uint16 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps);
        feeBps = newFeeBps;
        emit FeeSet(newFeeBps);
    }

    /**
     * @notice Change the share of fees that stays in reserves.
     * @dev Up to 100%: a vault whose index has run away from its reserves may
     *      rationally send every fee to the backstop until the gap closes.
     */
    function setReserveShareBps(uint16 newShareBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newShareBps > BPS) revert ShareTooHigh(newShareBps);
        reserveShareBps = newShareBps;
        emit ReserveShareSet(newShareBps);
    }

    /// @notice Reserves as a fraction of liabilities, in basis points.
    function coverageBps() external view returns (uint256) {
        uint256 owed = liabilities();
        if (owed == 0) return BPS;
        return (reserves() * BPS) / owed;
    }

    function setMaxShares(uint256 newMaxShares) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxShares == 0) revert ZeroAmount();
        /*
         * Bounded by the share token's immutable ceiling, because raising it
         * past that was a silent lie. `MaxSharesSet` fired and `maxShares()`
         * read back the new value, so the change looked applied - then at the
         * old ceiling `buy` began reverting `ETFShare.CapExceeded` naming a
         * cap this contract does not report, from a contract the front end is
         * not quoting. Lowering still works; it is the raise that could not.
         */
        if (address(share) != address(0) && newMaxShares > share.maxSupply()) {
            revert CapAboveShareSupply(newMaxShares, share.maxSupply());
        }
        maxShares = newMaxShares;
        emit MaxSharesSet(newMaxShares);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }
}
