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

    /* ---------------------------------------------------------------- events */

    event AnswerPublished(uint80 indexed roundId, int256 answer, uint256 updatedAt, address indexed publisher);
    event Paused(address indexed guardian);
    event Unpaused(address indexed guardian);

    /* ---------------------------------------------------------------- errors */

    error NotPositive(int256 answer);
    error DeviationTooLarge(int256 previous, int256 proposed, uint16 maxBps);
    error FeedPaused();
    error NoData();
    error AlreadyInThatState();
    error ZeroAddress();
    error InvalidParameter();

    /**
     * @param description_ e.g. "GOLOGGLE / MUSD"
     * @param decimals_ answer decimals; 8 matches Chainlink's USD feeds
     * @param maxDeviationBps_ per-round move bound, 1-10000
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
        if (bytes(description_).length == 0) revert InvalidParameter();

        _description = description_;
        decimals = decimals_;
        maxDeviationBps = maxDeviationBps_;
        maxStaleness = maxStaleness_;

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

        uint80 previousRound = _latestRound;
        if (previousRound != 0) {
            int256 previous = _rounds[previousRound].answer;
            // Basis points, multiplied before divided: no floats, no truncation
            // of the bound itself. |answer - previous| * 10000 <= previous * bps
            int256 difference = answer > previous ? answer - previous : previous - answer;
            if (difference * 10_000 > previous * int256(uint256(maxDeviationBps))) {
                revert DeviationTooLarge(previous, answer, maxDeviationBps);
            }
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
