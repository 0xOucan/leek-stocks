/**
 * Formatting that never shows a raw base unit and never shows a raw hex
 * address. Pure: no DOM, no network, so `node --test` can cover it.
 */

import { formatUnits, parseUnits } from "viem";

/** `0x1189...c503`. Enough of both ends to compare against a block explorer. */
export function truncateAddress(address: string): string {
  if (!/^0x[0-9a-fA-F]{40}$/.test(address)) return address;
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

/**
 * A token amount with a bounded number of fraction digits.
 *
 * `formatUnits` is exact, which for an 18-decimal token means up to eighteen
 * digits after the point. That is correct and unreadable, so display rounds
 * and the full value goes in a `title` attribute at the call site.
 */
export function formatAmount(value: bigint, decimals: number, maxFractionDigits = 4): string {
  const exact = formatUnits(value, decimals);
  const [whole = "0", fraction = ""] = exact.split(".");
  const grouped = BigInt(whole).toLocaleString("en-US");
  if (maxFractionDigits === 0 || fraction.length === 0) return grouped;
  const trimmed = fraction.slice(0, maxFractionDigits).replace(/0+$/, "");
  return trimmed.length === 0 ? grouped : `${grouped}.${trimmed}`;
}

/**
 * Parse user input into base units, or report why it cannot be.
 *
 * Returns a discriminated result rather than throwing: a typo in an amount
 * field is the most common thing that happens on this page, and it belongs
 * inline next to the field, not in a rejected promise.
 */
export type ParseResult = { ok: true; value: bigint } | { ok: false; reason: string };

export function parseAmount(input: string, decimals: number): ParseResult {
  const text = input.trim();
  if (text.length === 0) return { ok: false, reason: "Enter an amount." };
  if (!/^\d*\.?\d*$/.test(text) || text === ".") return { ok: false, reason: "Numbers only." };
  const fraction = text.split(".")[1] ?? "";
  if (fraction.length > decimals) {
    return { ok: false, reason: `At most ${decimals} decimal places.` };
  }
  const value = parseUnits(text, decimals);
  if (value === 0n) return { ok: false, reason: "Amount must be more than zero." };
  return { ok: true, value };
}

/** "4 min ago". Seconds-resolution input, because that is what the chain has. */
export function formatAge(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "unknown";
  if (seconds < 60) return `${Math.floor(seconds)}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)} h ago`;
  return `${Math.floor(seconds / 86_400)} d ago`;
}

/**
 * An index value as the feed reports it: a number of whole units, two places.
 * The feed's `value` is a JS number by the time it reaches us (it is JSON), so
 * this is deliberately not a bigint path.
 */
export function formatIndexValue(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return "—";
  return value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
