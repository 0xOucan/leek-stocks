/**
 * The price source: CoinGecko's public endpoint, which needs no key and asks
 * for attribution rather than a licence. Chosen for that reason, not for
 * precision — see `indices.ts` for why equity quotes are not used.
 */

const DEFAULT_ENDPOINT = "https://api.coingecko.com/api/v3/simple/price";

export interface SourceResult {
  readonly prices: Readonly<Record<string, number>>;
  /** Where these came from, carried through to the log and the status page. */
  readonly origin: "source" | "synthetic";
}

/**
 * Fetch the given ids, quoted in USD.
 *
 * Fails loudly. A source that answers with a missing id, a zero, or a
 * non-number is a failure, not a price: the caller's fallback is deliberate
 * and labelled, and silently substituting a stale or partial basket would
 * publish a move that never happened.
 */
export async function fetchPrices(
  ids: readonly string[],
  options: { readonly endpoint?: string; readonly timeoutMs?: number } = {},
): Promise<Readonly<Record<string, number>>> {
  const endpoint = options.endpoint ?? DEFAULT_ENDPOINT;
  const timeoutMs = options.timeoutMs ?? 10_000;
  const url = `${endpoint}?ids=${encodeURIComponent(ids.join(","))}&vs_currencies=usd`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      headers: { accept: "application/json" },
    });
    if (!response.ok) throw new Error(`source answered ${response.status}`);
    const body = (await response.json()) as Record<string, { usd?: unknown }>;

    const prices: Record<string, number> = {};
    for (const id of ids) {
      const value = body[id]?.usd;
      if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
        throw new Error(`source returned no usable price for ${id}`);
      }
      prices[id] = value;
    }
    return prices;
  } finally {
    clearTimeout(timer);
  }
}
