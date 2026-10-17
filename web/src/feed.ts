/**
 * Reading the feed service's `GET /prices`.
 *
 * Same-origin by default: Caddy proxies `/prices` on this host to the feed
 * container, so there is no second origin, no CORS preflight and no
 * `connect-src` entry to open. In development Vite's dev server proxies the
 * same path, so the code has one shape in both places.
 *
 * Polled with a chained `setTimeout` rather than `setInterval`: the feed runs
 * on a small VPS behind the same Caddy as this page, and with an interval a
 * response slower than the period stacks requests until the browser's
 * per-host connection limit queues them, after which the page shows numbers
 * that are minutes old while appearing live. Chaining makes the next request
 * start after the previous one finishes, so a slow feed degrades to a slower
 * refresh and nothing else.
 */

import { CONFIG } from "./config.ts";

/** The shape `FeedService.statusSnapshot()` serialises; see feed/src/service.ts. */
export interface IndexStatus {
  symbol: string;
  description: string;
  value: number | null;
  onChainAnswer: string | null;
  onChainRound: string | null;
  onChainUpdatedAt: number | null;
  origin: "source" | "synthetic" | null;
  lastAttemptAt: number | null;
  lastError: string | null;
  lastDecision: string | null;
}

export interface FeedSnapshot {
  readonly indices: readonly IndexStatus[] | null;
  readonly error: string | null;
}

export async function fetchFeed(signal?: AbortSignal): Promise<FeedSnapshot> {
  try {
    const response = await fetch(CONFIG.feedEndpoint, {
      signal: signal ?? null,
      // The feed sets no-store itself; asked for here as well so a proxy in
      // front of it cannot serve a cached price as a live one.
      cache: "no-store",
    });
    if (!response.ok) {
      return { indices: null, error: `The feed answered ${response.status}.` };
    }
    const body = (await response.json()) as { indices?: IndexStatus[] };
    if (!Array.isArray(body.indices)) {
      return { indices: null, error: "The feed's response did not contain an index list." };
    }
    return { indices: body.indices, error: null };
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      return { indices: null, error: null };
    }
    return {
      indices: null,
      error: "The feed service is unreachable, so the values below may be out of date.",
    };
  }
}

/**
 * Chained polling. Returns a stop function; the caller owns the lifetime.
 *
 * The visibility check exists because a tab left open overnight otherwise
 * makes 17,000 requests nobody reads, which on a single-endpoint testnet RPC
 * and a 128 MB feed container is rude rather than harmless.
 */
export function pollFeed(periodMs: number, onSnapshot: (snapshot: FeedSnapshot) => void): () => void {
  let stopped = false;
  let timer: number | undefined;

  const run = async (): Promise<void> => {
    if (stopped) return;
    if (document.visibilityState === "visible") {
      onSnapshot(await fetchFeed());
    }
    if (stopped) return;
    timer = window.setTimeout(() => void run(), periodMs);
  };

  void run();
  return () => {
    stopped = true;
    if (timer !== undefined) window.clearTimeout(timer);
  };
}
