import type { IndexDefinition } from "./index-math.ts";

/**
 * The indices this service publishes.
 *
 * **Parody names, and that is a legal position rather than a joke.** The
 * Buildathon's own terms warrant that a submission does not infringe
 * third-party trademarks, so a share token named after a real company, or
 * carrying its logo, is exactly the risk to avoid. `Gologgle` is a distinct
 * mark; nothing here claims to track Alphabet, and the index tracks the basket
 * below and nothing else.
 *
 * The constituents are public crypto assets because their prices come from an
 * openly licensed source. Equity quotes from a free tier are delayed on
 * purpose - the delay is how a provider avoids exchange licensing fees - and
 * almost all of them forbid redistribution, which is what publishing a quote
 * on chain would be.
 *
 * `baseBasket` is the basket's value on the base date, recorded so the index
 * reads as growth from 100 rather than as the sum of some prices. Re-measuring
 * it would silently rebase every holder's position, so it is a constant with a
 * date on it.
 */
export const INDICES: readonly IndexDefinition[] = [
  {
    symbol: "GOLOGGLE",
    description: "GOLOGGLE / MUSD",
    // A search-and-infrastructure parody: two large caps and a compute-ish
    // weighting. Weights are round numbers because nothing here is optimised.
    constituents: [
      { id: "bitcoin", weightBps: 4000 },
      { id: "ethereum", weightBps: 4000 },
      { id: "chainlink", weightBps: 2000 },
    ],
    baseValue: 100,
    /*
     * Measured 2026-10-16 from the same endpoint the service uses:
     * bitcoin 81504, ethereum 2418.42, chainlink 12.30 USD, weighted
     * 40/40/20, giving 33571.428. Recorded rather than re-measured at start-up
     * because re-measuring would silently rebase every holder's position: the
     * index would read 100 again after a move, and a chart would show a
     * market that never happened.
     */
    baseBasket: 33_571.428,
  },
  {
    symbol: "AMEZON",
    description: "AMEZON / MUSD",
    constituents: [
      { id: "bitcoin", weightBps: 3000 },
      { id: "ethereum", weightBps: 3000 },
      { id: "solana", weightBps: 4000 },
    ],
    baseValue: 100,
    // Same measurement, 30/30/40 over bitcoin, ethereum and solana (104.25).
    baseBasket: 25_218.426,
  },
];

export function indexBySymbol(symbol: string): IndexDefinition {
  const found = INDICES.find((i) => i.symbol === symbol);
  if (!found) throw new Error(`unknown index ${symbol}`);
  return found;
}
