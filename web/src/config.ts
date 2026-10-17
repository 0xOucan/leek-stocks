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

/** A comma-separated list, with anything unparseable dropped rather than shown. */
function addressList(value: string | undefined): readonly Address[] {
  return String(value ?? "")
    .split(",")
    .map((entry: string) => optionalAddress(entry))
    .filter((entry): entry is Address => entry !== undefined);
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

/** Resolved once, because three things below branch on it. */
const CHAIN_ID = Number(import.meta.env.VITE_CHAIN_ID ?? 31_611);

/**
 * Mezo's own contracts, which we did not deploy and cannot choose.
 *
 * Defaulted per chain id rather than required in the environment: these
 * addresses are properties of Mezo testnet, not of our deployment, so a build
 * that forgot to set them would silently lose the one step that gets a user
 * their first MUSD. Overridable all the same, because the proxy can move and
 * a stale default is worse than a configured one.
 *
 * Only BorrowerOperations is listed. troveManager, priceFeed and musd are
 * read FROM it at runtime: it knows which ones it is wired to and this file
 * does not, and three more addresses here is three more things to go stale.
 */
function mezoBorrowerOperations(chainId: number): Address | undefined {
  if (chainId === 31_611) return getAddress("0xa14cbA6DD12D537A8decc7dd3c4aC413B8711eba");
  // No default for mainnet Mezo: this has never been tested there, and
  // guessing an address for a market that mints real debt is not a default.
  return undefined;
}

/**
 * Mezo's faucet, which hands out the testnet BTC that is both gas and
 * collateral here. A link rather than a call: it is a hosted web form with a
 * captcha, not a contract this page could invoke.
 */
function mezoFaucetUrl(chainId: number): string | undefined {
  return chainId === 31_611 ? "https://faucet.test.mezo.org" : undefined;
}

export const CONFIG = {
  rpcUrl: import.meta.env.VITE_RPC_URL ?? "https://rpc.test.mezo.org",
  /*
   * The chain id, which used to be a constant beside the RPC URL. That made
   * VITE_RPC_URL a half-measure: reads followed it anywhere, and any write
   * failed viem's chain assertion because the client still said 31611. A
   * rehearsal against a local chain could therefore read but never buy.
   */
  chainId: CHAIN_ID,
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
  /** The test-token faucet, on chains where the real MUSD does not exist. */
  faucet: optionalAddress(import.meta.env.VITE_FAUCET),
  /**
   * The tokens that faucet serves. A list rather than one variable per token,
   * because the set differs per chain and the page reads each token's symbol
   * and decimals from the token itself.
   */
  faucetTokens: addressList(import.meta.env.VITE_FAUCET_TOKENS),
  /** Mezo's native borrow market, where MUSD is minted against BTC. */
  borrowerOperations:
    optionalAddress(import.meta.env.VITE_BORROWER_OPERATIONS) ??
    mezoBorrowerOperations(CHAIN_ID),
  /** Where to send someone who holds no BTC at all. */
  nativeFaucetUrl:
    (import.meta.env.VITE_NATIVE_FAUCET_URL ?? "").trim() ||
    mezoFaucetUrl(CHAIN_ID),
} as const;

/** Nothing on this page works without a vault address, so it has one check. */
export function anyMarketDeployed(): boolean {
  return MARKETS.some((market) => market.vault !== undefined && market.share !== undefined);
}
