/**
 * The test-token faucet.
 *
 * **The ABI below is assumed, not generated.** `TokenFaucet` lives in the
 * sibling `leek-lend` repository and is not written yet, so the cooldown is
 * read from a primary shape (`nextClaimAt`) with a fallback to a second
 * (`cooldown` plus `lastClaim`), and every read tolerates a revert. A mismatch
 * therefore degrades to "claim and find out" rather than to an empty section.
 * Check it against the deployed contract before anyone relies on the
 * countdown; `README.md` records it as untested.
 *
 * The faucet exists for chains where the real MUSD does not, and its mock
 * tokens carry a `leek` prefix - leekMUSD, leekwBTC, leekWETH - because
 * Mezo's own bridged tokens use `m`: mUSDC, mUSDT and mDAI are real
 * contracts. A mock named mMUSD would read as one of theirs, and the symbol
 * beside an amount is the user's only clue which asset they are about to
 * spend. So nothing here hardcodes a symbol: every one is read from its token,
 * and a token that will not report one is not rendered at all.
 */

import type { Address } from "viem";
import { readContract } from "viem/actions";
import { ERC20_ABI } from "./abi.ts";
import { publicClient } from "./chain.ts";

export const FAUCET_ABI = [
  {
    type: "function",
    name: "claim",
    stateMutability: "nonpayable",
    inputs: [{ name: "token", type: "address" }],
    outputs: [],
  },
  {
    type: "function",
    name: "nextClaimAt",
    stateMutability: "view",
    inputs: [
      { name: "token", type: "address" },
      { name: "account", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "cooldown", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "lastClaim",
    stateMutability: "view",
    inputs: [
      { name: "token", type: "address" },
      { name: "account", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "dripAmount",
    stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

/**
 * Chains the faucet must never appear on.
 *
 * The contract refuses to operate on a mainnet chain id by construction, and
 * the UI mirrors that rather than offering a button the contract will reject.
 * Listed by id because "this is a mainnet" is not something a chain id says.
 */
const MAINNET_CHAIN_IDS = new Set([1, 10, 56, 137, 8453, 31_612, 42_161, 43_114]);

export function faucetAllowedOnChain(chainId: number): boolean {
  return !MAINNET_CHAIN_IDS.has(chainId);
}

export interface FaucetToken {
  readonly address: Address;
  readonly symbol: string;
  readonly decimals: number;
  readonly balance: bigint;
  readonly dripAmount: bigint | null;
  /** Unix seconds when the next claim becomes available, or null if unknown. */
  readonly nextClaimAt: number | null;
}

async function orNull<T>(promise: Promise<T>): Promise<T | null> {
  try {
    return await promise;
  } catch {
    return null;
  }
}

export async function readFaucetToken(
  faucet: Address,
  token: Address,
  account: Address,
): Promise<FaucetToken | null> {
  const [symbol, decimals, balance, drip, next, cooldown, last] = await Promise.all([
    orNull(readContract(publicClient, { address: token, abi: ERC20_ABI, functionName: "symbol" })),
    orNull(readContract(publicClient, { address: token, abi: ERC20_ABI, functionName: "decimals" })),
    orNull(readContract(publicClient, { address: token, abi: ERC20_ABI, functionName: "balanceOf", args: [account] })),
    orNull(readContract(publicClient, { address: faucet, abi: FAUCET_ABI, functionName: "dripAmount", args: [token] })),
    orNull(
      readContract(publicClient, {
        address: faucet,
        abi: FAUCET_ABI,
        functionName: "nextClaimAt",
        args: [token, account],
      }),
    ),
    orNull(readContract(publicClient, { address: faucet, abi: FAUCET_ABI, functionName: "cooldown" })),
    orNull(
      readContract(publicClient, { address: faucet, abi: FAUCET_ABI, functionName: "lastClaim", args: [token, account] }),
    ),
  ]);
  // No symbol or no decimals means this address is not the token it was
  // configured as, and an amount shown without a symbol is exactly the
  // confusion the leek prefix exists to prevent.
  if (symbol === null || decimals === null) return null;

  const nextClaimAt =
    next !== null && next > 0n
      ? Number(next)
      : cooldown !== null && last !== null && last > 0n
        ? Number(last + cooldown)
        : null;

  return {
    address: token,
    symbol,
    decimals: Number(decimals),
    balance: balance ?? 0n,
    dripAmount: drip,
    nextClaimAt,
  };
}
