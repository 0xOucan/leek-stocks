import { strict as assert } from "node:assert";
import { test } from "node:test";
import { currentStep, isComplete, onboardingSteps, type OnboardingInput } from "../src/lib/onboarding.ts";

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
  assert.ok(isComplete(list));
});

test("the gas step says where the BTC went rather than that it is missing", () => {
  const gas = steps({ native: 0n, hasTrove: true }).find((s) => s.id === "gas");
  assert.equal(gas?.state, "done");
  assert.match(gas?.detail ?? "", /Spent on collateral/);
});

test("MUSD in hand makes buying the current step", () => {
  assert.equal(currentStep(steps())?.id, "buy");
  assert.equal(isComplete(steps()), false);
});

test("holding shares completes onboarding", () => {
  const list = steps({ shares: 1n });
  assert.ok(isComplete(list));
  assert.equal(list.find((s) => s.id === "redeem")?.state, "current");
});

test("redeem is never marked done, because selling is not a milestone", () => {
  for (const input of [{}, { shares: ONE }, { shares: 0n, musd: 0n }] as Partial<OnboardingInput>[]) {
    assert.notEqual(steps(input).find((s) => s.id === "redeem")?.state, "done");
  }
});
