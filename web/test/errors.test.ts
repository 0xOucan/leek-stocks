import { strict as assert } from "node:assert";
import { test } from "node:test";
import { encodeErrorResult } from "viem";
import { ERROR_ABI, describeError, explainRevertData, explainWalletCode } from "../src/lib/errors.ts";

const ONE = 10n ** 18n;

function encode(name: string, args: readonly unknown[]): `0x${string}` {
  return encodeErrorResult({ abi: ERROR_ABI, errorName: name as never, args: args as never });
}

test("InsufficientReserves quotes both sides of the shortfall", () => {
  const explained = explainRevertData(encode("InsufficientReserves", [1194n * ONE, 995n * ONE]));
  assert.equal(explained?.name, "InsufficientReserves");
  assert.match(explained?.message ?? "", /owes 1194 MUSD/);
  assert.match(explained?.message ?? "", /holds 995 MUSD/);
  assert.match(explained?.message ?? "", /fund the backstop/);
});

test("Slippage says what to do about it", () => {
  const explained = explainRevertData(encode("Slippage", [4n * ONE, 5n * ONE]));
  assert.equal(explained?.name, "Slippage");
  assert.match(explained?.message ?? "", /slippage tolerance/);
});

test("StalePrice names the window the vault enforces", () => {
  const explained = explainRevertData(encode("StalePrice", [1_760_000_000n, 3600]));
  assert.match(explained?.message ?? "", /3600s/);
});

test("every custom error this page lists decodes to a sentence", () => {
  const cases: [string, readonly unknown[]][] = [
    ["CapExceeded", [2n * ONE, ONE]],
    ["VaultPaused", []],
    ["BadPrice", [-1n]],
    ["IncompleteRound", [2n, 1n, 0n]],
    ["ZeroAmount", []],
    ["FeeTooHigh", [600]],
    ["ZeroAddress", []],
    ["NoData", []],
    ["FeedPaused", []],
    ["ERC20InsufficientAllowance", ["0x0000000000000000000000000000000000000001", 0n, ONE]],
  ];
  for (const [name, args] of cases) {
    const explained = explainRevertData(encode(name, args));
    assert.equal(explained?.name, name, name);
    // Never a bare selector, and never an empty string.
    assert.ok((explained?.message.length ?? 0) > 20, name);
    assert.doesNotMatch(explained?.message ?? "", /^0x/, name);
  }
});

test("an unknown selector is reported as unknown rather than guessed", () => {
  assert.equal(explainRevertData("0xdeadbeef"), null);
});

test("wallet rejection is recognised by code and by message", () => {
  assert.equal(explainWalletCode(4001)?.name, "UserRejected");
  assert.equal(describeError({ code: 4001 }).name, "UserRejected");
  assert.equal(describeError(new Error("User rejected the request")).name, "UserRejected");
});

test("revert data nested the way viem and providers nest it is still found", () => {
  const data = encode("VaultPaused", []);
  assert.equal(describeError({ cause: { cause: { data } } }).name, "VaultPaused");
  assert.equal(describeError({ error: { data: { data } } }).name, "VaultPaused");
});

test("a selector with no match says so and keeps the selector for a bug report", () => {
  const explained = describeError({ cause: { data: "0xdeadbeef" } });
  assert.equal(explained.name, "0xdeadbeef");
  assert.match(explained.message, /does not recognise/);
});

test("insufficient gas names BTC, because Mezo's gas token is not ether", () => {
  const explained = describeError(new Error("insufficient funds for gas * price + value"));
  assert.match(explained.message, /BTC/);
  assert.doesNotMatch(explained.message, /\bETH\b/);
});

test("an unrecognised failure returns its first line, not a viem essay", () => {
  const explained = describeError(new Error("Something broke.\nRequest: {...}\nVersion: viem@2"));
  assert.equal(explained.message, "Something broke.");
});
