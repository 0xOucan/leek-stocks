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
import { allowanceFor } from "./allowance.ts";
import {
  FEE_MARGIN_BPS,
  GAS_COMPENSATION,
  currentIcr,
  formatIcr,
  startingCollateral,
  troveQuote,
} from "./lib/borrow.ts";
import {
  currentStep,
  isSetUp,
  onboardingSteps,
  setupProgress,
  type OnboardingStep,
} from "./lib/onboarding.ts";
import {
  BORROWER_OPERATIONS_ABI,
  TROVE_ACTIVE,
  ZERO_ADDRESS,
  readBorrowMarket,
  readTrove,
  type BorrowMarket,
  type TrovePosition,
} from "./mezoBorrow.ts";
import { readBalances, readMarket, readVaultPrice, type Balances, type MarketState } from "./market.ts";
import {
  ICONS,
  actionButton,
  addressChip,
  clear,
  el,
  icon,
  notice,
  preservingFocus,
  stat,
  type ActionButton,
} from "./ui/dom.ts";
import { connect, onWalletsChanged, startWalletDiscovery, switchToMezo, walletOptions, watchConnection } from "./wallet.ts";

const MUSD_DECIMALS = 18; // Confirmed against the live token by test/fork/MezoFork.t.sol.
const SHARE_DECIMALS = 18;
const DEFAULT_SLIPPAGE_BPS = 50;

/**
 * Gas money, on top of whatever is being locked as collateral.
 *
 * 0.0001 BTC. Mezo's base fee is measured in hundreds of wei, so opening a
 * trove costs a rounding error of this; the margin is for the padding wallets
 * add to their own estimates.
 */
const GAS_ALLOWANCE = 10n ** 14n;

/**
 * The fallback "enough BTC" line, used only before the price is known.
 *
 * It is a fallback and not the rule, because the rule cannot be a constant:
 * how much BTC is enough depends on the live BTC price, and Mezo's faucet
 * does not publish its drip amount anywhere this page can read - its page is
 * a JavaScript shell. So the real threshold is computed from what the next
 * step actually needs (see `minNativeNeeded`) and this number is only what
 * the stepper uses in the moment before the first price read lands. Guessing
 * a threshold would mean a faucet that drips less than the guess leaves the
 * step permanently unticked, with no way for a user to proceed.
 */
const MIN_NATIVE_FALLBACK = 5n * 10n ** 14n;

/**
 * Enough BTC to open the position currently in the form, plus gas.
 *
 * Self-consistent by construction: if this returns true the borrow button
 * below will not be blocked for want of collateral, and if it returns false
 * that button would be. The stepper and the form cannot disagree.
 */
function minNativeNeeded(): bigint {
  const market = state.borrowMarket;
  if (!market || market.price === null) return MIN_NATIVE_FALLBACK;
  const quote = troveQuote({
    debtRequested: borrowDebtWei() ?? market.minNetDebt,
    collateral: 0n,
    price: market.price,
    minNetDebt: market.minNetDebt,
    mcr: market.mcr,
    balance: 0n,
  });
  // The suggested figure, not the protocol's 110% minimum: the form refuses
  // anything under 150%, so 110% is not a state a user can reach from here.
  return quote.suggestedCollateral + GAS_ALLOWANCE;
}

/** Below this there is not enough MUSD to buy a share worth looking at. */
const MIN_MUSD = 10n ** 18n;

/** What the borrow form starts at: the protocol's own minimum. */
const DEFAULT_BORROW = "1800";

type Mode = "buy" | "redeem";

interface State {
  feed: FeedSnapshot;
  connection: { provider: EIP1193Provider; address: Address; chainId: number; walletName: string } | null;
  selected: string;
  mode: Mode;
  amount: string;
  slippageBps: number;
  market: MarketState | null;
  /** On-chain price per index, so every card can show one. */
  prices: Record<string, bigint | null>;
  balances: Balances | null;
  /** Per-section messages, kept beside the control that produced them. */
  /** Mezo's borrow market, read from the chain. Null when not on Mezo. */
  borrowMarket: BorrowMarket | null;
  /** The connected address's position in it. */
  trove: TrovePosition | null;
  borrowDebt: string;
  borrowCollateral: string;
  /** Set once, when the market and a balance are first known. */
  borrowPrefilled: boolean;
  borrowMessage: { kind: "error" | "ok"; text: string; name?: string } | null;
  /**
   * Set only by the user clicking "show the setup steps".
   *
   * The panel hides itself once a wallet is set up, so this is the way back
   * for someone helping a newcomer or connecting a second, empty wallet. It
   * is never set by a poll: a panel that reappears on its own is the thing
   * being fixed.
   */
  showSteps: boolean;
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
  prices: {},
  balances: null,
  borrowMarket: null,
  trove: null,
  borrowDebt: DEFAULT_BORROW,
  borrowCollateral: "",
  borrowPrefilled: false,
  borrowMessage: null,
  showSteps: false,
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
  const { value } = parsedAmount();
  if (value !== null) {
    /* Each mode spends a different token, so each needs its own allowance.
       `buy` pulls MUSD from the buyer. `redeem` calls burnFrom on the SHARE
       token, and ETFShare spends an allowance there on purpose so the vault
       cannot burn a holder's shares uninvited - see its burnFrom.
       This only checked the MUSD allowance, and only in buy mode, so every
       first redeem went straight to execute and reverted with
       ERC20InsufficientAllowance(vault, 0, shares). A comment further down
       described a separate share-approval button as though it existed; it did
       not. */
    if (allowanceFor(state.mode, state.balances) < value) return "approve";
  }
  return "execute";
}

/* ------------------------------------------------------------------ layout */

const root = document.querySelector<HTMLElement>("#app");
const sections = {
  wallet: el("div", { class: "wallet-bar" }),
  start: el("section", { class: "panel panel-start", id: "start", "aria-labelledby": "start-heading" }),
  indices: el("section", { class: "panel", id: "indices", "aria-labelledby": "indices-heading" }),
  borrow: el("section", { class: "panel", id: "borrow", "aria-labelledby": "borrow-heading" }),
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
        /* The product is LeekStonks; LeekDefi is the host it shares with
           Leeknding, which is written and tested but not deployed. Naming it
           here as coming rather than as a tab is the honest version: a tab
           implies something to click. */
        /* "Parody" is gone from every visible string.
           It was accurate and it was the wrong word on a trading screen: a
           tester who reads "parody" in the first line treats the numbers as a
           joke and stops checking whether they are right. The behaviour is
           not a joke - a real oracle, a real fee, a real reserve check, real
           settlement - and that is what the line should say. The index names
           (GOLOGGLE, AMEZON) are invented on purpose and belong to no company,
           which is the thing "parody" was doing and the disclaimer below now
           does explicitly instead. */
        el("p", { class: "tagline" }, ["Synthetic index exposure, cash-settled in MUSD \u00b7 part of LeekDefi"]),
        el("p", { class: "muted small" }, [
          /* The chain comes from the chain, not from this sentence. On a
             rehearsal chain the settlement token is a mock and saying "on
             Mezo testnet" was the last place the page still asserted where it
             was running. The disclaimers after it are true everywhere. */
          `Prices track an index, settlement is in MUSD, and the vault's cover is on screen. Running on ${mezoTestnet.name}.`,
        ]),
        /* The honest small print, kept small and kept precise.
           It has to say these are not equities - they are not, and claiming
           otherwise would be a lie with a regulator attached. It does not have
           to apologise for itself. The indices are invented names, not
           tickers, and nothing here is a claim on a company. */
        el("p", { class: "muted small" }, [
          "Not securities and not shares in any company: GOLOGGLE and AMEZON are invented index names. Testnet only.",
        ]),
      ]),
      sections.wallet,
    ]),
    sections.start,
    sections.indices,
    sections.borrow,
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
        "Leeknding, the lending half, is built and tested but not deployed: multichain Leeknding is coming. Nothing on this page borrows, lends or charges interest.",
      ]),
      /* Named from the chain rather than asserted: on Mezo this is the useful
         warning that gas is bitcoin, and on a rehearsal chain the same
         sentence would have been a lie. */
      el("p", {}, [
        `Gas on ${mezoTestnet.name} is paid in `,
        el("strong", {}, [mezoTestnet.nativeCurrency.symbol]),
        mezoTestnet.nativeCurrency.symbol === "BTC" ? ", not ether." : ".",
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
    preservingFocus(() => {
      renderIndices();
      renderTrade();
      renderStart();
    });
  });
  /* Chain reads every 5 seconds, not every 15.
     Fifteen seconds was chosen because chain reads are slower than the feed
     and Mezo publishes exactly one testnet RPC, with no second provider to
     fall back to - so polling it hard is a real cost, not a theoretical one.
     It was still too slow. Reserves changed out of band (a backstop top-up
     sent from a script) and for the next fifteen seconds the page refused a
     redemption that the chain would have accepted, quoting a reserve figure
     the chain had already moved past. A blocking warning computed from stale
     state is worse than a slow number: the reader believes it and stops.
     Five seconds matches the feed loop and the 2-5s that the frontend
     guidance asks for. These are eight small eth_call reads on a chain whose
     base fee is measured in hundreds of wei; if the single operator ever
     becomes the binding constraint, the answer is a private node in
     VITE_RPC_URL, which exists for this. */
  const chainLoop = (): void => {
    window.setTimeout(() => {
      void refreshChain().finally(chainLoop);
    }, 5_000);
  };
  chainLoop();
}

function renderAll(): void {
  renderWallet();
  renderStart();
  renderBorrow();
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
  /* The on-chain price of every configured vault, not only the selected one:
     a card that shows the feed's value with no on-chain figure beside it
     cannot tell a stopped feed from an unread one. */
  state.prices = Object.fromEntries(
    await Promise.all(
      MARKETS.filter((m) => m.vault !== undefined).map(async (m) => [
        m.symbol,
        await readVaultPrice(m.vault as Address),
      ]),
    ),
  ) as Record<string, bigint | null>;
  /* Mezo's borrow market, every poll.
     Its parameters are governance-settable and its price moves, and this page
     quotes a user the collateral they are about to lock against them. A
     cached minNetDebt or a cached BTC price is a quote that the chain will
     refuse - or worse, accept at a ratio the user did not intend. */
  if (CONFIG.borrowerOperations) {
    state.borrowMarket = await readBorrowMarket();
  }

  const connection = state.connection;
  if (connection && CONFIG.borrowerOperations) {
    state.trove = await readTrove(connection.address);
  } else {
    state.trove = null;
  }
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
  renderStart();
  renderBorrow();
  /* Prefilled once, after the first read that knows both the price and the
     wallet's balance - not from a constant. The collateral a borrow needs is
     a function of the live BTC price, so a hardcoded default would be either
     absurdly over-collateralised or a revert, depending on the day. */
  maybePrefillBorrow();
  /* Wrapped, because this one runs on a five-second timer rather than in
     response to anything the user did. The caret belongs to them. */
  preservingFocus(() => {
    renderStart();
    renderBorrow();
    renderIndices();
    renderTrade();
    renderPosition();
    renderFaucet();
  });
}

/** The borrow field in base units, or null when it is empty or malformed. */
function borrowDebtWei(): bigint | null {
  const parsed = parseAmount(state.borrowDebt, MUSD_DECIMALS);
  return parsed.ok ? parsed.value : null;
}

/** The collateral field in wei, or null. */
function borrowCollateralWei(): bigint | null {
  const parsed = parseAmount(state.borrowCollateral, mezoTestnet.nativeCurrency.decimals);
  return parsed.ok ? parsed.value : null;
}

/** Prefills the collateral field once the price and a balance are known. */
function maybePrefillBorrow(): void {
  if (state.borrowPrefilled) return;
  const market = state.borrowMarket;
  const balance = state.balances?.native ?? null;
  if (!market || market.price === null || balance === null) return;

  const quote = troveQuote({
    debtRequested: borrowDebtWei() ?? market.minNetDebt,
    collateral: 0n,
    price: market.price,
    minNetDebt: market.minNetDebt,
    mcr: market.mcr,
    balance,
  });
  const target = startingCollateral(quote.suggestedCollateral, balance, GAS_ALLOWANCE);
  // Zero means this wallet cannot cover the position at the ratio this page
  // requires. Leaving the field empty is right: a prefilled figure that
  // renders its own error before the user has typed anything reads as the
  // page being broken rather than as a suggestion.
  if (target <= 0n) return;
  state.borrowCollateral = formatUnits(target, 18);
  state.borrowPrefilled = true;
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


/* ------------------------------------------------------------- get started */

/**
 * Where the user is in the flow.
 *
 * Derived from chain state on every poll rather than remembered, so it is
 * correct for someone arriving with a wallet that has already done half of
 * it - which is most returning testers, and all of my own reloads.
 */
function steps(): readonly OnboardingStep[] {
  return onboardingSteps({
    connected: state.connection !== null,
    onRightChain: onRightChain(),
    native: state.balances?.native ?? 0n,
    musd: state.balances?.musd ?? 0n,
    shares: state.balances?.shares ?? 0n,
    hasTrove: state.trove?.status === TROVE_ACTIVE,
    minNative: minNativeNeeded(),
    minMusd: MIN_MUSD,
  });
}

/** Scrolls a panel into view and moves focus into it, for keyboard users. */
function goToSection(id: "borrow" | "trade"): void {
  const panel = sections[id];
  panel.scrollIntoView({ behavior: "smooth", block: "start" });
  // tabindex -1 so focus can land on a section that is not itself focusable;
  // without it the scroll moves the viewport and leaves the keyboard caret
  // wherever it was, which is the classic "skip link that does nothing".
  panel.setAttribute("tabindex", "-1");
  panel.focus({ preventScroll: true });
}

/**
 * The one action the current step needs, or null when the step is satisfied
 * elsewhere on the page.
 *
 * Deliberately not a button per step: five buttons, four of them disabled, is
 * the pattern this page spent its whole trade section avoiding. One action,
 * and it is always the one that works right now.
 */
function stepAction(step: OnboardingStep): HTMLElement | null {
  const connection = state.connection;

  if (step.id === "connect") {
    const button = el("button", { type: "button", class: "button" }, ["Choose a wallet"]);
    button.addEventListener("click", () => {
      document.querySelector<HTMLElement>(".wallet-options button:not([disabled])")?.focus();
    });
    return button;
  }

  if (step.id === "network" && connection) {
    return actionButton({
      label: `Switch to ${mezoTestnet.name}`,
      pendingLabel: "Confirm in your wallet…",
      onClick: async () => {
        try {
          await switchToMezo(connection.provider);
          const chainId = (await connection.provider.request({ method: "eth_chainId" })) as string;
          state.connection = { ...connection, chainId: Number.parseInt(chainId, 16) };
          await refreshChain();
        } catch (error) {
          state.walletMessage = describeError(error).message;
        } finally {
          renderAll();
        }
      },
    }).element;
  }

  if (step.id === "gas") {
    /* An external link, not a transaction. Mezo's faucet is a hosted form
       with a captcha; there is no contract this page could call, and
       pretending otherwise with a button that opens a new tab under a
       "Claim" label would be a lie about what is happening. */
    if (!CONFIG.nativeFaucetUrl) return null;
    return el("a", {
      class: "button",
      href: CONFIG.nativeFaucetUrl,
      target: "_blank",
      rel: "noopener noreferrer",
    }, [`Open Mezo's faucet`, icon(ICONS.external)]);
  }

  if (step.id === "borrow") {
    const button = el("button", { type: "button", class: "button" }, ["Borrow MUSD"]);
    button.addEventListener("click", () => goToSection("borrow"));
    return button;
  }

  if (step.id === "buy" || step.id === "redeem") {
    const button = el("button", { type: "button", class: `button${step.id === "redeem" ? " button-secondary" : ""}` }, [
      step.id === "buy" ? "Go to buy" : "Go to redeem",
    ]);
    button.addEventListener("click", () => {
      if (step.id === "redeem") {
        state.mode = "redeem";
        state.amount = "";
        renderTrade();
      }
      goToSection("trade");
    });
    return button;
  }

  return null;
}

function renderStart(): void {
  clear(sections.start);

  const list = steps();
  const current = currentStep(list);
  const progress = setupProgress(list);

  /*
   * Gone, not collapsed into a congratulation, once the wallet is set up.
   *
   * A wallet holding gas and something to spend can use every control on this
   * page, so a panel above them explaining how to get there is furniture -
   * and the first thing it said was "you are here: buy index shares", which
   * the trade form asks for in its own words two panels down. The one line
   * that stays is the way back for someone connecting a second, empty wallet
   * or walking a newcomer through it; it is a link, not a tutorial, and it
   * only opens when clicked.
   */
  if (isSetUp(list) && !state.showSteps) {
    sections.start.classList.add("is-collapsed");
    const reveal = el("button", { type: "button", class: "button button-ghost small" }, ["Show the setup steps"]);
    reveal.addEventListener("click", () => {
      state.showSteps = true;
      renderStart();
    });
    sections.start.append(
      el("p", { class: "muted small start-collapsed" }, [
        `This wallet is ready: it holds ${mezoTestnet.nativeCurrency.symbol} for gas and MUSD to spend. `,
        reveal,
      ]),
    );
    return;
  }
  sections.start.classList.remove("is-collapsed");

  const head: HTMLElement[] = [
    el("h2", { id: "start-heading" }, ["Start here"]),
    el("p", { class: "muted small" }, [
      // Counted, not written: the list is the source of truth for its own
      // length, and "four steps" above a list of five is the kind of small
      // wrongness that makes a reader distrust the rest.
      `${progress.total} steps from an empty wallet to MUSD you can spend. The page works out which one you are on and only ever asks you for that one.`,
    ]),
  ];
  if (state.showSteps && isSetUp(list)) {
    // Shown on request by a wallet that did not need it, so it says so and
    // offers the way back out.
    const hide = el("button", { type: "button", class: "button button-ghost small" }, ["Hide these"]);
    hide.addEventListener("click", () => {
      state.showSteps = false;
      renderStart();
    });
    head.push(el("p", { class: "muted small" }, ["This wallet has done all of it already. ", hide]));
  }

  sections.start.append(
    el("div", { class: "start-head" }, [
      el("div", {}, head),
      el("p", { class: "start-progress mono" }, [`${progress.done} / ${progress.total}`]),
    ]),
  );

  if (!CONFIG.borrowerOperations) {
    sections.start.append(
      notice(
        "warning",
        `No borrow market is configured for chain ${CONFIG.chainId}, so there is no way to obtain MUSD from this page. On Mezo testnet this is set by default; elsewhere, set VITE_BORROWER_OPERATIONS or use the test-token faucet below.`,
      ),
    );
  }
  if (state.borrowMarket?.mismatch) {
    // The worst failure available here, so it is said first and in red.
    sections.start.append(notice("error", state.borrowMarket.mismatch));
  }

  const ol = el("ol", { class: "steps" });
  for (const [index, step] of list.entries()) {
    const action = step.state === "current" ? stepAction(step) : null;
    ol.append(
      el("li", { class: `step is-${step.state}`, "aria-current": step.state === "current" ? "step" : undefined }, [
        el("span", { class: "step-marker", "aria-hidden": "true" }, [
          step.state === "done" ? icon(ICONS.check) : String(index + 1),
        ]),
        el("div", { class: "step-body" }, [
          el("p", { class: "step-title" }, [
            step.title,
            // The state is in the text, not only in the colour: the whole
            // stepper would otherwise be unreadable to anyone who cannot
            // distinguish the done green from the current blue.
            el("span", { class: "step-state muted small" }, [
              step.state === "done" ? " · done" : step.state === "current" ? " · you are here" : "",
            ]),
          ]),
          el("p", { class: "muted small" }, [step.detail]),
          action,
        ].filter((node): node is HTMLElement => node !== null && node !== undefined)),
      ]),
    );
  }
  sections.start.append(ol);

  if (current?.id === "gas" && CONFIG.nativeFaucetUrl) {
    sections.start.append(
      el("p", { class: "muted small" }, [
        `The faucet sends ${mezoTestnet.nativeCurrency.symbol} to the address you paste in. Copy yours from the top of this page, and come back when it arrives - this step ticks itself off within five seconds.`,
      ]),
    );
  }
  if (state.walletMessage && current?.id === "network") {
    sections.start.append(notice("error", state.walletMessage));
  }
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
    // Read for every index; see readVaultPrice.
    const onChainPrice = onChain?.price ?? state.prices[market.symbol] ?? null;
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
          onChainPrice ? formatAmount(onChainPrice, MUSD_DECIMALS, 2) + " MUSD" : "—",
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
    /* The hash either way: it is the one thing that lets anyone else look
       this up, and on a chain with no explorer a bare hash is honest where a
       dead link is not. */
    const link = explorerTxUrl(hash);
    throw new Error(
      link
        ? `The transaction was mined but reverted. See ${link}`
        : `The transaction was mined but reverted. Hash ${hash}`,
    );
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
      // Buying spends MUSD; redeeming spends shares, which the vault burns
      // through burnFrom. Approving the wrong one leaves the real allowance at
      // zero and the action reverts, so the token is chosen from the mode
      // rather than hard-coded to MUSD.
      const spending = state.mode === "buy" ? musd : (market.share as Address);
      const spendingLabel = state.mode === "buy" ? "MUSD" : `${market.symbol} shares`;
      primary = actionButton({
        label: `Approve ${formatAmount(amount ?? 0n, MUSD_DECIMALS, 4)} ${spendingLabel}`,
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
              address: spending,
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

    // Redeeming needs an allowance on the share token, which the vault spends
    // in `burnFrom`. It is the same single-primary-action flow as buying -
    // nextStep() picks the token from the mode - rather than a second button:
    // two approvals on screen at once is what the step machine above exists to
    // avoid.
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


/* ------------------------------------------------------------------ borrow */

/**
 * Mezo's native borrow market, in a panel.
 *
 * Nothing here is ours. This calls Mezo's own BorrowerOperations, which mints
 * the MUSD that our vaults settle in, and it exists because that was the one
 * step in the flow a visitor could not do from this page. It is the only
 * place on the site that creates a debt, so it says so in those words, more
 * than once, and never while a quote is on screen that would hide it.
 */
function renderBorrow(): void {
  clear(sections.borrow);
  sections.borrow.append(el("h2", { id: "borrow-heading" }, ["Get MUSD: borrow against BTC"]));

  const market = state.borrowMarket;
  const connection = state.connection;

  if (!CONFIG.borrowerOperations) {
    sections.borrow.append(
      el("p", { class: "muted" }, [
        `Chain ${CONFIG.chainId} has no configured borrow market, so MUSD cannot be minted from this page.`,
      ]),
    );
    return;
  }

  sections.borrow.append(
    el("p", { class: "muted small" }, [
      "This page settles in MUSD and mints none of it. MUSD comes from Mezo's own borrow market: you lock ",
      el("strong", {}, [mezoTestnet.nativeCurrency.symbol]),
      " as collateral and it mints MUSD against it. It is a loan, not a swap - the ",
      el("strong", {}, [mezoTestnet.nativeCurrency.symbol]),
      " comes back when the debt is repaid, and it can be liquidated if the collateral ratio falls too far.",
    ]),
    el("div", { class: "card-foot" }, [
      el("span", { class: "muted small" }, ["Mezo BorrowerOperations"]),
      addressChip(
        CONFIG.borrowerOperations,
        truncateAddress(CONFIG.borrowerOperations),
        explorerAddressUrl(CONFIG.borrowerOperations),
      ),
    ]),
  );

  if (market?.mismatch) {
    sections.borrow.append(notice("error", market.mismatch));
    return;
  }
  if (!market) {
    sections.borrow.append(
      el("p", { class: "muted" }, ["Reading Mezo's borrow market…"]),
    );
    return;
  }

  // An existing position, which is the common case on a second visit. There
  // is no second openTrove: the call reverts for an address that already has
  // a trove, so offering the form again would be offering a revert.
  const trove = state.trove;
  if (trove && trove.status === TROVE_ACTIVE) {
    const icr = currentIcr(trove.collateral, market.price, trove.debt);
    sections.borrow.append(
      el("div", { class: "stats" }, [
        stat("Collateral locked", `${formatAmount(trove.collateral, 18, 8)} ${mezoTestnet.nativeCurrency.symbol}`, formatUnits(trove.collateral, 18), "returned when the debt is repaid"),
        stat("Debt owed", `${formatAmount(trove.debt, MUSD_DECIMALS, 2)} MUSD`, formatUnits(trove.debt, MUSD_DECIMALS), `includes the ${GAS_COMPENSATION / 10n ** 18n} MUSD liquidation reserve`),
        stat("Collateral ratio", formatIcr(icr), undefined, "liquidatable below 110%"),
      ]),
      notice(
        "ok",
        "You already have a position in Mezo's borrow market, so the MUSD you need is either in your wallet or in shares. One address can hold one position: opening a second reverts, and this page will not offer it.",
      ),
      el("p", { class: "muted small" }, [
        "To borrow more against the same collateral, repay, or close the position and get the ",
        mezoTestnet.nativeCurrency.symbol,
        " back, use Mezo's own app: ",
        el("a", { href: "https://mezo.org", target: "_blank", rel: "noopener noreferrer" }, ["mezo.org"]),
        ". This page only ever opens a position; it deliberately has no button that adjusts or closes one, because getting that wrong costs collateral.",
      ]),
    );
    return;
  }

  if (!connection) {
    sections.borrow.append(el("p", { class: "muted" }, ["Connect a wallet to borrow."]));
    return;
  }
  if (!onRightChain()) {
    sections.borrow.append(notice("warning", `Switch to ${mezoTestnet.name} first: this market exists only there.`));
    return;
  }

  const balance = state.balances?.native ?? 0n;
  const debtInput = el("input", {
    class: "input mono",
    id: "borrow-debt",
    type: "text",
    inputmode: "decimal",
    autocomplete: "off",
    spellcheck: false,
    placeholder: DEFAULT_BORROW,
    value: state.borrowDebt,
  });
  const collateralInput = el("input", {
    class: "input mono",
    id: "borrow-collateral",
    type: "text",
    inputmode: "decimal",
    autocomplete: "off",
    spellcheck: false,
    placeholder: "0.0",
    value: state.borrowCollateral,
  });

  const quoteBox = el("div", { class: "quote", "aria-live": "polite" });
  const actionRow = el("div", { class: "action-row" });
  const messageBox = el("div", { class: "messages" });

  const suggestButton = el("button", { type: "button", class: "button button-ghost small" }, ["Suggest"]);

  debtInput.addEventListener("input", () => {
    state.borrowDebt = debtInput.value;
    renderBorrowQuote();
  });
  collateralInput.addEventListener("input", () => {
    state.borrowCollateral = collateralInput.value;
    renderBorrowQuote();
  });

  sections.borrow.append(
    el("div", { class: "field-pair" }, [
      el("div", { class: "field" }, [
        el("label", { class: "field-label", for: "borrow-debt" }, ["Borrow (MUSD)"]),
        debtInput,
        el("p", { class: "muted small" }, [
          `Minimum ${formatAmount(market.minNetDebt, MUSD_DECIMALS, 0)} MUSD, set by the protocol.`,
        ]),
      ]),
      el("div", { class: "field" }, [
        el("label", { class: "field-label", for: "borrow-collateral" }, [
          `Lock (${mezoTestnet.nativeCurrency.symbol})`,
        ]),
        el("div", { class: "field-row" }, [collateralInput, suggestButton]),
        el("p", { class: "muted small" }, [
          `You hold ${formatAmount(balance, 18, 8)} ${mezoTestnet.nativeCurrency.symbol}.`,
        ]),
      ]),
    ]),
    quoteBox,
    actionRow,
    messageBox,
  );

  /** The quote, the action and the messages. Re-rendered on every keystroke. */
  function renderBorrowQuote(): void {
    // Re-checked rather than relying on the guard above: this is a hoisted
    // function declaration, so the compiler will not carry the outer
    // narrowing into it, and a `!` here would be asserting something about
    // call order instead of checking it.
    if (!market) return;
    clear(quoteBox);
    clear(actionRow);
    clear(messageBox);

    const debt = borrowDebtWei();
    const collateral = borrowCollateralWei();
    const price = market.price;

    const quote = troveQuote({
      debtRequested: debt ?? 0n,
      collateral: collateral ?? 0n,
      price: price ?? 0n,
      minNetDebt: market.minNetDebt,
      mcr: market.mcr,
      balance,
    });

    /* The same clamp as the prefill, so the two cannot disagree and so the
       button never fills in a figure this wallet is then refused for. Zero
       means it cannot: the button says so and disables itself rather than
       being a click that does nothing, which is the worse of the two. */
    const suggestion = startingCollateral(quote.suggestedCollateral, balance, GAS_ALLOWANCE);
    suggestButton.disabled = suggestion <= 0n;
    suggestButton.title =
      suggestion > 0n
        ? `Fill in ${formatAmount(suggestion, 18, 8)} ${mezoTestnet.nativeCurrency.symbol}, comfortably above the 150% this page requires`
        : `This wallet cannot cover ${formatAmount(debt ?? market.minNetDebt, MUSD_DECIMALS, 0)} MUSD at a safe ratio. Borrow less, or claim more ${mezoTestnet.nativeCurrency.symbol}.`;
    suggestButton.onclick = () => {
      if (suggestion <= 0n) return;
      state.borrowCollateral = formatUnits(suggestion, 18);
      collateralInput.value = state.borrowCollateral;
      renderBorrowQuote();
    };

    quoteBox.append(
      el("dl", { class: "quote-list" }, [
        el("dt", {}, ["You receive"]),
        el("dd", { class: "mono" }, [`${formatAmount(debt ?? 0n, MUSD_DECIMALS, 2)} MUSD`]),
        /* Said as its own line, because it is the number that surprises
           people: the debt is larger than the borrow. 200 MUSD of it is the
           protocol's liquidation gas reserve, which is held against the
           position and returned when it closes, and the rest is the issuance
           fee. Neither reaches the wallet. */
        el("dt", {}, ["Your debt becomes"]),
        el("dd", { class: "mono" }, [`≈ ${formatAmount(quote.estimatedDebt, MUSD_DECIMALS, 2)} MUSD`]),
        el("dt", {}, ["Collateral value"]),
        el("dd", { class: "mono" }, [`${formatAmount(quote.collateralValue, MUSD_DECIMALS, 2)} MUSD`]),
        el("dt", {}, ["Collateral ratio"]),
        el("dd", { class: "mono" }, [formatIcr(quote.icr)]),
      ]),
      el("p", { class: "muted small" }, [
        `The debt is more than you receive: ${GAS_COMPENSATION / 10n ** 18n} MUSD of it is the protocol's liquidation reserve, held against the position and returned when it closes, plus an issuance fee of up to ${Number(FEE_MARGIN_BPS) / 100}%. Mezo's contracts publish no fee getter, so this page over-states the fee rather than under-stating the collateral you need.`,
      ]),
    );

    if (price !== null) {
      quoteBox.append(
        el("p", { class: "muted small" }, [
          `At Mezo's testnet price of ${formatAmount(price, MUSD_DECIMALS, 0)} MUSD per ${mezoTestnet.nativeCurrency.symbol}, this borrow needs at least ${formatAmount(quote.minimumCollateral, 18, 8)} to be accepted and ${formatAmount(quote.suggestedCollateral, 18, 8)} to sit at the 150% this page asks for. The testnet price is not the real bitcoin price.`,
        ]),
      );
    }

    if (quote.blocker) {
      quoteBox.append(notice("warning", quote.blocker));
    }

    const primary = actionButton({
      label: `Lock ${formatAmount(collateral ?? 0n, 18, 8)} ${mezoTestnet.nativeCurrency.symbol} and borrow ${formatAmount(debt ?? 0n, MUSD_DECIMALS, 0)} MUSD`,
      pendingLabel: "Opening the position…",
      onClick: async () => {
        if (!connection || debt === null || collateral === null) return;
        state.borrowMessage = null;
        try {
          const wallet = walletClientFor(connection.provider, connection.address);
          const hash = await writeContract(wallet, {
            address: CONFIG.borrowerOperations as Address,
            abi: BORROWER_OPERATIONS_ABI,
            functionName: "openTrove",
            // Zero hints: correct at any list length, and merely costs gas.
            // See mezoBorrow.ts for why this signature and not Liquity's.
            args: [debt, ZERO_ADDRESS, ZERO_ADDRESS],
            value: collateral,
          });
          state.borrowMessage = { kind: "ok", text: "Sent. Waiting for the position to open…" };
          renderBorrowQuote();
          await sendAndWait(hash);
          await refreshChain();
          state.borrowMessage = {
            kind: "ok",
            text: "Borrowed. The MUSD is in your wallet and the next step is below.",
          };
        } catch (error) {
          const explained = describeError(error);
          state.borrowMessage = { kind: "error", text: explained.message, name: explained.name };
        } finally {
          renderAll();
        }
      },
    });
    primary.setBlocked(quote.blocker);
    actionRow.append(primary.element);

    /* The warning sits under the button rather than above the quote, because
       it has to be the last thing read before the click. It is not a
       disclaimer: an unrepaid trove on testnet costs nothing, and the habit
       of reading this sentence before signing it is the whole point. */
    messageBox.append(
      el("p", { class: "muted small" }, [
        "This opens a debt position in Mezo's borrow market, not ours. Your ",
        mezoTestnet.nativeCurrency.symbol,
        " is locked until the debt is repaid, one address can hold one position, and if the collateral ratio falls below 110% the position can be liquidated. Testnet funds only.",
      ]),
    );
    if (state.borrowMessage) {
      messageBox.append(notice(state.borrowMessage.kind, state.borrowMessage.text, state.borrowMessage.name));
    }
  }

  renderBorrowQuote();
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
    const availability = claimAvailability(token, now);
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

/**
 * What a share balance is worth, in MUSD, at the price now on chain.
 *
 * Returns undefined rather than a zero when there is no usable price: an
 * index whose oracle is stale or reverting has no value to state, and
 * printing "$0.00" for it would be a number where there is none.
 */
function sharesWorth(shares: bigint | null): string | undefined {
  if (shares === null) return undefined;
  const price = state.market?.price ?? null;
  if (price === null) return undefined;
  const musd = (shares * price) / 10n ** BigInt(SHARE_DECIMALS);
  return `≈ ${formatAmount(musd, MUSD_DECIMALS, 2)} MUSD`;
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
      /* Every figure says what it is worth, because a share count is in index
         points and nobody values those in their head. The share line is the
         one that needs it most: 1.4974 shares means nothing, $149.31 does. */
      stat(
        `${market.symbol} shares`,
        balances ? formatAmount(balances.shares, SHARE_DECIMALS, 6) : "—",
        balances ? formatUnits(balances.shares, SHARE_DECIMALS) : undefined,
        sharesWorth(balances?.shares ?? null),
      ),
      stat(
        "MUSD",
        balances ? formatAmount(balances.musd, MUSD_DECIMALS, 4) : "—",
        balances ? formatUnits(balances.musd, MUSD_DECIMALS) : undefined,
        /* MUSD is dollar-denominated, so its own figure is the dollar figure.
           Said once, as parity rather than as a fact: MUSD is a borrowed
           stablecoin and nothing on this page guarantees it trades at a
           dollar. */
        balances ? "dollar-denominated, at $1.00 parity" : undefined,
      ),
      stat(
        `${symbol} (gas)`,
        balances ? formatAmount(balances.native, mezoTestnet.nativeCurrency.decimals, 8) : "—",
        balances ? formatUnits(balances.native, mezoTestnet.nativeCurrency.decimals) : undefined,
        /* No dollar value for gas, on purpose. Mezo's testnet price feed
           reports BTC at about $20,000,000, so a converted figure here would
           read as thousands of dollars of gas and be pure fiction. Naming it
           as testnet gas is the true statement available. */
        "testnet gas, not priced",
      ),
      /* Both allowances, not just the MUSD one.
         Buying spends MUSD and redeeming spends shares, and the page showed
         only the first - so a reader looking for why a redeem failed saw a
         healthy allowance and no hint that a different token was the one
         standing at zero. */
      stat(
        "MUSD approved",
        balances ? `${formatAmount(balances.allowance, MUSD_DECIMALS, 4)} MUSD` : "—",
        undefined,
        "spent by buying",
      ),
      stat(
        "Shares approved",
        balances ? formatAmount(balances.shareAllowance, SHARE_DECIMALS, 4) : "—",
        balances ? formatUnits(balances.shareAllowance, SHARE_DECIMALS) : undefined,
        "burned by redeeming",
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

  /*
   * The borrow position, for anyone who has one.
   *
   * It lived only in the borrow panel, which hides itself behind an existing
   * position and is below this one - so the panel called "Your position"
   * showed a balance of borrowed MUSD and said nothing about the debt that
   * produced it or the BTC locked against it. That is the half of a position
   * a holder most needs to see: the MUSD is theirs to spend and the debt is
   * theirs to repay, and only one of them was on screen.
   */
  const trove = state.trove;
  if (trove && trove.status === TROVE_ACTIVE) {
    const price = state.borrowMarket?.price ?? null;
    const icr = currentIcr(trove.collateral, price, trove.debt);
    const symbol = mezoTestnet.nativeCurrency.symbol;
    sections.position.append(
      el("h3", { class: "position-subhead" }, [`Your borrow position on ${mezoTestnet.name}`]),
      el("div", { class: "stats" }, [
        stat(
          `${symbol} locked`,
          formatAmount(trove.collateral, mezoTestnet.nativeCurrency.decimals, 8),
          formatUnits(trove.collateral, mezoTestnet.nativeCurrency.decimals),
          "collateral, returned when the debt is repaid",
        ),
        stat(
          "MUSD owed",
          formatAmount(trove.debt, MUSD_DECIMALS, 2),
          formatUnits(trove.debt, MUSD_DECIMALS),
          `includes the ${GAS_COMPENSATION / 10n ** 18n} MUSD liquidation reserve`,
        ),
        stat(
          "Collateral ratio",
          formatIcr(icr),
          undefined,
          /* The threshold, not a reassurance. Whether a given ratio is
             comfortable is the holder's call, and on this testnet - where BTC
             is priced at twenty million dollars - every honest ratio is
             enormous and saying "healthy" would teach the wrong reflex. */
          "liquidatable below 110%",
        ),
      ]),
      el("p", { class: "muted small" }, [
        "This is a position in Mezo's own borrow market, not in ours. Repaying it or closing it is done in ",
        el("a", { href: "https://mezo.org", target: "_blank", rel: "noopener noreferrer" }, ["Mezo's app"]),
        "; this page deliberately has no button that adjusts or closes a position, because getting that wrong costs collateral.",
      ]),
    );
  }
}
