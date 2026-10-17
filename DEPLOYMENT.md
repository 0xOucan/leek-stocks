# Deploying LeekDefi

**LeekDefi** is the host: one front end serving **LeekStonks** (the index
market, this repository) and later **Leeknding** (the lending market, in
`leek-lend`).

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
2. **Audit the history and make the repository public** (3a) — vpsinfra clones
   it, and both registry entries say `github-public`.
3. **A publisher key that holds `PUBLISHER_ROLE` and nothing else** (3b).
4. **The feed's secrets file** at `/srv/oucan/secrets/projects/leekdefi-feed.env`,
   mode 0600, holding that key (4).
5. The dapp's build arguments, which are Dockerfile defaults today (4b).
6. Both deployments, feed first (5), then the verification list (6).

### Hard gates

Each of these has exactly one failure mode and it is silent. Tick them, do not
assume them.

- [ ] `git check-ignore -v feed/.env web/.env` prints **both** paths. Silence
      means a private key is about to be published.
- [ ] The key in `/srv/oucan/secrets/projects/leekdefi-feed.env` is **not** the
      deployer key. The deployer holds admin, guardian and treasurer on every
      contract; a compromised server holding it could pause the feed, move the
      fees and reconfigure the vaults. A publisher key can only push a price
      inside an immutable per-round bound.
      Verify with `hasRole`, not from memory:
      ```sh
      ORACLE=0x7fCb1ed8d6fAaEF00AA5A0104A062299ab7D5BF6
      PUB=0x76460066A45E72C07e84cd118CB3c6Fc0c8F949E   # production publisher
      cast call $ORACLE "hasRole(bytes32,address)(bool)" $(cast keccak "PUBLISHER_ROLE") \
        $PUB --rpc-url https://rpc.test.mezo.org   # must be true
      cast call $ORACLE "hasRole(bytes32,address)(bool)" $(cast keccak "DEFAULT_ADMIN_ROLE") \
        $PUB --rpc-url https://rpc.test.mezo.org   # must be false
      ```
- [ ] That secrets file is `0600` and outside every repository:
      `stat -c '%a %U %n' /srv/oucan/secrets/projects/leekdefi-feed.env`.
- [ ] The publisher holds only gas. `sweep-publisher.sh` moves the rest home.
- [ ] `npm run build` in `web/` ends with `check-bundle: ok`. It fails the
      build if a contract address is missing or an impostor MUSD is baked in,
      which is what a forgotten build arg produces (4b).
- [ ] Neither container port answers at the origin IP:
      `curl --max-time 5 http://<origin ip>:8080` and `:8787` must both fail.

## 1. Contracts

Pre-flight, in order, each one a gate rather than a suggestion:

- [ ] `forge test` green, including `test/fork/*` against live MUSD.
- [ ] `slither . --filter-paths "lib|test|script"` with no unaddressed high or
      medium finding.
- [ ] The deployer address funded with **test BTC** — Mezo's gas token is BTC,
      not ether, so a balance of "ETH" is not a thing on this chain.
- [ ] **Which MUSD.** Two live tokens on Mezo testnet answer to that symbol
      and only one is borrowable. See ADDRESSES.md: settle in `0xf9BBcC…`, and
      re-run the `mintList` check that proves it, because a redeployment on
      Mezo's side moves the answer.
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

# [LOCAL] Verify the sources. Found by probing on 2026-10-17: the API is NOT
# on the explorer host. explorer.test.mezo.org returns a Blockscout 404 page
# for every API path; api.explorer.test.mezo.org answers, which is where
# --verifier-url must point. Proved by reading MUSD's own verified source back
# through it. No Etherscan API key is involved: Blockscout needs none, so
# there is nothing here to keep secret.
forge verify-contract <address> src/IndexOracle.sol:IndexOracle   --chain-id 31611   --verifier blockscout   --verifier-url https://api.explorer.test.mezo.org/api   --watch
```

Verification is better folded into the deploy itself, because an unverified
contract is one nobody can audit from the explorer:

```sh
forge script script/DeployMezoTestnet.s.sol \
  --rpc-url mezo_testnet --account monad-deployer --sender <address> \
  --broadcast --verify --verifier blockscout \
  --verifier-url https://api.explorer.test.mezo.org/api
```

If verification fails mid-run the deployment still happened: re-run
`forge verify-contract` per address rather than redeploying.

Then confirm the first oracle round published — the script does it in the same
reviewed step, so a feed's first answer is never the unbounded one (finding
L-1) — and that `vaultFor` resolves for both symbols.

**On keys, and a deliberate divergence.** The ethskills tools guide's own
example passes `--private-key` on the command line. We do not: a command line
is visible in `ps` to every user on the machine and lands in shell history, so
every invocation here uses `--account` and types the password into a prompt.
The guide is right about the toolchain and wrong about that one habit.

### Mezo is Cosmos underneath, and it changes how a deploy must be sent

`mezod` is a fork of Evmos, so Mezo is an EVM on top of Cosmos. One
consequence breaks a normal Foundry deployment and is worth knowing before it
costs an afternoon:

**Transactions must be sent one at a time.** Foundry's broadcast pipelines by
default — it signs several transactions with consecutive nonces and sends them
together, which an Ethereum mempool queues by nonce. Cosmos checks the account
*sequence* when a transaction arrives, so one that turns up with sequence 1
while the account sits at 0 is **rejected**, not queued:

```
error code -32000: invalid nonce; got 1, expected 0: invalid sequence
```

`--slow` is the fix, and `scripts/deploy-mezo.sh` passes it.

**And receipts arrive late.** With `--slow`, the next failure was
`Failure on receiving a receipt ... server returned a null response`. That was
not a failure either: the transaction was in block 16203095 with status 1 and
its contract is on chain. Mezo's RPC answers `eth_getTransactionReceipt` with
null for a short window after a transaction has already been included, and
Foundry treats the null as fatal. Hence `--timeout 300`, and
`./scripts/deploy-mezo.sh --resume` to continue a broadcast that stopped this
way rather than starting again and orphaning what landed.

**Check before you re-run, every time:** `cast receipt <hash>` and `cast nonce
<deployer>`. A deploy on this chain can report failure and have succeeded. The first attempt
here was made without it: one contract landed, the rest were refused, and the
addresses printed in that run's log were simulation's predictions rather than
anything that exists. **Record addresses only from a log that completed.** An
orphaned contract from a failed attempt is harmless — gas on Mezo is measured
in hundreds of wei — but a recorded address that holds no contract is not.

**And the gas estimate is not a usable gas limit.** Mezo enforces the EIP-7623
calldata floor, but `eth_estimateGas` does not apply that floor, so a
transaction built from the node's own estimate is refused by the same node:

```
failed to verify the fees: gas limit below EIP-7623 floor:
  21240 (gas limit) < 21600 (floor data gas): out of gas
```

The floor is `21000 + 10 * tokens`, where a zero calldata byte counts as one
token and a non-zero byte as four. So the floor depends on how many zero bytes
the ABI-encoded arguments contain, and whether a call is refused depends on
**the digits of the number being sent**. This surfaced in the feed: in one
cycle the AMEZON oracle published at 115.20 while GOLOGGLE was refused at
128.00, same contract, same ABI, same key. That is the dangerous shape of this
bug — an intermittent fee error looks like a flaky RPC and invites a retry
loop, which can never succeed, rather than a gas limit.

The fix is to compute the floor and send `max(estimate, floor)` with a margin.
`eip7623FloorGas()` in `feed/src/service.ts` does this, and a test pins it
against the exact 21600 that Mezo reported. Foundry deployments have not hit
it, because contract-creation calldata is large enough that the estimate
already exceeds the floor; it bites small calls with mostly-zero arguments,
which is exactly what an oracle publish is.

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

Both registry entries say `SOURCE_TYPE=github-public`, so **no deploy key is
needed**: vpsinfra clones over HTTPS. That is only true while the repository
actually is public — read the next section before making it so, and if it ever
goes private again, both entries must go back to `github-private` and each
needs a read-only deploy key (step 6 of `docs/adding-projects.md`).

## 3a. Before this repository goes public

The Buildathon requires a public GitHub repository, and this one holds a
deployment runbook. Audited on 2026-10-17 across **every commit on every
branch**, not just the tip:

```sh
# [LOCAL] the whole history, not the working tree
git log --all --name-only -- '*.env'        # which .env files were ever committed

# Key-shaped strings in every commit. Looped, NOT
# `git grep ... $(git rev-list --all)`: past a few dozen commits that form
# exceeds the argument limit and the command prints NOTHING AT ALL, which
# reads exactly like a clean result. It did, here, at 67 commits - after
# having worked at 60. An audit that fails silently is worse than no audit.
git rev-list --all | while read c; do
  git grep -hoE '0x[0-9a-fA-F]{64}' "$c" -- . 2>/dev/null
done | sort -u

git rev-list --all | while read c; do
  git grep -hoIiE '(PASSWORD|SECRET|TOKEN|PRIVATE_KEY)=["'"'"']?[A-Za-z0-9+/_-]{12,}' "$c" -- . 2>/dev/null
done | sort -u
```

Sanity-check any "clean" result before believing it: `git grep -nE
'0x[0-9a-fA-F]{64}' HEAD -- .` must find the two known strings below. If it
finds nothing, the command is broken, not the history.

**Result on 2026-10-17 at `72de950`, 67 commits, all branches:** exactly two
64-hex strings exist in the entire history, both below. Nothing else.

What it found, and why each is fine:

| Hit | Verdict |
|---|---|
| `feed/.env.example` → `PUBLISHER_PRIVATE_KEY=0x000…000` | a 32-byte zero placeholder |
| `scripts/local-up.sh` → `0xac0974be…f2ff80` | **Anvil account 0**, a key published in Foundry's own documentation and already annotated as such. Worthless by design; do not "fix" it |
| `web/deploy/leekdefi.env`, `feed/deploy/leekdefi-feed.env` | registry entries. No secrets: hostnames, ports, limits, and a WalletConnect project id, which is a public client identifier |

Zero hits for PEM private keys, mnemonics, seed phrases, Cloudflare API
tokens, Tailscale auth keys (`tskey-`), GitHub tokens (`ghp_`,
`github_pat_`), Etherscan keys and keystore ciphertext. The ~190 matches for
"password" are all prompt plumbing — `read -rsp`, `--password-file`,
`PASSFILE` — and none is a password value.

**Two files hold real secrets and neither is tracked**, which `.gitignore`
asserts and `git check-ignore` proves rather than assumes:

```sh
# [LOCAL] must print both paths; silence means a secret is about to be published
git check-ignore -v feed/.env web/.env
```

- `feed/.env` — the publisher private key. Written by
  `scripts/feed-env.sh`, which refuses to write it unless the path is already
  git-ignored, creates it 0600 before anything goes into it, and never puts
  the key in an argument or a log.
- `web/.env` — no secret, but local build values that should not shadow the
  Dockerfile's.

Re-run the three commands above before flipping the repository to public.
The audit is cheap; a leaked publisher key is a key rotation and a redeploy.

## 3b. A key for the feed, and only for the feed

The deploy put all four roles on one key, which the script warns about and
which is fine for getting a testnet up. It is **not** fine for the feed: that
process signs continuously, so its key has to sit in a file on a server, and
the deployer key holds admin, guardian and treasurer on everything deployed. A
compromised server would then be able to pause the feed, move the fees and
reconfigure the vaults, rather than only push prices inside an immutable
per-round bound — which is all `PUBLISHER_ROLE` can do.

**Done on 2026-10-17.** The production publisher is
`0x76460066A45E72C07e84cd118CB3c6Fc0c8F949E`, granted on both oracles and
funded with 0.005 BTC. `leek-publisher`
(`0x843914e5BBdbE92296F2c3D895D424301b3517fC`) keeps the role for local
rehearsals: one key per location, so a compromised workstation reaches nothing
in production. Both are publisher-only. For a future one:

```sh
cast wallet new                                      # [LOCAL] a key for this and nothing else
./scripts/grant-publisher.sh 0xTheNewAddress         # grant it the role
./scripts/grant-publisher.sh 0xTheNewAddress --revoke-deployer
cast send 0xTheNewAddress --value 0.005ether --rpc-url https://rpc.test.mezo.org \
  --account monad-deployer --async                   # gas: ~130 wei a unit here
```

`--async` on that last line is not optional comfort. Without it `cast send`
waits for a receipt, Mezo answers `eth_getTransactionReceipt` with null for
minutes after inclusion, and it prints `Error: server returned a null response
when a non-null response was expected` for a transfer that landed. Confirm
with `cast balance`, not with the exit code.

`--revoke-deployer` drops the deployer's own publisher rights. It keeps
`DEFAULT_ADMIN_ROLE`, so it can always grant them back; what it loses is the
ability to move a price quietly, which is the point.

The grant is confirmed by **reading `hasRole` until it answers true**, not by
waiting for a receipt, for the reason in the previous section: a receipt here
can be minutes late and `cast send` reports a failure that did not happen.

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

## 4b. The dapp's build arguments, and why they are not in the registry

Vite inlines every `VITE_*` value **at build time**, so these are properties
of the image, not of the running container, and changing one means a rebuild.
Nothing secret may be among them: they are all readable in the shipped
JavaScript.

Nothing in `leekdefi.env` passes them, and nothing in vpsinfra's deploy script
does either — so **the defaults in `web/deploy/Dockerfile` are what ships**.
Those defaults were placeholders until 2026-10-17: empty vault and share
addresses and `VITE_MUSD` pointing at `0x118917a4…`, the MUSD the vaults
reject. A deploy would have succeeded and served a dapp rendering "No contract
addresses are configured in this build". They are now the live deployment.

Two consequences worth holding on to:

- **After any contract redeploy, the Dockerfile defaults must change too**, or
  the site keeps serving the old addresses. It is the second place addresses
  live; `ADDRESSES.md` is the first.
- `npm run build` ends in `scripts/check-bundle.mjs`, which reads the built
  bundle and fails if an address the app needs is absent or if any of the four
  impostor MUSD contracts is present. Verified by building with the old
  placeholders: six problems, exit 1. It skips itself when `VITE_CHAIN_ID` is
  not 31611, so a rehearsal build against Anvil is not blocked by it.

To override one without editing the Dockerfile:

```sh
# [VPS] if vpsinfra grows a build-args field, this is what belongs in it
--build-arg VITE_MUSD=0x... --build-arg VITE_VAULT_GOLOGGLE=0x...
```

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
      "LeekStonks — LeekDefi".
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
- [ ] **The onboarding panel, end to end, from an empty wallet.** Claim BTC at
      `faucet.test.mezo.org`, borrow MUSD in the page, approve, buy, redeem.
      Each of those write paths is simulated in CI and in `cast`, and a wallet
      signing them through the browser is a different thing from a simulation.
- [ ] The wordmark renders in Space Grotesk, not the system sans. Its two
      woff2 files were missing from `public/fonts` until 2026-10-17 and the
      only symptom was a silent fallback; `test/assets.test.ts` now fails if a
      declared font is absent.
- [ ] No mixed-content or CSP violations in the browser console. A blocked
      `connect-src` is the likeliest first failure, and the template comments
      say what each entry is for.

## Rolling back

`docs/deployment.md` describes health-gated deployment with automatic rollback
to the previous image and route. Nothing here needs a bespoke rollback path;
if the feed is rolled back while the dapp is not, the dapp keeps serving and
shows the last on-chain round with its age, which is the behaviour it was
built for.
