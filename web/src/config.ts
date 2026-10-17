/**
 * Build-time configuration.
 *
 * Every value here is compiled into the bundle, so every value here is
 * public. The app must also start with all of it missing: the contracts are
 * not deployed yet, and a front end that throws on a blank address cannot be
 * built or demonstrated before deployment day.
 */

import { getAddress, isAddress, type Address } from "viem";

/** `undefined` rather than a zero address, so "not deployed" has one shape. */
function optionalAddress(value: string | undefined): Address | undefined {
  if (!value) return undefined;
  const trimmed = value.trim();
  if (!isAddress(trimmed)) return undefined;
  // Checksummed on the way in, because a lowercase address compared against a
  // checksummed one from a log is a bug that only shows up in production.
  return getAddress(trimmed);
}

/** Accepts either an origin or a full endpoint, so neither spelling is a bug. */
function feedEndpointFrom(value: string | undefined): string {
  const trimmed = (value ?? "").trim().replace(/\/+$/, "");
  if (trimmed === "") return "/prices";
  return trimmed.endsWith("/prices") ? trimmed : `${trimmed}/prices`;
}

export interface MarketConfig {
  readonly symbol: string;
  readonly name: string;
  readonly vault: Address | undefined;
  readonly share: Address | undefined;
}

export const MARKETS: readonly MarketConfig[] = [
  {
    symbol: "GOLOGGLE",
    name: "Gologgle",
    vault: optionalAddress(import.meta.env.VITE_VAULT_GOLOGGLE),
    share: optionalAddress(import.meta.env.VITE_SHARE_GOLOGGLE),
  },
  {
    symbol: "AMEZON",
    name: "Amezon",
    vault: optionalAddress(import.meta.env.VITE_VAULT_AMEZON),
    share: optionalAddress(import.meta.env.VITE_SHARE_AMEZON),
  },
];

export const CONFIG = {
  rpcUrl: import.meta.env.VITE_RPC_URL ?? "https://rpc.test.mezo.org",
  /**
   * The feed's `/prices` endpoint. Relative by default, because Caddy proxies
   * `/prices` on this same host to the feed container: a same-origin request
   * needs no CORS preflight and no `connect-src` entry in the CSP. An absolute
   * URL here works, and costs a CSP change.
   */
  feedEndpoint: feedEndpointFrom(import.meta.env.VITE_FEED_URL),
  publicUrl: import.meta.env.VITE_PUBLIC_URL ?? "",
  reownProjectId: import.meta.env.VITE_REOWN_PROJECT_ID ?? "",
  musd: optionalAddress(import.meta.env.VITE_MUSD),
} as const;

/** Nothing on this page works without a vault address, so it has one check. */
export function anyMarketDeployed(): boolean {
  return MARKETS.some((market) => market.vault !== undefined && market.share !== undefined);
}
