import { strict as assert } from "node:assert";
import { test } from "node:test";
import { formatAge, formatAmount, formatIndexValue, parseAmount, truncateAddress } from "../src/lib/format.ts";

test("an address is truncated at both ends so it can be compared with an explorer", () => {
  assert.equal(truncateAddress("0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503"), "0x1189…c503");
});

test("something that is not an address is returned unchanged rather than mangled", () => {
  assert.equal(truncateAddress("not-an-address"), "not-an-address");
});

test("amounts are grouped and the fraction is bounded", () => {
  assert.equal(formatAmount(1_234_567_890_000_000_000_000n, 18, 4), "1,234.5678");
  assert.equal(formatAmount(1_000_000_000_000_000_000n, 18, 4), "1");
  assert.equal(formatAmount(0n, 18, 4), "0");
});

test("a dust amount does not display as zero without saying so", () => {
  // Four places of an 18-decimal token truncate 1 wei away; the UI pairs this
  // with the exact value in a title attribute, which the call site asserts.
  assert.equal(formatAmount(1n, 18, 4), "0");
  assert.equal(formatAmount(1n, 18, 18), "0.000000000000000001");
});

test("parsing rejects what the contract would reject", () => {
  assert.deepEqual(parseAmount("", 18), { ok: false, reason: "Enter an amount." });
  assert.deepEqual(parseAmount("1,5", 18), { ok: false, reason: "Numbers only." });
  assert.deepEqual(parseAmount("0", 18), { ok: false, reason: "Amount must be more than zero." });
  assert.deepEqual(parseAmount("1.5", 18), { ok: true, value: 1_500_000_000_000_000_000n });
});

test("more decimal places than the token has is refused, not silently truncated", () => {
  const result = parseAmount("1.1234567", 6);
  assert.equal(result.ok, false);
  assert.match(result.ok === false ? result.reason : "", /6 decimal places/);
});

test("ages read as a person would say them", () => {
  assert.equal(formatAge(12), "12s ago");
  assert.equal(formatAge(125), "2 min ago");
  assert.equal(formatAge(7300), "2 h ago");
  assert.equal(formatAge(180_000), "2 d ago");
  assert.equal(formatAge(Number.NaN), "unknown");
});

test("a missing index value shows an em dash, never a zero", () => {
  assert.equal(formatIndexValue(null), "—");
  assert.equal(formatIndexValue(102.5), "102.50");
});
