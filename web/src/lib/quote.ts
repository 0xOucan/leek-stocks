/**
 * The arithmetic the vault will do, repeated here so the user sees the number
 * before signing.
 *
 * These functions mirror `IssuanceVault.buy` and `IssuanceVault.redeem`
 * exactly, including the rounding direction: the contract divides down on the
 * fee (audit finding L-6) and divides down on the output, so a quote computed
 * with rounding-half-up would be optimistic by a wei and could display a
 * minimum the transaction then misses. Integer maths only, no floats.
 */

const BPS = 10_000n;
const SHARE_ONE = 10n ** 18n;

export interface BuyQuote {
  /** Fee in MUSD base units, taken from the input. */
  readonly fee: bigint;
  /** MUSD actually converted into shares. */
  readonly net: bigint;
  /** Shares the vault would mint, at this price. */
  readonly sharesOut: bigint;
}

/**
 * @param price MUSD base units per whole share, as `IssuanceVault.price()`
 *        returns it: already scaled from the feed's decimals to MUSD's.
 */
export function quoteBuy(musdAmount: bigint, price: bigint, feeBps: number): BuyQuote {
  if (musdAmount <= 0n || price <= 0n) return { fee: 0n, net: 0n, sharesOut: 0n };
  const fee = (musdAmount * BigInt(feeBps)) / BPS;
  const net = musdAmount - fee;
  return { fee, net, sharesOut: (net * SHARE_ONE) / price };
}

export interface RedeemQuote {
  /** MUSD the vault must have on hand; the figure `InsufficientReserves` compares. */
  readonly gross: bigint;
  readonly fee: bigint;
  readonly musdOut: bigint;
}

export function quoteRedeem(shares: bigint, price: bigint, feeBps: number): RedeemQuote {
  if (shares <= 0n || price <= 0n) return { gross: 0n, fee: 0n, musdOut: 0n };
  const gross = (shares * price) / SHARE_ONE;
  // From the undivided product, as the contract does. Taking the fee from
  // `gross` instead truncates twice and the quote would drift from the
  // transaction by a wei or two - small, but it is the difference between a
  // slippage minimum that holds and one that reverts.
  const fee = (shares * price * BigInt(feeBps)) / (SHARE_ONE * BPS);
  return { gross, fee, musdOut: gross - fee };
}

/**
 * The `minShares`/`minMusd` argument: the quote less the user's tolerance.
 *
 * Rounds down, so the minimum sent on chain is never above what the quote
 * promised. The vault compares with `<`, so an exact equal passes.
 */
export function applySlippage(quoted: bigint, toleranceBps: number): bigint {
  if (quoted <= 0n) return 0n;
  const bps = BigInt(Math.max(0, Math.min(10_000, Math.round(toleranceBps))));
  return (quoted * (BPS - bps)) / BPS;
}

/**
 * Whether redemption is at risk, which is audit finding H-1 made visible.
 *
 * A share is priced from an index the vault does not hold, so liabilities can
 * exceed reserves and `redeem` then reverts with `InsufficientReserves`
 * rather than paying partially. The page must say so before anyone buys, so
 * this is a computed state and not a caught error.
 */
export interface SolvencyView {
  readonly short: boolean;
  /** How much MUSD is missing, zero when reserves cover liabilities. */
  readonly shortfall: bigint;
  /** Reserves as a fraction of liabilities, in basis points; null if no shares exist. */
  readonly coverageBps: number | null;
}

export function solvency(reserves: bigint, liabilities: bigint): SolvencyView {
  if (liabilities === 0n) return { short: false, shortfall: 0n, coverageBps: null };
  const short = liabilities > reserves;
  return {
    short,
    shortfall: short ? liabilities - reserves : 0n,
    coverageBps: Number((reserves * BPS) / liabilities),
  };
}

/* ------------------------------------------------------- fees and revenue */

export interface FeeView {
  /** Reserves minus liabilities, zero when short. The over-collateralisation. */
  readonly surplus: bigint;
  /** The slice of each fee that stays in the vault, in basis points. */
  readonly toReservesBps: number;
  /** The slice that becomes protocol revenue, in basis points. */
  readonly toTreasuryBps: number;
}

/**
 * Where a fee goes, and what the vault holds beyond what it owes.
 *
 * This exists to be shown, and it exists because the page had no honest way
 * to answer "what do I earn by holding a share". The answer is nothing:
 * `redeem` pays `shares * price - fee`, so the reserve surplus below is a
 * solvency buffer and not a claim a holder can withdraw. Doubling reserves
 * does not change what one share returns. That makes a share price exposure,
 * and it makes an APY on shares a number with no mechanism behind it.
 *
 * `feeBps` and `reserveShareBps` are read from the vault every poll rather
 * than assumed, because both are settable within bounds and a page that
 * hardcodes 0.5% and a half becomes wrong the moment a governance call lands.
 */
export function feeView(feeBps: number, reserveShareBps: number, reserves: bigint, liabilities: bigint | null): FeeView {
  // Multiply before dividing, as everywhere else: at 50 bps and 5000 bps the
  // naive (feeBps / 2) happens to be right, and at an odd split it is not.
  const toReservesBps = (feeBps * reserveShareBps) / Number(BPS);
  return {
    surplus: liabilities !== null && reserves > liabilities ? reserves - liabilities : 0n,
    toReservesBps,
    toTreasuryBps: feeBps - toReservesBps,
  };
}
