import { strict as assert } from "node:assert";
import { test } from "node:test";
import { applySlippage, quoteBuy, quoteRedeem, solvency } from "../src/lib/quote.ts";

const ONE = 10n ** 18n;
/** 200 MUSD per share, as IssuanceVault.price() returns it after scaling. */
const PRICE = 200n * ONE;

test("a buy quote matches the contract: fee off the input, shares off the net", () => {
  const quote = quoteBuy(1000n * ONE, PRICE, 50);
  assert.equal(quote.fee, 5n * ONE);
  assert.equal(quote.net, 995n * ONE);
  // 995 / 200 = 4.975 shares, which is the figure the fork test measures
  // against the real MUSD.
  assert.equal(quote.sharesOut, 4_975_000_000_000_000_000n);
});

test("a redeem quote takes its fee from the undivided product, as redeem() does", () => {
  const shares = 4_975_000_000_000_000_000n;
  const quote = quoteRedeem(shares, PRICE, 50);
  assert.equal(quote.gross, 995n * ONE);
  assert.equal(quote.fee, (shares * PRICE * 50n) / (ONE * 10_000n));
  assert.equal(quote.musdOut, quote.gross - quote.fee);
});

test("a round trip never profits, which is what the contract's fuzz test asserts", () => {
  const spend = 1000n * ONE;
  const bought = quoteBuy(spend, PRICE, 50);
  const back = quoteRedeem(bought.sharesOut, PRICE, 50);
  assert.ok(back.musdOut < spend);
});

test("zero and a dead price quote nothing rather than dividing by zero", () => {
  assert.deepEqual(quoteBuy(0n, PRICE, 50), { fee: 0n, net: 0n, sharesOut: 0n });
  assert.deepEqual(quoteBuy(ONE, 0n, 50), { fee: 0n, net: 0n, sharesOut: 0n });
  assert.deepEqual(quoteRedeem(ONE, 0n, 50), { gross: 0n, fee: 0n, musdOut: 0n });
});

test("slippage rounds down, so the minimum sent on chain is never above the quote", () => {
  assert.equal(applySlippage(1000n, 50), 995n);
  assert.equal(applySlippage(1n, 50), 0n);
  assert.equal(applySlippage(1000n, 0), 1000n);
  // Clamped: a tolerance above 100% would make the minimum negative.
  assert.equal(applySlippage(1000n, 20_000), 0n);
});

test("solvency names the shortfall, which is finding H-1 made visible", () => {
  const view = solvency(995n * ONE, 1194n * ONE);
  assert.equal(view.short, true);
  assert.equal(view.shortfall, 199n * ONE);
  assert.equal(view.coverageBps, 8333);
});

test("a vault with no shares outstanding is not reported as short", () => {
  assert.deepEqual(solvency(0n, 0n), { short: false, shortfall: 0n, coverageBps: null });
});
