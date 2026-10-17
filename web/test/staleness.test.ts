import { strict as assert } from "node:assert";
import { test } from "node:test";
import { claimAvailability, freshness } from "../src/lib/staleness.ts";

const NOW = 1_760_000_000;

test("fresh inside the window, stale outside it, matching IssuanceVault.price()", () => {
  assert.deepEqual(freshness(NOW - 10, NOW, 3600), { state: "fresh", ageSeconds: 10 });
  assert.deepEqual(freshness(NOW - 3600, NOW, 3600), { state: "fresh", ageSeconds: 3600 });
  // The contract compares with `>`, so exactly maxStaleness still prices.
  assert.deepEqual(freshness(NOW - 3601, NOW, 3600), { state: "stale", ageSeconds: 3601 });
});

test("nothing published yet is unknown, not stale", () => {
  assert.deepEqual(freshness(null, NOW, 3600), { state: "unknown", ageSeconds: null });
  assert.deepEqual(freshness(0, NOW, 3600), { state: "unknown", ageSeconds: null });
});

test("a browser clock behind the chain's does not invent staleness", () => {
  assert.deepEqual(freshness(NOW + 30, NOW, 3600), { state: "fresh", ageSeconds: 0 });
});

test("a faucet cooldown is reported before the click, not after a revert", () => {
  assert.deepEqual(claimAvailability(NOW + 600, NOW), { ready: false, waitSeconds: 600 });
  assert.deepEqual(claimAvailability(NOW, NOW), { ready: true, waitSeconds: 0 });
  assert.deepEqual(claimAvailability(NOW - 1, NOW), { ready: true, waitSeconds: 0 });
});

test("an unreadable cooldown does not disable the button", () => {
  assert.deepEqual(claimAvailability(null, NOW), { ready: true, waitSeconds: 0 });
  assert.deepEqual(claimAvailability(0, NOW), { ready: true, waitSeconds: 0 });
});
