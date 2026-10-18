// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {IndexOracle} from "../src/IndexOracle.sol";

/**
 * Tests for the properties that matter: who may publish, what a publish is
 * allowed to do to the previous answer, that history is immutable, and that
 * staleness is reported from the publication time rather than the read time.
 * Getters and OpenZeppelin's own role plumbing are not re-tested.
 */
contract IndexOracleTest is Test {
    IndexOracle oracle;

    address admin = makeAddr("admin");
    address publisher = makeAddr("publisher");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");

    uint8 constant DECIMALS = 8;
    uint16 constant MAX_DEVIATION_BPS = 1000; // 10%
    uint32 constant MAX_STALENESS = 1 hours;
    /// Seconds the oracle requires between rounds. See IndexOracle.
    uint32 constant MIN_ROUND_INTERVAL = 30 seconds;
    int256 constant FIRST = 100e8;

    event AnswerPublished(uint80 indexed roundId, int256 answer, uint256 updatedAt, address indexed publisher);

    function setUp() public {
        oracle = new IndexOracle(
            "GOLOGGLE / MUSD", DECIMALS, MAX_DEVIATION_BPS, MAX_STALENESS, MIN_ROUND_INTERVAL, admin, publisher, guardian
        );
        // Timestamps start at 1 in Foundry; move clear of zero so that
        // "updatedAt == 0 means no round" cannot be satisfied accidentally.
        vm.warp(1_700_000_000);
    }

    /**
     * Publish, advancing the clock past the round interval first.
     *
     * The oracle now requires `minRoundInterval` between rounds, so a test
     * that publishes twice in one block is testing an impossible sequence.
     * The interval exists because the deviation bound is per round: without
     * it, five rounds in one transaction compound 20% into 2.49x and the same
     * transaction can buy before and redeem after. See
     * test/AdminTheft.t.sol.
     */
    function _publish(int256 answer) internal returns (uint80) {
        vm.warp(block.timestamp + MIN_ROUND_INTERVAL);
        vm.prank(publisher);
        return oracle.publish(answer);
    }

    /// Publish without advancing, for the tests that assert the refusal.
    function _publishNow(int256 answer) internal returns (uint80) {
        vm.prank(publisher);
        return oracle.publish(answer);
    }

    /* ------------------------------------------------------ construction */

    function test_constructor_rejectsNonsense() public {
        vm.expectRevert(IndexOracle.ZeroAddress.selector);
        new IndexOracle("x", DECIMALS, MAX_DEVIATION_BPS, MAX_STALENESS, MIN_ROUND_INTERVAL, address(0), publisher, guardian);

        vm.expectRevert(IndexOracle.InvalidParameter.selector);
        new IndexOracle("x", 19, MAX_DEVIATION_BPS, MAX_STALENESS, MIN_ROUND_INTERVAL, admin, publisher, guardian);

        vm.expectRevert(IndexOracle.InvalidParameter.selector);
        new IndexOracle("x", DECIMALS, 0, MAX_STALENESS, MIN_ROUND_INTERVAL, admin, publisher, guardian);

        vm.expectRevert(IndexOracle.InvalidParameter.selector);
        new IndexOracle("x", DECIMALS, 10_001, MAX_STALENESS, MIN_ROUND_INTERVAL, admin, publisher, guardian);

        vm.expectRevert(IndexOracle.InvalidParameter.selector);
        new IndexOracle("x", DECIMALS, MAX_DEVIATION_BPS, 0, MIN_ROUND_INTERVAL, admin, publisher, guardian);

        // A zero interval would permit a burst of rounds in one block, which
        // is what compounds the deviation bound into a price attack.
        vm.expectRevert(IndexOracle.InvalidParameter.selector);
        new IndexOracle("x", DECIMALS, MAX_DEVIATION_BPS, MAX_STALENESS, 0, admin, publisher, guardian);

        // An interval at or above staleness makes the feed stale before the
        // next round is even permitted.
        vm.expectRevert(IndexOracle.InvalidParameter.selector);
        new IndexOracle("x", DECIMALS, MAX_DEVIATION_BPS, MAX_STALENESS, MAX_STALENESS, admin, publisher, guardian);

        vm.expectRevert(IndexOracle.InvalidParameter.selector);
        new IndexOracle("", DECIMALS, MAX_DEVIATION_BPS, MAX_STALENESS, MIN_ROUND_INTERVAL, admin, publisher, guardian);
    }

    /* ----------------------------------------------------- empty feed */

    function test_readingBeforeAnyPublishReverts() public {
        vm.expectRevert(IndexOracle.NoData.selector);
        oracle.latestRoundData();
        vm.expectRevert(IndexOracle.NoData.selector);
        oracle.getRoundData(1);
        assertEq(oracle.latestRound(), 0);
        assertFalse(oracle.isFresh(), "an empty feed is not fresh");
    }

    /* ------------------------------------------------------- publishing */

    function test_publishEmitsAndRecords() public {
        // Warp before the expectation, not inside the publish helper: the
        // event carries block.timestamp, so the expected value has to be read
        // at the same clock the publish will see.
        vm.warp(block.timestamp + MIN_ROUND_INTERVAL);
        vm.expectEmit(true, true, false, true, address(oracle));
        emit AnswerPublished(1, FIRST, block.timestamp, publisher);
        uint80 id = _publishNow(FIRST);
        assertEq(id, 1);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) =
            oracle.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, FIRST);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredIn, 1);
        assertTrue(oracle.isFresh());
    }

    function test_onlyPublisherMayPublish() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, oracle.PUBLISHER_ROLE()
            )
        );
        vm.prank(stranger);
        oracle.publish(FIRST);

        // Nor may the guardian, whose power is to stop the feed, not to move it.
        vm.expectRevert();
        vm.prank(guardian);
        oracle.publish(FIRST);
    }

    function test_nonPositiveAnswersRejected() public {
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(IndexOracle.NotPositive.selector, int256(0)));
        oracle.publish(0);

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(IndexOracle.NotPositive.selector, int256(-1)));
        oracle.publish(-1);
    }

    function test_roundIdsAreMonotonicAndHistoryImmutable() public {
        _publish(FIRST);
        _publish(FIRST + 1e8);
        _publish(FIRST + 2e8);
        assertEq(oracle.latestRound(), 3);

        (, int256 first,,,) = oracle.getRoundData(1);
        assertEq(first, FIRST, "round 1 changed under later publishes");
        (, int256 second,,,) = oracle.getRoundData(2);
        assertEq(second, FIRST + 1e8);

        vm.expectRevert(IndexOracle.NoData.selector);
        oracle.getRoundData(4);
    }

    /* -------------------------------------------------- deviation bound */

    function test_deviationBoundHoldsBothDirections() public {
        _publish(FIRST); // 100.00000000

        // Exactly at the bound is allowed: 10% of 100 is 110.
        _publish(110e8);

        // A hair past the bound from 110 is refused.
        int256 tooHigh = 110e8 + (110e8 * int256(uint256(MAX_DEVIATION_BPS)) / 10_000) + 1;
        // Past the interval, so the refusal below is the deviation bound and
        // not the round interval. Both guards reject this publish; the test is
        // about the second one.
        vm.warp(block.timestamp + MIN_ROUND_INTERVAL);
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(IndexOracle.DeviationTooLarge.selector, 110e8, tooHigh, MAX_DEVIATION_BPS)
        );
        oracle.publish(tooHigh);

        // And downward: a collapse to a tenth is refused, which is the shape of
        // the fat-finger that liquidates everyone.
        vm.warp(block.timestamp + MIN_ROUND_INTERVAL);
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(IndexOracle.DeviationTooLarge.selector, 110e8, int256(11e8), MAX_DEVIATION_BPS)
        );
        oracle.publish(11e8);
    }

    function test_firstPublishIsExemptFromTheBound() public {
        // Nothing to deviate from, so any positive answer is accepted. This is
        // the one value the publisher sets freely, by design.
        _publish(1);
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, 1);
    }

    /// Fuzzed: a move within the bound is always accepted, one outside never is.
    function testFuzz_deviationBound(int256 start, int256 next) public {
        start = bound(start, 1e8, 1e18);
        next = bound(next, 1, type(int64).max);
        _publish(start);

        int256 difference = next > start ? next - start : start - next;
        bool withinBound = difference * 10_000 <= start * int256(uint256(MAX_DEVIATION_BPS));

        // Isolate the deviation bound from the round interval.
        vm.warp(block.timestamp + MIN_ROUND_INTERVAL);
        vm.prank(publisher);
        if (withinBound) {
            oracle.publish(next);
            (, int256 answer,,,) = oracle.latestRoundData();
            assertEq(answer, next, "an in-bound answer was not stored");
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(IndexOracle.DeviationTooLarge.selector, start, next, MAX_DEVIATION_BPS)
            );
            oracle.publish(next);
        }
    }

    /* ------------------------------------------------------- staleness */

    function test_stalenessIsMeasuredFromPublication() public {
        _publish(FIRST);
        assertTrue(oracle.isFresh());

        vm.warp(block.timestamp + MAX_STALENESS);
        assertTrue(oracle.isFresh(), "exactly at the limit is still fresh");

        vm.warp(block.timestamp + 1);
        assertFalse(oracle.isFresh(), "past the limit must not be fresh");

        // A read does not refresh anything: updatedAt is the publication time.
        (,,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(updatedAt, block.timestamp - MAX_STALENESS - 1);

        // And a stale answer is still returned rather than reverting, because
        // Chainlink's does the same and consumers are written for that.
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, FIRST);
    }

    function testFuzz_freshnessFollowsTheClock(uint32 elapsed) public {
        _publish(FIRST);
        vm.warp(block.timestamp + elapsed);
        assertEq(oracle.isFresh(), elapsed <= MAX_STALENESS);
    }

    /* --------------------------------------------------------- pausing */

    function test_guardianPausesPublishingOnly() public {
        _publish(FIRST);

        vm.prank(guardian);
        oracle.pause();
        assertTrue(oracle.paused());

        vm.prank(publisher);
        vm.expectRevert(IndexOracle.FeedPaused.selector);
        oracle.publish(FIRST);

        // Reads keep working while paused: a consumer decides what a paused
        // feed means for it, and freezing reads would strand every position.
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, FIRST);

        vm.prank(guardian);
        oracle.unpause();
        _publish(FIRST);
        assertEq(oracle.latestRound(), 2);
    }

    function test_onlyGuardianMayPause() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, publisher, oracle.GUARDIAN_ROLE()
            )
        );
        vm.prank(publisher);
        oracle.pause();
    }

    function test_redundantPauseReverts() public {
        vm.prank(guardian);
        oracle.pause();
        vm.prank(guardian);
        vm.expectRevert(IndexOracle.AlreadyInThatState.selector);
        oracle.pause();
    }

    /* ----------------------------------------------------- role separation */

    function test_rolesAreSeparate() public view {
        assertTrue(oracle.hasRole(oracle.PUBLISHER_ROLE(), publisher));
        assertFalse(oracle.hasRole(oracle.GUARDIAN_ROLE(), publisher), "publisher must not also pause");
        assertFalse(oracle.hasRole(oracle.PUBLISHER_ROLE(), guardian), "guardian must not also publish");
        assertFalse(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), publisher));
    }
}
