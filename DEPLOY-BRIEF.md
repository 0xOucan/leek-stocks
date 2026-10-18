# Brief for the infrastructure agent: deploying LeekDefi

Hand this to the agent that operates `0xOucan/vpsinfra`. It is written to be
the agent's whole context: what to deploy, what not to touch, and how to know
it worked. `DEPLOYMENT.md` beside this file is the long form with the
reasoning; this is the executable part.

## What you are deploying

**Two deployment units on one hostname.** They are separate because they fail
separately: a feed that cannot reach its price source must not take the dapp's
static assets down with it.

| Unit | Project | Type | Port | Hostname |
|---|---|---|---|---|
| The dapp | `leekdefi` | static (Caddy file-server) | 8080 | `leekdefi.0xoucanproject.xyz` |
| The price feed | `leekdefi-feed` | node | 8787 | `leekdefi-feed.0xoucanproject.xyz` |

The zone is **`0xoucanproject.xyz`**. Not `oucanproject.xyz` — that is a
different name and will produce a certificate for a host nobody visits.

The browser never calls the feed's hostname. The dapp fetches `/prices` on its
**own** origin and Caddy proxies that one path to the feed container over the
internal Docker network. That is deliberate: it keeps the dapp's
`connect-src` at `'self'` for prices instead of adding an origin to the
Content-Security-Policy. The feed's hostname exists only because vpsinfra's
deploy gate validates a health path over HTTP, and it answers nothing but
`/healthz`.

Source repository: `https://github.com/0xOucan/leek-stocks.git`, branch
`main`, **public**. Both registry entries say `SOURCE_TYPE=github-public`, so
no read-only deploy key is needed. If the repository is still private when you
start, **stop and say so** rather than switching it to `github-private`
yourself: the publication is gated on a secret audit the operator performs.

## Hard rules

1. **Never accept a private key in chat, in a command line, or in a file you
   write.** The feed needs one and the operator places it themselves. If you
   are handed a key, refuse it and ask for it to be put directly in the
   secrets file. A key in a command line is visible in `ps` and lands in shell
   history.
2. **Do not commit anything to vpsinfra that contains a secret.** The registry
   entries carry hostnames, ports and limits. Nothing else.
3. **Do not publish the origin.** Proxied `CNAME` records only, no `AAAA`, and
   no `origin`/`server`/`ssh` records pointing at the VPS.
4. **Do not change the contract addresses.** They are compiled into the dapp's
   image from defaults in `web/deploy/Dockerfile` and the build fails if they
   are wrong (see step 4).

## Step 1 — Cloudflare

For **both** hostnames, `leekdefi` and `leekdefi-feed`:

- DNS → **proxied** `CNAME` to `0xoucanproject.xyz`. Proxied, not DNS-only:
  DNS-only publishes the origin address.
- No `AAAA` record.
- SSL/TLS mode as the other projects on this zone use it. Caddy terminates TLS
  at the origin, so a mode that bypasses origin TLS downgrades the hop
  Cloudflare cannot see.

No API token is involved.

## Step 2 — Register both projects

Generate each entry with vpsinfra's own script rather than copying a file:

```sh
# [LOCAL or the VPS infrastructure checkout]
./scripts/add-project.sh --name leekdefi \
  --hostname leekdefi.0xoucanproject.xyz \
  --source github-public \
  --repository https://github.com/0xOucan/leek-stocks.git \
  --app-type static --port 8080 --database none --apply

./scripts/add-project.sh --name leekdefi-feed \
  --hostname leekdefi-feed.0xoucanproject.xyz \
  --source github-public \
  --repository https://github.com/0xOucan/leek-stocks.git \
  --app-type node --port 8787 --database none --apply
```

Then **diff each generated `projects/<name>.env` against the reference entry
in this repository** and carry over the fields the script does not ask for.
Those references are:

- `web/deploy/leekdefi.env`
- `feed/deploy/leekdefi-feed.env`

The fields that matter and that `add-project.sh` will not have set:

| Field | `leekdefi` | `leekdefi-feed` |
|---|---|---|
| `DOCKERFILE` | `web/deploy/Dockerfile` | `feed/deploy/Dockerfile` |
| `BUILD_CONTEXT` | `.` | `.` |
| `HEALTH_PATH` | `/` | `/healthz` |
| `CADDY_TEMPLATE` | `projects/leekdefi.caddy.tmpl` | `projects/leekdefi-feed.caddy.tmpl` |
| `READ_ONLY` | `true` | `true` |
| `MEMORY_LIMIT` | `128m` | `192m` |
| `CPU_LIMIT` | `0.50` | `0.50` |
| `BRANCH` | `main` | `main` |

`BUILD_CONTEXT=.` is the repository root for both, because each Dockerfile
copies from `web/` or `feed/` and needs the parent as its context.

`HEALTH_PATH=/` for the dapp and **not** `/prices`: `/prices` is proxied to
the feed container, so health-checking it would report the feed's health as
the dapp's.

## Step 3 — Caddy templates

Copy both into `projects/` under exactly the names the registry entries
reference:

```sh
cp <leek-stocks>/web/deploy/leekdefi.caddy.tmpl        projects/leekdefi.caddy.tmpl
cp <leek-stocks>/feed/deploy/leekdefi-feed.caddy.tmpl  projects/leekdefi-feed.caddy.tmpl
```

`{{UPSTREAM}}` is substituted with `oucan-<project>`, which is why the dapp's
template can name `oucan-leekdefi-feed:8787` directly for its `/prices` route.

**Do not simplify either template.** The dapp's `Content-Security-Policy` was
derived directive by directive from what the code actually calls, and every
entry has a comment saying why it is there. In particular
`style-src-attr 'unsafe-inline'` is required by WalletConnect's Lit-based
modal and is deliberately scoped to attributes so an injected `<style>` block
is still refused. Removing it gives a visibly broken wallet modal.

## Step 4 — The feed's secrets (operator, not the agent)

```sh
# [VPS] mode 0600, outside every repository
sudoedit /srv/oucan/secrets/projects/leekdefi-feed.env
```

Contents are documented in `feed/.env.example`. The values that matter:

```
PUBLISHER_PRIVATE_KEY=0x…      # placed by the operator, never by the agent
                               # derives to 0x76460066A45E72C07e84cd118CB3c6Fc0c8F949E
ORACLE_GOLOGGLE=0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
ORACLE_AMEZON=0xa513E6E4b8f2a923D98304ec87F64353C4D5C853
RPC_URL=https://rpc.test.mezo.org
CHAIN_ID=31611
INTERVAL_SECONDS=60
HEARTBEAT_SECONDS=1800
THRESHOLD_BPS=50
HTTP_PORT=8787
SYNTHETIC=0
```

Load it into the container as an environment file, following
`docs/adding-projects.md` for however this platform does that. **The
environment must win over any `.env` in the image**, which the feed's own
loader guarantees: `feed/src/main.ts` skips any key already present in
`process.env`.

The key must hold `PUBLISHER_ROLE` **and nothing else**. Verify before
deploying, in both directions:

```sh
R=https://rpc.test.mezo.org
ORACLE=0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
PUB=0x76460066A45E72C07e84cd118CB3c6Fc0c8F949E   # the production publisher
cast call $ORACLE "hasRole(bytes32,address)(bool)" $(cast keccak "PUBLISHER_ROLE") \
  $PUB --rpc-url $R      # must be true
cast call $ORACLE "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  $PUB --rpc-url $R      # must be FALSE
```

OpenZeppelin defines `DEFAULT_ADMIN_ROLE` as `bytes32(0)`. Do not hash its
name: that tests a different role and can produce a false sense of safety.

A `true` on the second line means the deployer key is about to sit on a server
that signs all day, able to pause the feed, move the fees and reconfigure the
vaults. Stop and tell the operator.

The dapp needs **no secrets at all**. Every `VITE_*` value is public by
construction and baked in at image build time from the Dockerfile's defaults.
`npm run build` ends with `scripts/check-bundle.mjs`, which fails the build if
a contract address is missing or if any of the four impostor MUSD contracts on
Mezo testnet is baked in instead of the real one. If the dapp's build fails
with `check-bundle: refusing this build`, that is the guard working: read what
it names, do not pass `--build-arg` to silence it.

## Step 5 — Deploy, feed first

```sh
# [VPS]
sudo ./scripts/deploy.sh leekdefi-feed --apply
sudo ./scripts/deploy.sh leekdefi --apply
```

Feed first only so the dapp's first paint has prices. Neither depends on the
other to start.

## Step 6 — Verify, and report each line

- [ ] `https://leekdefi.0xoucanproject.xyz` loads over HTTPS; the tab reads
      **LeekStonks — LeekDefi**.
- [ ] `https://leekdefi.0xoucanproject.xyz/prices` returns JSON with two
      indices. **This is the check that is easy to get wrong** — it proves the
      internal proxy works.
- [ ] `https://leekdefi-feed.0xoucanproject.xyz/healthz` returns
      `{"ok":true}`, and **every other path on that host returns 404**.
- [ ] `curl --max-time 5 http://<origin ip>:8080` and `:8787` both **fail**.
      This is the one check that catches a container published to the host by
      accident.
- [ ] The browser console shows **no CSP violation**. A blocked `connect-src`
      is the likeliest first failure; the template's comments say what each
      entry is for.
- [ ] The page shows a price with an origin label. A label reading
      `synthetic` means the feed's source was unreachable and it is publishing
      its deterministic series — correct behaviour, loudly labelled, but worth
      reporting.
- [ ] A wallet connects and the network switch offers **BTC** as the gas
      token, not ether. Mezo charges gas in BTC and a page saying otherwise
      sends people to top up the wrong asset.

Report the six checks individually. "Deployed successfully" is not a result.

## Rolling back

`DEPLOYMENT.md` has the procedure. Each unit rolls back independently, which
is the reason there are two.
