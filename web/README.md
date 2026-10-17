# web — LeekStonks

The dapp: read the oracle's prices, buy and redeem index shares against MUSD,
and see the vault's reserves against its liabilities before committing
anything. One page, three sections, no framework.

**Tab title:** "LeekStonks — Lending and ETFs protocol". The lending market
does not exist yet, so the page says so in a line rather than offering a
section that leads nowhere.

## Stack

Vite + TypeScript + [viem](https://viem.sh). Plain DOM with small render
functions. No React, no Next, no wagmi, no RainbowKit.

### Why not Scaffold-ETH 2

The ethskills frontend playbook mandates Scaffold-ETH 2 — Next.js with
RainbowKit, statically exported for IPFS — and this diverges from it on
purpose. Three reasons, and they are specific to this deployment rather than
general preferences:

1. **It is not going to IPFS.** It deploys as a static container behind the
   user's own Caddy on their own VPS, with a **128 MB memory limit** and a
   per-app CPU share. The playbook's export-for-IPFS path solves a hosting
   problem this project does not have, and a Next build step adds a toolchain
   to the image for no gain over `caddy file-server`.
2. **The wallet is this project's own hardware wallet.** The LeekWallet
   browser extension announces itself over **EIP-6963**, exactly as MetaMask
   does. Hand-wiring connection here means reading one short standard —
   listen for `eip6963:announceProvider`, list what announced itself — rather
   than avoiding one. RainbowKit would add a connector registry whose entire
   job is a wallet list we can build from the event in forty lines, and it
   would still need custom work for a wallet that is not in its registry.
3. **Minimal resource use was the explicit requirement.** The initial bundle
   is **59.3 kB gzipped of JavaScript** plus 2.3 kB of CSS. A Next +
   RainbowKit + wagmi starter is an order of magnitude more, most of it
   parsed on every cold load, and the user asked for something that "doesn't
   consume much RAM and resources".

Everything else in the playbook and in the frontend-ux skill still applies and
is followed: one primary action at a time, per-button pending state, decoded
custom errors inline, truncated and copyable addresses, `formatUnits`
everywhere, semantic colour tokens with a dark-mode block, one `<h1>`,
favicon, title and Open Graph tags.

## Bundle

| | raw | gzipped |
|---|---|---|
| entry JS | 199 kB | **59.3 kB** |
| CSS | 9.5 kB | 2.3 kB |
| `index.html` | 1.7 kB | 0.8 kB |

Self-hosted fonts add 180 kB of woff2, fetched in parallel and cached for a
year, with `font-display: swap` so text is readable before they arrive.

**WalletConnect is not in the initial bundle.** It is reached by
`await import("@walletconnect/ethereum-provider")` inside the connect handler,
so Rollup emits it as its own set of chunks — about 60 of them, the largest
being `core` at 178 kB gzipped — and none is referenced from `index.html`,
not even as a `modulepreload`. Someone who uses a browser extension, or who
only reads prices, never downloads any of it.

Two further measurements worth keeping:

- The read client is `createClient` with `readContract`, `getBalance` and
  `waitForTransactionReceipt` imported from `viem/actions`, not
  `createPublicClient`. The public client attaches every public action to the
  object, which defeats tree-shaking: it measured **98.6 kB gzipped** in the
  entry chunk against 59.3 kB this way.
- The ABIs are hand-written `as const` fragments covering only the functions
  this page calls, not Foundry artifacts.

## The faucet, and what is not here

**Lending is not built.** On Mezo the dapp will use Mezo's own native borrow
protocol; on other chains it will use the market in the sibling `leek-lend`
repository. Neither is deployed, so the title's promise is kept to one honest
line in the footer: no tab, no dead link, and no stub that looks interactive.

**The faucet section** covers the chains where the real MUSD does not exist
and the protocol ships its own mock tokens plus a rate-limited `TokenFaucet`.
It claims one token at a time, each button with its own pending state, and it
**reads the cooldown and shows "available again in N minutes" before the
click** — a revert the UI could have predicted is a UI bug. With no
`VITE_FAUCET` configured it says so in a line, exactly as an unconfigured
vault does, and on a mainnet chain id it does not render at all, because the
contract refuses those ids by construction.

Mock symbols carry a **`leek` prefix** — leekMUSD, leekwBTC, leekWETH —
because Mezo's own bridged tokens use `m`: `mUSDC`, `mUSDT` and `mDAI` are
real contracts, so a mock named `mMUSD` would read as one of theirs. Nothing
in the UI hardcodes a symbol: each one is read from its token, and a token
that will not report a symbol and decimals is not rendered, because the symbol
beside an amount is the user's only clue which asset they are about to spend.

`TokenFaucet` is not written yet, so **its ABI in `src/faucet.ts` is an
assumption**: the cooldown is read as `nextClaimAt(token, account)` with a
fallback to `cooldown()` plus `lastClaim(token, account)`, and every read
tolerates a revert so a mismatch degrades to "claim and find out" rather than
to an empty section. It must be checked against the deployed contract.

## Running it

```sh
cp .env.example .env     # then fill it in; .env is git-ignored
npm install
npm test                 # pure helpers, under node --test with type stripping
npm run dev              # http://localhost:5173
npm run build            # tsc --noEmit, then vite build
```

`npm run dev` proxies `/prices` to `http://127.0.0.1:8787`, which is where the
feed service listens. In production Caddy does the same thing on the same
path, so the fetch is relative in both places and there is one code path.

## Configuration

Everything is in `.env.example`, documented there. The important property:
**every `VITE_*` value is compiled into the JavaScript and shipped to the
browser, so every one of them is public.** Nothing secret goes in one. The
WalletConnect project id is in there because a project id is a public client
identifier — it travels in every relay URL and grants nothing but relay quota.
The publisher key that signs oracle rounds lives in the feed service's systemd
`EnvironmentFile`, and nothing in this directory can reach it.

**The app starts with no addresses configured.** The contracts are not
deployed, so `VITE_VAULT_*` and `VITE_SHARE_*` are empty and the page renders
a "not deployed yet" state per index rather than throwing on a blank address.

### The feed URL

`VITE_FEED_URL` defaults to empty, which means the relative path `/prices`.
Caddy proxies that path on this host to the feed container, so the request is
same-origin: no CORS, and **no `connect-src` entry in the CSP**. Setting it to
an absolute URL still works, and then that origin has to be added to
`connect-src` in `deploy/leekdefi.caddy.tmpl` — avoiding that edit is why the
default is relative.

### The RPC

The playbook says not to use a public RPC in production, and this does, because
**Mezo testnet has exactly one public endpoint** — `https://rpc.test.mezo.org`
— and no second provider to fall back to. That is a real single point of
failure and it is not papered over: `VITE_RPC_URL` exists so the build can be
pointed at a private node without a code change, and the read transport retries
twice on failure because asking again is the only recourse available.

Mezo's gas token is **BTC with 18 decimals**, not ether. It is read from the
chain definition everywhere and never written as a literal, because a user who
tops up the wrong asset because a page said "ETH" has been actively misled.

### Fonts

Space Grotesk (headings), Inter (body) and JetBrains Mono (every number) are
self-hosted woff2, latin subset, in `public/fonts`. They are **not** linked
from Google Fonts: a third-party font request is a third-party connection on
every page load, which is a privacy leak and would force `style-src` and
`font-src` open to two Google origins in a CSP that is otherwise entirely
`'self'`. The files come from the `@fontsource/*` packages, kept as dev
dependencies so the subset can be regenerated.

## What the UI will not do

- **It will not show a synthetic price as a real one.** The feed falls back to
  a seeded deterministic series when its source is unavailable and reports
  `origin` as `"source"` or `"synthetic"`; a synthetic value carries a badge on
  the card and a line next to the buy button.
- **It will not hide audit finding H-1.** A share is priced from an index the
  vault does not hold, so liabilities can exceed reserves. When they do, the
  trade section says so in plain words, names the shortfall, and explains that
  redemption reverts rather than paying part of what is owed. The same warning
  appears per-amount when a particular redemption exceeds reserves.
- **It will not ask for an unlimited allowance.** `buy` pulls exactly
  `musdAmount`, so the approval is for exactly that, at the cost of one
  approval per buy.
- **It will not show a raw selector or a raw address.** Every custom error
  these contracts declare is mapped to a sentence with the contract's own
  numbers in it; every address is truncated, copyable and linked to the
  explorer.

## Deployment

`deploy/` holds the three files the user's [vpsinfra](https://github.com/0xOucan/vpsinfra)
setup needs:

| File | Goes to |
|---|---|
| `Dockerfile` | built from the repository root; node stage builds, Caddy stage serves |
| `leekdefi.env` | `projects/leekdefi.env` in vpsinfra |
| `leekdefi.caddy.tmpl` | `projects/leekdefi.caddy.tmpl` in vpsinfra |

**Confirm the subdomain.** It is set to `leekdefi.0xoucanproject.xyz`.
`leekwallet.0xoucanproject.xyz` is already the firmware site, and the name
covers the lending market that will share this host.

The final image is `caddy:2.11.4-alpine` with the static output at `/srv`,
running as uid 10001 and with `cap_net_bind_service` removed from the caddy
binary — the container binds 8080 and is reached through the host's Caddy, so
that capability grants nothing and a public-facing binary should not keep a
privilege nothing uses. `caddy file-server` writes nothing, which is what makes
`READ_ONLY=true` work without a tmpfs mount.

The Caddy template routes `/prices` to `oucan-leekdefi-feed:8787` with
`Cache-Control: no-store`, serves `/assets/*` and `/fonts/*` immutable for a
year, and sets a CSP with `script-src 'self'` (no `unsafe-eval`),
`X-Content-Type-Options`, `Referrer-Policy` and a `Permissions-Policy` denying
camera, microphone and geolocation. Every `connect-src` entry is commented
with why it is there.

## Tests

`npm test` runs `node --test` with type stripping, the same approach as
`feed/`. The covered modules are pure and import nothing from the browser:

| Module | Covers |
|---|---|
| `src/lib/errors.ts` | every custom error decodes to a sentence; nested provider shapes; unknown selectors; wallet codes |
| `src/lib/format.ts` | address truncation, bounded fractions, input parsing and its rejections, ages |
| `src/lib/quote.ts` | buy and redeem maths against the contract's rounding, round trips, slippage, the H-1 shortfall |
| `src/lib/staleness.ts` | the freshness boundary the vault enforces, and the faucet cooldown |

**What is not tested.** The contracts are not deployed, so nothing here has
been exercised against a live vault, oracle or MUSD: no buy, no redeem, no
approval, no revert decoded from a real transaction, no chain switch in a real
wallet, and no faucet claim. The faucet's ABI is a guess at a contract that
does not exist yet. The quote maths is asserted against the figures in the contracts and
the fork test (1000 MUSD at a 200 price mints 4.975 shares), not against a
chain. The WalletConnect path has never completed a pairing, and the CSP's
WalletConnect entries are derived from what the provider documents it contacts
rather than from an observed session.
