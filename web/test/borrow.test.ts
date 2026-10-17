import { strict as assert } from "node:assert";
import { test } from "node:test";
import {
  FEE_MARGIN_BPS,
  GAS_COMPENSATION,
  currentIcr,
  formatIcr,
  borrowMoreBlocker,
  positionPlan,
  repayBlocker,
  startingCollateral,
  troveQuote,
} from "../src/lib/borrow.ts";

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

const GAS = 10n ** 14n;

test("a comfortable wallet is offered twice the suggested collateral", () => {
  assert.equal(startingCollateral(ONE / 1000n, ONE, GAS), ONE / 500n);
});

test("a thin wallet is offered what it can actually spend, not more", () => {
  const suggested = ONE / 1000n;              // 0.001
  const balance = suggested + GAS + 1n;       // only just enough
  const offered = startingCollateral(suggested, balance, GAS);
  assert.ok(offered >= suggested, "still meets the ratio this page requires");
  assert.ok(offered <= balance - GAS, "leaves the gas allowance behind");
});

test("a wallet that cannot cover the minimum ratio is offered nothing", () => {
  /* The dead end this function exists to prevent: the alternative was a
     prefill below the required ratio, whose only remedy - asking for the
     suggested figure - was then refused for insufficient balance. Zero is
     the honest answer, and it is the one the stepper's own threshold
     (suggested + gas) agrees with. */
  assert.equal(startingCollateral(ONE, ONE / 2n, GAS), 0n);
  assert.equal(startingCollateral(ONE, ONE + GAS - 1n, GAS), 0n);
});

test("nothing suggested means nothing offered, with no negative wei", () => {
  assert.equal(startingCollateral(0n, ONE, GAS), 0n);
  assert.equal(startingCollateral(ONE / 1000n, 0n, GAS), 0n);
});

test("currentIcr agrees with the chain for the live position", () => {
  /* Same reading as the formula test above, through the function the panels
     actually call, so the two cannot drift apart. */
  const chain = 99551329979908049209n;
  const icr = currentIcr(ONE / 100n, PRICE, 2009013835172674471222n);
  assert.ok(icr !== null);
  const drift = icr > chain ? icr - chain : chain - icr;
  assert.ok(drift * 10_000_000n < chain);
});

test("a position with no debt has no ratio, rather than a ratio of zero", () => {
  // 0% is the one number that means "liquidate me now". A closed or empty
  // trove must not render as one.
  assert.equal(currentIcr(ONE, PRICE, 0n), null);
  assert.equal(currentIcr(ONE, null, ONE), null);
  assert.equal(currentIcr(ONE, 0n, ONE), null);
});

/* ------------------------------------------------- managing a live position */

/** The deployer's real trove, read from the chain on 2026-10-17. */
const LIVE = {
  debt: 2009017413000000000000n,
  collateral: ONE / 100n,
  price: PRICE,
  minNetDebt: MIN_NET_DEBT,
  musdBalance: 1798873292098111198114n,
};

test("the plan reproduces the live position's limits to the wei", () => {
  /* Every one of these was simulated against the live contract from
     0x9c77..., which holds this exact trove and this exact MUSD balance:

       repayMUSD(5)       succeeds
       repayMUSD(9)       succeeds
       repayMUSD(20)      reverts, "Trove's net debt must be greater than minimum"
       closeTrove()       reverts, "Caller doesnt have enough mUSD to make repayment"

     So the ceiling is between 9 and 20, and this says 9.017413. */
  const plan = positionPlan(LIVE);
  assert.equal(plan.netDebt, 1809017413000000000000n);
  assert.equal(plan.repayCeiling, 9017413000000000000n);
  assert.equal(plan.maxRepay, 9017413000000000000n, "the wallet is not the binding limit here");
  assert.equal(plan.closeCost, plan.netDebt);
  assert.equal(plan.canClose, false);
  // Short by the interest and fee it has already paid out of that balance.
  assert.equal(plan.shortToClose, 10144120901888801886n);
});

test("the repay boundary matches the chain either side of it", () => {
  const plan = positionPlan(LIVE);
  assert.equal(repayBlocker(5n * ONE, plan, LIVE.musdBalance), null, "5 succeeded on chain");
  assert.equal(repayBlocker(9n * ONE, plan, LIVE.musdBalance), null, "9 succeeded on chain");
  assert.match(String(repayBlocker(20n * ONE, plan, LIVE.musdBalance)), /under the protocol's minimum/);
  // The boundary itself, which the chain accepts and one wei past it, which
  // it does not.
  assert.equal(repayBlocker(plan.repayCeiling, plan, LIVE.musdBalance), null);
  assert.match(String(repayBlocker(plan.repayCeiling + 1n, plan, LIVE.musdBalance)), /under the protocol's minimum/);
});

test("a trove exactly at the minimum cannot be repaid in part at all", () => {
  /* The common case for a tester: borrow the 1800 minimum, so there is no
     room between the debt and the floor. The message has to say that closing
     is the only route rather than "repay less", which would be advice that
     leads nowhere. */
  const plan = positionPlan({ ...LIVE, debt: MIN_NET_DEBT + GAS_COMPENSATION });
  assert.equal(plan.repayCeiling, 0n);
  assert.match(String(repayBlocker(ONE, plan, LIVE.musdBalance)), /cannot be repaid in part/);
});

test("closing is possible exactly when the wallet covers the net debt", () => {
  const atCost = positionPlan({ ...LIVE, musdBalance: 1809017413000000000000n });
  assert.ok(atCost.canClose);
  assert.equal(atCost.shortToClose, 0n);

  const oneShort = positionPlan({ ...LIVE, musdBalance: 1809017412999999999999n });
  assert.equal(oneShort.canClose, false);
  assert.equal(oneShort.shortToClose, 1n);
});

test("a wallet holding more MUSD than the debt is still only asked for the debt", () => {
  const rich = positionPlan({ ...LIVE, musdBalance: 10_000n * ONE });
  assert.ok(rich.canClose);
  assert.equal(rich.closeCost, rich.netDebt);
  // The ceiling, not the balance, is what bounds a partial repayment.
  assert.equal(rich.maxRepay, rich.repayCeiling);
});

test("borrowing more is bounded by 150%, which is stricter than the chain's 110%", () => {
  /* On chain, from the same position: withdrawMUSD(1000) and
     withdrawMUSD(100000) both succeed, and withdrawMUSD(200000) reverts with
     "An operation that would result in ICR < MCR". The collateral is worth
     $200,000, so the chain's own limit is near 181,000 and ours is near
     131,000. This page being the stricter of the two is the point. */
  const plan = positionPlan(LIVE);
  assert.equal(borrowMoreBlocker(1000n * ONE, plan), null);
  assert.equal(borrowMoreBlocker(100_000n * ONE, plan), null, "accepted on chain, and inside 150%");
  assert.match(String(borrowMoreBlocker(200_000n * ONE, plan)), /below the 150%/);

  // At the ceiling the resulting ratio is still at or above SAFE_ICR, fee
  // included - which is the thing the fee correction in positionPlan is for.
  const after = currentIcr(
    LIVE.collateral,
    PRICE,
    LIVE.debt + plan.maxBorrowMore + (plan.maxBorrowMore * FEE_MARGIN_BPS) / 10_000n,
  );
  assert.ok(after !== null && after >= (15n * ONE) / 10n, `ratio after borrowing the maximum: ${after}`);
});

test("no price means no borrowing more, rather than an unbounded figure", () => {
  assert.equal(positionPlan({ ...LIVE, price: null }).maxBorrowMore, 0n);
  assert.equal(positionPlan({ ...LIVE, price: 0n }).maxBorrowMore, 0n);
});

test("a position with no debt yields no limits and cannot be closed", () => {
  const plan = positionPlan({ ...LIVE, debt: 0n });
  assert.equal(plan.netDebt, 0n);
  assert.equal(plan.repayCeiling, 0n);
  assert.equal(plan.canClose, false, "there is nothing to close");
});
