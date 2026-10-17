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
 * One request for every id the caller needs, rather than one per index: the
 * keyless endpoint is rate-limited and unmetered, so the cheapest reliability
 * win available is to ask fewer times. Two indices sharing bitcoin and
 * ethereum cost one call between them, not two.
 *
 * Fails loudly. A source that answers with a missing id, a zero, or a
 * non-number is a failure, not a price: the caller's fallback is deliberate
 * and labelled, and silently substituting a stale or partial basket would
 * publish a move that never happened.
 */
export async function fetchPrices(
  ids: readonly string[],
  options: {
    readonly endpoint?: string;
    readonly timeoutMs?: number;
    /** A CoinGecko demo key. Optional; keyless is the default. */
    readonly apiKey?: string;
  } = {},
): Promise<Readonly<Record<string, number>>> {
  const endpoint = options.endpoint ?? DEFAULT_ENDPOINT;
  const timeoutMs = options.timeoutMs ?? 10_000;
  const url = `${endpoint}?ids=${encodeURIComponent(ids.join(","))}&vs_currencies=usd`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    /* A demo key, when one is configured, raises the rate limit and is sent as
     * a header rather than a query parameter so it does not end up in logs,
     * proxies or an error message quoting the URL. Keyless works and is the
     * default; the key only buys headroom. */
    const headers: Record<string, string> = { accept: "application/json" };
    const apiKey = options.apiKey ?? process.env.COINGECKO_API_KEY;
    if (apiKey) headers["x-cg-demo-api-key"] = apiKey;

    const response = await fetch(url, { signal: controller.signal, headers });
    // 429 is the one the free tier actually produces, and it is worth naming
    // in the log: it means back off, not that the source is broken.
    if (response.status === 429) throw new Error("source rate-limited this client (429)");
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
