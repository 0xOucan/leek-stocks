/**
 * Turning a revert into a sentence someone can act on.
 *
 * A wallet hands back either a four-byte selector or a nested error object,
 * and neither is something to put on a screen: "0x7c4d8b1a" tells a user
 * nothing, and "execution reverted" tells them nothing they can do. Every
 * custom error these contracts declare is listed here with the action it
 * implies, and the decoder reads the error's arguments so the message can
 * quote the actual numbers - `InsufficientReserves` carries both sides of the
 * shortfall and saying them is the whole point of the contract reverting
 * instead of paying partially.
 *
 * Pure, and deliberately not importing anything from the browser: the tests
 * run it under `node --test`.
 */

import { decodeErrorResult, formatUnits, type Hex } from "viem";

/** Every custom error reachable from a transaction this page sends. */
export const ERROR_ABI = [
  // IssuanceVault
  { type: "error", name: "ZeroAddress", inputs: [] },
  { type: "error", name: "ZeroAmount", inputs: [] },
  { type: "error", name: "VaultPaused", inputs: [] },
  { type: "error", name: "FeeTooHigh", inputs: [{ name: "feeBps", type: "uint16" }] },
  { type: "error", name: "ShareAlreadySet", inputs: [] },
  {
    type: "error",
    name: "CapExceeded",
    inputs: [
      { name: "supplyAfter", type: "uint256" },
      { name: "cap", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "Slippage",
    inputs: [
      { name: "got", type: "uint256" },
      { name: "wanted", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "InsufficientReserves",
    inputs: [
      { name: "owed", type: "uint256" },
      { name: "available", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "StalePrice",
    inputs: [
      { name: "updatedAt", type: "uint256" },
      { name: "maxStaleness", type: "uint32" },
    ],
  },
  { type: "error", name: "BadPrice", inputs: [{ name: "answer", type: "int256" }] },
  {
    type: "error",
    name: "IncompleteRound",
    inputs: [
      { name: "roundId", type: "uint80" },
      { name: "answeredInRound", type: "uint80" },
      { name: "startedAt", type: "uint256" },
    ],
  },
  // IndexOracle, reachable through the vault's price() call
  { type: "error", name: "NoData", inputs: [] },
  { type: "error", name: "FeedPaused", inputs: [] },
  // ERC-20 (OpenZeppelin v5), reachable on approve and on the vault's pulls
  {
    type: "error",
    name: "ERC20InsufficientBalance",
    inputs: [
      { name: "sender", type: "address" },
      { name: "balance", type: "uint256" },
      { name: "needed", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "ERC20InsufficientAllowance",
    inputs: [
      { name: "spender", type: "address" },
      { name: "allowance", type: "uint256" },
      { name: "needed", type: "uint256" },
    ],
  },
] as const;

export interface Explained {
  /** One sentence, in the imperative where there is something to do. */
  readonly message: string;
  /** The decoded error's name, for a `data-` attribute and for tests. */
  readonly name: string;
}

const MUSD_DECIMALS = 18;

function musd(value: bigint): string {
  return `${formatUnits(value, MUSD_DECIMALS)} MUSD`;
}

function shares(value: bigint): string {
  return formatUnits(value, 18);
}

/**
 * Decode revert data into a sentence.
 *
 * Exported separately from `describeError` so the mapping can be tested
 * against real encoded data without constructing a viem error object.
 */
export function explainRevertData(data: Hex): Explained | null {
  let decoded: { errorName: string; args: readonly unknown[] | undefined };
  try {
    decoded = decodeErrorResult({ abi: ERROR_ABI, data });
  } catch {
    // An error this page does not know. Named rather than swallowed: a
    // selector with no match means the contracts changed under the front end,
    // and silence would hide that.
    return null;
  }
  const args = decoded.args ?? [];
  /* uint32 and uint16 decode to `number` while uint256 decodes to `bigint`,
     so a bigint-only accessor silently printed "0s" for StalePrice's window.
     Normalised here rather than per case. */
  const at = (i: number): bigint => {
    const value = args[i];
    if (typeof value === "bigint") return value;
    if (typeof value === "number") return BigInt(value);
    return 0n;
  };

  switch (decoded.errorName) {
    case "Slippage":
      return {
        name: "Slippage",
        message: `The price moved while you were signing: this would have given ${shares(at(0))} against a minimum of ${shares(at(1))}. Raise the slippage tolerance or try again.`,
      };
    case "InsufficientReserves":
      return {
        name: "InsufficientReserves",
        message: `The vault owes ${musd(at(0))} for these shares and holds ${musd(at(1))}. Redemption reverts rather than paying part of it. Someone must fund the backstop, or redeem a smaller amount.`,
      };
    case "StalePrice":
      return {
        name: "StalePrice",
        message: `The oracle's last answer is older than the vault accepts (${at(1)}s), so it refuses to price the trade. Wait for the feed to publish a new round.`,
      };
    case "CapExceeded":
      return {
        name: "CapExceeded",
        message: `This would take supply to ${shares(at(0))} shares against a cap of ${shares(at(1))}. Buy a smaller amount.`,
      };
    case "VaultPaused":
      return {
        name: "VaultPaused",
        message: "The vault's guardian has paused buying and redeeming. Funding the backstop still works; nothing else does until it is unpaused.",
      };
    case "BadPrice":
      return {
        name: "BadPrice",
        message: "The oracle reported a non-positive price, which the vault refuses to trade on. Nothing can be bought or redeemed until a valid round is published.",
      };
    case "IncompleteRound":
      return {
        name: "IncompleteRound",
        message: "The oracle's latest round is incomplete, so the vault will not use it. Wait for the feed's next publication.",
      };
    case "NoData":
      return {
        name: "NoData",
        message: "The oracle has not published a round yet, so there is no price to trade at.",
      };
    case "FeedPaused":
      return {
        name: "FeedPaused",
        message: "The price feed is paused by its guardian, so no new price is being published.",
      };
    case "ZeroAmount":
      return {
        name: "ZeroAmount",
        message: "The amount rounds to zero at this price. Enter a larger amount.",
      };
    case "FeeTooHigh":
      return { name: "FeeTooHigh", message: `A fee of ${at(0)} basis points is above the vault's 5% ceiling.` };
    case "ZeroAddress":
      return { name: "ZeroAddress", message: "A zero address was passed where a real one is required." };
    case "ShareAlreadySet":
      return { name: "ShareAlreadySet", message: "This vault's share token is already set and cannot be changed." };
    case "ERC20InsufficientBalance":
      return {
        name: "ERC20InsufficientBalance",
        message: `You hold ${musd(at(1))} and this needs ${musd(at(2))}.`,
      };
    case "ERC20InsufficientAllowance":
      return {
        name: "ERC20InsufficientAllowance",
        message: `The vault is approved for ${musd(at(1))} and needs ${musd(at(2))}. Approve again.`,
      };
    default:
      return {
        name: decoded.errorName,
        message: `The contract reverted with ${decoded.errorName}.`,
      };
  }
}

/** Wallet-level failures, which never reach revert data. */
export function explainWalletCode(code: number): Explained | null {
  switch (code) {
    case 4001:
      return { name: "UserRejected", message: "You rejected the request in your wallet. Nothing was sent." };
    case 4100:
      return { name: "Unauthorized", message: "Your wallet has not authorised this account. Unlock it and connect again." };
    case 4200:
      return { name: "Unsupported", message: "Your wallet does not support this request." };
    case 4900:
      return { name: "Disconnected", message: "Your wallet is disconnected. Connect it and try again." };
    case 4901:
      return { name: "ChainDisconnected", message: "Your wallet is not connected to Mezo Testnet. Switch network and try again." };
    case -32000:
      return { name: "Underpriced", message: "The node rejected the transaction, usually for too little gas or too low a fee. Check your BTC balance for gas." };
    default:
      return null;
  }
}

/** The shapes a nested provider error can hide revert data in. */
function findRevertData(error: unknown, depth = 0): Hex | null {
  if (depth > 8 || error === null || typeof error !== "object") return null;
  const record = error as Record<string, unknown>;
  for (const key of ["data", "raw", "value"]) {
    const candidate = record[key];
    if (typeof candidate === "string" && /^0x[0-9a-fA-F]{8,}$/.test(candidate)) return candidate as Hex;
    if (typeof candidate === "object" && candidate !== null) {
      const nested = findRevertData(candidate, depth + 1);
      if (nested) return nested;
    }
  }
  // viem nests the originating error under `cause`, and a provider nests its
  // own under `error`; both chains have to be followed because which one
  // carries the data depends on whether the failure came from a simulation or
  // from the wallet.
  for (const key of ["cause", "error", "info"]) {
    const nested = record[key];
    if (nested) {
      const found = findRevertData(nested, depth + 1);
      if (found) return found;
    }
  }
  return null;
}

function findCode(error: unknown, depth = 0): number | null {
  if (depth > 8 || error === null || typeof error !== "object") return null;
  const record = error as Record<string, unknown>;
  if (typeof record["code"] === "number") return record["code"] as number;
  for (const key of ["cause", "error", "info"]) {
    const nested = record[key];
    if (nested) {
      const found = findCode(nested, depth + 1);
      if (found !== null) return found;
    }
  }
  return null;
}

/**
 * The one function the UI calls. Always returns something printable, and
 * never a bare selector: an unrecognised revert says so in words and keeps
 * the selector in `name` for a bug report.
 */
export function describeError(error: unknown): Explained {
  const data = findRevertData(error);
  if (data) {
    const explained = explainRevertData(data);
    if (explained) return explained;
    return {
      name: data.slice(0, 10),
      message: `The contract reverted with an error this page does not recognise (${data.slice(0, 10)}). That usually means the deployed contracts are newer than this page.`,
    };
  }

  const code = findCode(error);
  if (code !== null) {
    const explained = explainWalletCode(code);
    if (explained) return explained;
  }

  const text = error instanceof Error ? error.message : String(error);
  if (/insufficient funds/i.test(text)) {
    return {
      name: "InsufficientGas",
      message: "Not enough BTC to pay for gas on Mezo Testnet. Mezo's gas token is BTC, not ether.",
    };
  }
  if (/user (rejected|denied)/i.test(text)) {
    return { name: "UserRejected", message: "You rejected the request in your wallet. Nothing was sent." };
  }
  // The first line only. A viem error body carries the request, the ABI and a
  // version banner, which is for a console and not for a person.
  const firstLine = text.split("\n").find((line) => line.trim().length > 0) ?? "The request failed.";
  return { name: "Unknown", message: firstLine.trim() };
}
