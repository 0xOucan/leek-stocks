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

export const mezoTestnet = defineChain({
  id: 31_611,
  name: "Mezo Testnet",
  nativeCurrency: { name: "Test Bitcoin", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: [CONFIG.rpcUrl] } },
  blockExplorers: { default: { name: "Mezo Explorer", url: "https://explorer.test.mezo.org" } },
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
