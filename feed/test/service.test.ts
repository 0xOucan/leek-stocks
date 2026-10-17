import { strict as assert } from "node:assert";
import { test } from "node:test";
import { configFromEnv, FeedService, mezoTestnet } from "../src/service.ts";

/**
 * This file exists because the pure-function tests do not import the service,
 * so a file that cannot even be loaded stayed green through a full test run.
 * Node executes these files by stripping types, which refuses some TypeScript
 * constructs that a compiler would accept, and the only way to catch that is
 * to import the module.
 */

const KEY = `0x${"11".repeat(32)}`;

test("the service module loads and constructs under type stripping", () => {
  const service = new FeedService({
    oracles: { GOLOGGLE: "0x0000000000000000000000000000000000000001" },
    rpcUrl: mezoTestnet.rpcUrls.default.http[0],
    publisherKey: KEY,
    intervalSeconds: 60,
    heartbeatSeconds: 1800,
    thresholdBps: 50,
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
