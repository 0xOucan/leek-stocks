import { strict as assert } from "node:assert";
import { test } from "node:test";
import {
  assertDefinition,
  basketValue,
  decidePublish,
  indexValue,
  syntheticValue,
  toFeedUnits,
  type IndexDefinition,
} from "../src/index-math.ts";
import { INDICES } from "../src/indices.ts";

const DEFINITION: IndexDefinition = {
  symbol: "TESTDEX",
  description: "TESTDEX / MUSD",
  constituents: [
    { id: "a", weightBps: 6000 },
    { id: "b", weightBps: 4000 },
  ],
  baseValue: 100,
  baseBasket: 100,
};

test("the shipped definitions are well formed", () => {
  for (const index of INDICES) assertDefinition(index);
  // And none of them is named after a real company, which is a legal
  // requirement rather than taste: the Buildathon's terms warrant against
  // infringing third-party trademarks.
  const marks = ["google", "alphabet", "amazon", "apple", "microsoft", "nvidia", "tesla", "meta"];
  for (const index of INDICES) {
    const lowered = index.symbol.toLowerCase();
    for (const mark of marks) {
      assert.ok(!lowered.includes(mark), `${index.symbol} contains the mark ${mark}`);
    }
  }
});

test("weights must sum to 10000 bps and be unique", () => {
  assert.throws(
    () => assertDefinition({ ...DEFINITION, constituents: [{ id: "a", weightBps: 9999 }] }),
    /weights sum to 9999/,
  );
  assert.throws(
    () =>
      assertDefinition({
        ...DEFINITION,
        constituents: [
          { id: "a", weightBps: 5000 },
          { id: "a", weightBps: 5000 },
        ],
      }),
    /listed twice/,
  );
});

test("the basket is weighted, not averaged", () => {
  assert.equal(basketValue(DEFINITION, { a: 100, b: 200 }), 140);
});

test("a missing or absurd constituent price throws rather than counting as zero", () => {
  // The whole point: a dropped constituent would reprice the index downward by
  // its entire weight, which looks exactly like a market crash.
  assert.throws(() => basketValue(DEFINITION, { a: 100 }), /no usable price for b/);
  assert.throws(() => basketValue(DEFINITION, { a: 100, b: 0 }), /no usable price for b/);
  assert.throws(
    () => basketValue(DEFINITION, { a: 100, b: Number.NaN }),
    /no usable price for b/,
  );
});

test("the index reads as growth from its base", () => {
  // Basket at base is 100 and the index is 100; double the basket, double the
  // index, whatever the constituents' absolute prices are.
  assert.equal(indexValue(DEFINITION, { a: 100, b: 100 }), 100);
  assert.equal(indexValue(DEFINITION, { a: 200, b: 200 }), 200);
});

test("feed units round to nearest and refuse to round to zero", () => {
  assert.equal(toFeedUnits(123.456, 8), 12_345_600_000n);
  assert.equal(toFeedUnits(1.000000005, 8), 100_000_001n); // nearest, not truncated
  assert.throws(() => toFeedUnits(0.0000000001, 8), /rounds to zero/);
  assert.throws(() => toFeedUnits(0, 8), /not publishable/);
  assert.throws(() => toFeedUnits(-1, 8), /not publishable/);
});

const BASE = {
  thresholdBps: 50,
  heartbeatSeconds: 1800,
  maxDeviationBps: 2000,
};

test("the first round always publishes", () => {
  const decision = decidePublish({ ...BASE, target: 100n, last: null, secondsSinceLast: 0 });
  assert.equal(decision.publish, true);
  assert.equal(decision.answer, 100n);
  assert.match(decision.reason, /first round/);
});

test("a small move holds, so a quiet market does not burn gas", () => {
  const decision = decidePublish({
    ...BASE,
    target: 10_020n, // 20 bps
    last: 10_000n,
    secondsSinceLast: 10,
  });
  assert.equal(decision.publish, false);
  assert.match(decision.reason, /below 50/);
});

test("the heartbeat publishes even when nothing moved", () => {
  const decision = decidePublish({ ...BASE, target: 10_000n, last: 10_000n, secondsSinceLast: 1800 });
  assert.equal(decision.publish, true);
  assert.match(decision.reason, /heartbeat/);
});

test("a move past the oracle's bound is clamped, not dropped", () => {
  // The oracle reverts a round further than 20%, so publishing the bound walks
  // the price there over several rounds instead of losing the update.
  const up = decidePublish({ ...BASE, target: 20_000n, last: 10_000n, secondsSinceLast: 10 });
  assert.equal(up.publish, true);
  assert.equal(up.answer, 12_000n);
  assert.match(up.reason, /clamped/);

  const down = decidePublish({ ...BASE, target: 1_000n, last: 10_000n, secondsSinceLast: 10 });
  assert.equal(down.publish, true);
  assert.equal(down.answer, 8_000n);
});

test("a move exactly at the threshold publishes, and exactly at the bound is not clamped", () => {
  const atThreshold = decidePublish({ ...BASE, target: 10_050n, last: 10_000n, secondsSinceLast: 0 });
  assert.equal(atThreshold.publish, true);
  assert.equal(atThreshold.answer, 10_050n);

  const atBound = decidePublish({ ...BASE, target: 12_000n, last: 10_000n, secondsSinceLast: 0 });
  assert.equal(atBound.answer, 12_000n, "a move exactly at the bound must pass through");
  assert.doesNotMatch(atBound.reason, /clamped/);
});

test("a non-positive target throws rather than being published", () => {
  assert.throws(() => decidePublish({ ...BASE, target: 0n, last: 100n, secondsSinceLast: 0 }), /positive/);
});

test("the synthetic series is deterministic and stays inside the bound", () => {
  const index = INDICES[0]!;
  for (let step = 0; step < 50; step++) {
    const first = syntheticValue(index, step);
    assert.equal(syntheticValue(index, step), first, "the same step gave two values");
    assert.ok(
      first >= index.baseValue * 0.95 && first <= index.baseValue * 1.05,
      `step ${step} left the +/-5% band: ${first}`,
    );
  }
  // Two indices do not produce the same series, or a demo would show one line
  // drawn twice.
  assert.notEqual(syntheticValue(INDICES[0]!, 3), syntheticValue(INDICES[1]!, 3));
});
