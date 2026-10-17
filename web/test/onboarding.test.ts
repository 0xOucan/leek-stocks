import { strict as assert } from "node:assert";
import { test } from "node:test";
import {
  currentStep,
  isSetUp,
  onboardingSteps,
  setupProgress,
  type OnboardingInput,
} from "../src/lib/onboarding.ts";

const ONE = 10n ** 18n;

function steps(over: Partial<OnboardingInput> = {}) {
  return onboardingSteps({
    connected: true,
    onRightChain: true,
    native: ONE / 100n,
    musd: 1800n * ONE,
    shares: 0n,
    hasTrove: false,
    minNative: ONE / 1000n,
    minMusd: ONE,
    ...over,
  });
}

test("exactly one step is current, always", () => {
  for (const input of [
    {},
    { connected: false },
    { onRightChain: false },
    { native: 0n, musd: 0n },
    { shares: ONE },
  ] as Partial<OnboardingInput>[]) {
    assert.equal(steps(input).filter((s) => s.state === "current").length, 1, String(Object.keys(input)));
  }
});

test("a visitor with nothing is pointed at connecting, not at the faucet", () => {
  const list = steps({ connected: false, native: 0n, musd: 0n });
  assert.equal(currentStep(list)?.id, "connect");
  assert.ok(list.slice(1).every((s) => s.state === "todo"));
});

test("the wrong chain is caught before the faucet", () => {
  assert.equal(currentStep(steps({ onRightChain: false, native: 0n, musd: 0n }))?.id, "network");
});

test("an empty wallet on the right chain is sent to the faucet", () => {
  assert.equal(currentStep(steps({ native: 0n, musd: 0n }))?.id, "gas");
});

test("BTC but no MUSD is sent to the borrow market", () => {
  assert.equal(currentStep(steps({ musd: 0n }))?.id, "borrow");
});

test("an existing trove counts as borrowed even after the MUSD is spent", () => {
  /* The exact state after a full buy: the BTC went into collateral and the
     MUSD went into shares. Neither balance is high, and sending this user
     back to the faucet - or worse, to open a second trove, which reverts -
     is the loop this predicate exists to prevent. */
  const list = steps({ native: 0n, musd: 0n, shares: ONE, hasTrove: true });
  assert.equal(list.find((s) => s.id === "gas")?.state, "done");
  assert.equal(list.find((s) => s.id === "borrow")?.state, "done");
  assert.equal(currentStep(list)?.id, "redeem");
  assert.ok(isSetUp(list));
});

test("shares alone satisfy the borrow step, with no trove and no MUSD", () => {
  // MUSD from somewhere other than a trove, all of it already spent. There
  // is nothing left for this panel to teach.
  const list = steps({ musd: 0n, shares: ONE, hasTrove: false });
  assert.equal(list.find((s) => s.id === "borrow")?.state, "done");
  assert.ok(isSetUp(list));
});

test("the gas step says where the BTC went rather than that it is missing", () => {
  const gas = steps({ native: 0n, hasTrove: true }).find((s) => s.id === "gas");
  assert.equal(gas?.state, "done");
  assert.match(gas?.detail ?? "", /Spent on collateral/);
});

test("BTC and MUSD is set up, even with nothing bought yet", () => {
  /* The case that prompted this: 0x9c77... holds 0.085 BTC and 1798.87 MUSD
     with a trove open and no shares. Every control on the page works for it,
     so the setup panel has nothing to say and must not be shown. It used to
     be, with "you are here: buy index shares" - a step the trade form asks
     for in its own words two panels down. */
  const list = steps({ shares: 0n, hasTrove: true });
  assert.ok(isSetUp(list), "nothing left to set up");
  assert.equal(currentStep(list)?.id, "buy", "buying is still the next thing to do");
});

test("BTC but no MUSD is NOT set up, which is the other real wallet", () => {
  /* 0xcce7... holds 0.05 BTC, no MUSD and no trove. It can pay for gas and
     cannot buy anything, so the borrow step is exactly what it needs and the
     panel stays. */
  const list = steps({ musd: 0n, shares: 0n, hasTrove: false });
  assert.equal(isSetUp(list), false);
  assert.equal(currentStep(list)?.id, "borrow");
});

test("holding shares is also set up", () => {
  assert.ok(isSetUp(steps({ shares: 1n })));
  assert.equal(steps({ shares: 1n }).find((s) => s.id === "redeem")?.state, "current");
});

test("progress counts setup only, so it never reads 4 / 6 forever", () => {
  /* Buying and redeeming are the product, not onboarding. Counting them made
     a fully set-up wallet sit at "4 / 6" with no way to reach 6 short of
     selling, which reads as an unfinished checklist. */
  assert.deepEqual(setupProgress(steps({ connected: false, native: 0n, musd: 0n })), { done: 0, total: 4 });
  assert.deepEqual(setupProgress(steps({ musd: 0n })), { done: 3, total: 4 });
  assert.deepEqual(setupProgress(steps({ hasTrove: true })), { done: 4, total: 4 });
});

test("redeem is never marked done, because selling is not a milestone", () => {
  for (const input of [{}, { shares: ONE }, { shares: 0n, musd: 0n }] as Partial<OnboardingInput>[]) {
    assert.notEqual(steps(input).find((s) => s.id === "redeem")?.state, "done");
  }
});
