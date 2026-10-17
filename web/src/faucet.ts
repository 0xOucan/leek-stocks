/**
 * The test-token faucet.
 *
 * The ABI is the real one now, read from `TokenFaucet` in the sibling
 * `leek-lend` repository rather than guessed: `claimStatus(token, claimant)`
 * answers everything this section needs in one call - whether a claim will
 * succeed, how much it pays, how long until the next one, and how much of the
 * total cap is spent. One call rather than four reads stitched together, and
 * `claimable` is the contract's own verdict rather than our reconstruction of
 * it, so the button cannot disagree with the chain about whether it will work.
 *
 * Reads still tolerate a revert, for one honest reason: an address configured
 * as a faucet that is not one should grey the section out, not throw on load.
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
    outputs: [{ name: "amount", type: "uint256" }],
  },
  {
    type: "function",
    name: "claimStatus",
    stateMutability: "view",
    inputs: [
      { name: "token", type: "address" },
      { name: "claimant", type: "address" },
    ],
    outputs: [
      { name: "claimable", type: "bool" },
      { name: "amount", type: "uint256" },
      { name: "secondsRemaining", type: "uint256" },
      { name: "mintedSoFar", type: "uint256" },
      { name: "totalCap", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "secondsUntilClaim",
    stateMutability: "view",
    inputs: [
      { name: "token", type: "address" },
      { name: "claimant", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;

/**
 * Chains the faucet must never appear on.
 *
 * The contract refuses to operate on a mainnet chain id by construction, and
 * the UI mirrors that rather than offering a button the contract will reject.
 * Listed by id because "this is a mainnet" is not something a chain id says.
 */
const MAINNET_CHAIN_IDS = new Set([
  1, 10, 56, 100, 137, 250, 324, 1101, 5000, 8453, 31_612, 34_443, 42_161, 43_114, 59_144, 81_457, 534_352,
]);

export function faucetAllowedOnChain(chainId: number): boolean {
  return !MAINNET_CHAIN_IDS.has(chainId);
}

export interface FaucetToken {
  readonly address: Address;
  readonly symbol: string;
  readonly decimals: number;
  readonly balance: bigint;
  /** What one claim pays, from the contract. */
  readonly dripAmount: bigint | null;
  /** The contract's own verdict on whether a claim would succeed now. */
  readonly claimable: boolean;
  /** Seconds until the cooldown expires; 0 when it already has. */
  readonly secondsRemaining: number;
  /** How much of this token's total cap is spent, for an honest "nearly dry". */
  readonly mintedSoFar: bigint | null;
  readonly totalCap: bigint | null;
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
  const [symbol, decimals, balance, status] = await Promise.all([
    orNull(readContract(publicClient, { address: token, abi: ERC20_ABI, functionName: "symbol" })),
    orNull(readContract(publicClient, { address: token, abi: ERC20_ABI, functionName: "decimals" })),
    orNull(readContract(publicClient, { address: token, abi: ERC20_ABI, functionName: "balanceOf", args: [account] })),
    orNull(
      readContract(publicClient, {
        address: faucet,
        abi: FAUCET_ABI,
        functionName: "claimStatus",
        args: [token, account],
      }),
    ),
  ]);
  // No symbol or no decimals means this address is not the token it was
  // configured as, and an amount shown without a symbol is exactly the
  // confusion the leek prefix exists to prevent.
  if (symbol === null || decimals === null) return null;

  return {
    address: token,
    symbol,
    decimals: Number(decimals),
    balance: balance ?? 0n,
    dripAmount: status ? status[1] : null,
    claimable: status ? status[0] : false,
    secondsRemaining: status ? Number(status[2]) : 0,
    mintedSoFar: status ? status[3] : null,
    totalCap: status ? status[4] : null,

  };
}
