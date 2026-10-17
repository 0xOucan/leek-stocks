#!/usr/bin/env node
/**
 * Entry point. Reads configuration from the environment, starts the loop and
 * the status endpoint, and stops cleanly on a signal so systemd can restart it
 * without leaving a half-published round behind.
 */
import { existsSync, readFileSync } from "node:fs";

import { configFromEnv, FeedService } from "./service.ts";

/**
 * Load .env, without letting it override anything already in the environment.
 *
 * The file is how the VPS passes configuration (docker --env-file) and how a
 * local rehearsal reaches the live Mezo oracles; scripts/feed-env.sh writes
 * it. Nothing read it before, so `npm start` died on a missing oracle address
 * while the file sat right there.
 *
 * Explicit environment wins deliberately, and this is the whole reason the
 * loader is hand-rolled rather than process.loadEnvFile(). A .env written for
 * Mezo holds the publisher key and the live oracle addresses. local-up.sh
 * passes Anvil's key, Anvil's RPC and freshly deployed local oracles in the
 * environment. If the file could override those, a local test run would sign
 * with the real publisher key and push synthetic prices at the live oracles -
 * a one-character mistake away at all times. Precedence is the guard.
 */
function loadDotEnv(path = ".env"): void {
  if (!existsSync(path)) return;
  for (const raw of readFileSync(path, "utf8").split("\n")) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 1) continue;
    const key = line.slice(0, eq).trim();
    if (key in process.env) continue;
    let value = line.slice(eq + 1).trim();
    if (value.length > 1 && (value.startsWith('"') || value.startsWith("'")) && value.endsWith(value[0])) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}

loadDotEnv();

const service = new FeedService(configFromEnv());
service.start();

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    console.log(`feed: ${signal}, stopping`);
    service.stop();
    process.exit(0);
  });
}
