/**
 * On-chain reads for the MEZO fee-discount staking contract.
 *
 * Same shape and same rule as `market.ts`: one `Promise.all`, and every read
 * may fail on its own. A staking contract that is not deployed, or a MEZO
 * token that does not exist on this chain, must leave the rest of the page
 * working rather than throwing on mount.
 */

import type { Address } from "viem";
import { readContract } from "viem/actions";
import { publicClient } from "./chain.ts";
import { ERC20_ABI, STAKING_ABI, VAULT_FEE_ABI } from "./abi.ts";
import { CONFIG } from "./config.ts";

export interface Tier {
  readonly minStake: bigint;
  readonly discountBps: number;
}

export interface StakingState {
  readonly staking: Address;
  readonly totalStaked: bigint;
  /** Cumulative MUSD the contract has credited to stakers, ever. */
  readonly totalDistributed: bigint;
  /**
   * The reward-per-share accumulator, in 1e18 fixed point.
   *
   * The panel's rate is derived from how much this moves while the page
   * watches it, which is the only window whose length we actually know.
   * `totalDistributed` is cumulative since deployment with no timestamp, so it
   * can say what has been earned but not at what rate.
   */
  readonly accMusdPerShare: bigint;
  readonly cooldownSeconds: number;
  readonly tiers: readonly Tier[];
  /** Whether the vault for the selected market is still pointed at us. */
  readonly wiredToVault: boolean;
}

export interface StakerState {
  readonly staked: bigint;
  /** `pending` plus `claimable`: both are MUSD the staker owns. */
  readonly rewards: bigint;
  /** Of which this part is a payout a failed transfer set aside. */
  readonly setAside: bigint;
  readonly coolingUntil: number;
  readonly discountBps: number;
  /** The fee a buy would actually charge this account, read from the vault. */
  readonly effectiveFeeBps: number | null;
  readonly mezoBalance: bigint;
  readonly mezoAllowance: bigint;
}

async function orNull<T>(promise: Promise<T>): Promise<T | null> {
  try {
    return await promise;
  } catch {
    return null;
  }
}

export async function readStaking(vault: Address | undefined): Promise<StakingState | null> {
  const staking = CONFIG.staking;
  if (!staking) return null;

  const [totalStaked, totalDistributed, accMusdPerShare, cooldown, tierCount, wired] = await Promise.all([
    orNull(readContract(publicClient, { address: staking, abi: STAKING_ABI, functionName: "totalSupply" })),
    orNull(readContract(publicClient, { address: staking, abi: STAKING_ABI, functionName: "totalDistributed" })),
    orNull(readContract(publicClient, { address: staking, abi: STAKING_ABI, functionName: "accMusdPerShare" })),
    orNull(readContract(publicClient, { address: staking, abi: STAKING_ABI, functionName: "cooldown" })),
    orNull(readContract(publicClient, { address: staking, abi: STAKING_ABI, functionName: "tierCount" })),
    vault
      ? orNull(readContract(publicClient, { address: vault, abi: VAULT_FEE_ABI, functionName: "staking" }))
      : Promise.resolve(null),
  ]);

  // A contract that answers none of these is not a staking contract at this
  // address, and the panel should say nothing rather than a row of zeroes.
  if (totalStaked === null || cooldown === null) return null;

  /* The tiers are read, never hardcoded. They are admin-settable, so a page
     that listed them from a constant would eventually advertise a discount
     the contract no longer gives. */
  const count = Number(tierCount ?? 0n);
  const tiers = (
    await Promise.all(
      Array.from({ length: count }, (_, index) =>
        orNull(
          readContract(publicClient, {
            address: staking,
            abi: STAKING_ABI,
            functionName: "tierAt",
            args: [BigInt(index)],
          }),
        ),
      ),
    )
  )
    .filter((tier): tier is readonly [bigint, number] => tier !== null)
    .map(([minStake, discountBps]) => ({ minStake, discountBps }));

  return {
    staking,
    totalStaked,
    totalDistributed: totalDistributed ?? 0n,
    accMusdPerShare: accMusdPerShare ?? 0n,
    cooldownSeconds: Number(cooldown),
    tiers,
    /* Lower-cased on both sides: one of these comes from a contract read and
       one from a checksummed constant, and `===` between those two spellings
       is false while the addresses are the same. */
    wiredToVault: wired !== null && String(wired).toLowerCase() === staking.toLowerCase(),
  };
}

export async function readStaker(account: Address, vault: Address | undefined): Promise<StakerState | null> {
  const staking = CONFIG.staking;
  const mezo = CONFIG.mezo;
  if (!staking) return null;

  const [staked, pending, setAside, coolingUntil, discountBps, effectiveFeeBps, mezoBalance, mezoAllowance] =
    await Promise.all([
      orNull(
        readContract(publicClient, { address: staking, abi: STAKING_ABI, functionName: "balanceOf", args: [account] }),
      ),
      orNull(
        readContract(publicClient, { address: staking, abi: STAKING_ABI, functionName: "pending", args: [account] }),
      ),
      orNull(
        readContract(publicClient, { address: staking, abi: STAKING_ABI, functionName: "claimable", args: [account] }),
      ),
      orNull(
        readContract(publicClient, {
          address: staking,
          abi: STAKING_ABI,
          functionName: "coolingUntil",
          args: [account],
        }),
      ),
      orNull(
        readContract(publicClient, {
          address: staking,
          abi: STAKING_ABI,
          functionName: "discountBpsFor",
          args: [account],
        }),
      ),
      /* Read from the VAULT, not computed from the discount here.
         The vault clamps the discount independently and falls back to the
         undiscounted fee if the staking call fails or runs out of its gas
         stipend, so the only number that matches what a buy will charge is
         the one the vault itself returns. A page that multiplied the two
         locally would quote a fee the trade then contradicts. */
      vault
        ? orNull(
            readContract(publicClient, {
              address: vault,
              abi: VAULT_FEE_ABI,
              functionName: "effectiveFeeBps",
              args: [account],
            }),
          )
        : Promise.resolve(null),
      mezo
        ? orNull(readContract(publicClient, { address: mezo, abi: ERC20_ABI, functionName: "balanceOf", args: [account] }))
        : Promise.resolve(null),
      mezo
        ? orNull(
            readContract(publicClient, {
              address: mezo,
              abi: ERC20_ABI,
              functionName: "allowance",
              args: [account, staking],
            }),
          )
        : Promise.resolve(null),
    ]);

  if (staked === null) return null;

  return {
    staked,
    rewards: (pending ?? 0n) + (setAside ?? 0n),
    setAside: setAside ?? 0n,
    coolingUntil: Number(coolingUntil ?? 0n),
    discountBps: Number(discountBps ?? 0),
    effectiveFeeBps: effectiveFeeBps === null ? null : Number(effectiveFeeBps),
    mezoBalance: mezoBalance ?? 0n,
    mezoAllowance: mezoAllowance ?? 0n,
  };
}
