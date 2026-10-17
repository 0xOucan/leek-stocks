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
    /*
     * A search-and-infrastructure parody: the things an index about indexing
     * the world would be made of - a settlement layer, an oracle network and
     * storage. Nothing here is Alphabet and the index makes no claim on it.
     *
     * No constituent is shared with AMEZON, and that is the point. The first
     * weighting put bitcoin and ethereum at 80% of this basket and 60% of the
     * other, so the two indices moved together: on 2026-10-17 they read
     * 99.5961 and 99.5947, different in the fifth significant figure and
     * identical to anyone looking at them. Two indices that cannot be told
     * apart demonstrate nothing, however honest the arithmetic behind them.
     */
    constituents: [
      { id: "ethereum", weightBps: 4000 },
      { id: "chainlink", weightBps: 3500 },
      { id: "filecoin", weightBps: 2500 },
    ],
    baseValue: 100,
    /*
     * Measured 2026-10-17 from the same endpoint the service uses:
     * ethereum 2399.26, chainlink 11.98, filecoin 1.065 USD, weighted
     * 40/35/25, giving 964.163250.
     *
     * Recorded rather than re-measured at start-up because re-measuring
     * would silently rebase every holder's position: the index would read
     * 100 again after a move, and a chart would show a market that never
     * happened. Changing it is therefore a redeploy, not a config edit.
     */
    baseBasket: 964.163_25,
  },
  {
    symbol: "AMEZON",
    description: "AMEZON / MUSD",
    /*
     * A commerce-and-throughput parody: high-volume settlement and the
     * exchange layer on top of it. Again not Amazon, and again no
     * constituent in common with GOLOGGLE.
     */
    constituents: [
      { id: "solana", weightBps: 4000 },
      { id: "avalanche-2", weightBps: 3000 },
      { id: "uniswap", weightBps: 3000 },
    ],
    baseValue: 100,
    // Same measurement and endpoint: solana 103.34, avalanche-2 9.76,
    // uniswap 7.14, weighted 40/30/30, giving 46.406.
    baseBasket: 46.406,
  },
];

export function indexBySymbol(symbol: string): IndexDefinition {
  const found = INDICES.find((i) => i.symbol === symbol);
  if (!found) throw new Error(`unknown index ${symbol}`);
  return found;
}
