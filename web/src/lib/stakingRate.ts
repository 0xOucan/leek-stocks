/**
 * The staking rate, and what it is allowed to claim.
 *
 * There is a real revenue stream here - every buy and redeem splits its fee,
 * and the treasury half reaches MEZO stakers - so unlike a share (which pays
 * nothing, see `renderSolvencyPanel`) a staked position genuinely earns. That
 * makes a rate meaningful and makes an *overstated* rate the thing to guard
 * against.
 *
 * Two numbers, and the difference between them matters:
 *
 *   - **Realised.** `totalDistributed / totalStaked`: MUSD credited to
 *     stakers, ever, per unit staked now. A fact about the past, with no
 *     window and therefore no rate.
 *   - **Observed rate.** How far `accMusdPerShare` moved between two samples
 *     this page actually took, annualised. The window is the page's own
 *     uptime, which is the only interval whose length we know: the contract
 *     stores no timestamp against the accumulator, so nothing on chain can
 *     tell us over how long `totalDistributed` accumulated.
 *
 * The observed rate is an **extrapolation from minutes of fee revenue**, so it
 * is only returned once the window is long enough and some revenue has
 * actually arrived, and the caller is expected to print the window length
 * beside it. It is not a promise, it is not compounded, and a single large
 * trade inside the window dominates it. Returning `null` when the data is thin
 * is the point: a plausible-looking number from a 30-second sample of one
 * trade would be the most dishonest thing on the page.
 */

/** 1e18, the accumulator's fixed-point scale (`ACC_PRECISION`). */
const ACC_PRECISION = 10n ** 18n;
const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;

/** Below this the window is too short for the extrapolation to mean anything. */
export const MIN_WINDOW_SECONDS = 120;

export interface RateSample {
  readonly accMusdPerShare: bigint;
  readonly atSeconds: number;
}

export interface RateView {
  /** MUSD per 1 MEZO staked, credited since the contract was deployed. */
  readonly realisedPerMezo: number;
  /** Annualised percentage from the observed window, or null if not yet known. */
  readonly observedApr: number | null;
  /** How long the observation covers, in seconds. */
  readonly windowSeconds: number;
  /** Why there is no rate yet, for the panel to print instead of a number. */
  readonly reason: string | null;
}

export function rateView(args: {
  readonly totalDistributed: bigint;
  readonly totalStaked: bigint;
  readonly first: RateSample | null;
  readonly latest: RateSample;
}): RateView {
  const { totalDistributed, totalStaked, first, latest } = args;

  /* Per MEZO rather than per wei, and via the accumulator's own scale so the
     division is the same one the contract does. Floating point only at the
     very end, for display. */
  const realisedPerMezo =
    totalStaked === 0n ? 0 : Number((totalDistributed * ACC_PRECISION) / totalStaked) / Number(ACC_PRECISION);

  const windowSeconds = first ? Math.max(0, latest.atSeconds - first.atSeconds) : 0;

  if (!first) {
    return { realisedPerMezo, observedApr: null, windowSeconds, reason: "waiting for a second reading" };
  }
  if (windowSeconds < MIN_WINDOW_SECONDS) {
    return {
      realisedPerMezo,
      observedApr: null,
      windowSeconds,
      reason: `watching for ${MIN_WINDOW_SECONDS - windowSeconds}s more before quoting a rate`,
    };
  }
  if (totalStaked === 0n) {
    return { realisedPerMezo, observedApr: null, windowSeconds, reason: "nothing is staked" };
  }

  const movement = latest.accMusdPerShare - first.accMusdPerShare;
  if (movement <= 0n) {
    return {
      realisedPerMezo,
      observedApr: null,
      windowSeconds,
      reason: "no fee revenue has arrived while this page has been open",
    };
  }

  /* `accMusdPerShare` is already MUSD per staked wei, scaled by 1e18, so the
     movement over the window IS the per-unit return over the window - no
     division by totalStaked, which is where a stake made mid-window would
     otherwise corrupt the figure. Simple annualisation, deliberately not
     compounded: compounding an extrapolation from minutes would turn a noisy
     number into a dramatic one. */
  const perUnitOverWindow = Number(movement) / Number(ACC_PRECISION);
  const observedApr = perUnitOverWindow * (SECONDS_PER_YEAR / windowSeconds) * 100;

  return { realisedPerMezo, observedApr, windowSeconds, reason: null };
}

/** "1h 5m", for printing the window beside the rate. */
export function describeWindow(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}
