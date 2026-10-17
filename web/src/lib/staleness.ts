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
