/**
 * Freshness, computed the same way `IssuanceVault.price()` computes it.
 *
 * The vault reverts with `StalePrice` when `block.timestamp - updatedAt >
 * maxStaleness`, so a page that shows a price without showing its age is
 * showing a button that is about to fail. Pure, and the clock is a parameter
 * rather than a call to `Date.now()`, so the tests are not time-dependent.
 */

export type Freshness = "fresh" | "stale" | "unknown";

export interface FreshnessView {
  readonly state: Freshness;
  /** Seconds since publication, or null when nothing has been published. */
  readonly ageSeconds: number | null;
}

export function freshness(
  updatedAt: number | null,
  nowSeconds: number,
  maxStaleness: number,
): FreshnessView {
  if (updatedAt === null || updatedAt <= 0) return { state: "unknown", ageSeconds: null };
  const age = nowSeconds - updatedAt;
  // A negative age means the node's clock is ahead of the browser's. Treated
  // as fresh rather than as an error: the chain's timestamp is the one the
  // contract compares against, and a browser clock is not evidence.
  if (age < 0) return { state: "fresh", ageSeconds: 0 };
  return { state: age > maxStaleness ? "stale" : "fresh", ageSeconds: age };
}

/**
 * Whether a faucet claim is available yet, and how long until it is.
 *
 * Computed and shown before the button is pressed: a cooldown the user
 * discovers by watching a transaction revert is a UI bug, not a contract
 * behaviour. Pure for the same reason as `freshness` - the clock is an
 * argument, so the test is not time-dependent.
 */
export interface ClaimAvailability {
  readonly ready: boolean;
  /** Seconds until the next claim, zero when it is available now. */
  readonly waitSeconds: number;
}

export function claimAvailability(nextClaimAt: number | null, nowSeconds: number): ClaimAvailability {
  // Unknown reads as available: the faucet's own check is authoritative, and
  // disabling a button because a view function could not be read would hide a
  // working faucet behind a failed guess at its ABI.
  if (nextClaimAt === null || nextClaimAt <= 0) return { ready: true, waitSeconds: 0 };
  const wait = nextClaimAt - nowSeconds;
  return wait <= 0 ? { ready: true, waitSeconds: 0 } : { ready: false, waitSeconds: wait };
}
