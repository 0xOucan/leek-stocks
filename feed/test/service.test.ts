import { strict as assert } from "node:assert";
import { test } from "node:test";
import { encodeFunctionData } from "viem";
import { chainFor, configFromEnv, eip7623FloorGas, FeedService, mezoTestnet } from "../src/service.ts";

/**
 * This file exists because the pure-function tests do not import the service,
 * so a file that cannot even be loaded stayed green through a full test run.
 * Node executes these files by stripping types, which refuses some TypeScript
 * constructs that a compiler would accept, and the only way to catch that is
 * to import the module.
 */

const KEY: `0x${string}` = `0x${"11".repeat(32)}`;

test("the service module loads and constructs under type stripping", () => {
  const service = new FeedService({
    oracles: { GOLOGGLE: "0x0000000000000000000000000000000000000001" },
    rpcUrl: mezoTestnet.rpcUrls.default.http[0],
    chainId: mezoTestnet.id,
    publisherKey: KEY,
    intervalSeconds: 60,
    heartbeatSeconds: 1800,
    thresholdBps: 50,
  receiptTimeoutMs: 20_000,
    httpPort: 0,
    synthetic: true,
  });
  const rows = service.statusSnapshot();
  assert.equal(rows.length, 2, "one status row per shipped index");
  for (const row of rows) {
    assert.equal(row.value, null, "nothing is published before the first tick");
    assert.equal(row.origin, null);
  }
});

test("Mezo's gas token is BTC with 18 decimals", () => {
  // Not ether. A front end that renders gas as ETH here names the wrong asset.
  assert.equal(mezoTestnet.nativeCurrency.symbol, "BTC");
  assert.equal(mezoTestnet.nativeCurrency.decimals, 18);
  assert.equal(mezoTestnet.id, 31_611);
});

test("configuration refuses a malformed publisher key", () => {
  // Checked before viem sees it, so the failure cannot be a stack trace
  // carrying the value.
  assert.throws(
    () => configFromEnv({ PUBLISHER_PRIVATE_KEY: "nonsense", ORACLE_GOLOGGLE: "0x01" }),
    /not a 32-byte hex key/,
  );
  assert.throws(
    () => configFromEnv({ ORACLE_GOLOGGLE: "0x01" }),
    /PUBLISHER_PRIVATE_KEY is not set/,
  );
});

test("configuration refuses to run with no oracle address", () => {
  assert.throws(() => configFromEnv({ PUBLISHER_PRIVATE_KEY: KEY }), /no oracle addresses set/);
});

test("configuration defaults are the documented ones", () => {
  const config = configFromEnv({
    PUBLISHER_PRIVATE_KEY: KEY,
    ORACLE_GOLOGGLE: "0x0000000000000000000000000000000000000001",
  });
  assert.equal(config.intervalSeconds, 60);
  assert.equal(config.heartbeatSeconds, 1800);
  assert.equal(config.thresholdBps, 50);
  assert.equal(config.synthetic, false, "the real source is the default, not the synthetic one");
  assert.equal(config.rpcUrl, mezoTestnet.rpcUrls.default.http[0]);
});

test("the publishing chain is configurable, and Mezo testnet is the default", () => {
  // It was hardcoded to Mezo testnet while the RPC URL came from the
  // environment, so every write was signed for 31611 whatever node answered.
  // A local rehearsal failed with "invalid chain id for signer" on every
  // publish, which is how the bug stayed hidden: the publisher could only be
  // exercised against the one network it was going to run on.
  const base = { PUBLISHER_PRIVATE_KEY: KEY, ORACLE_GOLOGGLE: "0x0000000000000000000000000000000000000001" };
  assert.equal(configFromEnv(base).chainId, 31_611);
  assert.equal(configFromEnv({ ...base, CHAIN_ID: "31337" }).chainId, 31_337);

  assert.equal(chainFor(31_611, "http://x").name, "Mezo Testnet");
  assert.equal(chainFor(31_612, "http://x").name, "Mezo");
  assert.equal(chainFor(31_612, "http://x").nativeCurrency.symbol, "BTC");
  // A rehearsal chain is named for what it is rather than dressed as Mezo.
  assert.equal(chainFor(31_337, "http://x").id, 31_337);
  assert.match(chainFor(31_337, "http://x").name, /31337/);
});

test("the EIP-7623 floor is computed, and matches the value Mezo rejected", () => {
  // The exact calldata from the rejected GOLOGGLE publish: publish(12800000000).
  // Mezo said "21240 (gas limit) < 21600 (floor data gas)", so the floor for
  // this calldata is 21600 and the node's own estimate was below it.
  const data = encodeFunctionData({
    abi: [
      {
        type: "function",
        name: "publish",
        stateMutability: "nonpayable",
        inputs: [{ name: "answer", type: "int256" }],
        outputs: [],
      },
    ],
    functionName: "publish",
    args: [12800000000n],
  });
  assert.equal(eip7623FloorGas(data), 21600n);

  // An empty calldata transaction is a plain transfer: the floor is the base
  // cost and nothing more.
  assert.equal(eip7623FloorGas("0x"), 21000n);

  // Four non-zero bytes are four tokens each: 21000 + 10 * 16.
  assert.equal(eip7623FloorGas("0xdeadbeef"), 21160n);
});
