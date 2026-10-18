/**
 * The rate the staking panel prints, and the claims it is not allowed to make.
 *
 * A share pays no income and the page says so. A staked position does earn,
 * which makes a rate meaningful here and makes an overstated one the risk. So
 * these tests are mostly about when the function must refuse to answer.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { MIN_WINDOW_SECONDS, describeWindow, rateView } from "../src/lib/stakingRate.ts";

const ONE = 10n ** 18n;

test("no rate before a second reading", () => {
  const view = rateView({
    totalDistributed: ONE,
    totalStaked: 1_000n * ONE,
    first: null,
    latest: { accMusdPerShare: 5n * ONE, atSeconds: 1_000 },
  });
  assert.equal(view.observedApr, null);
  assert.match(view.reason ?? "", /second reading/);
});

test("no rate from a window too short to extrapolate from", () => {
  /* The failure this guards against is the plausible-looking number: one
     large trade 30 seconds after the page opened annualises to a figure that
     is arithmetically correct and completely meaningless. */
  const view = rateView({
    totalDistributed: ONE,
    totalStaked: 1_000n * ONE,
    first: { accMusdPerShare: 0n, atSeconds: 1_000 },
    latest: { accMusdPerShare: ONE / 100n, atSeconds: 1_030 },
  });
  assert.equal(view.observedApr, null);
  assert.equal(view.windowSeconds, 30);
  assert.match(view.reason ?? "", /before quoting a rate/);
});

test("no rate when no revenue arrived, however long the window", () => {
  // Zero is a real answer and the panel says it in words. Printing "0.00% APR"
  // would read as a measurement rather than as an absence of trades.
  const view = rateView({
    totalDistributed: 0n,
    totalStaked: 1_000n * ONE,
    first: { accMusdPerShare: 0n, atSeconds: 0 },
    latest: { accMusdPerShare: 0n, atSeconds: 86_400 },
  });
  assert.equal(view.observedApr, null);
  assert.match(view.reason ?? "", /no fee revenue/);
});

test("the rate annualises the accumulator's own movement", () => {
  /* 0.01 MUSD per staked unit over a day. The accumulator is already
     per-unit, so the answer must not depend on totalStaked at all - which is
     the property that stops a stake made mid-window corrupting the figure. */
  const window = 86_400;
  const movement = ONE / 100n;
  const expected = 0.01 * (365 * 24 * 60 * 60 / window) * 100;

  for (const totalStaked of [1n * ONE, 1_000n * ONE, 10_000_000n * ONE]) {
    const view = rateView({
      totalDistributed: ONE,
      totalStaked,
      first: { accMusdPerShare: 0n, atSeconds: 0 },
      latest: { accMusdPerShare: movement, atSeconds: window },
    });
    assert.ok(view.observedApr !== null);
    assert.ok(
      Math.abs((view.observedApr as number) - expected) < 1e-6,
      `totalStaked changed the rate: ${String(view.observedApr)} vs ${expected}`,
    );
  }
});

test("the realised figure is per MEZO, and survives an empty contract", () => {
  const view = rateView({
    totalDistributed: 50n * ONE,
    totalStaked: 1_000n * ONE,
    first: null,
    latest: { accMusdPerShare: 0n, atSeconds: 0 },
  });
  assert.ok(Math.abs(view.realisedPerMezo - 0.05) < 1e-12);

  const empty = rateView({
    totalDistributed: 0n,
    totalStaked: 0n,
    first: null,
    latest: { accMusdPerShare: 0n, atSeconds: 0 },
  });
  assert.equal(empty.realisedPerMezo, 0, "a division by an empty pool must not be NaN");
});

test("the window is long enough to be worth printing", () => {
  // Two minutes. Shorter and one trade dominates; much longer and a demo
  // never gets to show a number at all.
  assert.ok(MIN_WINDOW_SECONDS >= 60);
  assert.equal(describeWindow(30), "30s");
  assert.equal(describeWindow(600), "10m");
  assert.equal(describeWindow(3_900), "1h 5m");
});

test("the panel never prints a rate without the window beside it", () => {
  /* A bare "12.4% APR" reads as a property of the protocol. It is an
     extrapolation from however long this page happened to be open, and the
     sentence that says so has to travel with the number. */
  const APP = readFileSync(new URL("../src/app.ts", import.meta.url), "utf8");
  const index = APP.indexOf("% APR");
  assert.ok(index > 0, "the panel no longer prints a rate - update this test");
  const near = APP.slice(index, index + 500);
  assert.match(near, /describeWindow\(rate\.windowSeconds\)/);
  assert.match(near, /not a forecast/);
});

test("the page still refuses to claim a yield on holding a share", () => {
  /* The staking panel introduces a legitimate rate, and the risk is that it
     launders the share into looking like it earns too. Shares and stakes are
     different instruments and the page has to keep saying so. */
  const APP = readFileSync(new URL("../src/app.ts", import.meta.url), "utf8");
  assert.ok(APP.includes("Holding a share pays no income."));
  assert.ok(APP.includes("Unlike holding a share, this does earn."));
});
