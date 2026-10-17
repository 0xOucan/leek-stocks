/**
 * The arithmetic of opening a trove on Mezo's native borrow market.
 *
 * Kept import-free on purpose, like lib/quote.ts: the numbers a user commits
 * real collateral against are the numbers that most deserve a test, and a
 * module that reads `import.meta.env` cannot be tested under node.
 *
 * ---------------------------------------------------------------------------
 * What the protocol actually charges, established by reading the live
 * contracts rather than from documentation, because BorrowerOperations'
 * implementation is not verified and publishes no ABI:
 *
 *   minNetDebt            1800e18     the smallest borrow it will accept
 *   MUSD_GAS_COMPENSATION  200e18     added to the DEBT, held by the protocol
 *                                     as the liquidation gas reserve and
 *                                     returned when the trove is closed
 *   MCR                   1.1e18      110%: below this the trove is liquidatable
 *   price                 2e25        MUSD per BTC, 18 decimals. On testnet
 *                                     that is $20,000,000 a BTC.
 *
 * The issuance fee is NOT readable: every getter name Liquity v1 would expose
 * (getBorrowingFee, getBorrowingRate, borrowingFeeFloor) reverts or does not
 * exist on this deployment. Opening a 1800 MUSD trove produced a debt of
 * 2009.0138 MUSD, i.e. 1800 + 200 + 9.01, which is 0.5% of the borrow. So the
 * fee is treated as an estimate with a name that says so, and FEE_MARGIN_BPS
 * is deliberately larger than the figure observed: a quote that understates
 * the debt understates the collateral needed, and the cost of being wrong in
 * that direction is a liquidation.
 * ---------------------------------------------------------------------------
 */

/** Scaled by 1e18, as every ratio in this protocol is. */
const ONE = 10n ** 18n;

/** The protocol's liquidation gas reserve, added to the debt, not to the payout. */
export const GAS_COMPENSATION = 200n * ONE;

/** An upper bound on the issuance fee. See the note above: 0.5% was observed. */
export const FEE_MARGIN_BPS = 100n;

/**
 * The ratio this page will not let you open below.
 *
 * Not the protocol's 110%: a trove opened at exactly MCR is liquidatable by
 * the next tick of the price feed. 150% is the protocol's own recovery-mode
 * threshold (CCR) and is the lowest number that is not simply a trap.
 */
export const SAFE_ICR = (15n * ONE) / 10n;

export interface TroveQuoteInput {
  /** MUSD the user asked for, in base units. This is what reaches their wallet. */
  readonly debtRequested: bigint;
  /** BTC they are putting up, in wei. */
  readonly collateral: bigint;
  /** MUSD per BTC, 18 decimals, from the protocol's price feed. */
  readonly price: bigint;
  /** `minNetDebt()`, read from the chain rather than assumed. */
  readonly minNetDebt: bigint;
  /** `MCR()`, likewise. */
  readonly mcr: bigint;
  /** The user's spendable BTC, so the quote can say "you do not have this". */
  readonly balance: bigint;
}

export interface TroveQuote {
  /** Requested + gas reserve + the fee allowance. What the trove will owe. */
  readonly estimatedDebt: bigint;
  /** Collateral value in MUSD at the given price. */
  readonly collateralValue: bigint;
  /** Collateral value over debt, scaled 1e18. `null` when there is no debt. */
  readonly icr: bigint | null;
  /** Collateral that would put this borrow exactly at SAFE_ICR. */
  readonly suggestedCollateral: bigint;
  /** The least collateral the protocol itself would accept, at MCR. */
  readonly minimumCollateral: bigint;
  /** The one reason this cannot be sent, or null. First match wins. */
  readonly blocker: string | null;
}

function musdValueOf(collateral: bigint, price: bigint): bigint {
  return (collateral * price) / ONE;
}

/** Collateral whose value is `ratio` times `debt`, rounded up. */
function collateralFor(debt: bigint, ratio: bigint, price: bigint): bigint {
  if (price <= 0n) return 0n;
  const numerator = debt * ratio;
  // Rounded up, twice. Rounding a collateral requirement down produces a
  // number that is one wei short of the thing it claims to satisfy.
  const value = (numerator + ONE - 1n) / ONE;
  return (value * ONE + price - 1n) / price;
}

export function troveQuote(input: TroveQuoteInput): TroveQuote {
  const { debtRequested, collateral, price, minNetDebt, mcr, balance } = input;

  const fee = (debtRequested * FEE_MARGIN_BPS) / 10_000n;
  const estimatedDebt = debtRequested + GAS_COMPENSATION + fee;
  const collateralValue = musdValueOf(collateral, price);
  const icr = estimatedDebt > 0n ? (collateralValue * ONE) / estimatedDebt : null;

  const suggestedCollateral = collateralFor(estimatedDebt, SAFE_ICR, price);
  const minimumCollateral = collateralFor(estimatedDebt, mcr, price);

  /*
   * Ordered so that the message names the thing the user should change first.
   * A borrow below the minimum with no collateral at all should say "the
   * minimum is 1800", not "you have no BTC": the amount is the field they
   * typed, and the balance is a fact about their wallet.
   */
  let blocker: string | null = null;
  if (price <= 0n) {
    blocker = "Mezo's price feed is not returning a BTC price, so the collateral this needs cannot be calculated.";
  } else if (debtRequested <= 0n) {
    blocker = "Enter how much MUSD to borrow.";
  } else if (debtRequested < minNetDebt) {
    blocker = `Mezo's borrow market has a minimum of ${minNetDebt / ONE} MUSD per position, so a smaller borrow reverts.`;
  } else if (collateral <= 0n) {
    blocker = "Enter how much BTC to lock as collateral.";
  } else if (collateral > balance) {
    blocker = "That is more BTC than this wallet holds. Claim test BTC from Mezo's faucet first.";
  } else if (collateral === balance) {
    blocker = "Leave some BTC behind for gas: locking the entire balance leaves nothing to pay for the transaction.";
  } else if (icr !== null && icr < mcr) {
    blocker = "That collateral is below the protocol's 110% minimum, so the position could not be opened.";
  } else if (icr !== null && icr < SAFE_ICR) {
    blocker = "That collateral is above the 110% minimum but below 150%, which is close enough to liquidation that this page will not open it. Add more BTC.";
  }

  return { estimatedDebt, collateralValue, icr, suggestedCollateral, minimumCollateral, blocker };
}

/** `icr` as a percentage string, or an em dash. Capped, because 99551% is noise. */
export function formatIcr(icr: bigint | null): string {
  if (icr === null) return "—";
  const percent = (icr * 100n) / ONE;
  if (percent > 100_000n) return "> 100,000%";
  return `${percent.toLocaleString("en-US")}%`;
}

/**
 * A collateral figure to put in the form: comfortable if the wallet allows
 * it, and never one the wallet cannot cover.
 *
 * Both callers - the first prefill and the Suggest button - need the same
 * answer, and the answer has to be consistent with the threshold the stepper
 * uses to decide whether this step is reachable at all. Get that wrong and
 * there is a dead end: a wallet just over the line gets offered a figure
 * below the minimum ratio, and asking for a better one is refused for
 * insufficient balance. So:
 *
 *   - aim at twice `suggested`, because `suggested` is a boundary and a user
 *     who accepts a boundary is one price tick from being refused;
 *   - never exceed the balance less a gas allowance, because collateral is
 *     paid in the same asset as the fee;
 *   - return 0 rather than something unsendable when even `suggested` does
 *     not fit, which is the honest answer and the one the stepper agrees
 *     with.
 */
export function startingCollateral(suggested: bigint, balance: bigint, gasAllowance: bigint): bigint {
  const spendable = balance - gasAllowance;
  if (suggested <= 0n || spendable < suggested) return 0n;
  const comfortable = suggested * 2n;
  return comfortable > spendable ? spendable : comfortable;
}

/**
 * The collateral ratio of an existing position.
 *
 * Separated from `troveQuote` because it answers a different question: the
 * quote is about a position that does not exist yet, and this is about one
 * that does, read straight from TroveManager. Both panels that show a live
 * trove use it, so there is one formula rather than two that can drift.
 *
 * Null, never zero, when there is no debt or no price: a position with no
 * debt has no ratio, and printing "0%" for it would name the one number that
 * means "liquidate me immediately".
 */
export function currentIcr(collateral: bigint, price: bigint | null, debt: bigint): bigint | null {
  if (price === null || price <= 0n || debt <= 0n) return null;
  return (musdValueOf(collateral, price) * ONE) / debt;
}
