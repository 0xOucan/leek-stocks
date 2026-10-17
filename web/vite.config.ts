import { defineConfig } from "vite";

// Where the dev server finds the price feed. Defaults to a feed running
// locally; point it at the deployed dapp host to work against production
// prices when no local feed is up (the VPS feed is the only publisher, so
// running a second one locally pays twice for duplicate oracle rounds):
//   FEED_PROXY_TARGET=https://leekdefi.0xoucanproject.xyz npm run dev
const feedTarget = process.env.FEED_PROXY_TARGET ?? "http://127.0.0.1:8787";
const remoteFeed = feedTarget.startsWith("https:");

export default defineConfig({
  server: {
    // In production Caddy proxies /prices on this host to the feed container.
    // The dev server does the same thing so the fetch path is relative in both
    // places: one code path, no CORS, nothing to add to the CSP.
    proxy: {
      "/prices": {
        target: feedTarget,
        // A remote target needs the Host header rewritten or its TLS/SNI and
        // vhost routing reject us; a local one must keep it, as before.
        changeOrigin: remoteFeed,
      },
    },
  },
  build: {
    // Reported in the README so a regression is visible: the point of not
    // shipping React and RainbowKit is a small initial download, and a number
    // nobody measures stops being true.
    reportCompressedSize: true,
    // esnext, because this is served to a browser that supports top-level
    // await; transpiling down would pull in regenerator-style helpers for no
    // reader we have.
    target: "esnext",
  },
});
