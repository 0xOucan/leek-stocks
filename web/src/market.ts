/**
 * On-chain reads for one market.
 *
 * Every read is batched into one `Promise.all` and every one of them is
 * allowed to fail independently: `price()` reverts on a stale, incomplete or
 * non-positive round (audit note I-2, which is deliberate), and a page that
 * let that reject would show nothing at all - no reserves, no balances, no
 * reason. So the price is captured as either a value or an explanation, and
 * the rest of the card still renders.
 */

import type { Address } from "viem";
import { getBalance, readContract } from "viem/actions";
import { publicClient } from "./chain.ts";
import { ERC20_ABI, ORACLE_ABI, VAULT_ABI } from "./abi.ts";
import { describeError } from "./lib/errors.ts";
import type { MarketConfig } from "./config.ts";

export interface MarketState {
  readonly symbol: string;
  readonly price: bigint | null;
  readonly priceError: string | null;
  readonly reserves: bigint;
  readonly liabilities: bigint | null;
  readonly feeBps: number;
  readonly maxShares: bigint;
  readonly paused: boolean;
  readonly maxStaleness: number;
  readonly round: { id: bigint; updatedAt: number } | null;
  readonly shareSupplyKnown: boolean;
}

export interface Balances {
  readonly musd: bigint;
  readonly shares: bigint;
  readonly allowance: bigint;
  readonly native: bigint;
}

async function orNull<T>(promise: Promise<T>): Promise<T | null> {
  try {
    return await promise;
  } catch {
    return null;
  }
}

export async function readMarket(market: MarketConfig): Promise<MarketState | null> {
  const vault = market.vault;
  if (!vault) return null;

  const [price, reserves, liabilities, feeBps, maxShares, paused, maxStaleness, oracle] = await Promise.all([
    readContract(publicClient, { address: vault, abi: VAULT_ABI, functionName: "price" })
      .then((value) => ({ value, error: null as string | null }))
      .catch((error: unknown) => ({ value: null, error: describeError(error).message })),
    orNull(readContract(publicClient, { address: vault, abi: VAULT_ABI, functionName: "reserves" })),
    orNull(readContract(publicClient, { address: vault, abi: VAULT_ABI, functionName: "liabilities" })),
    orNull(readContract(publicClient, { address: vault, abi: VAULT_ABI, functionName: "feeBps" })),
    orNull(readContract(publicClient, { address: vault, abi: VAULT_ABI, functionName: "maxShares" })),
    orNull(readContract(publicClient, { address: vault, abi: VAULT_ABI, functionName: "paused" })),
    orNull(readContract(publicClient, { address: vault, abi: VAULT_ABI, functionName: "maxStaleness" })),
    orNull(readContract(publicClient, { address: vault, abi: VAULT_ABI, functionName: "oracle" })),
  ]);

  const round = oracle
    ? await orNull(
        readContract(publicClient, { address: oracle as Address, abi: ORACLE_ABI, functionName: "latestRoundData" })
          .then((data) => ({ id: data[0], updatedAt: Number(data[3]) })),
      )
    : null;

  return {
    symbol: market.symbol,
    price: price.value,
    priceError: price.error,
    reserves: reserves ?? 0n,
    // Null rather than zero: `liabilities()` calls `price()`, so it reverts
    // whenever the price does, and showing 0 MUSD owed when the real answer
    // is unknown would understate exactly the risk this page must surface.
    liabilities,
    feeBps: Number(feeBps ?? 0),
    maxShares: maxShares ?? 0n,
    paused: paused ?? false,
    maxStaleness: Number(maxStaleness ?? 3600),
    round,
    shareSupplyKnown: liabilities !== null,
  };
}

export async function readBalances(
  owner: Address,
  musd: Address,
  share: Address,
  vault: Address,
): Promise<Balances> {
  const [musdBalance, shareBalance, allowance, native] = await Promise.all([
    orNull(readContract(publicClient, { address: musd, abi: ERC20_ABI, functionName: "balanceOf", args: [owner] })),
    orNull(readContract(publicClient, { address: share, abi: ERC20_ABI, functionName: "balanceOf", args: [owner] })),
    orNull(
      readContract(publicClient, { address: musd, abi: ERC20_ABI, functionName: "allowance", args: [owner, vault] }),
    ),
    orNull(getBalance(publicClient, { address: owner })),
  ]);
  return {
    musd: musdBalance ?? 0n,
    shares: shareBalance ?? 0n,
    allowance: allowance ?? 0n,
    native: native ?? 0n,
  };
}
