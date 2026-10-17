/**
 * Wallet discovery and connection, by hand, over two standards.
 *
 * **EIP-6963** rather than `window.ethereum`. With two extensions installed,
 * `window.ethereum` is whichever one won the race to assign it, which is how
 * a user with both MetaMask and the LeekWallet extension ends up signing in
 * the wrong wallet. 6963 has each extension announce itself with a name, an
 * icon and its own provider object, so the choice belongs to the user and
 * nothing here is hardcoded to a wallet.
 *
 * **WalletConnect** is the second path, for a phone running the LeekWallet
 * Android companion, and it is imported only when someone picks it: the
 * package and its relay client are several hundred kilobytes, which is more
 * than the rest of this app, and most visitors use an extension or none.
 */

import type { Address, EIP1193Provider } from "viem";
import { CONFIG } from "./config.ts";
import { MEZO_ADD_CHAIN_PARAMS, mezoTestnet } from "./chain.ts";

export interface WalletOption {
  readonly id: string;
  readonly name: string;
  /** A data: URI per EIP-6963, or an inline SVG we supply for WalletConnect. */
  readonly icon: string;
  readonly kind: "injected" | "walletconnect";
  /** Set when the option cannot be used, and shown as the reason. */
  readonly disabledReason?: string;
}

export interface Connection {
  readonly provider: EIP1193Provider;
  readonly address: Address;
  readonly chainId: number;
  readonly walletName: string;
}

interface Eip6963ProviderInfo {
  uuid: string;
  name: string;
  icon: string;
  rdns: string;
}

interface Eip6963Detail {
  info: Eip6963ProviderInfo;
  provider: EIP1193Provider;
}

const injected = new Map<string, Eip6963Detail>();
const listeners = new Set<() => void>();

function notify(): void {
  for (const listener of listeners) listener();
}

/**
 * Start listening before requesting, which is the order the standard
 * requires: an extension that has already announced itself will re-announce
 * on `eip6963:requestProvider`, but one that loads later only ever fires the
 * announce event, so the listener has to be installed first and left in place.
 */
export function startWalletDiscovery(): void {
  window.addEventListener("eip6963:announceProvider", (event) => {
    const detail = (event as CustomEvent<Eip6963Detail>).detail;
    if (!detail?.info?.uuid) return;
    injected.set(detail.info.rdns, detail);
    notify();
  });
  window.dispatchEvent(new Event("eip6963:requestProvider"));
}

export function onWalletsChanged(listener: () => void): void {
  listeners.add(listener);
}

const WALLETCONNECT_ICON =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" fill="none"><circle cx="16" cy="16" r="16" fill="#3396FF"/><path d="M9.6 12.6c3.5-3.4 9.3-3.4 12.8 0l.4.4c.2.2.2.5 0 .7l-1.4 1.4c-.1.1-.3.1-.4 0l-.6-.6c-2.5-2.4-6.4-2.4-8.8 0l-.6.6c-.1.1-.3.1-.4 0L9.2 13.7c-.2-.2-.2-.5 0-.7l.4-.4Zm15.8 3 1.3 1.2c.2.2.2.5 0 .7l-5.7 5.6c-.2.2-.5.2-.7 0l-4-4c-.1-.1-.2-.1-.3 0l-4 4c-.2.2-.5.2-.7 0L5.3 17.5c-.2-.2-.2-.5 0-.7l1.3-1.2c.2-.2.5-.2.7 0l4 3.9c.1.1.2.1.3 0l4-3.9c.2-.2.5-.2.7 0l4 3.9c.1.1.2.1.3 0l4-3.9c.2-.2.5-.2.7 0Z" fill="#fff"/></svg>',
  );

export function walletOptions(): WalletOption[] {
  const options: WalletOption[] = [...injected.values()].map((detail) => ({
    id: detail.info.rdns,
    name: detail.info.name,
    icon: detail.info.icon,
    kind: "injected" as const,
  }));
  options.sort((a, b) => a.name.localeCompare(b.name));
  // Offered disabled rather than hidden when there is no project id: hiding it
  // makes a missing build variable look like a missing feature, and failing on
  // click wastes the user's time after they have committed to a choice.
  options.push({
    id: "walletconnect",
    name: "WalletConnect",
    icon: WALLETCONNECT_ICON,
    kind: "walletconnect",
    ...(CONFIG.reownProjectId
      ? {}
      : { disabledReason: "This build has no WalletConnect project id, so the QR bridge is unavailable." }),
  });
  return options;
}

async function requestAccounts(provider: EIP1193Provider, name: string): Promise<Connection> {
  const accounts = (await provider.request({ method: "eth_requestAccounts" })) as Address[];
  const address = accounts[0];
  if (!address) throw new Error("The wallet returned no account.");
  const chainId = (await provider.request({ method: "eth_chainId" })) as string;
  return { provider, address, chainId: Number.parseInt(chainId, 16), walletName: name };
}

export async function connect(option: WalletOption): Promise<Connection> {
  if (option.kind === "injected") {
    const detail = injected.get(option.id);
    if (!detail) throw new Error("That wallet is no longer announcing itself. Reload the page.");
    return requestAccounts(detail.provider, detail.info.name);
  }

  if (!CONFIG.reownProjectId) {
    throw new Error("This build has no WalletConnect project id.");
  }
  // The only dynamic import in the app, and the reason the initial bundle is
  // small. Vite emits it as a separate chunk, fetched when this line runs.
  const { EthereumProvider } = await import("@walletconnect/ethereum-provider");
  const provider = await EthereumProvider.init({
    projectId: CONFIG.reownProjectId,
    chains: [mezoTestnet.id],
    showQrModal: true,
    metadata: {
      name: "leek-stocks",
      description: "Synthetic index exposure, cash-settled in MUSD on Mezo",
      url: CONFIG.publicUrl || window.location.origin,
      icons: [`${CONFIG.publicUrl || window.location.origin}/favicon.svg`],
    },
  });
  await provider.connect();
  return requestAccounts(provider as unknown as EIP1193Provider, "WalletConnect");
}

/**
 * Switch to Mezo, adding it if the wallet has never heard of it.
 *
 * 4902 is the only code that means "unknown chain"; everything else - a
 * rejection, a locked wallet - must propagate, because adding a chain the
 * user just declined to switch to would be the opposite of what they asked.
 */
export async function switchToMezo(provider: EIP1193Provider): Promise<void> {
  try {
    await provider.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: MEZO_ADD_CHAIN_PARAMS.chainId }],
    } as never);
  } catch (error) {
    const code = (error as { code?: number } | null)?.code;
    const nested = (error as { data?: { originalError?: { code?: number } } } | null)?.data?.originalError?.code;
    if (code !== 4902 && nested !== 4902) throw error;
    await provider.request({
      method: "wallet_addEthereumChain",
      params: [MEZO_ADD_CHAIN_PARAMS],
    } as never);
  }
}

/** Account and chain changes, which arrive without the page asking. */
export function watchConnection(
  provider: EIP1193Provider,
  handlers: { accounts: (accounts: Address[]) => void; chain: (chainId: number) => void },
): void {
  const anyProvider = provider as unknown as {
    on?: (event: string, listener: (payload: unknown) => void) => void;
  };
  anyProvider.on?.("accountsChanged", (payload) => handlers.accounts(payload as Address[]));
  anyProvider.on?.("chainChanged", (payload) => handlers.chain(Number.parseInt(String(payload), 16)));
}
