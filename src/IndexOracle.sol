// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/**
 * @title IndexOracle
 * @notice A push oracle for one index, speaking Chainlink's AggregatorV3 so
 *         that consumers written against Chainlink need no adapter.
 *
 * @dev **Trust model, stated rather than implied.** This is a single-operator
 *      feed: an off-chain service holding PUBLISHER_ROLE pushes prices. Anyone
 *      relying on it is relying on that operator, and no on-chain mechanism
 *      here changes that. What the contract does instead is bound the damage a
 *      bad or captured publisher can do in one round, and let a separate
 *      guardian stop it:
 *
 *      - **Staleness.** Every answer carries its publication time, untouched
 *        by reads. Consumers must reject an answer older than
 *        `maxStaleness()`; `latestRoundData` does not revert on a stale
 *        answer, because Chainlink's does not and a consumer written for
 *        Chainlink would not expect it to.
 *      - **Deviation bound.** A push further than `maxDeviationBps` from the
 *        previous answer reverts. A fat-fingered or hostile update fails
 *        instead of repricing every position that depends on it. The bound is
 *        deliberately not removable by the publisher.
 *      - **Separated roles.** Publishing, pausing and administration are three
 *        roles, so the key that pushes prices cannot pause the feed, and the
 *        key that pauses cannot push. The security checklist's note about a
 *        single owner holding a pause stands: the guardian should be a
 *        multisig, and the admin should not be the publisher.
 *      - **Monotonic rounds.** Round ids increase by one and never repeat, and
 *        historical rounds are immutable once written.
 *
 *      Prices are `int256` because the interface says so, but a non-positive
 *      answer is rejected at publication: an index cannot be worth nothing,
 *      and a consumer that forgets to check a zero is the classic oracle bug.
 */
contract IndexOracle is AccessControl, AggregatorV3Interface {
    /* ----------------------------------------------------------------- roles */

    /// @notice May publish a new round. Held by the off-chain feed service.
    bytes32 public constant PUBLISHER_ROLE = keccak256("PUBLISHER_ROLE");
    /// @notice May pause and unpause the feed. Should be a multisig.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /* ------------------------------------------------------------ immutables */

    /// @inheritdoc AggregatorV3Interface
    uint8 public immutable decimals;
    /// @notice Human-readable index name, e.g. "GOLOGGLE / MUSD".
    string private _description;
    /**
     * @notice Largest move, in basis points, one round may make from the last.
     * @dev Immutable on purpose: a publisher who could widen this bound could
     *      publish anything, which would make the bound decorative.
     */
    uint16 public immutable maxDeviationBps;
    /// @notice Age, in seconds, past which consumers must treat an answer as stale.
    uint32 public immutable maxStaleness;

    /**
     * @notice Seconds that must pass between two rounds.
     *
     * @dev Without this the deviation bound bounds nothing useful. It is a
     *      per-round limit, so five rounds in one block compound it: 20% a
     *      round takes a price from 100 to 248.83 inside a single
     *      transaction, and test/AdminTheft.t.sol buys before and redeems
     *      after for 2.46x out of other holders' reserves. The guardian can
     *      pause the feed, but only after seeing it, and none of that is
     *      visible until the block is mined.
     *
     *      With an interval the per-round bound becomes a bound per unit of
     *      time, which is the thing a guardian can actually react inside.
     *      Immutable for the same reason as `maxDeviationBps`: a publisher
     *      who could shorten it could undo it.
     */
    uint32 public immutable minRoundInterval;

    /**
     * @notice Largest answer this feed will accept, in its own decimals.
     *
     * @dev The first round is exempt from the deviation bound by design, so
     *      it was the one answer with no bound of any kind. A first answer of
     *      1e75 makes every later `publish` overflow `previous * 10_000` and
     *      there is no way to reset a round or lower `_latestRound`, so the
     *      feed would be bricked permanently by one mistyped number. Bounding
     *      the magnitude on every publish closes that and also keeps the
     *      consuming vault's `shares * price * feeBps * reserveShareBps`
     *      product far from overflowing.
     */
    int256 public constant MAX_ANSWER = 1e30;

    /**
     * @notice Length of the window the cumulative bound is measured over.
     *
     * @dev `maxDeviationBps` plus `minRoundInterval` bound the price per unit
     *      of time, and audit finding R4-6 is that per unit of time is still
     *      a ratchet: at 2000 bps every 30 seconds a compromised publisher
     *      doubles the price in four rounds - **two minutes** - and
     *      `maxStaleness` is an hour, so nothing goes stale while the walk
     *      happens. The walk *is* fresh publishes. A guardian who is not
     *      already watching has no brake at all.
     *
     *      So there is a second bound, measured not from the previous answer
     *      but from an anchor that only refreshes once a window has elapsed.
     *      Inside a window the price may move `maxWindowDeviationBps` in
     *      total, however many rounds it takes. At one hour and 2000 bps,
     *      doubling the price takes **11,010 seconds** - a little over three
     *      hours - instead of 120 seconds. That figure is measured by
     *      test/Ratchet.t.sol rather than reasoned about, and it is three
     *      hours rather than four because of the window boundary described
     *      under `maxWindowDeviationBps`. Either way it is time a human can
     *      act in, which is the whole claim.
     *
     *      Immutable for the same reason as the other two: a publisher who
     *      could lengthen the window or widen its budget could undo it.
     */
    uint32 public immutable deviationWindow;

    /**
     * @notice Total move, in basis points, permitted within one window.
     *
     * @dev Measured from `anchorAnswer`, not from the previous round, so a
     *      sequence of small in-bound steps cannot add up to more than this.
     *
     *      **The honest limit of this design.** The window is fixed rather
     *      than sliding, so a publisher can spend the whole budget at the end
     *      of one window and the whole of the next budget immediately after
     *      it rolls: worst case is twice this in a short span, at a boundary,
     *      once. Every step after that costs a further window. A true sliding
     *      bound needs the answer from exactly `deviationWindow` ago, which
     *      means storing one entry per round - about 120 of them at a
     *      30-second interval - and that cost is not worth buying the last
     *      factor of two. Recorded here rather than left for a reader to
     *      discover, because a bound whose worst case is undocumented is the
     *      kind of thing this audit keeps finding.
     */
    uint16 public immutable maxWindowDeviationBps;

    /**
     * @notice The smallest publishable answer, in feed decimals.
     *
     * @dev The mirror image of `MAX_ANSWER`, and it took a re-audit to see
     *      that the bound had only one side.
     *
     *      The deviation bound is multiplicative, so small answers are
     *      *absorbing*: at `previous == 1` and 2000 bps the right-hand side
     *      of the check is 2000, an integer `difference * 10_000` cannot be
     *      less than without being zero, so the only answer ever publishable
     *      again is 1. There is no way to reset a round or lower
     *      `_latestRound`, so one mistyped first answer pins the feed at
     *      dust for good - and because the off-chain publisher's own bound
     *      truncates to zero there too, it keeps republishing the pinned
     *      value on the heartbeat, the feed never goes stale, `price()` never
     *      reverts, and the vault trades at ~0 indefinitely. That is the
     *      worse half of the brick `MAX_ANSWER` was added to prevent.
     *
     *      1e6 at 8 decimals is 0.01 index points. At that floor the bound
     *      still permits a move of 20,000 units, so no reachable answer is
     *      absorbing, and an index based at 100 has four orders of magnitude
     *      of headroom below it.
     */
    int256 public constant MIN_ANSWER = 1e6;

    /* ----------------------------------------------------------------- state */

    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
    }

    /// @dev Round ids start at 1, so round 0 means "nothing published yet".
    uint80 private _latestRound;
    mapping(uint80 roundId => Round) private _rounds;
    /// @notice True while publishing is halted by a guardian.
    bool public paused;

    /**
     * @notice The answer the current window's budget is measured from.
     * @dev Public so a monitor can compute the remaining budget itself rather
     *      than trusting `windowBudget()` below to be the only reader.
     */
    int256 public anchorAnswer;
    /// @notice When the current window began.
    uint256 public anchorAt;

    /* ---------------------------------------------------------------- events */

    event AnswerPublished(uint80 indexed roundId, int256 answer, uint256 updatedAt, address indexed publisher);
    event WindowAnchorMoved(int256 anchorAnswer, uint256 anchorAt);
    event Paused(address indexed guardian);
    event Unpaused(address indexed guardian);

    /* ---------------------------------------------------------------- errors */

    error NotPositive(int256 answer);
    error AnswerTooLarge(int256 answer);
    error AnswerTooSmall(int256 answer);
    error TooSoon(uint256 elapsed, uint32 required);
    error DeviationTooLarge(int256 previous, int256 proposed, uint16 maxBps);
    error WindowDeviationTooLarge(int256 anchor, int256 proposed, uint16 maxBps, uint32 window);
    error FeedPaused();
    error NoData();
    error AlreadyInThatState();
    error ZeroAddress();
    error InvalidParameter();

    /**
     * @param description_ e.g. "GOLOGGLE / MUSD"
     * @param decimals_ answer decimals; 8 matches Chainlink's USD feeds
     * @param maxDeviationBps_ per-round move bound, 1-10000
     * @param deviationWindow_ seconds the cumulative bound is measured over
     * @param maxWindowDeviationBps_ total move permitted per window, 1-10000
     * @param maxStaleness_ seconds after which consumers must refuse an answer
     * @param admin role administrator; should not also publish
     * @param publisher the off-chain feed service
     * @param guardian pause authority; should be a multisig
     */
    constructor(
        string memory description_,
        uint8 decimals_,
        uint16 maxDeviationBps_,
        uint32 maxStaleness_,
        uint32 minRoundInterval_,
        uint32 deviationWindow_,
        uint16 maxWindowDeviationBps_,
        address admin,
        address publisher,
        address guardian
    ) {
        if (admin == address(0) || publisher == address(0) || guardian == address(0)) revert ZeroAddress();
        // An 18-decimal answer multiplied by a bound is still far from
        // overflowing int256, but a decimals value above 18 is a typo, and a
        // zero deviation bound or staleness would freeze or void the feed.
        if (decimals_ == 0 || decimals_ > 18) revert InvalidParameter();
        if (maxDeviationBps_ == 0 || maxDeviationBps_ > 10_000) revert InvalidParameter();
        if (maxStaleness_ == 0) revert InvalidParameter();
        /* The interval has to leave room for a publisher to actually publish
           inside the staleness window: an interval at or above staleness
           means the feed is stale before the next round is permitted. */
        if (minRoundInterval_ == 0 || minRoundInterval_ >= maxStaleness_) revert InvalidParameter();
        /*
         * The window must be longer than one round interval, or it expires
         * between rounds and bounds nothing - the degenerate configuration
         * that would make this look implemented while doing nothing, which is
         * worse than not having it.
         */
        if (deviationWindow_ <= minRoundInterval_) revert InvalidParameter();
        if (maxWindowDeviationBps_ == 0 || maxWindowDeviationBps_ > 10_000) revert InvalidParameter();
        if (bytes(description_).length == 0) revert InvalidParameter();

        _description = description_;
        decimals = decimals_;
        maxDeviationBps = maxDeviationBps_;
        maxStaleness = maxStaleness_;
        minRoundInterval = minRoundInterval_;
        deviationWindow = deviationWindow_;
        maxWindowDeviationBps = maxWindowDeviationBps_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PUBLISHER_ROLE, publisher);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    /* ------------------------------------------------------------ publishing */

    /**
     * @notice Publish the next round.
     * @dev The first round is exempt from the deviation bound: there is nothing
     *      to deviate from, and a feed has to start somewhere. That makes the
     *      initial answer the one value a publisher sets freely, which is why
     *      deployment and first publication belong to the same reviewed step.
     */
    function publish(int256 answer) external onlyRole(PUBLISHER_ROLE) returns (uint80 roundId) {
        if (paused) revert FeedPaused();
        if (answer <= 0) revert NotPositive(answer);
        // Bounded both ways on every round including the first: see
        // MAX_ANSWER and MIN_ANSWER.
        if (answer > MAX_ANSWER) revert AnswerTooLarge(answer);
        if (answer < MIN_ANSWER) revert AnswerTooSmall(answer);

        uint80 previousRound = _latestRound;
        if (previousRound != 0) {
            // The interval, before the deviation check, so a rejected burst
            // reverts for the honest reason rather than the derived one.
            uint256 elapsed = block.timestamp - _rounds[previousRound].updatedAt;
            if (elapsed < minRoundInterval) revert TooSoon(elapsed, minRoundInterval);

            int256 previous = _rounds[previousRound].answer;
            // Basis points, multiplied before divided: no floats, no truncation
            // of the bound itself. |answer - previous| * 10000 <= previous * bps
            int256 difference = answer > previous ? answer - previous : previous - answer;
            // A one-unit step is always permitted. With MIN_ANSWER in place no
            // reachable answer is absorbing, so this is belt and braces rather
            // than the fix - but it costs nothing and it means the bound can
            // never again be arithmetically unsatisfiable for any `previous`.
            // One unit is 1e-8 index points, and `minRoundInterval` bounds how
            // often it can be taken.
            if (difference > 1 && difference * 10_000 > previous * int256(uint256(maxDeviationBps))) {
                revert DeviationTooLarge(previous, answer, maxDeviationBps);
            }

            /*
             * And last, the cumulative bound, measured from an anchor that
             * only moves once a window has elapsed.
             *
             * Checked after the per-round bound deliberately, for the same
             * reason the interval is checked before it: a publish should fail
             * for the most immediate reason, not a derived one. If a single
             * step is too large, that is the fact worth reporting. Only when
             * every individual step is legal does "this window's budget is
             * spent" become the real reason - and that is the case this bound
             * exists for, because the attack it closes is a sequence of
             * perfectly in-bound steps.
             *
             * Refreshed lazily here rather than by anyone having to call
             * something: a window that only advances when somebody remembers
             * to advance it is a window that stays open. It refreshes to
             * `previous`, the last published answer, not to `answer`, so the
             * budget is spent relative to where the feed was when the window
             * opened.
             */
            if (block.timestamp - anchorAt >= deviationWindow) {
                anchorAnswer = previous;
                anchorAt = block.timestamp;
                emit WindowAnchorMoved(previous, block.timestamp);
            }
            int256 fromAnchor = answer > anchorAnswer ? answer - anchorAnswer : anchorAnswer - answer;
            // The same one-unit allowance as the per-round bound, so this one
            // cannot be arithmetically unsatisfiable either.
            if (fromAnchor > 1 && fromAnchor * 10_000 > anchorAnswer * int256(uint256(maxWindowDeviationBps))) {
                revert WindowDeviationTooLarge(anchorAnswer, answer, maxWindowDeviationBps, deviationWindow);
            }
        }

        if (previousRound == 0) {
            // The first round opens the first window. Exempt from both bounds
            // because there is nothing to measure from, which is the same
            // reason MIN_ANSWER and MAX_ANSWER exist.
            anchorAnswer = answer;
            anchorAt = block.timestamp;
            emit WindowAnchorMoved(answer, block.timestamp);
        }

        roundId = previousRound + 1;
        _latestRound = roundId;
        _rounds[roundId] = Round({answer: answer, startedAt: block.timestamp, updatedAt: block.timestamp});

        emit AnswerPublished(roundId, answer, block.timestamp, msg.sender);
    }

    /* --------------------------------------------------------------- pausing */

    function pause() external onlyRole(GUARDIAN_ROLE) {
        if (paused) revert AlreadyInThatState();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        if (!paused) revert AlreadyInThatState();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /* --------------------------------------------------------------- reading */

    /// @inheritdoc AggregatorV3Interface
    function description() external view returns (string memory) {
        return _description;
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure returns (uint256) {
        return 4;
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = _latestRound;
        if (roundId == 0) revert NoData();
        Round storage r = _rounds[roundId];
        // updatedAt is the publication time and is never touched by a read:
        // a consumer's staleness check is only as good as this field's honesty.
        return (roundId, r.answer, r.startedAt, r.updatedAt, roundId);
    }

    /// @inheritdoc AggregatorV3Interface
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round storage r = _rounds[_roundId];
        if (r.updatedAt == 0) revert NoData();
        return (_roundId, r.answer, r.startedAt, r.updatedAt, _roundId);
    }

    /// @notice The current round id, or 0 if nothing has been published.
    function latestRound() external view returns (uint80) {
        return _latestRound;
    }

    /**
     * @notice True when the latest answer is fresh enough to act on.
     * @dev A convenience for consumers; it does not excuse them from checking,
     *      and a consumer must still reject a paused feed if that matters to it.
     */
    function isFresh() external view returns (bool) {
        uint80 roundId = _latestRound;
        if (roundId == 0) return false;
        return block.timestamp - _rounds[roundId].updatedAt <= maxStaleness;
    }
}
