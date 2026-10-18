# Runbook: redeploying LeekStonks on Mezo testnet

**Yes — this is the document for achieving the deployment.** Two files, and
they do different halves:

| File | Who runs it | What it does |
|---|---|---|
| **this one** | you, locally | deploys the contracts to Mezo testnet, records the addresses, verifies them, funds the demo |
| `REDEPLOY-PROMPT.md` | the VPS infra agent | redeploys the hosted dapp and price feed onto the new contracts |

Step 4 below is where you hand the second file over. Neither replaces the
other: the contracts are not on the VPS and the website is not on your
machine.

Every step in order, what it costs, and how to know it worked. Commands marked
**[you]** need your keystore password and must be run by you, not by an agent.

## The one clock that matters

`MAX_STALENESS` is **1 hour**. The deploy script publishes a first round on
both oracles itself, so the dapp works immediately — but if the VPS feed is
not publishing to the **new** oracle addresses within an hour of the deploy,
`price()` reverts on both vaults and the dapp shows an unreadable price. That
is not a failure you can wait out; it needs the feed redeployed.

So: **do not start the deploy until you can finish step 6 in the same
sitting**, or accept a window where the live site is broken.

## What is funded, and what is not

Read live on 2026-10-17:

| Account | Holds | Enough for |
|---|---|---|
| `monad-deployer` `0x9c77…6e45` | **0.08 BTC**, **1798.87 MUSD**, **100 MEZO** | everything below, with large headroom |
| publisher (VPS) `0x7646…949E` | 0.005 BTC | thousands of publishes; one costs ~1e-8 BTC |
| treasurer `0x8439…17fC` | 0.005 BTC | withdrawing fees, if you ever do |

The whole deploy costs about **0.00000001 BTC**. Gas is not the constraint
here and never has been; MUSD is.

**Nothing needs funding before the deploy.** The things that need MUSD come
after it, and the budget is:

| Step | Costs | Leaves |
|---|---|---|
| buy 3 GOLOGGLE shares | ~301.5 MUSD | ~1497 |
| seed the GOLOGGLE/MUSD pool with those 3 shares | 300 MUSD | ~1197 |
| fund the backstop (optional, only if coverage drops) | your choice | — |
| stake MEZO | 0 MUSD, 1–50 MEZO | 50–99 MEZO spare |

## Step 0 — Pre-flight, deploys nothing

**[you]**

```sh
cd /home/oucan/leek-stocks
PUBLISHER=0x76460066A45E72C07e84cd118CB3c6Fc0c8F949E \
GUARDIAN=0x9c77c6fafc1eb0821F1De12972Ef0199C97C6e45 \
TREASURER=0x843914e5BBdbE92296F2c3D895D424301b3517fC \
./scripts/deploy-mezo.sh --checks-only
```

It checks the chain id, the deployer's balance, that the settlement token
reports MUSD/18 **and** that `mintList(BorrowerOperations)` is still true, and
runs the full test suite. It asks for your password to read the keystore
address and nothing else.

Expect: `checks only, nothing deployed`.

`GUARDIAN` and `TREASURER` must differ — the factory refuses one address
holding both, because the guardian can detach staking and the treasurer takes
the fees that then accrue instead. The treasurer is `leek-publisher`'s
address, a keystore you hold.

## Step 1 — Deploy

**[you]** — the clock starts here.

```sh
PUBLISHER=0x76460066A45E72C07e84cd118CB3c6Fc0c8F949E \
GUARDIAN=0x9c77c6fafc1eb0821F1De12972Ef0199C97C6e45 \
TREASURER=0x843914e5BBdbE92296F2c3D895D424301b3517fC \
./scripts/deploy-mezo.sh
```

It prints the four role holders, asks you to type `yes`, prompts once for the
password, and then loops: Mezo answers `eth_getTransactionReceipt` with null
for minutes after a transaction is already in a block, Foundry reads that as
failure and stops, so each `--resume` advances one transaction. **A reported
failure here is usually not one.** The loop handles it; let it run.

The full log is at `/tmp/leekstonks-mezo-deploy.log`.

Expect at the end: ten addresses, and `price of a share
100000000000000000000`. **That last line is the check that matters** — it is
exactly 100, matching the indices' own base. The previous deployment opened at
200 and had to walk down over four rounds, mispricing every share bought in
that window by up to 2×.

The deploy also grants `PUBLISHER_ROLE` to the VPS publisher and renounces it
from the deployer, so `grant-publisher.sh` is **not** needed this time.

## Step 2 — Record the addresses

```sh
./scripts/record-deployment.sh
```

No password; reads the log and the chain. It verifies before writing anything:
code at all eight addresses, each vault bound to its own share and its own
oracle, both settling in the right MUSD, both wired to staking, staking
holding MEZO and paying MUSD, and the two indices not collapsed onto one
oracle or one share token. Then it rewrites every tracked file that carried a
previous address — 88 files scanned, including the five scripts you are about
to run — and **fails** if a dead address survives anywhere.

```sh
git diff --stat
git add -A && git commit -m "Record the Mezo testnet redeployment"
git push origin main
```

The push matters: the infra agent deploys from `origin/main` and reads the
addresses out of the tree.

## Step 3 — Verify the contracts independently

```sh
./scripts/verify-bytecode.sh
```

No key, no explorer, no trust: it compares every deployed contract against a
local build with immutables masked. Anyone can reproduce it.

Then the roles, which bytecode cannot tell you:

```sh
R=https://rpc.test.mezo.org
D=0x9c77c6fafc1eb0821F1De12972Ef0199C97C6e45
P=0x76460066A45E72C07e84cd118CB3c6Fc0c8F949E
PUB=$(cast keccak "PUBLISHER_ROLE")
for O in <GOLOGGLE oracle> <AMEZON oracle>; do
  echo "$O publisher=$(cast call $O "hasRole(bytes32,address)(bool)" $PUB $P --rpc-url $R)" \
       "deployer=$(cast call $O "hasRole(bytes32,address)(bool)" $PUB $D --rpc-url $R)"
done
```

Both oracles must read **publisher=true, deployer=false**. If the deployer can
still publish, the key that deployed can also walk the price — stop and fix it
before the dapp goes live.

## Step 4 — Hand the redeploy prompt to the VPS infra agent

Send `REDEPLOY-PROMPT.md` (in this repo, at the commit you just pushed). It
contains **no addresses on purpose**: the agent reads them from the tree, so a
plain build is the correct build and `check-bundle.mjs` stays the only thing
that can catch a stale one.

**You** do the one secret edit it asks for — replacing `ORACLE_GOLOGGLE` and
`ORACLE_AMEZON` in `/srv/oucan/secrets/projects/leekdefi-feed.env` with the
two values from `ADDRESSES.md`. `PUBLISHER_PRIVATE_KEY` is unchanged and must
not be re-entered.

Feed first, then wait for `onChainRound` to be non-null on both indices, then
the dapp. **This is the step that stops the one-hour clock.**

## Step 5 — Check the live site

```sh
curl -s https://leekdefi.0xoucanproject.xyz/prices | jq '.indices[] | {symbol, onChainAnswer, onChainRound, lastDecision, lastError}'
```

- both indices present, `onChainRound` non-null, `lastError` null
- the two `onChainAnswer` values **differ** — the baskets were re-weighted to
  share no constituents, so identical numbers mean both vaults read one oracle
- `lastDecision` of `hold: Ns since the last round, the oracle requires 30s`
  is normal and expected

In the browser: a **Stake MEZO** panel exists, a share price near 100 not 200,
and the fees panel still says *"Holding a share pays no income."*

## Step 6 — Fund the demo

Only now, and in this order. All **[you]**.

### 6a. Buy shares

```sh
./scripts/buy-shares.sh GOLOGGLE --shares 3            # dry run, prints the quote
./scripts/buy-shares.sh GOLOGGLE --shares 3 --execute
```

~301.5 MUSD for 3 shares at a price of 100 plus the 0.5% fee. The script
grosses the fee up exactly, so you get 3 shares and not 2.985.

### 6b. Seed the pool, once

```sh
./scripts/create-pool.sh GOLOGGLE --shares 3           # dry run
./scripts/create-pool.sh GOLOGGLE --shares 3 --execute
./scripts/verify-pool.sh GOLOGGLE
```

300 MUSD alongside the 3 shares, at the oracle's own ratio. It refuses an
unborrowable MUSD and refuses a ratio that disagrees with the oracle by more
than 100 bps.

**This is team-seeded liquidity and should be described as such.** It is one
account providing both sides at the oracle price. It makes the pair tradeable
and it is not organic depth; say so in the submission rather than letting a
TVL number imply otherwise.

### 6c. Stake MEZO and watch the discount appear

```sh
MEZO=0x7B7c000000000000000000000000000000000001
cast send $MEZO "approve(address,uint256)" <staking> 50000000000000000000 \
  --account monad-deployer --rpc-url https://rpc.test.mezo.org
cast send <staking> "stake(uint256)" 50000000000000000000 \
  --account monad-deployer --rpc-url https://rpc.test.mezo.org
```

50 MEZO is the top tier. Then **wait one hour**: `discountBpsFor` returns 0
during the cooldown and `effectiveFeeBps` stays at 50. That is correct, not a
bug — the discount requires the position to have been *held*, which is what
stops it being rented for a single transaction. After the hour:

```sh
cast call <staking> "discountBpsFor(address)(uint16)" $D --rpc-url $R   # 5000
cast call <vault> "effectiveFeeBps(address)(uint16)" $D --rpc-url $R    # 25
```

Doing this through the dapp is better for a demo: the panel prints the
remaining cooldown and explains it.

### 6d. Generate revenue so the rate has something to measure

Each buy or redeem routes half its fee to stakers. A few trades from the dapp
are enough for `totalDistributed` to be non-zero and for the panel's **observed
rate** to stop saying `not yet` — it needs two minutes of observation *and*
some revenue.

**Label this as team-generated volume.** It is you trading with yourself to
exercise the path.

### 6e. The backstop, only if needed

```sh
cast call <vault> "coverageBps()(uint256)" --rpc-url $R
```

10000 is 100%. It only drops below if the index rises after shares are sold —
that is audit finding H-1 and it is real, not hypothetical. If it does:

```sh
VAULT=<vault> ./scripts/fund-backstop.sh
```

## What this does not cover

- **The AMEZON pool.** Gauges need both tokens whitelisted in `PoolsVoter` and
  an index share is not, so a second pool earns no incentives. One pool
  demonstrates the listing; two cost 300 more MUSD for nothing extra.
- **`ConfigureMezoTestnet.s.sol`**, the two-phase path. Not used here, because
  `ADMIN` is the deployer. It has open audit findings (R4-7) and should not be
  used until they are closed.
