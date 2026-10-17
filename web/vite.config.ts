import { defineConfig } from "vite";

export default defineConfig({
  server: {
    // In production Caddy proxies /prices on this host to the feed container.
    // The dev server does the same thing so the fetch path is relative in both
    // places: one code path, no CORS, nothing to add to the CSP.
    proxy: {
      "/prices": { target: "http://127.0.0.1:8787", changeOrigin: false },
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
