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

/* -------------------------------------------------------- managing a trove */

/**
 * What an existing position allows, which is less obvious than it looks.
 *
 * Three limits, each discovered by simulating the live contract rather than
 * read from documentation:
 *
 * 1. **Repaying has a floor.** The trove's *net* debt - the debt less the
 *    200 MUSD gas reserve - must stay at or above `minNetDebt`. Repaying
 *    past that reverts with "BorrowerOps: Trove's net debt must be greater
 *    than minimum". So a trove opened at the 1800 minimum can only repay
 *    whatever interest and fee sit on top of it, which is single-digit MUSD.
 *    The only way out of a position is to close it.
 *
 * 2. **Closing costs the net debt, not the debt.** `closeTrove` needs the
 *    whole net debt in the wallet and cancels the gas reserve against the
 *    rest. A wallet that borrowed 1800 and spent it cannot close: it needs
 *    1800 plus accrued interest, and it has less than 1800. That is not a
 *    bug, and the number it is short by is the thing to put on screen -
 *    otherwise the revert reads as the button being broken.
 *
 * 3. **Borrowing more is bounded by the ratio, not by the minimum.** The
 *    chain's own limit is MCR; this page's is SAFE_ICR, so the figure here
 *    is deliberately smaller than what the contract would accept.
 *
 * No allowance is involved anywhere: BorrowerOperations burns MUSD directly,
 * confirmed by simulating a repayment with an allowance of zero.
 */
export interface PositionPlan {
  /** Debt less the gas reserve: the figure every limit is actually about. */
  readonly netDebt: bigint;
  /** The most that may be repaid without going under `minNetDebt`. */
  readonly repayCeiling: bigint;
  /** The most that may be repaid now, also accounting for the wallet. */
  readonly maxRepay: bigint;
  /** MUSD needed in the wallet to close the position outright. */
  readonly closeCost: bigint;
  /** Zero when the position can be closed, otherwise how much is missing. */
  readonly shortToClose: bigint;
  readonly canClose: boolean;
  /** The most that may be borrowed against this collateral, at SAFE_ICR. */
  readonly maxBorrowMore: bigint;
}

export interface PositionPlanInput {
  readonly debt: bigint;
  readonly collateral: bigint;
  readonly price: bigint | null;
  readonly minNetDebt: bigint;
  readonly musdBalance: bigint;
}

function min(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
}

function atLeastZero(value: bigint): bigint {
  return value > 0n ? value : 0n;
}

export function positionPlan(input: PositionPlanInput): PositionPlan {
  const { debt, collateral, price, minNetDebt, musdBalance } = input;

  const netDebt = atLeastZero(debt - GAS_COMPENSATION);
  const repayCeiling = atLeastZero(netDebt - minNetDebt);
  const maxRepay = min(repayCeiling, musdBalance);
  const closeCost = netDebt;
  const shortToClose = atLeastZero(closeCost - musdBalance);

  /*
   * Headroom at SAFE_ICR, with the issuance fee taken off the top.
   *
   * Borrowing `x` more adds `x` plus a fee on `x` to the debt, so solving for
   * the debt limit and then subtracting the current debt would over-state the
   * answer by the fee and hand the user a figure the chain refuses. The
   * division by (10000 + fee) is that correction.
   */
  let maxBorrowMore = 0n;
  if (price !== null && price > 0n) {
    const value = (collateral * price) / ONE;
    const debtLimit = (value * ONE) / SAFE_ICR;
    const headroom = atLeastZero(debtLimit - debt);
    maxBorrowMore = (headroom * 10_000n) / (10_000n + FEE_MARGIN_BPS);
  }

  return {
    netDebt,
    repayCeiling,
    maxRepay,
    closeCost,
    shortToClose,
    canClose: shortToClose === 0n && closeCost > 0n,
    maxBorrowMore,
  };
}

/** The one reason a repayment of `amount` cannot be sent, or null. */
export function repayBlocker(amount: bigint | null, plan: PositionPlan, musdBalance: bigint): string | null {
  if (amount === null || amount <= 0n) return "Enter how much MUSD to repay.";
  if (amount > musdBalance) return "That is more MUSD than this wallet holds.";
  if (plan.repayCeiling === 0n) {
    return "This position is already at the protocol's minimum debt, so it cannot be repaid in part. Closing it is the only way to reduce it, and that needs the whole balance of the debt.";
  }
  if (amount > plan.repayCeiling) {
    return "Repaying that much would take the position under the protocol's minimum debt, which reverts. Repay less, or close the position outright.";
  }
  return null;
}

/** The one reason more MUSD cannot be borrowed against this position, or null. */
export function borrowMoreBlocker(amount: bigint | null, plan: PositionPlan): string | null {
  if (amount === null || amount <= 0n) return "Enter how much more MUSD to borrow.";
  if (plan.maxBorrowMore === 0n) {
    return "This position has no room to borrow more at a safe collateral ratio. Add collateral in Mezo's app first.";
  }
  if (amount > plan.maxBorrowMore) {
    return "That would take the collateral ratio below the 150% this page requires. Borrow less, or add collateral.";
  }
  return null;
}
