# Redeploy prompt for the infrastructure agent — LeekDefi, round 2

**This file covers the hosting only.** The contracts are deployed separately,
by the operator, following `RUNBOOK-REDEPLOY.md`; by the time you read this
that has already happened and the new addresses are in the repository. If they
are not, step 1 below tells you to stop.

Hand this to the agent that operates `0xOucan/vpsinfra`. **`DEPLOY-BRIEF.md`
beside this file is still the authority** on hostnames, ports, Cloudflare,
registry entries, Caddy templates and the hard rules. This is the delta: what
changed, what has to be re-done, and what must not be touched.

Both units are already registered and already deployed. Nothing in Cloudflare
changes. No new secret is introduced.

## What changed since the running revision

1. **The contracts were redeployed.** New factory, new oracles, new shares,
   new vaults, plus one contract that did not exist before: `LeekStaking`.
   The old addresses are dead — the old vaults still exist on chain and still
   work, so a dapp left pointing at them does not error, it just quietly
   serves a protocol nobody else is using. That is the failure to avoid here.
2. **The dapp gained a staking panel**, which needs two new build args.
3. **The feed needs the two new oracle addresses.** This is the only secrets
   change, and it is the operator's edit, not yours.
4. **The feed's publishing logic changed** in ways that matter operationally:
   it now reads the oracle's `minRoundInterval` and holds instead of sending a
   publish that reverts; it bounds how long it waits for a receipt; and it
   refuses to run two overlapping ticks. One new optional variable,
   `RECEIPT_TIMEOUT_MS`, defaults to 20000 and does not need setting.

## Do not do these

In addition to every hard rule in `DEPLOY-BRIEF.md`:

- **Do not type a contract address into a command.** Every address lives in
  the repository at the revision you deploy: the dapp's in
  `web/deploy/Dockerfile` as `ARG VITE_*` defaults, all of them in
  `ADDRESSES.md`. A plain `docker build` with no `--build-arg` is therefore
  correct, and `web/scripts/check-bundle.mjs` fails the build if the bundle
  is missing one or carries a known-bad MUSD. Passing addresses by hand
  bypasses the only check that would catch a stale one.
- **Do not place or replace `PUBLISHER_PRIVATE_KEY`.** It is unchanged. If you
  find yourself about to write a key anywhere, stop.
- **Do not deploy the dapp before the feed.** With new oracle addresses the
  feed has to publish a first round before the dapp's `price()` reads succeed;
  a dapp deployed first shows an unreadable price for as long as it takes, and
  it reads as a broken deployment.
- **Do not roll both units forward at once.** They roll back independently and
  that is the point.

## Step 1 — Confirm the revision, before anything else

```sh
# [LOCAL or wherever you check the repo out]
git -C <checkout> fetch origin
git -C <checkout> log --oneline -1 origin/main
```

Report the commit hash you are deploying. Then confirm the addresses are
actually in the tree, so a half-recorded redeploy is caught here rather than
in a browser:

```sh
grep -E 'ARG VITE_(VAULT|SHARE|MUSD|STAKING|MEZO)' <checkout>/web/deploy/Dockerfile
```

**Stop and report** if `VITE_STAKING` is empty. That means the deployment was
not recorded (`scripts/record-deployment.sh` was not run) and the dapp would
build with the staking panel silently switched off.

## Step 2 — The feed's secrets (operator, not the agent)

Only two lines change. Everything else in the file stays exactly as it is.

```sh
# [VPS] mode 0600, outside every repository
sudoedit /srv/oucan/secrets/projects/leekdefi-feed.env
```

Replace `ORACLE_GOLOGGLE` and `ORACLE_AMEZON` with the two values from the
`IndexOracle` rows of `ADDRESSES.md` **at the commit from step 1**. Read them
from the file; do not accept them from chat.

Leave `PUBLISHER_PRIVATE_KEY` untouched. It still derives to
`0x76460066A45E72C07e84cd118CB3c6Fc0c8F949E`.

Before deploying, verify that key's rights on the **new** oracles — it had the
role on the old ones and a redeploy does not carry that over:

```sh
# [LOCAL] read-only, no key involved
cast call <new oracle> "hasRole(bytes32,address)(bool)" \
  $(cast keccak "PUBLISHER_ROLE") 0x76460066A45E72C07e84cd118CB3c6Fc0c8F949E \
  --rpc-url https://rpc.test.mezo.org
```

Both oracles must answer `true`. If either answers `false`, **stop** — the
feed will start, fetch prices, and fail every publish with an access-control
revert, which looks like a working service in `/healthz` and a dead feed in
`/prices`. The operator fixes it with `./scripts/grant-publisher.sh` from the
project repository.

## Step 3 — Deploy, feed first, and wait for a round

```sh
# [VPS]
sudo ./scripts/deploy.sh leekdefi-feed --apply
```

Then **wait for the feed to publish a first round on both oracles** before
touching the dapp:

```sh
curl -s https://leekdefi-feed.0xoucanproject.xyz/healthz
# and, from the dapp's origin once it is up, or from a local checkout:
curl -s https://leekdefi.0xoucanproject.xyz/prices | jq '.indices[] | {symbol, onChainRound, lastDecision, lastError}'
```

`onChainRound` must be non-null for **both** indices. A `lastDecision` of
`hold: Ns since the last round, the oracle requires 30s` is normal and
expected — the oracles enforce a 30-second minimum between rounds and the feed
now knows that. A `lastError` is not normal; report its text verbatim.

```sh
# [VPS]
sudo ./scripts/deploy.sh leekdefi --apply
```

## Step 4 — Verify, and report each line individually

Every check from `DEPLOY-BRIEF.md` step 6 still applies and still has to be
reported one line at a time. These are the additional ones for this round:

- [ ] The page shows a **"Stake MEZO"** panel. If it is absent, the build did
      not receive `VITE_STAKING` and step 1's grep was not done.
- [ ] That panel shows a **Total staked** and a **Revenue to stakers** figure
      rather than "The staking contract is not answering on this chain."
- [ ] Its **Observed rate** reads `not yet` with a reason beside it on a fresh
      page. That is correct: the rate needs two minutes of observation and
      some fee revenue, and a number appearing instantly would be the bug.
- [ ] The **share price is near 100**, not near 200. The previous deployment
      opened its feed at twice the index's own base and had to walk down over
      four rounds; if you see a price near 200 the wrong revision shipped.
- [ ] `/prices` reports **both** indices with **different** values. The two
      baskets were re-weighted to share no constituents, so identical numbers
      mean both vaults are reading one oracle.
- [ ] The fees panel still contains the sentence **"Holding a share pays no
      income."** It is a deliberate disclosure, not boilerplate, and a build
      that lost it is a build that misrepresents the product.
- [ ] `curl --max-time 5 http://<origin ip>:8080` and `:8787` both still fail.

Report the commit hash, the two oracle addresses you configured (public, safe
to report), and each check above as its own line. "Redeployed successfully" is
not a result.

## If something is wrong

Roll the **dapp** back first and leave the feed running: the feed publishing
to new oracles is harmless on its own, and a dapp pointed at the wrong vaults
is the thing that misleads a visitor. `DEPLOYMENT.md` has the procedure.
