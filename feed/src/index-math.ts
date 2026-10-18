/**
 * The index transform, and the decision of whether to publish — both pure, so
 * they are testable without a network, a chain or a clock.
 *
 * Why a transform at all, rather than publishing a quote: a free market-data
 * tier is delayed deliberately, because the delay is how the provider avoids
 * exchange licensing fees, and nearly all of them forbid redistribution.
 * Publishing a raw quote on chain is republishing market data. A *derived*
 * index over an openly licensed source is not, and since these indices are
 * parodies, nothing of value is lost: what the demo shows is the mechanism.
 */

/** One constituent of an index: a source asset and its weight in basis points. */
export interface Constituent {
  /** The id this asset has at the source, e.g. a CoinGecko id. */
  readonly id: string;
  /** Weight in basis points. The weights of an index must sum to 10000. */
  readonly weightBps: number;
}

export interface IndexDefinition {
  /** On-chain symbol, e.g. "GOLOGGLE". A parody, never a real company's mark. */
  readonly symbol: string;
  readonly description: string;
  readonly constituents: readonly Constituent[];
  /**
   * The index's value at its base date, in whole units of the quote currency.
   * The published price is this times the basket's growth since the base,
   * which is what makes the number readable: an index at 100 that doubles
   * reads 200, rather than reading as the sum of some basket's prices.
   */
  readonly baseValue: number;
  /** The basket's value at the base date, from the same source. */
  readonly baseBasket: number;
}

export const WEIGHT_TOTAL_BPS = 10_000;

export function assertDefinition(definition: IndexDefinition): void {
  const total = definition.constituents.reduce((sum, c) => sum + c.weightBps, 0);
  if (total !== WEIGHT_TOTAL_BPS) {
    throw new Error(`${definition.symbol}: weights sum to ${total} bps, not ${WEIGHT_TOTAL_BPS}`);
  }
  if (definition.constituents.length === 0) throw new Error(`${definition.symbol}: no constituents`);
  if (definition.baseValue <= 0 || definition.baseBasket <= 0) {
    throw new Error(`${definition.symbol}: base value and base basket must be positive`);
  }
  const ids = new Set(definition.constituents.map((c) => c.id));
  if (ids.size !== definition.constituents.length) {
    throw new Error(`${definition.symbol}: a constituent is listed twice`);
  }
}

/**
 * The basket's weighted value from a price map.
 *
 * Throws on a missing or non-finite constituent price rather than treating it
 * as zero: a dropped constituent would silently reprice the index downward by
 * its whole weight, which is a failure that looks exactly like a market move.
 */
export function basketValue(
  definition: IndexDefinition,
  prices: Readonly<Record<string, number>>,
): number {
  let total = 0;
  for (const c of definition.constituents) {
    const price = prices[c.id];
    if (typeof price !== "number" || !Number.isFinite(price) || price <= 0) {
      throw new Error(`${definition.symbol}: no usable price for ${c.id}`);
    }
    total += (price * c.weightBps) / WEIGHT_TOTAL_BPS;
  }
  return total;
}

/** The index value to publish, in whole units of the quote currency. */
export function indexValue(
  definition: IndexDefinition,
  prices: Readonly<Record<string, number>>,
): number {
  const basket = basketValue(definition, prices);
  return (definition.baseValue * basket) / definition.baseBasket;
}

/**
 * Scale a decimal value to the feed's integer units.
 *
 * Rounds to nearest rather than truncating, and rejects a value that would
 * round to zero: the oracle refuses a non-positive answer, and arriving there
 * by rounding would be a confusing way to find that out.
 */
export function toFeedUnits(value: number, decimals: number): bigint {
  if (!Number.isFinite(value) || value <= 0) throw new Error(`value ${value} is not publishable`);
  const scaled = BigInt(Math.round(value * 10 ** decimals));
  if (scaled <= 0n) throw new Error(`value ${value} rounds to zero at ${decimals} decimals`);
  return scaled;
}

export interface PublishDecision {
  readonly publish: boolean;
  /** Why, for the log. A silent no-op is indistinguishable from a crash. */
  readonly reason: string;
  /**
   * The answer to publish, which may be clamped: the oracle rejects a round
   * that moves further than its bound, so a bigger move goes out as several
   * rounds rather than being dropped.
   */
  readonly answer: bigint;
}

/**
 * Whether to publish, and what.
 *
 * Three reasons to publish and one not to. Publish when nothing is on chain
 * yet, when the price has moved more than `thresholdBps` (so a quiet market
 * does not burn gas), or when the heartbeat has elapsed (so consumers never
 * see a stale feed even in a flat market). Otherwise do nothing.
 *
 * The clamp is the important part. The oracle's per-round deviation bound is
 * immutable and reverts a larger move; publishing the bound instead walks the
 * price in steps, which is slower but never drops an update on the floor. It
 * also means a genuine crash takes several rounds to express, which is the
 * trade that bound was chosen for in the first place.
 */
export function decidePublish(args: {
  readonly target: bigint;
  readonly last: bigint | null;
  readonly secondsSinceLast: number;
  readonly thresholdBps: number;
  readonly heartbeatSeconds: number;
  readonly maxDeviationBps: number;
  /** The oracle's immutable per-round cooldown, in seconds. */
  readonly minRoundInterval: number;
  /** The oracle's floor, in feed units. Answers below it revert. */
  readonly minAnswer: bigint;
  /**
   * The cumulative bound: the answer this window's budget is measured from,
   * and the budget. `anchorAnswer` of 0 means there is no window yet.
   */
  readonly anchorAnswer: bigint;
  readonly maxWindowDeviationBps: number;
  /** Seconds since the window opened, and how long a window lasts. */
  readonly secondsSinceAnchor: number;
  readonly deviationWindow: number;
}): PublishDecision {
  const { target, last, secondsSinceLast, thresholdBps, heartbeatSeconds, maxDeviationBps } = args;
  const { minRoundInterval, minAnswer } = args;
  const { anchorAnswer, maxWindowDeviationBps, secondsSinceAnchor, deviationWindow } = args;
  if (target <= 0n) throw new Error("target must be positive");
  if (last === null || last === 0n) {
    /* Clamped up to the floor even on the first round. A first answer below
     * MIN_ANSWER reverts on chain, and before the floor existed it was worse
     * than a revert: it pinned the feed at dust permanently. */
    return {
      publish: true,
      reason: target < minAnswer ? `first round, raised to the oracle's floor` : "first round",
      answer: target < minAnswer ? minAnswer : target,
    };
  }

  /* The oracle's own cooldown. The service did not know this existed, so
   * after every restart it burned a tick on a TooSoon revert that read in
   * /prices as a feed error. Holding here is not a failure and says so. */
  if (secondsSinceLast < minRoundInterval) {
    return {
      publish: false,
      reason: `${secondsSinceLast}s since the last round, the oracle requires ${minRoundInterval}s`,
      answer: target,
    };
  }

  const difference = target > last ? target - last : last - target;
  const movedBps = (difference * 10_000n) / last;
  /* At least one unit, matching the contract's one-unit allowance. The
   * division truncates to zero for a small `last`, and a bound of zero makes
   * every step a clamp to the current value - the off-chain half of the
   * absorbing-floor bug that MIN_ANSWER closes on chain. */
  const divided = (last * BigInt(maxDeviationBps)) / 10_000n;
  const bound = divided > 0n ? divided : 1n;
  const stepped = difference > bound ? (target > last ? last + bound : last - bound) : target;

  /* And the cumulative bound, which the per-round clamp above knows nothing
   * about. Audit finding R4-6 added a second bound on chain: total movement
   * from an anchor, per window. Without mirroring it here the service would
   * send a perfectly in-bound step that the oracle rejects with
   * WindowDeviationTooLarge, every tick, for the rest of the window - a
   * self-inflicted error that reads in /prices as an RPC fault, which is
   * exactly how `minRoundInterval` behaved before it was mirrored.
   *
   * The anchor on chain refreshes lazily, inside `publish`, once the window
   * has elapsed. So the budget available to the NEXT publish is measured
   * from `last` when the window is about to roll, and from `anchorAnswer`
   * when it is not. Getting this wrong in the safe direction only costs a
   * held publish; getting it wrong the other way costs a revert. */
  const windowRolls = secondsSinceAnchor >= deviationWindow;
  const effectiveAnchor = windowRolls || anchorAnswer <= 0n ? last : anchorAnswer;
  const windowDivided = (effectiveAnchor * BigInt(maxWindowDeviationBps)) / 10_000n;
  const windowBound = windowDivided > 0n ? windowDivided : 1n;
  const windowLow = effectiveAnchor - windowBound;
  const windowHigh = effectiveAnchor + windowBound;

  const inWindow = stepped > windowHigh ? windowHigh : stepped < windowLow ? windowLow : stepped;

  // Never below the floor, whatever either clamp said.
  const clamped = inWindow < minAnswer ? minAnswer : inWindow;
  const wasClamped = clamped !== target;

  if (movedBps >= BigInt(thresholdBps)) {
    /* Which bound bit, named. "Clamped" without saying by what sent an
     * operator reading /prices to the wrong one of two bounds. */
    const by = clamped !== inWindow
      ? `the oracle's floor`
      : inWindow !== stepped
        ? `the oracle's ${maxWindowDeviationBps} bps-per-${deviationWindow}s window budget`
        : `the oracle's ${maxDeviationBps} bps per-round bound`;
    return {
      publish: true,
      reason: wasClamped ? `moved ${movedBps} bps, clamped to ${by}` : `moved ${movedBps} bps`,
      answer: clamped,
    };
  }
  if (secondsSinceLast >= heartbeatSeconds) {
    return { publish: true, reason: `heartbeat after ${secondsSinceLast}s`, answer: clamped };
  }
  return { publish: false, reason: `moved ${movedBps} bps, below ${thresholdBps}`, answer: clamped };
}

/**
 * A deterministic stand-in for a source that is down, and the series used for
 * a filmed demo.
 *
 * Not random: seeded, so the same inputs give the same series on every run and
 * a recorded demo is reproducible. It is a bounded walk around the base value,
 * and the service labels every answer published from it, because a synthetic
 * price presented as a real one would be the one dishonest thing here.
 */
export function syntheticValue(definition: IndexDefinition, step: number): number {
  // A small LCG over the symbol's characters plus the step. Nothing here needs
  // statistical quality; it needs to be the same series twice.
  let seed = step + 1;
  for (const char of definition.symbol) seed = (seed * 31 + char.charCodeAt(0)) % 2_147_483_647;
  const unit = ((seed * 1_103_515_245 + 12_345) % 2_147_483_647) / 2_147_483_647;
  // Plus or minus 5% around the base, which stays inside a 20% per-round bound
  // even when consecutive steps land at opposite extremes.
  return definition.baseValue * (0.95 + unit * 0.1);
}
