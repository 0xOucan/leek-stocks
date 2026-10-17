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
  // The contract's own verdict, not a reconstruction of it: claimStatus
  // already accounts for the cooldown, the pause, the per-token enablement and
  // the total cap, so anything computed here could only disagree with it.
  assert.deepEqual(claimAvailability({ claimable: false, secondsRemaining: 600 }, NOW), {
    ready: false,
    waitSeconds: 600,
  });
  assert.deepEqual(claimAvailability({ claimable: true, secondsRemaining: 0 }, NOW), {
    ready: true,
    waitSeconds: 0,
  });
});

test("not claimable for a reason other than the clock still disables the button", () => {
  // Paused, disabled, or the total cap reached: no time remains, and the claim
  // would still revert. Reporting "ready" because the cooldown expired would
  // be the UI predicting success the contract has already refused.
  assert.deepEqual(claimAvailability({ claimable: false, secondsRemaining: 0 }, NOW), {
    ready: false,
    waitSeconds: 0,
  });
});

test("an unreadable status does not disable the button", () => {
  // Hiding a working faucet behind a failed read is worse than a claim that
  // reverts and says why.
  assert.deepEqual(claimAvailability(null, NOW), { ready: true, waitSeconds: 0 });
});
