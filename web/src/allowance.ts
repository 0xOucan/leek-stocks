/**
 * Which allowance gates which action.
 *
 * `buy` pulls MUSD from the buyer with transferFrom. `redeem` calls burnFrom
 * on the SHARE token, and ETFShare spends an allowance there deliberately so
 * that the vault cannot burn a holder's shares uninvited. The two actions
 * therefore gate on allowances of two different tokens, and a page that
 * checks only one sends the other straight to a revert - which is what
 * happened on Mezo testnet in transaction 0x74bf904f: MUSD approved, shares
 * not, and redeem reverted with ERC20InsufficientAllowance(vault, 0, shares).
 *
 * This lives in its own module, rather than in market.ts beside the readers,
 * because market.ts imports config.ts for the deployed addresses and config.ts
 * reads import.meta.env, which exists only inside a Vite build. A test that
 * imported it under plain node failed on `Cannot read properties of undefined
 * (reading 'VITE_VAULT_GOLOGGLE')` before reaching a single assertion. Keeping
 * the rule in a module with no imports at all is what makes it testable.
 */

/** Just the fields this rule needs, so nothing here depends on the readers. */
export interface AllowanceBalances {
  readonly allowance: bigint;
  readonly shareAllowance: bigint;
}

export function allowanceFor(mode: "buy" | "redeem", balances: AllowanceBalances | null): bigint {
  if (balances === null) return 0n;
  return mode === "buy" ? balances.allowance : balances.shareAllowance;
}
