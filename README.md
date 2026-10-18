# leek-stocks — LeekStonks

Parody index tokens, settled in **MUSD** on Mezo, with an oracle you can read
and a signing path that ends on hardware.

**The names.** **LeekDefi** is the whole thing, at
`leekdefi.0xoucanproject.xyz`: one host, one front end, two products.
**LeekStonks** is this repository — the index market. **Leeknding** is the
lending market, in `leek-lend`, written and tested and not yet deployed. The
wallet that signs for all of it is **LeekWallet**.

Built for the **Mezo Buildathon** (AKINDO), Wave 1, Track 1. The wallet that
signs it is [LeekWallet](https://github.com/0xOucan/LeekWallet) — Track 2,
which now carries a **LeekDefi mini-app** that reads these same contracts and
four decoder rows so the device draws a `buy` itself, page by page. The lending
market that borrows against these shares will live in `leek-lend`.

## Where this is, today

**Live on Mezo testnet (31611), redeployed 2026-10-18.** Eight contracts,
settling in the MUSD Mezo's own borrow system mints, so MUSD obtained by
borrowing against BTC can be spent here. Addresses, the live state when
recorded, and both keys and what each can do are in
[ADDRESSES.md](ADDRESSES.md).

The front end and the price feed are **deployed** at
[leekdefi.0xoucanproject.xyz](https://leekdefi.0xoucanproject.xyz), both
oracles publishing, with the deploying key's `PUBLISHER_ROLE` renounced on
both — so the key that deployed cannot walk the price.

**Two things about the demo state, said here rather than implied by a number.**
The GOLOGGLE/MUSD pool is **one account providing both sides** at the oracle
price: it makes the pair tradeable and it is not organic depth. The trades that
produced the staking revenue are **team-generated**, made to exercise the path.

| Piece | State |
|---|---|
| Contracts | **deployed and verified** on Mezo testnet; three verified on the explorer, all seven against the source (`./scripts/verify-bytecode.sh`) |
| Roles | split: a publisher key that can only publish, a deployer key that can do everything but publish |
| Price feed | **deployed**; both oracles publishing, `lastError` null, a round every 30s when the price moves 50 bps |
| Front end | **deployed**; a full buy -> redeem round trip completed on chain; onboarding, the faucet link, native borrowing and the MEZO staking panel are in the page |
| Leeknding (lending) | written, 95 tests, 8 invariants, **not deployed** — `leek-lend` |
| Air-gapped signing | the wallet draws Mezo transactions in BTC, and `buy`, `redeem`, `stake` and `unstake` field by field from its own decoder; **no byte has been flashed to a board yet**, so no screen has drawn one |

> **Trying this?** [WALKTHROUGH.md](WALKTHROUGH.md) is the step-by-step, plus
> the things that are awkward on this chain rather than broken — late
> receipts, a single-digit repay ceiling, and why closing a position can be
> refused for a few MUSD.

## The flow a tester follows

All of it from the page, with no scripts and nothing from me. The front end
works out which step the wallet is on from chain state and offers only that
one, so arriving half-way through — which is every reload — lands in the right
place.

1. **Connect a wallet.** EIP-6963 or WalletConnect.
2. **Switch to Mezo Testnet.** The button adds the chain if the wallet does
   not have it.
3. **Claim test BTC** from [faucet.test.mezo.org](https://faucet.test.mezo.org).
   Gas on Mezo is BTC, not ether, and the same BTC is the collateral for the
   next step. The faucet is a hosted form with a captcha, so the page links to
   it rather than pretending to call it.
4. **Borrow MUSD against that BTC**, in the page, through Mezo's own
   `BorrowerOperations`. We mint no MUSD and this is not our market: it is a
   loan, the BTC is locked until it is repaid, and the page says so above and
   below the button. The minimum is 1800 MUSD, the protocol's own
   `minNetDebt`, and the debt comes out 200 MUSD higher than the borrow
   because of the liquidation gas reserve — which the quote states as its own
   line, because it is the number that surprises people.
5. **Approve, then buy** index shares.
6. **Redeem** back to MUSD whenever, at the oracle price, less the same fee.

**Repaying, borrowing more and closing** are in the page too, on the same
panel, once a position exists. The limits are the protocol's and each was
simulated against the live contract before it was written down: a partial
repayment cannot take the net debt under `minNetDebt`, closing needs the whole
net debt in the wallet, and borrowing more is capped at 150% rather than the
chain's 110%. ADDRESSES.md has the simulated boundaries and the exact revert
strings. Repaying needs no approval — `BorrowerOperations` burns MUSD directly.

The collateral ratio the page will open is **150%**, not the protocol's 110%
minimum: a position opened at exactly MCR is liquidatable on the next tick of
the price feed. `web/src/lib/borrow.ts` holds that arithmetic and
`web/test/borrow.test.ts` checks it against a `getCurrentICR` reading taken
from the live chain.

## What this is, plainly

- **Parody indices.** `Gologgle`, `Amezon`. They are **not** tokenised shares
  of any real company, they are **not** backed by anything, and they track an
  index this project's own oracle publishes. Testnet only.
- **MUSD settlement.** Shares are priced and bought in MUSD, at
  `0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af` on Mezo testnet. Mezo testnet
  has **two** contracts reporting MUSD with 18 decimals; this is the one
  `BorrowerOperations` can mint, which makes it the only one a user can
  actually obtain by borrowing against BTC. This file named the other one
  until 2026-10-17 — see ADDRESSES.md for the `mintList` evidence, and read
  it from the vault (`cast call <vault> "musd()(address)"`) rather than from
  any document, including this one.
- **An oracle whose trust model is written down**, below, rather than implied.

## Trust model

**The oracle is a single operator.** An off-chain service holding
`PUBLISHER_ROLE` pushes prices; anyone relying on the feed is relying on that
operator. Nothing on chain changes that. What the contract does is bound the
damage one bad round can do:

| Guard | Effect |
|---|---|
| `maxDeviationBps`, immutable | a push further than this from the last answer reverts |
| `minRoundInterval`, immutable | 30s between rounds, so the per-round bound becomes a bound per unit of time rather than per transaction |
| `maxWindowDeviationBps` over `deviationWindow`, both immutable | **total** movement from an anchor, 20% per hour. The per-round bound limits one step; this limits a sequence of them |
| `MIN_ANSWER` and `MAX_ANSWER` | the answer range is bounded on both sides, so no mistyped value can brick the feed or pin it at dust |
| `maxStaleness` | consumers must refuse an answer older than this; `updatedAt` is the publication time and no read touches it |
| Positive-answer check | a zero or negative price is refused at publication |
| Separated roles | publishing, pausing and administration are three roles; the publisher cannot pause and the guardian cannot publish |
| Monotonic rounds | ids increase by one, and history is immutable once written |

### Why the cumulative bound exists, with the numbers

A per-round bound alone is a **ratchet**, and it is worth stating how fast it
turns because that is what decides whether a guardian is real. At 20% a round
and 30 seconds a round, a compromised publisher takes the price from 100 to
over 200 in **four rounds — 120 seconds** — and every one of those publishes
is individually legal, so there is no oversized step to catch.
`maxStaleness` is an hour and gives no brake at all: nothing goes stale while
the walk is happening, because the walk *is* fresh publishes.

With the window bound, the same walk takes **11,010 seconds**, a little over
three hours. That figure is measured by `test/Ratchet.t.sol` rather than
reasoned about. The honest limit: the window is fixed rather than sliding, so
the budget can be spent at the end of one window and the next budget
immediately after it rolls — twice the budget in a short span, at a boundary,
once, which is asserted directly in that test. Every step after costs a
further window.

The guardian should be a multisig, and the admin should not be the publisher.
A single key that can freeze a feed is a censorship risk, and saying so is part
of the design rather than a disclaimer.

## Contracts

| Contract | Does |
|---|---|
| `IndexOracle` | one index's price, as a Chainlink `AggregatorV3` feed: push-only, role-separated, bounded per round, pausable |
| `ETFFactory` | `registerIndex` freezes a symbol's configuration; `deployETF(string name, string symbol)` deploys its share and vault |
| `ETFShare` | the share token: ERC-20 with permit, mint and burn held only by its vault |
| `IssuanceVault` | buy and redeem shares against MUSD at the oracle price, with fees, a cap, a backstop and a guardian |

### Why `deployETF` takes two strings and nothing else

LeekWallet draws a transaction on a 128x64 screen and refuses what it cannot
draw. Its predecessor on Hedera failed that test: an issuance call carrying a
seventeen-field struct came to 3,748 bytes against a 768-byte limit, and a
screen reading "deploy equity, approve?" over 3.7 KB nobody can read is blind
signing with better manners. So everything that does not vary — the settlement
token, the feed, the fee, the cap, the three role holders — is frozen in
registry state by `registerIndex`, and the only values in the calldata are the
two a human actually decides.

### What this is not

**It is not solvent if the index rises.** A share is priced from an index the
vault does not hold, so the MUSD paid in by buyers can be less than the MUSD
owed to redeemers. The contract bounds that rather than hiding it: redemption
**reverts** naming what is owed and what is available, total shares are
**capped**, `reserves()` and `liabilities()` are public so the gap is visible
before anyone commits, and anyone may `fund()` the backstop. It is a testnet
demonstration of issuance, pricing and hardware-confirmed signing. It is not a
fund, and nobody should put money in it. See
[audit/AUDIT-REPORT.md](audit/AUDIT-REPORT.md), finding H-1.

## Fees, revenue and what a share does not pay

The protocol charges a fee on both sides of issuance and splits it. Every
number here is a getter, so the dapp reads them rather than repeating them:

| Getter | Live on Mezo testnet | What it is |
|---|---|---|
| `feeBps()` | 50 | 0.5% on `buy` and on `redeem`, taken from the undivided product so the split does not compound the fee's own truncation |
| `reserveShareBps()` | 5000 | the share of each fee that **stays in the vault** as backing |
| `feesAccrued()` | 1.1366 MUSD | protocol revenue to date, held **outside** `reserves()` and withdrawable only by `TREASURER_ROLE` |
| `MAX_FEE_BPS` | 500 | the ceiling the deployer may set, enforced in the constructor and in `setFee` |

So at the live settings a 100 MUSD purchase pays 0.5 MUSD, of which 0.25
becomes backing and 0.25 becomes revenue.

### A share pays no income, and there is no APY

This needs saying plainly, because the fee stream above makes it easy to
assume otherwise.

`redeem` pays `shares * price - fee`. The price comes from the oracle. **The
vault's reserves do not enter that calculation.** A holder who waits while
reserves grow receives exactly what they would have received before:

```
reserves           145.035739 MUSD
share supply         1.448714
oracle price        99.742924 MUSD/share
liabilities        144.498950 MUSD   (supply * price)
backing ratio          100.371%
surplus                  0.536788 MUSD

MUSD per share, today:           99.742924   (price only)
MUSD per share, reserves doubled: 99.742924   (unchanged)
```

The surplus is **over-collateralisation**. It makes redemption more likely to
succeed against a rising index, which is worth something to a holder, but it
is not a balance anyone can withdraw and it is not yield. There is no
mechanism in `IssuanceVault` that pays a holder for holding, so there is no
rate to quote, and a quoted APY would be a number the contract contradicts.
The dapp says this where someone decides whether to hold.

Redemption is priced from the oracle rather than from net asset value on
purpose: a share is meant to **track the index**. NAV-based redemption would
make the share track the vault's balance sheet instead, which is a different
product and not the one being built.

### Where the yield comes from: staking MEZO

Not from holding a share - from staking MEZO against the revenue stream above.
`LeekStaking` is deployed and both vaults are wired to it.

Stake MEZO, receive sMEZO one for one, and two things follow.

**A fee discount.** `IssuanceVault.effectiveFeeBps(address)` is what a buy or
a redemption actually charges, and it is the number the dapp quotes - read
from the vault rather than multiplied out in the page, because the vault
clamps the discount independently and falls back to the undiscounted fee if
the staking call reverts or exhausts its gas stipend. The tiers at the live
settings:

| Staked MEZO | Discount | Fee paid |
|---|---|---|
| 1 | 10% | 0.45% |
| 10 | 25% | 0.375% |
| 50 | 50% | 0.25% |

**Those thresholds are what a testnet faucet hands out, not a schedule.** They
were 100 / 1,000 / 5,000, which reads like a real one and was checked against
nothing: the deployer holds 100 MEZO, so the top two tiers were unreachable
and the bottom one cost the whole balance. A tier nobody on the chain can
reach is a tier that has not been tested. The discounts are the economic
claim and are unchanged; only the thresholds moved.

`MAX_DISCOUNT_BPS` is 5000, so the fee can never be discounted below half
whatever a future tier says, and `tierAt`/`tierCount` are public so the dapp
lists them rather than hardcoding the table above.

**A share of the revenue.** The treasury half of every fee is transferred to
`LeekStaking` and credited through an `accMusdPerShare` accumulator with the
usual `rewardDebt` per account, so a staker earns only on revenue that arrived
while they were staked. `pending(address)` is what they can claim and
`totalDistributed()` is what has been credited to everyone, ever. **Nothing is
minted to fund this.** There is no emission, no inflation and no token
schedule: if nobody trades, stakers earn nothing, and the dapp says so in
words rather than showing a zero that reads like a measurement.

#### The holding period, which is deliberate and surprising

A discount that could be acquired and released inside one transaction is a
discount for rent, not for holding - and because sMEZO is transferable, one
stake could have granted the top tier to any number of traders, one per
transaction. So `LeekStaking` enforces a cooldown, and three things follow
that are worth knowing before you stake:

- **The discount does not apply during the cooldown.** `discountBpsFor`
  returns 0 while an account is cooling. Staking and immediately seeing no
  discount is correct behaviour, and the dapp explains it rather than leaving
  it to look broken.
- **`unstake` and `claim` are both gated** by the same clock. Gating only
  `unstake` left the reward leg of the attack free, which is one of the two
  High findings the third audit round raised against the second round's own
  fix for this.
- **Every increase extends the cooldown in proportion** to how much the
  position grew, accumulating from whichever is later of the existing deadline
  and now. Taking the maximum of the per-step fractions instead - which is
  what the first fix did - let a position grown in 144 small steps inside one
  transaction wait **35 seconds instead of 3,600**. Proportional extension
  also means 1 wei sent to a large position moves the deadline by
  approximately nothing, which is what stops the cooldown being usable as a
  griefing weapon.

#### What rate the dapp may quote, and what it may not

There is a real rate here, which is exactly why the page is careful with it.
It shows two numbers that answer different questions:

- **Realised per MEZO** is `totalDistributed / totalStaked`: fees credited to
  date over what is staked now. A fact about the past. It carries no window
  and therefore is not a rate.
- **Observed rate** is how far `accMusdPerShare` moved between two samples the
  page itself took, annualised, with the length of that window printed beside
  it.

The window is the page's own uptime because that is the only interval whose
length is known: the accumulator carries no timestamp on chain, so nothing can
say over how long `totalDistributed` accumulated. The function refuses to
answer below two minutes, refuses when no revenue arrived however long the
window, and never compounds - a plausible-looking figure extrapolated from a
thirty-second sample of a single trade would be the most dishonest thing on
the page. `web/test/stakingRate.test.ts` is mostly tests of when it must say
"not yet" instead of a number.

#### The guardian can detach it, and cannot be overruled immediately

A staking contract that reverts would otherwise freeze buying *and* redeeming,
so `GUARDIAN_ROLE` can call `emergencyUnsetStaking()` (only while paused, so
the step is part of a declared incident) and revenue goes back to
`feesAccrued`. That rescue holds for `STAKING_RELOCK_DELAY`, 24 hours:
`setStaking` reverts with `StakingLocked` inside the window, because without
it the admin whose mistake caused the incident could re-point the vault in the
next block, as often as the guardian unset it. Setting staking to **zero**
stays allowed throughout, so the lock can never trap a vault pointed at a
hostile contract.

`registerIndex` also refuses `guardian == treasurer`. The written argument for
delegating the detach was that unsetting "cannot take value, because only
`TREASURER_ROLE` can reach `feesAccrued`", and that is only true when the two
differ - one address holding both could stop every staker's rewards while
trading looked entirely normal, then withdraw the fees that accrued instead.

## Mezo testnet has two MUSD contracts, and the ecosystem is split

This cost real time to find and it changes what a project built here has to
check, so it is written down rather than left in a commit message.

Two contracts on Mezo testnet are called `MUSD`, both report 18 decimals, and
they are not interchangeable:

| Address | `mintList(BorrowerOperations)` | Who uses it |
|---|---|---|
| `0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af` | **true** | `BorrowerOperations` mints it, so this is the MUSD a user gets by borrowing. **What this project settles in.** |
| `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` | **false** | the official MUSD/BTC pool on Mezo's own DEX, and the address Mezo's public docs give for testnet MUSD |

Three more contracts on the chain also report MUSD with 18 decimals and also
return false; all four are listed in
[web/scripts/check-bundle.mjs](web/scripts/check-bundle.mjs), which fails the
build if any of them reaches a bundle.

The consequence is not theoretical. Mezo's own getting-started guidance says
to obtain testnet MUSD by swapping BTC in the dApp, and that swap goes through
the MUSD/BTC pool - which holds the *second* token. A tester who follows those
instructions ends up holding MUSD that `BorrowerOperations` never minted, that
no vault here accepts, and that cannot be used to repay a trove. The balance
looks right, the symbol looks right, and every transaction reverts.

So: **on Mezo testnet, resolve MUSD by `mintList(BorrowerOperations)`, not by
symbol and not from the docs.** Every vault here reads its settlement token
back with `musd()` and the dapp compares that against the borrow market's own
`musd()` on every poll, surfacing a mismatch rather than letting someone
approve a token the vault will reject.

This has been reported to the Mezo team. It is a testnet-only split; mainnet
has one MUSD.

## Listing shares on Mezo's own DEX

Mezo runs an Aerodrome-style AMM ("Mezo Pools") with basic and concentrated
pools, and it is deployed on testnet - at different addresses from the mainnet
ones in the same documentation table, which is worth reading carefully before
pointing a script at either.

`PoolFactory.createPool` is permissionless, so an index share can be paired
with the **borrowable** MUSD above and traded on infrastructure Mezo already
operates. That is composition with a live protocol rather than another
contract of ours, and it makes a share tradeable without touching the vault.

| Mezo testnet | Address |
|---|---|
| Router | `0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9` |
| PoolFactory | `0x4947243CC818b627A5D06d14C4eCe7398A23Ce1A` |
| CL Factory | `0x7B61BC8Aa460476d142F1CD107A47297002f69ff` |
| NonfungiblePositionManager | `0x9B753e11bFEd0D88F6e1D2777E3c7dac42F96062` |

`scripts/create-pool.sh` lists a pair and `scripts/verify-pool.sh` checks the
result. Three things the scripts refuse to do, each because the failure is
silent otherwise:

- **Pair against an MUSD nobody can borrow.** It reads
  `mintList(BorrowerOperations)` and stops if it is false.
- **Seed at a price nobody chose.** The first deposit *is* the pool's price.
  A basic pool carries no oracle and a testnet has no arbitrage, so a lopsided
  first deposit is never corrected - it becomes the price and whoever trades
  next absorbs it. The script quotes the vault, derives the matching MUSD, and
  refuses if the router's own quote differs by more than a tolerance.
- **Trust a receipt.** `cast send` cannot confirm anything on Mezo, so
  `verify-pool.sh` reads the resulting state: that the factory and the router
  agree on the address, that neither side is empty, and that the pool's price
  is still within 300 bps of the oracle.

### What this does not get us yet

Gauges and MEZO emissions need **both** tokens whitelisted in `PoolsVoter`,
and only Mezo's own assets are. An index share is not, so a share pool cannot
receive emissions without Mezo whitelisting it. The pool is real and tradeable;
the emissions are not available to it today, and claiming otherwise would be
describing someone else's governance decision as a feature of this project.

## The indices track crypto baskets, not equities

Deliberately, and this is a product boundary rather than a limitation.

The names are parodies - GOLOGGLE, AMEZON - and the constituents are
**cryptoassets** priced from CoinGecko. GOLOGGLE is ethereum, chainlink and
filecoin; AMEZON is solana, avalanche and uniswap. Neither basket contains,
references or derives from any company's shares.

A token that tracked a real company's share price would be a synthetic equity
derivative. It would contradict the `DISCLAIMER` constant compiled into
[ETFShare](src/ETFShare.sol) - *"Not a security. Not backed by any real asset
or company"* - which travels with the token precisely so a front end cannot
separate the claim from it. The parody name would make that worse rather than
better: a real securities exposure wearing a joke label.

There is also no honest data source for it. No free, keyless, real-time equity
API exists; the keyless options refresh weekly or lag fifteen minutes, and
CoinGecko covers cryptoassets, not equities. An index is only as good as the
feed behind it, and a fifteen-minute-old price on a 0.5% fee is a worse
product than a real-time one on a basket nobody is pretending is Alphabet.

## Front end

[web/](web/) is the dapp: prices, buy and redeem, and the vault's reserves
against its liabilities. Vite, TypeScript and viem with no framework, served as
a static container; `web/README.md` records why it diverges from the mandated
Scaffold-ETH 2 starter and what the bundle costs.

## Audit

[audit/AUDIT-REPORT.md](audit/AUDIT-REPORT.md) applies the ethskills EVM audit
checklists and lists eight findings with their status. Both deployment gates are now closed:
`slither` runs clean of unaddressed high and medium findings, and the
invariant and fork suites are in the tree.

## Standards

- The oracle implements **Chainlink's `AggregatorV3Interface`**, which needs
  nothing from Chainlink: it is four view functions. Anything already written
  against Chainlink feeds — Mezo's own `PriceFeed` among them — consumes this
  one unchanged.

## Run the whole thing locally

```sh
./scripts/local-up.sh              # anvil, contracts, feed, dapp -> http://127.0.0.1:5173
./scripts/local-up.sh --no-dapp    # contracts and feed only
```

Anvil on chain 31337; the real deploy script, through its `ALLOW_CHAIN_ID`
rehearsal escape, so the script that deploys to Mezo is the script that gets
tested; a mock settlement token, because the real MUSD exists only on Mezo,
with a million of it minted to Anvil's first account; the feed publishing
synthetic prices every ten seconds; and the dapp pointed at all of it through
a `web/.env.local` written fresh on each run, so a stale address cannot
survive a redeploy.

Ctrl-C stops everything it started. The private key in that script is Anvil's
own published test key - safe because this chain holds nothing, and it appears
nowhere near the deployment path.

To click through it: add a network to your wallet with RPC
`http://127.0.0.1:8545` and chain id `31337`, then import Anvil's account 0.

## Scripts

Every one of these refuses rather than warns when something is wrong, and none
of them puts a key or a password on a command line.

| Script | Does |
|---|---|
| `local-up.sh` | the whole stack on a local chain: anvil, the real deploy script, a mock settlement token, the feed, the dapp. `--fund 0xYou` mints to your own wallet |
| `deploy-mezo.sh` | deploys to Mezo testnet after five pre-flight checks, loops past the chain's late receipts, verifies on the explorer. `--checks-only` proves everything and deploys nothing |
| `record-deployment.sh` | reads a deploy log, verifies every address against the chain (code present, each vault bound to its own share and oracle, both bound to staking, the two indices distinct), and only then writes them into `ADDRESSES.md`, the Dockerfile's build args and `check-bundle.mjs`. Exists because a redeploy lands eight addresses that then have to appear identically in four places, and silent transcription error is what the whole preamble of `ADDRESSES.md` is about |
| `verify-bytecode.sh` | compares every deployed contract with a local build, masking immutables. No key, no explorer, anyone can reproduce it |
| `grant-publisher.sh` | grants `PUBLISHER_ROLE` to a dedicated key and revokes it from the deployer, confirming by reading `hasRole` |
| `sweep-publisher.sh` | sends all but a gas float from the publisher back to the deployer |
| `feed-env.sh` | writes `feed/.env` with the publisher's key taken out of the keystore and never shown |
| `borrow-musd.sh` | opens a trove on Mezo's native borrow system, so there is MUSD to buy shares with (the dapp now does this too, from the page) |
| `fund-backstop.sh` | donates MUSD to a vault's reserves to cover the H-1 shortfall, so every share can be redeemed |
| `buy-shares.sh` | buys shares from the keystore account, by share count or by MUSD spent. Exists because seeding a pool needs shares and MUSD in the same account, and the alternative was importing the deployer key into a browser |
| `create-pool.sh` | lists an index share against borrowable MUSD on Mezo's own DEX. Dry run by default; refuses an unborrowable MUSD, a ratio that disagrees with the oracle, and `FROM` with `--execute` |
| `verify-pool.sh` | reads a listed pool back: factory and router agree, neither side empty, price within 300 bps of the oracle. The only honest confirmation on a chain whose receipts lag |

## What Mezo does differently, and what it cost to find out

Four things break standard EVM tooling here. All four are in
[DEPLOYMENT.md](DEPLOYMENT.md) with the exact errors; the summary:

1. **Sequence, not nonce.** `mezod` forks Evmos, so Cosmos checks the account
   sequence when a transaction *arrives*. Foundry's pipelined broadcast is
   refused with `invalid nonce; got 1, expected 0: invalid sequence`. Fix:
   `--slow`.
2. **A transaction is in a block long before its receipt can be read.**
   Foundry treats a null receipt as fatal, so a successful deploy reports
   failure. Measured: once a receipt is readable it reads instantly every
   time, so the lag is after inclusion, not permanent. Fix: `--resume`, and
   confirm by **state** — `cast nonce`, `cast code`, `hasRole` — rather than
   by receipt.
3. **The explorer does not index contracts deployed by a contract.** It
   answers `is_contract: false` for them while `eth_getCode` returns their
   code, so Blockscout verification cannot match them. Fix:
   `verify-bytecode.sh`.
4. **`eth_estimateGas` returns a limit the chain then refuses.** Mezo enforces
   the EIP-7623 calldata floor but does not apply it when estimating, so a
   transaction built from the node's own estimate is rejected: `gas limit
   below EIP-7623 floor: 21240 (gas limit) < 21600 (floor data gas)`. The
   floor counts zero and non-zero calldata bytes differently, so whether a
   call fails depends on the *digits of the number being sent* - one oracle
   published at 115.20 while the other was refused at 128.00 in the same
   cycle. An intermittent fee error reads like a flaky RPC and invites a retry
   loop, which would never have worked. Fix: compute the floor
   (`eip7623FloorGas` in the feed) and send `max(estimate, floor)` with a
   margin.

None of these is a fault in this repository, and none is in Mezo's
documentation.

## Build and test

```sh
forge build
forge test -vvv                      # fuzz runs are configured at 1000
forge test --match-path "test/fork/*"  # against the real MUSD on Mezo testnet
forge snapshot                       # gas
slither .                            # static analysis
```

The fork suite pins a block number so a run is reproducible, and skips with a
printed reason when the RPC is unreachable, so an offline machine does not
turn into a red build. It proves what a mock cannot: that the live MUSD still
reports `MUSD` and 18 decimals (finding L-5), that its `transfer` and
`transferFrom` move exactly the amount asked for (finding L-2), and that a
vault deployed against it prices and mints correctly.

## Deploying

Already done once; this is how to do it again, or elsewhere.


See [script/README.md](script/README.md) for the parameters, the role-holder
environment variables and the pre-flight checklist. The invocation is:

```sh
forge script script/DeployMezoTestnet.s.sol \
  --rpc-url mezo_testnet --account monad-deployer \
  --sender <address> --broadcast
```

`--account` makes Foundry prompt for the keystore password, so no key and no
password is ever passed on a command line.

## Licence

Apache-2.0. A lending market forked from `mezo-org/musd` is GPL-3.0 and lives
in its own repository for that reason; nothing in here is derived from it.
