/**
 * The page: three sections over one piece of mutable state.
 *
 * The state is a plain object and each section re-renders its own container
 * when something it reads changes. There is no diffing because there is
 * nothing to diff - the largest section is about forty nodes - and no
 * reactivity library because a five-second poll and a handful of buttons do
 * not need one.
 */

import { type Address, type EIP1193Provider, createClient, custom, formatUnits } from "viem";
import { waitForTransactionReceipt, writeContract } from "viem/actions";
import { ERC20_ABI, VAULT_ABI } from "./abi.ts";
import { explorerAddressUrl, explorerTxUrl, mezoTestnet, publicClient } from "./chain.ts";
import { CONFIG, MARKETS, anyMarketDeployed, type MarketConfig } from "./config.ts";
import { pollFeed, type FeedSnapshot, type IndexStatus } from "./feed.ts";
import { describeError } from "./lib/errors.ts";
import { formatAge, formatAmount, formatIndexValue, parseAmount, truncateAddress } from "./lib/format.ts";
import { applySlippage, quoteBuy, quoteRedeem, solvency } from "./lib/quote.ts";
import { claimAvailability, freshness } from "./lib/staleness.ts";
import { faucetAllowedOnChain, readFaucetToken, FAUCET_ABI, type FaucetToken } from "./faucet.ts";
import { readBalances, readMarket, type Balances, type MarketState } from "./market.ts";
import {
  actionButton,
  addressChip,
  clear,
  el,
  notice,
  stat,
  type ActionButton,
} from "./ui/dom.ts";
import { connect, onWalletsChanged, startWalletDiscovery, switchToMezo, walletOptions, watchConnection } from "./wallet.ts";

const MUSD_DECIMALS = 18; // Confirmed against the live token by test/fork/MezoFork.t.sol.
const SHARE_DECIMALS = 18;
const DEFAULT_SLIPPAGE_BPS = 50;

type Mode = "buy" | "redeem";

interface State {
  feed: FeedSnapshot;
  connection: { provider: EIP1193Provider; address: Address; chainId: number; walletName: string } | null;
  selected: string;
  mode: Mode;
  amount: string;
  slippageBps: number;
  market: MarketState | null;
  balances: Balances | null;
  /** Per-section messages, kept beside the control that produced them. */
  faucetTokens: readonly FaucetToken[] | null;
  faucetMessage: { kind: "error" | "ok"; text: string; name?: string } | null;
  walletMessage: string | null;
  tradeMessage: { kind: "error" | "ok"; text: string; name?: string } | null;
  approveMessage: { kind: "error" | "ok"; text: string; name?: string } | null;
}

const state: State = {
  feed: { indices: null, error: null },
  connection: null,
  selected: MARKETS[0]?.symbol ?? "GOLOGGLE",
  mode: "buy",
  amount: "",
  slippageBps: DEFAULT_SLIPPAGE_BPS,
  market: null,
  balances: null,
  faucetTokens: null,
  faucetMessage: null,
  walletMessage: null,
  tradeMessage: null,
  approveMessage: null,
};

/* --------------------------------------------------------------- selectors */

function selectedMarket(): MarketConfig {
  return MARKETS.find((m) => m.symbol === state.selected) ?? (MARKETS[0] as MarketConfig);
}

function selectedStatus(): IndexStatus | null {
  return state.feed.indices?.find((i) => i.symbol === state.selected) ?? null;
}

function onRightChain(): boolean {
  return state.connection?.chainId === mezoTestnet.id;
}

/** Parsed input in base units, or the reason it is not usable. */
function parsedAmount(): { value: bigint | null; reason: string | null } {
  if (state.amount.trim() === "") return { value: null, reason: null };
  const parsed = parseAmount(state.amount, state.mode === "buy" ? MUSD_DECIMALS : SHARE_DECIMALS);
  return parsed.ok ? { value: parsed.value, reason: null } : { value: null, reason: parsed.reason };
}

/**
 * The single next step, resolved in a fixed order.
 *
 * One primary action at a time: showing "approve" and "buy" together invites
 * a user to click buy first, watch it revert on an allowance, and conclude
 * the app is broken. The order is connect, switch network, approve, execute,
 * and only the current one is enabled.
 */
type Step = "connect" | "switch" | "approve" | "execute";

function nextStep(): Step {
  if (!state.connection) return "connect";
  if (!onRightChain()) return "switch";
  if (state.mode === "buy") {
    const { value } = parsedAmount();
    if (value !== null && (state.balances?.allowance ?? 0n) < value) return "approve";
  }
  return "execute";
}

/* ------------------------------------------------------------------ layout */

const root = document.querySelector<HTMLElement>("#app");
const sections = {
  wallet: el("div", { class: "wallet-bar" }),
  indices: el("section", { class: "panel", id: "indices", "aria-labelledby": "indices-heading" }),
  trade: el("section", { class: "panel", id: "trade", "aria-labelledby": "trade-heading" }),
  position: el("section", { class: "panel", id: "position", "aria-labelledby": "position-heading" }),
  faucet: el("section", { class: "panel", id: "faucet", "aria-labelledby": "faucet-heading" }),
};

export function mount(): void {
  if (!root) throw new Error("#app is missing from the document.");
  root.append(
    el("header", { class: "masthead" }, [
      el("div", { class: "masthead-title" }, [
        el("h1", {}, ["LeekStonks"]),
        el("p", { class: "tagline" }, ["Lending and ETFs protocol"]),
        el("p", { class: "muted small" }, [
          "Parody index tokens, settled in MUSD on Mezo testnet. Not securities, not backed by anything.",
        ]),
      ]),
      sections.wallet,
    ]),
    sections.indices,
    sections.trade,
    sections.position,
    sections.faucet,
    el("footer", { class: "footnote" }, [
      el("p", {}, [
        "A share is priced from an index the vault does not hold, so the MUSD paid in by buyers can be less than the MUSD owed to redeemers. Redemption reverts when reserves are short rather than paying part of it. See audit finding H-1.",
      ]),
      el("p", {}, [
        // Named rather than linked: the lending market is not deployed, and a
        // navigation item that leads nowhere is worse than a sentence saying so.
        "The lending half of the protocol is not built yet. Nothing on this page borrows, lends or charges interest.",
      ]),
      el("p", {}, [
        "Gas on Mezo is paid in ",
        el("strong", {}, [mezoTestnet.nativeCurrency.symbol]),
        ", not ether.",
      ]),
    ]),
  );

  startWalletDiscovery();
  onWalletsChanged(renderWallet);
  renderAll();

  if (!anyMarketDeployed()) return;
  void refreshChain();
  pollFeed(5000, (snapshot) => {
    // A failed poll keeps the previous values and adds a banner rather than
    // blanking the cards: a blank card reads as "price is zero".
    state.feed = snapshot.indices ? snapshot : { indices: state.feed.indices, error: snapshot.error };
    renderIndices();
    renderTrade();
  });
  // Chain reads are slower and change less often than the feed, so they run
  // on their own, longer chain rather than inside the five-second loop.
  const chainLoop = (): void => {
    window.setTimeout(() => {
      void refreshChain().finally(chainLoop);
    }, 15_000);
  };
  chainLoop();
}

function renderAll(): void {
  renderWallet();
  renderIndices();
  renderTrade();
  renderPosition();
  renderFaucet();
}

/* ------------------------------------------------------------------- reads */

async function refreshChain(): Promise<void> {
  if (document.visibilityState !== "visible") return;
  const market = selectedMarket();
  state.market = await readMarket(market);
  const connection = state.connection;
  if (connection && CONFIG.musd && market.share && market.vault) {
    state.balances = await readBalances(connection.address, CONFIG.musd, market.share, market.vault);
  }
  if (connection && CONFIG.faucet && faucetAllowedOnChain(connection.chainId)) {
    const faucet = CONFIG.faucet;
    const tokens = await Promise.all(
      CONFIG.faucetTokens.map((token) => readFaucetToken(faucet, token, connection.address)),
    );
    state.faucetTokens = tokens.filter((token): token is FaucetToken => token !== null);
  } else {
    state.faucetTokens = null;
  }
  renderIndices();
  renderTrade();
  renderPosition();
  renderFaucet();
}

/* ------------------------------------------------------------- wallet bar */

function renderWallet(): void {
  clear(sections.wallet);
  const connection = state.connection;

  if (connection) {
    sections.wallet.append(
      el("div", { class: "wallet-connected" }, [
        el("span", { class: "wallet-name" }, [connection.walletName]),
        addressChip(connection.address, truncateAddress(connection.address), explorerAddressUrl(connection.address)),
        onRightChain()
          ? el("span", { class: "badge badge-ok" }, [mezoTestnet.name])
          : el("span", { class: "badge badge-warn" }, [`Chain ${connection.chainId}`]),
      ]),
    );
    if (!onRightChain()) {
      const switchButton = actionButton({
        label: `Switch to ${mezoTestnet.name}`,
        pendingLabel: "Confirm in your wallet…",
        onClick: async () => {
          state.walletMessage = null;
          renderWallet();
          try {
            await switchToMezo(connection.provider);
            const chainId = (await connection.provider.request({ method: "eth_chainId" })) as string;
            state.connection = { ...connection, chainId: Number.parseInt(chainId, 16) };
            await refreshChain();
          } catch (error) {
            state.walletMessage = describeError(error).message;
          } finally {
            renderWallet();
            renderTrade();
          }
        },
      });
      sections.wallet.append(switchButton.element);
    }
    if (state.walletMessage) sections.wallet.append(notice("error", state.walletMessage));
    return;
  }

  const list = el("div", { class: "wallet-options", role: "group", "aria-label": "Available wallets" });
  const options = walletOptions();
  const injectedCount = options.filter((o) => o.kind === "injected").length;
  if (injectedCount === 0) {
    list.append(
      el("p", { class: "muted" }, [
        "No browser wallet announced itself. Install the LeekWallet extension or another EIP-6963 wallet, or use WalletConnect.",
      ]),
    );
  }
  for (const option of options) {
    if (option.disabledReason) {
      const disabled = el("button", {
        type: "button",
        class: "wallet-option",
        disabled: true,
        title: option.disabledReason,
        "aria-describedby": "wc-disabled-reason",
      }, [
        el("img", { src: option.icon, alt: "", width: 20, height: 20 }),
        el("span", {}, [option.name]),
      ]);
      list.append(disabled, el("p", { class: "muted small", id: "wc-disabled-reason" }, [option.disabledReason]));
      continue;
    }
    const button = actionButton({
      label: option.name,
      pendingLabel: `Opening ${option.name}…`,
      variant: "secondary",
      onClick: async () => {
        state.walletMessage = null;
        renderWallet();
        try {
          const connected = await connect(option);
          state.connection = connected;
          watchConnection(connected.provider, {
            accounts: (accounts) => {
              const next = accounts[0];
              // A wallet that reports no accounts has been locked or had this
              // site revoked; treating it as still connected would show a
              // stale balance under a button that cannot sign.
              state.connection = next ? { ...connected, address: next } : null;
              state.balances = null;
              renderAll();
              void refreshChain();
            },
            chain: (chainId) => {
              state.connection = state.connection ? { ...state.connection, chainId } : null;
              renderAll();
              void refreshChain();
            },
          });
          await refreshChain();
        } catch (error) {
          state.walletMessage = describeError(error).message;
        } finally {
          renderAll();
        }
      },
    });
    button.element.prepend(el("img", { src: option.icon, alt: "", width: 20, height: 20 }));
    button.element.classList.add("wallet-option");
    list.append(button.element);
  }
  sections.wallet.append(list);
  if (state.walletMessage) sections.wallet.append(notice("error", state.walletMessage));
}

/* ----------------------------------------------------------------- indices */

function originBadge(origin: IndexStatus["origin"]): HTMLElement {
  if (origin === "synthetic") {
    // Labelled, loudly. The feed falls back to a seeded series when its source
    // fails, and a synthetic number shown as a market price is the one piece of
    // dishonesty this page could commit by accident.
    return el("span", { class: "badge badge-synthetic", title: "The feed's source was unavailable, so this is a deterministic series, not a market price." }, [
      "synthetic",
    ]);
  }
  if (origin === "source") return el("span", { class: "badge badge-ok" }, ["source"]);
  return el("span", { class: "badge badge-muted" }, ["no data"]);
}

function renderIndices(): void {
  clear(sections.indices);
  sections.indices.append(el("h2", { id: "indices-heading" }, ["Indices"]));

  if (!anyMarketDeployed()) {
    sections.indices.append(
      notice(
        "warning",
        "No contract addresses are configured in this build, so there is nothing to read on chain yet. Set VITE_VAULT_* and VITE_SHARE_* once the contracts are deployed.",
      ),
    );
  }
  if (state.feed.error) sections.indices.append(notice("warning", state.feed.error));

  const now = Math.floor(Date.now() / 1000);
  const grid = el("div", { class: "grid" });
  for (const market of MARKETS) {
    const status = state.feed.indices?.find((i) => i.symbol === market.symbol) ?? null;
    const onChain = market.symbol === state.selected ? state.market : null;
    const fresh = freshness(
      status?.onChainUpdatedAt ?? onChain?.round?.updatedAt ?? null,
      now,
      onChain?.maxStaleness ?? 3600,
    );

    const card = el("article", { class: "card", "aria-label": `${market.name} index` }, [
      el("div", { class: "card-head" }, [
        el("div", {}, [
          el("h3", {}, [market.symbol]),
          el("p", { class: "muted small" }, [status?.description ?? `${market.symbol} / MUSD`]),
        ]),
        originBadge(status?.origin ?? null),
      ]),
      // Fixed-height value row, so a value arriving on the next poll does not
      // push the rest of the card down.
      el("p", { class: "price mono" }, [formatIndexValue(status?.value ?? null)]),
      el("dl", { class: "meta" }, [
        el("dt", {}, ["Round"]),
        el("dd", { class: "mono" }, [status?.onChainRound ?? onChain?.round?.id.toString() ?? "—"]),
        el("dt", {}, ["Published"]),
        el("dd", {}, [fresh.ageSeconds === null ? "never" : formatAge(fresh.ageSeconds)]),
        el("dt", {}, ["On chain"]),
        el("dd", { class: "mono" }, [
          onChain?.price ? formatAmount(onChain.price, MUSD_DECIMALS, 2) + " MUSD" : "—",
        ]),
      ]),
      fresh.state === "stale"
        ? notice(
            "warning",
            `This answer is older than the vault's staleness window (${onChain?.maxStaleness ?? 3600}s), so buying and redeeming revert until a new round is published.`,
          )
        : null,
      market.vault
        ? el("div", { class: "card-foot" }, [
            el("span", { class: "muted small" }, ["Vault"]),
            addressChip(market.vault, truncateAddress(market.vault), explorerAddressUrl(market.vault)),
          ])
        : el("p", { class: "muted small" }, ["Not deployed yet."]),
    ]);
    grid.append(card);
  }
  sections.indices.append(grid);
}

/* ------------------------------------------------------------------- trade */

function walletClientFor(provider: EIP1193Provider, address: Address) {
  // Same reason as the read client: `createWalletClient` would attach every
  // wallet action, and this page sends exactly two kinds of transaction.
  return createClient({ account: address, chain: mezoTestnet, transport: custom(provider) });
}

async function sendAndWait(hash: `0x${string}`): Promise<void> {
  const receipt = await waitForTransactionReceipt(publicClient, { hash });
  if (receipt.status !== "success") {
    // A mined-but-reverted transaction carries no revert reason in the
    // receipt, so the only honest message names the hash and lets the user
    // read it on the explorer.
    throw new Error(`The transaction was mined but reverted. See ${explorerTxUrl(hash)}`);
  }
}

function renderTrade(): void {
  clear(sections.trade);
  sections.trade.append(el("h2", { id: "trade-heading" }, ["Buy and redeem"]));

  const market = selectedMarket();
  const chain = state.market;
  const status = selectedStatus();

  const marketSelect = el("select", { class: "select", id: "market-select", "aria-label": "Index" });
  for (const option of MARKETS) {
    const item = el("option", { value: option.symbol, selected: option.symbol === state.selected }, [
      `${option.symbol}${option.vault ? "" : " (not deployed)"}`,
    ]);
    marketSelect.append(item);
  }
  marketSelect.addEventListener("change", () => {
    state.selected = marketSelect.value;
    state.market = null;
    state.balances = null;
    state.tradeMessage = null;
    state.approveMessage = null;
    renderAll();
    void refreshChain();
  });

  const modeGroup = el("div", { class: "segmented", role: "radiogroup", "aria-label": "Action" });
  for (const mode of ["buy", "redeem"] as const) {
    const button = el("button", {
      type: "button",
      role: "radio",
      "aria-checked": state.mode === mode ? "true" : "false",
      class: `segment${state.mode === mode ? " is-active" : ""}`,
    }, [mode === "buy" ? "Buy" : "Redeem"]);
    button.addEventListener("click", () => {
      state.mode = mode;
      state.amount = "";
      state.tradeMessage = null;
      renderTrade();
    });
    modeGroup.append(button);
  }

  sections.trade.append(
    el("div", { class: "trade-head" }, [
      el("label", { class: "field-label", for: "market-select" }, ["Index"]),
      marketSelect,
      modeGroup,
    ]),
  );

  if (!market.vault || !market.share || !CONFIG.musd) {
    sections.trade.append(
      notice("warning", `${market.symbol} is not deployed in this build, so there is nothing to buy yet.`),
    );
    return;
  }

  // H-1, before anyone commits rather than after a revert.
  if (chain && chain.liabilities !== null) {
    const view = solvency(chain.reserves, chain.liabilities);
    if (view.short) {
      sections.trade.append(
        notice(
          "warning",
          `This vault owes ${formatAmount(chain.liabilities, MUSD_DECIMALS, 2)} MUSD if every share were redeemed and holds ${formatAmount(chain.reserves, MUSD_DECIMALS, 2)} MUSD, a shortfall of ${formatAmount(view.shortfall, MUSD_DECIMALS, 2)} MUSD. Shares are priced from an index the vault does not hold, so a rising index opens this gap. Redemption will revert rather than pay part of what is owed until someone funds the backstop.`,
        ),
      );
    }
  }
  if (chain?.paused) {
    sections.trade.append(notice("warning", "The guardian has paused this vault. Buying and redeeming revert until it is unpaused."));
  }
  if (chain?.priceError) {
    sections.trade.append(notice("error", `No usable price: ${chain.priceError}`));
  }

  const decimals = state.mode === "buy" ? MUSD_DECIMALS : SHARE_DECIMALS;
  const unit = state.mode === "buy" ? "MUSD" : "shares";
  const input = el("input", {
    class: "input mono",
    id: "amount",
    type: "text",
    inputmode: "decimal",
    autocomplete: "off",
    spellcheck: false,
    placeholder: "0.00",
    value: state.amount,
    "aria-describedby": "amount-help",
  });
  input.addEventListener("input", () => {
    state.amount = input.value;
    renderQuote();
  });

  const balanceForMode = state.mode === "buy" ? state.balances?.musd : state.balances?.shares;
  const maxButton = el("button", { type: "button", class: "button button-ghost small" }, ["Max"]);
  maxButton.addEventListener("click", () => {
    if (balanceForMode === undefined) return;
    state.amount = formatUnits(balanceForMode, decimals);
    input.value = state.amount;
    renderQuote();
  });

  const slippage = el("select", { class: "select", id: "slippage", "aria-label": "Slippage tolerance" });
  for (const bps of [10, 50, 100, 300]) {
    slippage.append(
      el("option", { value: String(bps), selected: state.slippageBps === bps }, [`${bps / 100}%`]),
    );
  }
  slippage.addEventListener("change", () => {
    state.slippageBps = Number(slippage.value);
    renderQuote();
  });

  const quoteBox = el("div", { class: "quote", "aria-live": "polite" });
  const actionRow = el("div", { class: "action-row" });
  const messageBox = el("div", { class: "messages" });

  sections.trade.append(
    el("div", { class: "field" }, [
      el("label", { class: "field-label", for: "amount" }, [`Amount (${unit})`]),
      el("div", { class: "field-row" }, [input, maxButton]),
      el("p", { class: "muted small", id: "amount-help" }, [
        balanceForMode === undefined
          ? "Connect a wallet to see your balance."
          : `You hold ${formatAmount(balanceForMode, decimals, 4)} ${unit}.`,
      ]),
    ]),
    el("div", { class: "field field-inline" }, [
      el("label", { class: "field-label", for: "slippage" }, ["Slippage tolerance"]),
      slippage,
    ]),
    quoteBox,
    actionRow,
    messageBox,
  );

  /** Re-renders only the quote, the action and the messages. */
  function renderQuote(): void {
    clear(quoteBox);
    clear(actionRow);
    clear(messageBox);

    const { value: amount, reason } = parsedAmount();
    const price = chain?.price ?? null;
    const feeBps = chain?.feeBps ?? 0;

    if (reason) quoteBox.append(notice("error", reason));

    let minimum = 0n;
    if (amount !== null && price !== null && price > 0n) {
      if (state.mode === "buy") {
        const quote = quoteBuy(amount, price, feeBps);
        minimum = applySlippage(quote.sharesOut, state.slippageBps);
        quoteBox.append(
          el("dl", { class: "quote-list" }, [
            el("dt", {}, ["Fee"]),
            el("dd", { class: "mono" }, [`${formatAmount(quote.fee, MUSD_DECIMALS, 6)} MUSD (${feeBps / 100}%)`]),
            el("dt", {}, ["Shares"]),
            el("dd", { class: "mono" }, [formatAmount(quote.sharesOut, SHARE_DECIMALS, 6)]),
            el("dt", {}, ["Minimum accepted"]),
            el("dd", { class: "mono" }, [formatAmount(minimum, SHARE_DECIMALS, 6)]),
            el("dt", {}, ["Price"]),
            el("dd", { class: "mono" }, [`${formatAmount(price, MUSD_DECIMALS, 2)} MUSD / share`]),
          ]),
        );
        if (chain && chain.maxShares > 0n) {
          quoteBox.append(
            el("p", { class: "muted small" }, [
              `Supply is capped at ${formatAmount(chain.maxShares, SHARE_DECIMALS, 0)} shares; a buy that would pass the cap reverts.`,
            ]),
          );
        }
      } else {
        const quote = quoteRedeem(amount, price, feeBps);
        minimum = applySlippage(quote.musdOut, state.slippageBps);
        quoteBox.append(
          el("dl", { class: "quote-list" }, [
            el("dt", {}, ["Fee"]),
            el("dd", { class: "mono" }, [`${formatAmount(quote.fee, MUSD_DECIMALS, 6)} MUSD (${feeBps / 100}%)`]),
            el("dt", {}, ["You receive"]),
            el("dd", { class: "mono" }, [`${formatAmount(quote.musdOut, MUSD_DECIMALS, 6)} MUSD`]),
            el("dt", {}, ["Minimum accepted"]),
            el("dd", { class: "mono" }, [`${formatAmount(minimum, MUSD_DECIMALS, 6)} MUSD`]),
            el("dt", {}, ["Vault must hold"]),
            el("dd", { class: "mono" }, [`${formatAmount(quote.gross, MUSD_DECIMALS, 2)} MUSD`]),
          ]),
        );
        if (chain && quote.gross > chain.reserves) {
          quoteBox.append(
            notice(
              "warning",
              `The vault holds ${formatAmount(chain.reserves, MUSD_DECIMALS, 2)} MUSD, less than the ${formatAmount(quote.gross, MUSD_DECIMALS, 2)} MUSD this redemption needs, so it would revert with InsufficientReserves.`,
            ),
          );
        }
      }
    } else if (!reason) {
      // Reserved space, so the action row does not jump when a quote appears.
      quoteBox.append(el("p", { class: "muted small" }, ["Enter an amount to see the fee and the minimum you would accept."]));
    }

    const step = nextStep();
    const connection = state.connection;
    const vault = market.vault as Address;
    const musd = CONFIG.musd as Address;

    let primary: ActionButton;
    if (step === "connect") {
      primary = actionButton({
        label: "Connect a wallet",
        pendingLabel: "Connect a wallet",
        onClick: async () => {
          document.querySelector<HTMLElement>(".wallet-options button:not([disabled])")?.focus();
        },
      });
    } else if (step === "switch") {
      primary = actionButton({
        label: `Switch to ${mezoTestnet.name}`,
        pendingLabel: "Confirm in your wallet…",
        onClick: async () => {
          if (!connection) return;
          try {
            await switchToMezo(connection.provider);
            const chainId = (await connection.provider.request({ method: "eth_chainId" })) as string;
            state.connection = { ...connection, chainId: Number.parseInt(chainId, 16) };
            await refreshChain();
          } catch (error) {
            const explained = describeError(error);
            state.tradeMessage = { kind: "error", text: explained.message, name: explained.name };
          } finally {
            renderAll();
          }
        },
      });
    } else if (step === "approve") {
      primary = actionButton({
        label: `Approve ${formatAmount(amount ?? 0n, MUSD_DECIMALS, 4)} MUSD`,
        pendingLabel: "Approving…",
        onClick: async () => {
          if (!connection || amount === null) return;
          state.approveMessage = null;
          try {
            const wallet = walletClientFor(connection.provider, connection.address);
            // Exact amount, not an unlimited allowance: the vault pulls
            // exactly `musdAmount` in `buy`, so a max approval would be
            // standing authority over the user's whole MUSD balance for no
            // benefit. The cost is one approval per buy, which is the trade
            // the audit's "no infinite approvals" row asks for.
            const hash = await writeContract(wallet, {
              address: musd,
              abi: ERC20_ABI,
              functionName: "approve",
              args: [vault, amount],
            });
            state.approveMessage = { kind: "ok", text: "Approved. Waiting for the allowance to confirm…" };
            renderQuote();
            await sendAndWait(hash);
            // Re-read rather than assume: the allowance the vault will see is
            // the chain's, and this is also the cooldown - the buy button
            // stays out of reach until the new allowance is actually there.
            await refreshChain();
            state.approveMessage = { kind: "ok", text: "Allowance confirmed." };
          } catch (error) {
            const explained = describeError(error);
            state.approveMessage = { kind: "error", text: explained.message, name: explained.name };
          } finally {
            renderAll();
          }
        },
      });
    } else {
      const disabledReason =
        amount === null
          ? "Enter an amount first."
          : chain?.paused
            ? "The vault is paused."
            : chain?.price === null
              ? "There is no usable price right now."
              : null;
      primary = actionButton({
        label: state.mode === "buy" ? "Buy shares" : "Redeem shares",
        pendingLabel: state.mode === "buy" ? "Buying…" : "Redeeming…",
        onClick: async () => {
          if (!connection || amount === null) return;
          state.tradeMessage = null;
          try {
            const wallet = walletClientFor(connection.provider, connection.address);
            const hash =
              state.mode === "buy"
                ? await writeContract(wallet, {
                    address: vault,
                    abi: VAULT_ABI,
                    functionName: "buy",
                    args: [amount, minimum],
                  })
                : await writeContract(wallet, {
                    address: vault,
                    abi: VAULT_ABI,
                    functionName: "redeem",
                    args: [amount, minimum],
                  });
            await sendAndWait(hash);
            await refreshChain();
            state.amount = "";
            state.tradeMessage = {
              kind: "ok",
              text: state.mode === "buy" ? "Bought. Your balance is below." : "Redeemed. Your balance is below.",
            };
          } catch (error) {
            const explained = describeError(error);
            state.tradeMessage = { kind: "error", text: explained.message, name: explained.name };
          } finally {
            renderAll();
          }
        },
      });
      primary.setBlocked(disabledReason);
    }

    // Redeeming needs an allowance on the share token, which the vault pulls
    // in `burnFrom`. It is a separate approval with its own button, so a
    // pending share approval never greys out the MUSD one.
    actionRow.append(primary.element);

    if (state.approveMessage) {
      messageBox.append(notice(state.approveMessage.kind, state.approveMessage.text, state.approveMessage.name));
    }
    if (state.tradeMessage) {
      messageBox.append(notice(state.tradeMessage.kind, state.tradeMessage.text, state.tradeMessage.name));
    }
    if (status?.origin === "synthetic") {
      messageBox.append(
        notice("warning", "The feed is publishing its deterministic series, not a market price, because its source was unavailable."),
      );
    }
  }

  renderQuote();
}

/* ------------------------------------------------------------------ faucet */

function renderFaucet(): void {
  clear(sections.faucet);
  const connection = state.connection;

  // Not shown at all on a mainnet: the contract refuses those chain ids by
  // construction, so an explanation would be noise on a page where the faucet
  // is simply not a thing that exists.
  if (connection && !faucetAllowedOnChain(connection.chainId)) return;

  sections.faucet.append(el("h2", { id: "faucet-heading" }, ["Get test tokens"]));

  if (!CONFIG.faucet) {
    sections.faucet.append(
      notice(
        "warning",
        "No faucet is configured in this build. On Mezo testnet the settlement token is the real MUSD, so there is nothing to mint; on the chains where the protocol ships its own mock tokens, set VITE_FAUCET once the faucet is deployed.",
      ),
    );
    return;
  }
  if (!connection) {
    sections.faucet.append(el("p", { class: "muted" }, ["Connect a wallet to claim test tokens."]));
    return;
  }

  const tokens = state.faucetTokens;
  if (tokens === null) {
    sections.faucet.append(el("p", { class: "muted" }, ["Reading the faucet\u2026"]));
    return;
  }
  if (tokens.length === 0) {
    sections.faucet.append(
      notice("warning", "The configured faucet reports no tokens this page can read, so there is nothing to claim yet."),
    );
    return;
  }

  const now = Math.floor(Date.now() / 1000);
  const grid = el("div", { class: "grid" });
  for (const token of tokens) {
    const availability = claimAvailability(token.nextClaimAt, now);
    // Each claim owns its own pending state, so one token in flight does not
    // grey out the others.
    const button = actionButton({
      label: `Claim ${token.symbol}`,
      pendingLabel: "Claiming\u2026",
      variant: "secondary",
      onClick: async () => {
        state.faucetMessage = null;
        try {
          const wallet = walletClientFor(connection.provider, connection.address);
          const hash = await writeContract(wallet, {
            address: CONFIG.faucet as Address,
            abi: FAUCET_ABI,
            functionName: "claim",
            args: [token.address],
          });
          await sendAndWait(hash);
          await refreshChain();
          state.faucetMessage = { kind: "ok", text: `Claimed ${token.symbol}. Your balance is below.` };
        } catch (error) {
          const explained = describeError(error);
          state.faucetMessage = { kind: "error", text: explained.message, name: explained.name };
        } finally {
          renderFaucet();
          renderPosition();
        }
      },
    });
    // The cooldown is read and shown before the click. A revert the UI could
    // have predicted is a UI bug, not a contract behaviour.
    if (!availability.ready) {
      button.setBlocked(`You can claim ${token.symbol} again in ${formatAge(availability.waitSeconds).replace(" ago", "")}.`);
    }

    grid.append(
      el("article", { class: "card" }, [
        el("div", { class: "card-head" }, [
          el("div", {}, [
            // The symbol comes from the token, never from this page: on a
            // chain with mocks, that symbol is the only thing distinguishing
            // leekMUSD from the real MUSD on Mezo.
            el("h3", { class: "mono" }, [token.symbol]),
            el("p", { class: "muted small" }, [
              token.dripAmount === null
                ? "Claim amount is set by the faucet."
                : `${formatAmount(token.dripAmount, token.decimals, 4)} per claim`,
            ]),
          ]),
          addressChip(token.address, truncateAddress(token.address), explorerAddressUrl(token.address)),
        ]),
        stat("Your balance", formatAmount(token.balance, token.decimals, 6), formatUnits(token.balance, token.decimals)),
        availability.ready
          ? null
          : el("p", { class: "muted small" }, [
              `Available again in ${formatAge(availability.waitSeconds).replace(" ago", "")}.`,
            ]),
        button.element,
      ].filter((node): node is HTMLElement => node !== null)),
    );
  }
  sections.faucet.append(grid);
  if (state.faucetMessage) {
    sections.faucet.append(notice(state.faucetMessage.kind, state.faucetMessage.text, state.faucetMessage.name));
  }
}

/* ---------------------------------------------------------------- position */

function renderPosition(): void {
  clear(sections.position);
  sections.position.append(el("h2", { id: "position-heading" }, ["Your position"]));

  const connection = state.connection;
  if (!connection) {
    sections.position.append(el("p", { class: "muted" }, ["Connect a wallet to see your balances."]));
    return;
  }
  const market = selectedMarket();
  const balances = state.balances;
  const symbol = mezoTestnet.nativeCurrency.symbol;

  sections.position.append(
    el("div", { class: "stats" }, [
      stat(
        `${market.symbol} shares`,
        balances ? formatAmount(balances.shares, SHARE_DECIMALS, 6) : "—",
        balances ? formatUnits(balances.shares, SHARE_DECIMALS) : undefined,
      ),
      stat(
        "MUSD",
        balances ? formatAmount(balances.musd, MUSD_DECIMALS, 4) : "—",
        balances ? formatUnits(balances.musd, MUSD_DECIMALS) : undefined,
      ),
      stat(
        `${symbol} (gas)`,
        balances ? formatAmount(balances.native, mezoTestnet.nativeCurrency.decimals, 8) : "—",
        balances ? formatUnits(balances.native, mezoTestnet.nativeCurrency.decimals) : undefined,
      ),
      stat(
        "Approved to vault",
        balances ? `${formatAmount(balances.allowance, MUSD_DECIMALS, 4)} MUSD` : "—",
      ),
    ]),
    el("div", { class: "card-foot" }, [
      el("span", { class: "muted small" }, ["Address"]),
      addressChip(connection.address, truncateAddress(connection.address), explorerAddressUrl(connection.address)),
    ]),
  );
  if (market.share) {
    sections.position.append(
      el("div", { class: "card-foot" }, [
        el("span", { class: "muted small" }, ["Share token"]),
        addressChip(market.share, truncateAddress(market.share), explorerAddressUrl(market.share)),
      ]),
    );
  }
}
