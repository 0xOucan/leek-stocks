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
import { createPublicClient, createWalletClient, defineChain, http, type Address } from "viem";
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
  { type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;

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
  readonly httpPort: number;
  /** Use the deterministic series instead of the source. For a filmed demo. */
  readonly synthetic: boolean;
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
    httpPort: Number(env.HTTP_PORT ?? 8787),
    synthetic: env.SYNTHETIC === "1",
  };
}

export class FeedService {
  private readonly status = new Map<string, IndexStatus>();
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
    this.step += 1;
    /* One request per tick for every constituent of every index, rather than
     * one per index: the source is rate-limited, the indices overlap, and a
     * 429 is the likeliest way this service fails. Fetched once here and
     * shared, so adding an index costs no extra request. */
    const shared = await this.sharedPrices();
    const account = privateKeyToAccount(this.config.publisherKey);
    const transport = http(this.config.rpcUrl);
    const publicClient = createPublicClient({ chain: mezoTestnet, transport });
    const walletClient = createWalletClient({ account, chain: mezoTestnet, transport });

    for (const index of INDICES) {
      const oracle = this.config.oracles[index.symbol];
      if (!oracle) continue;
      const state = this.status.get(index.symbol)!;
      state.lastAttemptAt = Math.floor(Date.now() / 1000);
      try {
        const { value, origin } = this.valueFor(index, shared);
        state.value = value;
        state.origin = origin;

        const [decimals, maxDeviationBps, paused, latest] = await Promise.all([
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "decimals" }),
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "maxDeviationBps" }),
          publicClient.readContract({ address: oracle, abi: ORACLE_ABI, functionName: "paused" }),
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
          secondsSinceLast: updatedAt === null ? Number.MAX_SAFE_INTEGER : Math.floor(Date.now() / 1000) - updatedAt,
          thresholdBps: this.config.thresholdBps,
          heartbeatSeconds: this.config.heartbeatSeconds,
          maxDeviationBps: Number(maxDeviationBps),
        });
        state.lastDecision = `${decision.publish ? "publish" : "hold"}: ${decision.reason} (${origin})`;

        if (decision.publish) {
          const hash = await walletClient.writeContract({
            address: oracle,
            abi: ORACLE_ABI,
            functionName: "publish",
            args: [decision.answer],
          });
          await publicClient.waitForTransactionReceipt({ hash });
          state.onChainAnswer = decision.answer.toString();
        }
        state.lastError = null;
      } catch (error) {
        // The message only; a stack could carry a URL with a key in it.
        state.lastError = error instanceof Error ? error.message : String(error);
        console.error(`[${index.symbol}] ${state.lastError}`);
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
        response.end(JSON.stringify({ ok: healthy }));
        return;
      }
      if (request.url === "/prices") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ indices: this.statusSnapshot() }, null, 2));
        return;
      }
      response.writeHead(404).end();
    });
    this.server.listen(this.config.httpPort, () => {
      console.log(`feed: http on :${this.config.httpPort}, publishing every ${this.config.intervalSeconds}s`);
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
