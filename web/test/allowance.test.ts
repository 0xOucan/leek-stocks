import { strict as assert } from "node:assert";
import { test } from "node:test";
import { allowanceFor } from "../src/allowance.ts";

test("each action gates on the allowance of the token it actually spends", () => {
  // The shape that caused a real failed transaction on Mezo testnet
  // (0x74bf904f...): MUSD approved for the buy, shares never approved, so
  // redeem reverted with ERC20InsufficientAllowance(vault, 0, 1497409528018993890).
  const afterBuy = {
    musd: 0n,
    shares: 1497409528018993890n,
    allowance: 10n ** 21n,
    shareAllowance: 0n,
    native: 10n ** 16n,
  };
  assert.equal(allowanceFor("buy", afterBuy), 10n ** 21n);
  assert.equal(allowanceFor("redeem", afterBuy), 0n, "redeem must not read the MUSD allowance");

  // And the reverse: a share approval does not let a buy through.
  const afterShareApproval = { ...afterBuy, allowance: 0n, shareAllowance: 1497409528018993890n };
  assert.equal(allowanceFor("buy", afterShareApproval), 0n);
  assert.equal(allowanceFor("redeem", afterShareApproval), 1497409528018993890n);

  // No balances read yet is zero, not a crash and not permission.
  assert.equal(allowanceFor("buy", null), 0n);
  assert.equal(allowanceFor("redeem", null), 0n);
});
