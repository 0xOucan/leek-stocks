#!/usr/bin/env node
/**
 * Entry point. Reads configuration from the environment, starts the loop and
 * the status endpoint, and stops cleanly on a signal so systemd can restart it
 * without leaving a half-published round behind.
 */
import { configFromEnv, FeedService } from "./service.ts";

const service = new FeedService(configFromEnv());
service.start();

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    console.log(`feed: ${signal}, stopping`);
    service.stop();
    process.exit(0);
  });
}
