/**
 * Mezo's own borrow market, read and called from this page.
 *
 * Why this is here at all: the vaults settle in MUSD and mint none of it.
 * MUSD comes from one place - locking BTC in Mezo's native borrow system -
 * and until now that step was a shell script I ran for people. A tester who
 * holds no MUSD has nothing to buy with and no way to get any, which makes
 * every other part of this page undemonstrable.
 *
 * ---------------------------------------------------------------------------
 * The ABI below is NOT from an artifact. BorrowerOperations is a
 * TransparentUpgradeableProxy whose implementation is unverified on the
 * explorer and publishes no ABI, so these fragments were recovered by matching
 * four-byte selectors against the deployed bytecode and then confirmed by
 * calling each one against the live chain.
 *
 *   openTrove(uint256,address,address)   0x2f3a6d98, payable
 *
 * It is *not* Liquity v1's signature, which is what every piece of
 * documentation and every LLM will tell you it is: there is no
 * maxFeePercentage parameter, and the collateral is msg.value rather than an
 * argument. Getting that wrong produces a revert with no reason string.
 *
 * The hints are insertion points into the sorted trove list. Zero is always
 * correct and merely costs more gas - the list walks from the head - so this
 * page passes zero rather than shipping a hint-finding routine for a testnet
 * list of a few hundred positions.
 * ---------------------------------------------------------------------------
 */

import type { Address } from "viem";
import { getBalance, readContract } from "viem/actions";
import { publicClient } from "./chain.ts";
import { CONFIG } from "./config.ts";

export const BORROWER_OPERATIONS_ABI = [
  {
    type: "function",
    name: "openTrove",
    stateMutability: "payable",
    inputs: [
      { name: "debtAmount", type: "uint256" },
      { name: "upperHint", type: "address" },
      { name: "lowerHint", type: "address" },
    ],
    outputs: [],
  },
  { type: "function", name: "minNetDebt", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "MCR", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "musd", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "troveManager", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "priceFeed", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

export const TROVE_MANAGER_ABI = [
  /** 0 = nonExistent, 1 = active, 2 = closedByOwner, 3 = closedByLiquidation. */
  {
    type: "function",
    name: "getTroveStatus",
    stateMutability: "view",
    inputs: [{ name: "borrower", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "getTroveDebt",
    stateMutability: "view",
    inputs: [{ name: "borrower", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "getTroveColl",
    stateMutability: "view",
    inputs: [{ name: "borrower", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

export const PRICE_FEED_ABI = [
  /*
   * Declared view so this page can eth_call it. Liquity's PriceFeed marks
   * fetchPrice as nonpayable because it may cache; Mezo's answers a plain
   * eth_call, which is how the deploy script and every one of my probes read
   * the BTC price. This page only ever reads it.
   */
  { type: "function", name: "fetchPrice", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

export interface BorrowMarket {
  readonly borrowerOperations: Address;
  readonly minNetDebt: bigint;
  readonly mcr: bigint;
  /** MUSD per BTC, 18 decimals. Null when the feed is unreadable. */
  readonly price: bigint | null;
  /**
   * Set when the token this market mints is not the token our vaults settle
   * in. Mezo testnet has two contracts reporting MUSD with 18 decimals, and
   * sending a tester to borrow the other one would hand them a balance that
   * every vault rejects with an opaque allowance error. It cost me an
   * afternoon once; it is now a read, every poll.
   */
  readonly mismatch: string | null;
}

export interface TrovePosition {
  readonly status: number;
  readonly debt: bigint;
  readonly collateral: bigint;
}

export const TROVE_ACTIVE = 1;

async function orNull<T>(promise: Promise<T>): Promise<T | null> {
  try {
    return await promise;
  } catch {
    return null;
  }
}

/**
 * The market's parameters, every one of them read from the chain.
 *
 * None of these are constants in this file on purpose. `minNetDebt` and `MCR`
 * are governance-settable, the price moves, and the linked contracts are
 * behind a proxy that can be upgraded. A front end holding its own copy of
 * any of them is a front end that will one day quote a user a position the
 * chain refuses.
 */
export async function readBorrowMarket(): Promise<BorrowMarket | null> {
  const borrowerOperations = CONFIG.borrowerOperations;
  if (!borrowerOperations) return null;

  const [minNetDebt, mcr, musd, priceFeed] = await Promise.all([
    orNull(readContract(publicClient, { address: borrowerOperations, abi: BORROWER_OPERATIONS_ABI, functionName: "minNetDebt" })),
    orNull(readContract(publicClient, { address: borrowerOperations, abi: BORROWER_OPERATIONS_ABI, functionName: "MCR" })),
    orNull(readContract(publicClient, { address: borrowerOperations, abi: BORROWER_OPERATIONS_ABI, functionName: "musd" })),
    orNull(readContract(publicClient, { address: borrowerOperations, abi: BORROWER_OPERATIONS_ABI, functionName: "priceFeed" })),
  ]);
  // Nothing there answers these: either the address is wrong or this chain is
  // not Mezo. Either way the section must not render a borrow form.
  if (minNetDebt === null || mcr === null) return null;

  const price = priceFeed
    ? await orNull(readContract(publicClient, { address: priceFeed, abi: PRICE_FEED_ABI, functionName: "fetchPrice" }))
    : null;

  const mismatch =
    musd && CONFIG.musd && musd.toLowerCase() !== CONFIG.musd.toLowerCase()
      ? `Mezo's borrow market mints ${musd}, but this build settles in ${CONFIG.musd}. Borrowing here would produce a token the vaults reject. Fix VITE_MUSD before using this.`
      : null;

  return { borrowerOperations, minNetDebt, mcr, price, mismatch };
}

/** The caller's position, or null when the market is not configured. */
export async function readTrove(owner: Address): Promise<TrovePosition | null> {
  const borrowerOperations = CONFIG.borrowerOperations;
  if (!borrowerOperations) return null;
  const troveManager = await orNull(
    readContract(publicClient, { address: borrowerOperations, abi: BORROWER_OPERATIONS_ABI, functionName: "troveManager" }),
  );
  if (!troveManager) return null;

  const [status, debt, collateral] = await Promise.all([
    orNull(readContract(publicClient, { address: troveManager, abi: TROVE_MANAGER_ABI, functionName: "getTroveStatus", args: [owner] })),
    orNull(readContract(publicClient, { address: troveManager, abi: TROVE_MANAGER_ABI, functionName: "getTroveDebt", args: [owner] })),
    orNull(readContract(publicClient, { address: troveManager, abi: TROVE_MANAGER_ABI, functionName: "getTroveColl", args: [owner] })),
  ]);
  if (status === null) return null;
  return { status: Number(status), debt: debt ?? 0n, collateral: collateral ?? 0n };
}

/** Used only by the gas step, which has to work before any token exists. */
export async function nativeBalance(owner: Address): Promise<bigint | null> {
  return orNull(getBalance(publicClient, { address: owner }));
}
