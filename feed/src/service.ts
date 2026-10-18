/**
 * The publisher loop and the read-only status endpoint.
 *
 * One process, two jobs: push rounds to each index's `IndexOracle` on chain,
 * and serve the same numbers over HTTP so both front ends can render a price
 * without an archive node. The HTTP side is strictly read-only and holds no
 * authority; the chain side holds a hot key and nothing else.
 *
 * **The key.** Publishing needs a key that can sign, so this process is a hot
 * wallet by definition. What limits the damage is which key it is: the
 * publisher holds `PUBLISHER_ROLE` and nothing more. It cannot pause the feed
 * (that is the guardian, a separate holder), it cannot move fees (the
 * treasurer), and it cannot change a bound (the bound is immutable). A
 * compromised publisher can walk the price inside the per-round bound, which
 * is a real loss and is written up as finding M-1; it cannot drain anything
 * directly. Keep only gas on it.
 *
 * The key is read from `PUBLISHER_PRIVATE_KEY` in the environment, which in
 * production comes from a systemd `EnvironmentFile` with mode 0600 - never
 * from a command line, where it would be visible in `ps` and in shell
 * history, and never from a file in this repository.
 */

import { createServer } from "node:http";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeFunctionData,
  http,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { INDICES } from "./indices.ts";
import {
  assertDefinition,
  decidePublish,
  indexValue,
  syntheticValue,
  toFeedUnits,
  type IndexDefinition,
} from "./index-math.ts";
import { fetchPrices, type SourceResult } from "./source.ts";

/**
 * How long the contract will think has passed, by the time our transaction
 * is in a block.
 *
 * Neither clock alone is right, and both failures were seen within an hour of
 * each other.
 *
 * `Date.now()` alone compares two unrelated clocks: the contract compares
 * `block.timestamp` to `block.timestamp`, so all the skew between the host
 * and the chain lands in our number, and it can go **negative** — a chain
 * running ahead of the host made `secondsSinceLast < minRoundInterval` true
 * forever and the feed stopped publishing while reporting a healthy hold.
 *
 * The latest block's timestamp alone is worse on an idle chain. Anvil mines
 * only when there is a transaction, so with nothing happening the chain clock
 * is **frozen**: the feed held at "1s since the last round" indefinitely and
 * the local rehearsal never produced a second round. That is a dev-chain
 * property rather than a Mezo one, but a rehearsal that cannot publish is a
 * rehearsal that proves nothing.
 *
 * So: the larger of the two. The quantity actually wanted is the timestamp of
 * the block that will *include* this publish, which is in the future relative
 * to the latest block, and the maximum is the better predictor of it in both
 * cases. The asymmetry also favours it — being too small means the feed holds
 * and stops, being too large means at worst one publish reverts with
 * `TooSoon` and the next tick corrects.
 */
export function elapsedSince(thenSeconds: number, latestBlockTimestamp: bigint): number {
  const byChain = Number(latestBlockTimestamp) - thenSeconds;
  const byWallClock = Math.floor(Date.now() / 1000) - thenSeconds;
  return Math.max(0, byChain, byWallClock);
}

const ORACLE_ABI = [
  {
    type: "function",
    name: "publish",
    stateMutability: "nonpayable",
    inputs: [{ name: "answer", type: "int256" }],
    outputs: [{ name: "roundId", type: "uint80" }],
  },
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
  {
    type: "function",
    name: "maxDeviationBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint16" }],
  },
  {
    type: "function",
    name: "minRoundInterval",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint32" }],
  },
  {
    type: "function",
    name: "MIN_ANSWER",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "int256" }],
  },
  {
    type: "function",
    name: "deviationWindow",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint32" }],
  },
  {
    type: "function",
    name: "maxWindowDeviationBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint16" }],
  },
  { type: "function", name: "anchorAnswer", stateMutability: "view", inputs: [], outputs: [{ type: "int256" }] },
  { type: "function", name: "anchorAt", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;

/**
 * The chain to publish to, resolved from configuration.
 *
 * It used to be Mezo testnet, hardcoded, while the RPC URL came from the
 * environment — so reads followed the URL and writes were signed for 31611
 * whatever node answered. An end-to-end rehearsal against a local chain
 * failed with `invalid chain id for signer` on every publish, which is also
 * why the bug survived this long: the publisher could only ever be exercised
 * against the one network it was going to run on.
 */
export function chainFor(chainId: number, rpcUrl: string) {
  if (chainId === mezoTestnet.id) return mezoTestnet;
  if (chainId === 31_612) {
    return defineChain({
      id: 31_612,
      name: "Mezo",
      nativeCurrency: { name: "Bitcoin", symbol: "BTC", decimals: 18 },
      rpcUrls: { default: { http: [rpcUrl] } },
      blockExplorers: { default: { name: "Mezo Explorer", url: "https://explorer.mezo.org" } },
    });
  }
  /* Anything else is a rehearsal target: a local chain or a fork. Named for
     the log rather than pretended to be Mezo, and gas is left as the chain's
     own 18-decimal unit because nothing here spends it beyond fees. */
  return defineChain({
    id: chainId,
    name: `chain ${chainId}`,
    nativeCurrency: { name: "Gas", symbol: "GAS", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
    testnet: true,
  });
}

/** Mezo testnet. BTC is the gas token, with 18 decimals. */
export const mezoTestnet = defineChain({
  id: 31_611,
  name: "Mezo Testnet",
  nativeCurrency: { name: "Test Bitcoin", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.test.mezo.org"] } },
  blockExplorers: { default: { name: "Mezo Explorer", url: "https://explorer.test.mezo.org" } },
  testnet: true,
});

export interface IndexStatus {
  symbol: string;
  description: string;
  /** The last value this service computed, in whole units. */
  value: number | null;
  /** What was last published on chain, in feed units, as a decimal string. */
  onChainAnswer: string | null;
  onChainRound: string | null;
  onChainUpdatedAt: number | null;
  /** "source" or "synthetic": a synthetic price is never presented as real. */
  origin: SourceResult["origin"] | null;
  lastAttemptAt: number | null;
  lastError: string | null;
  lastDecision: string | null;
}

export interface Config {
  readonly oracles: Readonly<Record<string, Address>>;
  readonly rpcUrl: string;
  readonly publisherKey: `0x${string}`;
  readonly intervalSeconds: number;
  readonly heartbeatSeconds: number;
  readonly thresholdBps: number;
  /** How long to wait for a receipt before moving on. See tick(). */
  readonly receiptTimeoutMs: number;
  readonly httpPort: number;
  /** Which chain to publish to. Defaults to Mezo testnet. */
  readonly chainId: number;
  /** Use the deterministic series instead of the source. For a filmed demo. */
  readonly synthetic: boolean;
}

/**
 * The EIP-7623 calldata floor, in gas, for a transaction carrying `data`.
 *
 * Mezo enforces this floor and its `eth_estimateGas` does not account for it,
 * so the node rejects a transaction built from the node's own estimate:
 *
 *   failed to verify the fees: gas limit below EIP-7623 floor:
 *     21240 (gas limit) < 21600 (floor data gas): out of gas
 *
 * The floor is 21000 plus 10 gas per calldata token, where a zero byte is one
 * token and a non-zero byte is four. That makes the floor depend on how many
 * zero bytes the ABI-encoded price happens to contain - so the failure is
 * intermittent, decided by the digits of the number being published. One
 * oracle published at 115.20 while the other was rejected at 128.00 in the
 * same cycle, which is how this was found; a price that fails today succeeds
 * at a different value tomorrow. Worth stating plainly, because an
 * intermittent fee error reads like a flaky RPC and invites a retry loop
 * rather than a gas limit.
 *
 * Computed rather than hard-coded: the oracle's calldata is fixed in shape but
 * not in content, and a hard-coded 21600 would be wrong the moment the ABI
 * changes.
 */
export function eip7623FloorGas(data: Hex): bigint {
  const bytes = data.slice(2);
  let tokens = 0n;
  for (let i = 0; i < bytes.length; i += 2) {
    tokens += bytes.slice(i, i + 2) === "00" ? 1n : 4n;
  }
  return 21000n + 10n * tokens;
}

function max(a: bigint, b: bigint): bigint {
  return a > b ? a : b;
}

export function configFromEnv(env: NodeJS.ProcessEnv = process.env): Config {
  const required = (name: string): string => {
    const value = env[name];
    if (!value) throw new Error(`${name} is not set`);
    return value;
  };
  const oracles: Record<string, Address> = {};
  for (const index of INDICES) {
    const key = `ORACLE_${index.symbol}`;
    const address = env[key];
    if (address) oracles[index.symbol] = address as Address;
  }
  if (Object.keys(oracles).length === 0) {
    throw new Error(`no oracle addresses set; expected ORACLE_<SYMBOL> for one of ${INDICES.map((i) => i.symbol).join(", ")}`);
  }
  const key = required("PUBLISHER_PRIVATE_KEY");
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) {
    // Checked rather than passed through, because the failure a malformed key
    // produces otherwise is a viem stack trace that could carry the value.
    throw new Error("PUBLISHER_PRIVATE_KEY is not a 32-byte hex key");
  }
  return {
    oracles,
    rpcUrl: env.RPC_URL ?? mezoTestnet.rpcUrls.default.http[0],
    publisherKey: key as `0x${string}`,
    intervalSeconds: Number(env.INTERVAL_SECONDS ?? 60),
    heartbeatSeconds: Number(env.HEARTBEAT_SECONDS ?? 1800),
    thresholdBps: Number(env.THRESHOLD_BPS ?? 50),
    receiptTimeoutMs: Number(env.RECEIPT_TIMEOUT_MS ?? 20_000),
    httpPort: Number(env.HTTP_PORT ?? 8787),
    chainId: Number(env.CHAIN_ID ?? mezoTestnet.id),
    synthetic: env.SYNTHETIC === "1",
  };
}

export class FeedService {
  private readonly status = new Map<string, IndexStatus>();
  private ticking = false;
  private step = 0;
  private timer: NodeJS.Timeout | null = null;
  private server: ReturnType<typeof createServer> | null = null;

  /* Declared rather than written as a constructor parameter property: Node
     runs these files by stripping types, and a parameter property is a
     TypeScript construct that emits code, which strip-only mode refuses. The
     service would have failed at start-up while the pure-function tests,
     which never import this file, stayed green. */
  private readonly config: Config;

  constructor(config: Config) {
    this.config = config;
    for (const index of INDICES) {
      assertDefinition(index);
      this.status.set(index.symbol, {
        symbol: index.symbol,
        description: index.description,
        value: null,
        onChainAnswer: null,
        onChainRound: null,
        onChainUpdatedAt: null,
        origin: null,
        lastAttemptAt: null,
        lastError: null,
        lastDecision: null,
      });
    }
  }

  statusSnapshot(): IndexStatus[] {
    return [...this.status.values()];
  }

  /** One pass over every configured index. Never throws: a failing index logs
   *  and leaves the others alone, because one dead constituent should not stop
   *  a feed that is otherwise healthy. */
  async tick(): Promise<void> {
    /* One tick at a time.
     *
     * `setInterval` fires on a wall clock and does not wait for the previous
     * callback's promise, so a tick slower than INTERVAL_SECONDS used to
     * overlap the next one. Two overlapping ticks publish from the same key
     * concurrently, which on Mezo means one of them is rejected for being out
     * of sequence - a self-inflicted feed error that looks like an RPC fault.
     * Skipping is right rather than queueing: the skipped tick's work is to
     * read a price and publish it, and the tick in flight is already doing
     * exactly that with fresher data. */
    if (this.ticking) {
      console.warn("feed: previous tick still running, skipping this one");
      return;
    }
    this.ticking = true;
    try {
      await this.tickOnce();
    } finally {
      this.ticking = false;
    }
  }

  private async tickOnce(): Promise<void> {
    this.step += 1;
    /* One request per tick for every constituent of every index, rather than
     * one per index: the source is rate-limited, the indices overlap, and a
     * 429 is the likeliest way this service fails. Fetched once here and
     * shared, so adding an index costs no extra request. */
    const shared = await this.sharedPrices();
    const account = privateKeyToAccount(this.config.publisherKey);
    const transport = http(this.config.rpcUrl);
    const chain = chainFor(this.config.chainId, this.config.rpcUrl);
    const publicClient = createPublicClient({ chain, transport });
    const walletClient = createWalletClient({ account, chain, transport });

    for (const index of INDICES) {
      const oracle = this.config.oracles[index.symbol];
      if (!oracle) continue;
      const state = this.status.get(index.symbol)!;
      state.lastAttemptAt = Math.floor(Date.now() / 1000);
      try {
        const { value, origin } = this.valueFor(index, shared);
        state.value = value;
        state.origin = origin;

        const [
          decimals,
          maxDeviationBps,
          minRoundInterval,
          minAnswer,
          deviationWindow,
          maxWindowDeviationBps,
          anchorAnswer,
          anchorAt,
          paused,
          block,
          latest,
        ] = await Promise.all([
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "decimals" }),
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "maxDeviationBps" }),
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "minRoundInterval" }),
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "MIN_ANSWER" }),
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "deviationWindow" }),
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "maxWindowDeviationBps" }),
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "anchorAnswer" }),
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "anchorAt" }),
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "paused" }),
          // The chain's own clock, for elapsedSince() below.
          publicClient.getBlock({ blockTag: "latest" }),
          publicClient
            .readContract({ address: oracle, abi: ORACLE_ABI, functionName: "latestRoundData" })
            .catch(() => null), // reverts with NoData before the first round
        ]);

        if (paused) {
          state.lastDecision = "feed paused by its guardian; not publishing";
          state.lastError = null;
          continue;
        }

        const last = latest ? (latest[1] as bigint) : null;
        const updatedAt = latest ? Number(latest[3] as bigint) : null;
        state.onChainAnswer = last === null ? null : last.toString();
        state.onChainRound = latest ? (latest[0] as bigint).toString() : null;
        state.onChainUpdatedAt = updatedAt;

        const decision = decidePublish({
          target: toFeedUnits(value, Number(decimals)),
          last,
          secondsSinceLast: updatedAt === null ? Number.MAX_SAFE_INTEGER : elapsedSince(updatedAt, block.timestamp),
          thresholdBps: this.config.thresholdBps,
          heartbeatSeconds: this.config.heartbeatSeconds,
          maxDeviationBps: Number(maxDeviationBps),
          minRoundInterval: Number(minRoundInterval),
          minAnswer: minAnswer as bigint,
          anchorAnswer: anchorAnswer as bigint,
          maxWindowDeviationBps: Number(maxWindowDeviationBps),
          // Off the chain's clock, like secondsSinceLast above and for the
          // same reason: the contract compares block.timestamp to anchorAt.
          secondsSinceAnchor: elapsedSince(Number(anchorAt as bigint), block.timestamp),
          deviationWindow: Number(deviationWindow),
        });
        state.lastDecision = `${decision.publish ? "publish" : "hold"}: ${decision.reason} (${origin})`;

        if (decision.publish) {
          /* An explicit gas limit, because Mezo rejects its own estimate.
             See eip7623FloorGas() for why. */
          const data = encodeFunctionData({
            abi: ORACLE_ABI,
            functionName: "publish",
            args: [decision.answer],
          });
          const estimate = await publicClient.estimateContractGas({
            address: oracle,
            abi: ORACLE_ABI,
            functionName: "publish",
            args: [decision.answer],
            account,
          });
          const floor = eip7623FloorGas(data);
          const gas = (max(estimate, floor) * 12n) / 10n;

          const hash = await walletClient.writeContract({
            address: oracle,
            abi: ORACLE_ABI,
            functionName: "publish",
            args: [decision.answer],
            gas,
          });
          /* Bounded, and a timeout is not an error.
           *
           * Mezo's eth_getTransactionReceipt returns null for minutes after a
           * transaction is already mined, and this await was unbounded. Both
           * indices publish from one key in this one sequential loop, so a
           * single slow receipt starved the *other* oracle for the whole tick
           * - long enough, repeatedly, to take a vault stale and stop it
           * trading, caused entirely by the other index. Sequential is
           * deliberate (one key, one nonce sequence, and Mezo rejects
           * out-of-sequence sends), so the fix is to stop waiting rather than
           * to parallelise.
           *
           * The transaction is submitted either way; the re-read below, and
           * failing that the next tick, reports what actually landed. */
          try {
            await publicClient.waitForTransactionReceipt({
              hash,
              timeout: this.config.receiptTimeoutMs,
              confirmations: 1,
            });
          } catch {
            state.lastDecision = `${state.lastDecision}; submitted ${hash}, receipt not seen yet`;
          }

          /* Re-read, rather than only writing the answer back.
             Setting onChainAnswer alone left onChainRound and
             onChainUpdatedAt holding their pre-publish values, so /prices
             reported a fresh answer beside a timestamp minutes old - a
             working feed that reads as a stale one, which is exactly the
             thing a monitor would page someone about.
             Re-read instead of assuming round + 1 and now: the round is the
             chain's to say, not ours, and another holder of PUBLISHER_ROLE
             would make a derived guess quietly wrong. On a failed read the
             three fields stay as they were and the next cycle corrects
             them. */
          const after = await publicClient
            .readContract({ address: oracle, abi: ORACLE_ABI, functionName: "latestRoundData" })
            .catch(() => null);
          if (after) {
            state.onChainRound = (after[0] as bigint).toString();
            state.onChainAnswer = (after[1] as bigint).toString();
            state.onChainUpdatedAt = Number(after[3] as bigint);
          } else {
            state.onChainAnswer = decision.answer.toString();
          }
        }
        state.lastError = null;
      } catch (error) {
        /* Redacted, because `/prices` is public and viem's full message is
           not: it embeds the RPC URL, the entire eth_sendRawTransaction body
           and the raw signed transaction. An earlier comment here claimed
           taking `.message` was enough — it is not, and a production RPC URL
           may carry an access token in its path. `shortMessage` is viem's own
           one-liner; the name is the fallback, and the full text still goes to
           the operator's log where only they can read it. */
        const short = (error as { shortMessage?: unknown })?.shortMessage;
        state.lastError =
          typeof short === "string" && short.length > 0
            ? short
            : error instanceof Error
              ? error.name
              : "publish failed";
        console.error(`[${index.symbol}]`, error);
      }
    }
  }

  /** Every constituent of every index, in one request, or null if it failed. */
  private async sharedPrices(): Promise<Readonly<Record<string, number>> | null> {
    if (this.config.synthetic) return null;
    const ids = [...new Set(INDICES.flatMap((i) => i.constituents.map((c) => c.id)))].sort();
    try {
      return await fetchPrices(ids);
    } catch (error) {
      // Labelled, not hidden: a demo that stalls because an API is down is
      // worse than a demo that says which series it is showing.
      console.warn(`source failed, using the deterministic series: ${String(error)}`);
      return null;
    }
  }

  private valueFor(
    index: IndexDefinition,
    shared: Readonly<Record<string, number>> | null,
  ): { value: number; origin: SourceResult["origin"] } {
    if (shared === null) {
      return { value: syntheticValue(index, this.step), origin: "synthetic" };
    }
    try {
      return { value: indexValue(index, shared), origin: "source" };
    } catch (error) {
      // One index can be unpublishable while the others are fine: a
      // constituent the source dropped must not take the whole feed down.
      console.warn(`[${index.symbol}] ${String(error)}; using the deterministic series`);
      return { value: syntheticValue(index, this.step), origin: "synthetic" };
    }
  }

  start(): void {
    this.server = createServer((request, response) => {
      // Read-only, and CORS-open because both front ends are static pages on
      // other origins. There is nothing here to protect: it is public data
      // and no request can change anything.
      response.setHeader("access-control-allow-origin", "*");
      response.setHeader("cache-control", "no-store");
      if (request.method !== "GET") {
        response.writeHead(405).end();
        return;
      }
      if (request.url === "/healthz") {
        const healthy = this.statusSnapshot().some((s) => s.value !== null);
        response.writeHead(healthy ? 200 : 503, { "content-type": "application/json" });
        response.end(JSON.stringify({ ok: healthy, chainId: this.config.chainId }));
        return;
      }
      if (request.url === "/prices") {
        response.writeHead(200, { "content-type": "application/json" });
        /* The chain and the RPC host, not only the prices.
         *
         * Two feeds can run at once - a local rehearsal and the real one - and
         * they answer the same path on the same port. Without this, telling
         * them apart means noticing that a round number is implausible, which
         * is exactly the kind of inference a status endpoint exists to spare
         * you. It cost a confused five minutes to find out the hard way. The
         * host only, never the full URL, because an RPC URL can carry a token
         * in its path and this response is public. */
        let rpcHost = "unknown";
        try {
          rpcHost = new URL(this.config.rpcUrl).host;
        } catch {
          /* a malformed URL is the caller's problem, not this endpoint's */
        }
        response.end(
          JSON.stringify(
            {
              chainId: this.config.chainId,
              chain: chainFor(this.config.chainId, this.config.rpcUrl).name,
              rpcHost,
              synthetic: this.config.synthetic,
              indices: this.statusSnapshot(),
            },
            null,
            2,
          ),
        );
        return;
      }
      response.writeHead(404).end();
    });
    this.server.listen(this.config.httpPort, () => {
      const chain = chainFor(this.config.chainId, this.config.rpcUrl);
      console.log(
        `feed: ${chain.name} (${this.config.chainId}) via ${this.config.rpcUrl}, ` +
          `http on :${this.config.httpPort}, every ${this.config.intervalSeconds}s, ` +
          `${this.config.synthetic ? "SYNTHETIC series" : "real source"}`,
      );
      for (const index of INDICES) {
        const oracle = this.config.oracles[index.symbol];
        console.log(`  ${index.symbol.padEnd(10)} ${oracle ?? "(not configured)"}`);
      }
    });
    this.server.on("error", (error: NodeJS.ErrnoException) => {
      /* Said plainly, because the likeliest cause is the one that wasted time
         here: another feed already running on this port, serving a different
         chain's prices under the same path. */
      if (error.code === "EADDRINUSE") {
        console.error(
          `feed: port ${this.config.httpPort} is already in use. Another feed is probably ` +
            `running - check it is not pointed at a different chain - or set HTTP_PORT.`,
        );
        process.exit(1);
      }
      throw error;
    });

    const run = (): void => {
      void this.tick();
    };
    run();
    this.timer = setInterval(run, this.config.intervalSeconds * 1000);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.server?.close();
  }
}
