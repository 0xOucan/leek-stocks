import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { feeView, solvency } from "../src/lib/quote.ts";

const ONE = 10n ** 18n;

/*
 * Pinned to the live GOLOGGLE vault on Mezo testnet, read 2026-10-17:
 *   feeBps 50, reserveShareBps 5000, feesAccrued 1.136595981122828616 MUSD,
 *   reserves 145.035739, supply 1.448714, price 99.742924.
 */
const RESERVES = 145035739000000000000n;
const LIABILITIES = 144498950000000000000n;

test("the fee split is read, not assumed", () => {
  const v = feeView(50, 5000, RESERVES, LIABILITIES);
  assert.equal(v.toReservesBps, 25);
  assert.equal(v.toTreasuryBps, 25);
});

test("an odd split does not silently become a half", () => {
  // The bug this guards: writing feeBps / 2 because the live split happens to
  // be even. At 7500 bps three quarters of the fee is backing.
  const v = feeView(50, 7500, RESERVES, LIABILITIES);
  assert.equal(v.toReservesBps, 37.5);
  assert.equal(v.toTreasuryBps, 12.5);
  // The two halves must still account for the whole fee.
  assert.equal(v.toReservesBps + v.toTreasuryBps, 50);
});

test("a fee that all goes to backing leaves no revenue", () => {
  const v = feeView(50, 10_000, RESERVES, LIABILITIES);
  assert.equal(v.toReservesBps, 50);
  assert.equal(v.toTreasuryBps, 0);
});

test("surplus is the over-collateralisation, and zero when short", () => {
  assert.equal(feeView(50, 5000, RESERVES, LIABILITIES).surplus, RESERVES - LIABILITIES);
  // Short: the surplus is zero rather than negative, and solvency() owns the
  // shortfall so there is exactly one source for that number.
  assert.equal(feeView(50, 5000, LIABILITIES, RESERVES).surplus, 0n);
  assert.equal(solvency(LIABILITIES, RESERVES).shortfall, RESERVES - LIABILITIES);
});

test("an unreadable price leaves the surplus unknown rather than inventing one", () => {
  // liabilities() calls price(), so it reverts whenever the price does.
  // Reporting the whole of reserves as surplus would be the worst answer.
  assert.equal(feeView(50, 5000, RESERVES, null).surplus, 0n);
});

test("the live vault is over-collateralised, and barely", () => {
  const v = solvency(RESERVES, LIABILITIES);
  assert.equal(v.short, false);
  // 100.371%, so the panel must not round this to a flat 100%.
  assert.ok(v.coverageBps !== null && v.coverageBps > 10_000 && v.coverageBps < 10_050);
});

/*
 * The claim guard.
 *
 * redeem() pays `shares * price - fee` and never reads reserves, so holding a
 * share pays nothing. These assertions exist so that a later change which
 * introduces an APY, a yield figure or a "shares earn" claim has to delete a
 * test that says why it is false, rather than quietly shipping it.
 */
const APP = readFileSync(new URL("../src/app.ts", import.meta.url), "utf8");
const VAULT = readFileSync(new URL("../../src/IssuanceVault.sol", import.meta.url), "utf8");

test("redeem still pays from the price alone, so the no-yield claim holds", () => {
  const body = VAULT.slice(VAULT.indexOf("function redeem("), VAULT.indexOf("function fund("));
  assert.ok(body.includes("uint256 gross = (shares * p) / SHARE_ONE;"));
  // reserves() appears only as the sufficiency check, never in the payout.
  assert.ok(body.includes("if (gross > available) revert InsufficientReserves"));
  assert.ok(
    !body.includes("reserves() * shares") && !body.includes("totalSupply()"),
    "redeem now reads the balance sheet: the no-yield wording in app.ts and the README is out of date",
  );
});

test("the dapp states that a share pays no income", () => {
  assert.ok(APP.includes("Holding a share pays no income."));
  assert.ok(
    APP.includes("there is no yield and no APY to quote"),
    "the sentence denying a share APY is gone",
  );
  // The thing that must never ship is a *computed* rate: an APY or yield
  // interpolated from a value. Prose mentioning the words is fine - the
  // denial above is prose - so the guard looks for a figure instead.
  for (const line of APP.split("\n")) {
    if (!/APY|yield/i.test(line)) continue;
    if (line.trimStart().startsWith("*") || line.trimStart().startsWith("//")) continue;
    assert.ok(
      !line.includes("${") && !line.includes("toFixed"),
      `a yield or APY figure is being computed for display: ${line.trim().slice(0, 90)}`,
    );
  }
});
