/**
 * The chain definition and the read-only client.
 *
 * Mezo's gas token is BTC with 18 decimals, not ether. Rendering "ETH"
 * anywhere on a Mezo page is wrong in a way users act on - they top up the
 * wrong asset - so the symbol is read from this definition everywhere and
 * never written as a literal.
 */

import { createClient, defineChain, http, type Client } from "viem";
import { CONFIG } from "./config.ts";

/**
 * The chain's name and gas token, resolved from its id.
 *
 * Both used to be the Mezo testnet's, hardcoded, while the id came from
 * configuration — so a local rehearsal on chain 31337 showed the badge "Mezo
 * Testnet" and labelled its balance "BTC (gas)". Anvil charges ether and is
 * not Mezo, so the one screen whose job is to say which chain and which asset
 * was saying both wrongly. A label nobody can trust on a test chain is a
 * label nobody should trust on a real one.
 */
function chainIdentity(id: number): { name: string; currency: { name: string; symbol: string; decimals: 18 } } {
  if (id === 31_611) {
    return { name: "Mezo Testnet", currency: { name: "Test Bitcoin", symbol: "BTC", decimals: 18 } };
  }
  if (id === 31_612) {
    return { name: "Mezo", currency: { name: "Bitcoin", symbol: "BTC", decimals: 18 } };
  }
  /* A rehearsal chain: named by its number, and its gas called ether, which
     is what anvil and every fork of a mainnet actually charge. */
  return { name: `Chain ${id}`, currency: { name: "Ether", symbol: "ETH", decimals: 18 } };
}

const IDENTITY = chainIdentity(CONFIG.chainId);

export const mezoTestnet = defineChain({
  id: CONFIG.chainId,
  name: IDENTITY.name,
  // BTC on Mezo, ether on a rehearsal chain. See chainIdentity above.
  nativeCurrency: IDENTITY.currency,
  rpcUrls: { default: { http: [CONFIG.rpcUrl] } },
  blockExplorers: {
    default: {
      name: CONFIG.chainId === 31_612 ? "Mezo Explorer" : "Mezo Testnet Explorer",
      url: CONFIG.chainId === 31_612 ? "https://explorer.mezo.org" : "https://explorer.test.mezo.org",
    },
  },
  testnet: true,
});

/** `wallet_addEthereumChain`'s argument, in the shape that RPC wants. */
export const MEZO_ADD_CHAIN_PARAMS = {
  chainId: "0x7b7b", // 31611
  chainName: mezoTestnet.name,
  nativeCurrency: mezoTestnet.nativeCurrency,
  rpcUrls: ["https://rpc.test.mezo.org"],
  blockExplorerUrls: [mezoTestnet.blockExplorers.default.url],
} as const;

/**
 * Reads go here rather than through the wallet, so the page renders prices,
 * reserves and liabilities before anyone connects anything. A visitor who
 * only wants to look at the numbers never has to expose an address.
 *
 * `createClient` rather than `createPublicClient`, with the four actions this
 * app uses imported individually from `viem/actions`: the public client
 * attaches every public action to the object, which defeats tree-shaking and
 * measured 98.6 kB gzipped in the entry chunk. The actions we actually call
 * are readContract, getBalance and waitForTransactionReceipt.
 */
export const publicClient: Client = createClient({
  chain: mezoTestnet,
  transport: http(CONFIG.rpcUrl, {
    // Two retries: Mezo publishes one testnet endpoint, so a transient 502
    // there has no second provider to fall back to and the only thing left is
    // to ask again.
    retryCount: 2,
    timeout: 10_000,
  }),
});

export function explorerAddressUrl(address: string): string {
  return `${mezoTestnet.blockExplorers.default.url}/address/${address}`;
}

export function explorerTxUrl(hash: string): string {
  return `${mezoTestnet.blockExplorers.default.url}/tx/${hash}`;
}
