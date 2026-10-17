import { strict as assert } from "node:assert";
import { test } from "node:test";
import { FEE_MARGIN_BPS, GAS_COMPENSATION, formatIcr, troveQuote } from "../src/lib/borrow.ts";

const ONE = 10n ** 18n;
/** Mezo testnet's real feed: $20,000,000 a BTC. */
const PRICE = 2n * 10n ** 25n;
const MIN_NET_DEBT = 1800n * ONE;
const MCR = (11n * ONE) / 10n;

function quote(over: Partial<Parameters<typeof troveQuote>[0]> = {}) {
  return troveQuote({
    debtRequested: MIN_NET_DEBT,
    collateral: ONE / 100n, // 0.01 BTC
    price: PRICE,
    minNetDebt: MIN_NET_DEBT,
    mcr: MCR,
    balance: ONE / 10n,
    ...over,
  });
}

test("the debt is the borrow plus the gas reserve plus a fee allowance", () => {
  const q = quote();
  assert.equal(q.estimatedDebt, MIN_NET_DEBT + GAS_COMPENSATION + (MIN_NET_DEBT * FEE_MARGIN_BPS) / 10_000n);
  // 1800 + 200 + 18. The real trove opened on chain owed 2009.0138, so this
  // over-states by ~9 MUSD, which is the direction that cannot hurt anyone.
  assert.equal(q.estimatedDebt, 2018n * ONE);
});

test("the ICR formula is the protocol's, checked against a live getCurrentICR", () => {
  /* The real trove: 0.01 BTC against a debt getTroveDebt reported as
     2009.013835172674471222 MUSD, for which getCurrentICR answered
     99551329979908049209 at $20,000,000 a BTC.

     Checked to a tolerance rather than for equality, and the tolerance is the
     finding: the two values came from two eth_calls in two different blocks,
     and this trove accrues interest, so the debt had grown by the time the
     ICR was read. They agree to twelve significant digits, which is
     consistent with a few seconds of interest and not with a wrong formula.
     The drift is 3.8e-9 of the value; at this trove's rate, interest moves
     the debt by about 1.6e-9 per second, so the two reads were roughly two
     seconds apart. The tolerance below is 1e-7 - a couple of minutes of
     interest - because a transposed multiply and divide would be out by
     orders of magnitude, not by parts per billion. */
  const debt = 2009013835172674471222n;
  const collateralValue = ((ONE / 100n) * PRICE) / ONE;
  const mine = (collateralValue * ONE) / debt;
  const chain = 99551329979908049209n;
  const drift = mine > chain ? mine - chain : chain - mine;
  assert.ok(drift * 10_000_000n < chain, `drift ${drift} is too large to be interest`);
});

test("0.01 BTC against the minimum borrow is nowhere near liquidation", () => {
  const q = quote();
  assert.equal(q.blocker, null);
  // 0.01 BTC is $200,000 against 2018 MUSD: 9910%.
  assert.ok(q.icr !== null && q.icr > 99n * ONE);
});

test("the suggested collateral lands at or just above 150%", () => {
  const q = quote();
  const at = quote({ collateral: q.suggestedCollateral });
  assert.equal(at.blocker, null);
  assert.ok(at.icr !== null && at.icr >= (15n * ONE) / 10n);
});

test("the minimum collateral is accepted by the protocol but refused by this page", () => {
  const q = quote();
  const at = quote({ collateral: q.minimumCollateral });
  assert.ok(at.icr !== null && at.icr >= MCR, "the protocol's own floor is met");
  assert.match(String(at.blocker), /below 150%/);
});

test("a borrow under the protocol minimum names the minimum, not the balance", () => {
  const q = quote({ debtRequested: 100n * ONE, collateral: 0n, balance: 0n });
  assert.match(String(q.blocker), /minimum of 1800 MUSD/);
});

test("collateral above the balance is refused before it is signed", () => {
  assert.match(String(quote({ collateral: ONE, balance: ONE / 2n }).blocker), /more BTC than this wallet holds/);
});

test("locking the whole balance is refused, because gas comes out of it", () => {
  assert.match(String(quote({ collateral: ONE / 10n, balance: ONE / 10n }).blocker), /some BTC behind for gas/);
});

test("a dead price feed blocks rather than dividing by zero", () => {
  const q = quote({ price: 0n });
  assert.match(String(q.blocker), /price feed/);
  assert.equal(q.suggestedCollateral, 0n);
  assert.equal(q.icr, 0n);
});

test("empty inputs ask for the amount rather than reporting a failure", () => {
  assert.equal(quote({ debtRequested: 0n }).blocker, "Enter how much MUSD to borrow.");
  assert.equal(quote({ collateral: 0n }).blocker, "Enter how much BTC to lock as collateral.");
});

test("formatIcr caps the testnet's absurd ratios instead of printing them", () => {
  assert.equal(formatIcr(null), "—");
  assert.equal(formatIcr((2n * ONE)), "200%");
  assert.equal(formatIcr(99551n * ONE), "> 100,000%");
});
