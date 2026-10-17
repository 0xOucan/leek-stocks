# Deploying LeekStonks

Two deployment units on one hostname, plus the contracts they talk to. Written
against the operator's own infrastructure repository (`0xOucan/vpsinfra`:
Cloudflare → VPS IPv4 → Caddy → isolated Docker services) and its
`docs/adding-projects.md`, `docs/cloudflare.md` and `docs/deployment.md`.

Markers follow that repository's convention: `[LOCAL]` runs on the
workstation, `[VPS]` on the server, `[CLOUDFLARE]` in the dashboard.

| Unit | Project | Container | Port | Hostname |
|---|---|---|---|---|
| The dapp (static) | `leekdefi` | `oucan-leekdefi` | 8080 | `leekdefi.0xoucanproject.xyz` |
| The price feed (node) | `leekdefi-feed` | `oucan-leekdefi-feed` | 8787 | `feed.leekdefi.0xoucanproject.xyz`, which answers only `/healthz` |

**Why two.** They fail separately. A feed that cannot reach its price source
must not take the dapp's static assets down with it, and rolling one back
should not roll back the other.

**Why the second hostname exists at all.** vpsinfra's deploy gate validates a
health path over HTTP, and hostnames are its deployment boundary. The browser
never uses it: the dapp fetches `/prices` on **its own** origin and Caddy
proxies that one path to the feed container over the internal network. That is
what keeps `connect-src 'self'` for prices instead of adding an origin to the
Content-Security-Policy, and every origin in a CSP is somewhere a compromised
dependency could send data to.

## Order of operations

Nothing here works before the contracts exist, because the feed's whole job is
to publish to an oracle address and the dapp's whole job is to read vault
addresses.

1. Contracts to Mezo testnet (below).
2. The feed's secrets file, which needs those addresses.
3. Both deployments.

## 1. Contracts

Pre-flight, in order, each one a gate rather than a suggestion:

- [ ] `forge test` green, including `test/fork/*` against live MUSD.
- [ ] `slither . --filter-paths "lib|test|script"` with no unaddressed high or
      medium finding.
- [ ] The deployer address funded with **test BTC** — Mezo's gas token is BTC,
      not ether, so a balance of "ETH" is not a thing on this chain.
- [ ] `cast call <MUSD> "decimals()(uint8)" --rpc-url https://rpc.test.mezo.org`
      returns 18. The deploy script enforces this too (audit finding L-5), but
      checking by hand costs nothing and the script's revert costs gas.
- [ ] Role holders decided. Admin, publisher, guardian and treasurer are four
      separate addresses in `script/DeployMezoTestnet.s.sol`; collapsing them
      to one key is testnet-only and the script says so loudly.

```sh
# [LOCAL] --account prompts for the keystore password. A key or a password on a
# command line is visible in `ps` and lands in shell history, so neither ever
# goes there.
forge script script/DeployMezoTestnet.s.sol \
  --rpc-url mezo_testnet \
  --account monad-deployer \
  --sender <deployer address> \
  --broadcast
```

Afterwards, in order:

```sh
# [LOCAL] Record the addresses in ADDRESSES.md with the date, then prove each
# one is a contract rather than a plausible-looking string. An address with no
# code accepts a transfer and loses it, silently.
cast code <address> --rpc-url https://rpc.test.mezo.org | head -c 20

# [LOCAL] Verify the sources. Mezo's explorer is Blockscout, so the verifier
# is blockscout and the URL ends in /api, not the explorer's front page.
forge verify-contract <address> src/IndexOracle.sol:IndexOracle   --chain-id 31611   --verifier blockscout   --verifier-url https://explorer.test.mezo.org/api   --watch
```

Then confirm the first oracle round published — the script does it in the same
reviewed step, so a feed's first answer is never the unbounded one (finding
L-1) — and that `vaultFor` resolves for both symbols.

**On keys, and a deliberate divergence.** The ethskills tools guide's own
example passes `--private-key` on the command line. We do not: a command line
is visible in `ps` to every user on the machine and lands in shell history, so
every invocation here uses `--account` and types the password into a prompt.
The guide is right about the toolchain and wrong about that one habit.

## 2. Cloudflare

Per `docs/cloudflare.md`, the origin is one VPS IPv4 and the zone is
`0xoucanproject.xyz`. For each of the two hostnames:

1. `[CLOUDFLARE]` DNS → add a **proxied** `CNAME` from the hostname to
   `0xoucanproject.xyz`. Proxied, not DNS-only: DNS-only would publish the
   origin address.
2. `[CLOUDFLARE]` Do **not** add an `AAAA` record, and do not create
   `origin`, `server` or `ssh` records pointing at the VPS. That rule is in
   the infrastructure repository and it exists so the origin stays reachable
   only through Cloudflare.
3. `[CLOUDFLARE]` SSL/TLS mode as the other projects use it; Caddy terminates
   TLS at the origin, so a mode that bypasses origin TLS would downgrade the
   hop Cloudflare cannot see.

No API token is needed, and none belongs in this repository.

## 3. Registering both projects

The registry entries are written for you and live beside the code:
`web/deploy/leekdefi.env` and `feed/deploy/leekdefi-feed.env`. Generate the
real ones with the infrastructure repository's own script rather than copying
files by hand, then diff them against these and carry over the fields that
matter.

```sh
# [LOCAL] in the vpsinfra checkout
./scripts/add-project.sh   # name, hostname, source, app type, port, database
# then review and commit the generated projects/<name>.env
```

Copy the two Caddy templates into `projects/` under the names the registry
entries reference: `leekdefi.caddy.tmpl` and `leekdefi-feed.caddy.tmpl`.
`{{UPSTREAM}}` is substituted with `oucan-<project>`, which is why the dapp's
template can name `oucan-leekdefi-feed:8787` directly for the `/prices` route.

Both repositories are private, so each needs a **read-only deploy key** on the
VPS (step 6 of `docs/adding-projects.md`).

## 4. The feed's secrets

```sh
# [VPS] mode 0600, outside any repository, as docs/adding-projects.md requires
sudoedit /srv/oucan/secrets/projects/leekdefi-feed.env
```

Contents are documented in `feed/.env.example`. The two that matter:

- `PUBLISHER_PRIVATE_KEY` — the publisher key, which holds `PUBLISHER_ROLE`
  and nothing else. It cannot pause the feed (that is the guardian), cannot
  move fees (the treasurer) and cannot widen the oracle's deviation bound
  (immutable). **Keep only gas on it.** A compromised publisher can walk the
  price inside the per-round bound, which is finding M-1, so it is a hot key
  with a bounded blast radius rather than a safe one.
- `ORACLE_GOLOGGLE`, `ORACLE_AMEZON` — from the deploy above.

Never paste this file's contents into a commit, an issue or a chat message.

## 5. Deploy

```sh
# [VPS]
sudo ./scripts/deploy.sh leekdefi-feed --apply   # the feed first: the dapp reads it
sudo ./scripts/deploy.sh leekdefi --apply
```

The feed goes first only so the dapp's first paint has prices to show; neither
depends on the other to start.

## 6. Verify

- [ ] `https://leekdefi.0xoucanproject.xyz` loads over HTTPS, and the tab reads
      "LeekStonks — Lending and ETFs protocol".
- [ ] `https://leekdefi.0xoucanproject.xyz/prices` returns JSON. This proves the
      internal proxy works, which is the part that is easy to get wrong.
- [ ] `https://feed.leekdefi.0xoucanproject.xyz/healthz` returns `{"ok":true}`
      and **every other path on that host returns 404**.
- [ ] The application ports are **not** reachable at the origin address:
      `curl --max-time 5 http://<origin ip>:8080` and `:8787` must both fail.
      Step 8 of `docs/adding-projects.md`, and the one check that catches a
      container published to the host by accident.
- [ ] A wallet connects, the network switch to Mezo testnet offers **BTC** as
      the gas token, and a price shows with its origin label. A price marked
      `synthetic` means the source was unreachable and the deterministic series
      is being published — correct behaviour, and it must say so on screen.
- [ ] No mixed-content or CSP violations in the browser console. A blocked
      `connect-src` is the likeliest first failure, and the template comments
      say what each entry is for.

## Rolling back

`docs/deployment.md` describes health-gated deployment with automatic rollback
to the previous image and route. Nothing here needs a bespoke rollback path;
if the feed is rolled back while the dapp is not, the dapp keeps serving and
shows the last on-chain round with its age, which is the behaviour it was
built for.
