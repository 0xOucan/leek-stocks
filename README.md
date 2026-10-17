# leek-stocks — LeekStonks

Parody index tokens, settled in **MUSD** on Mezo, with an oracle you can read
and a signing path that ends on hardware.

**The names.** **LeekDefi** is the whole thing, at
`leekdefi.0xoucanproject.xyz`: one host, one front end, two products.
**LeekStonks** is this repository — the index market. **Leeknding** is the
lending market, in `leek-lend`, written and tested and not yet deployed. The
wallet that signs for all of it is **LeekWallet**.

Built for the Mezo Buildathon, Track 1. The wallet that signs it is
[LeekWallet](https://github.com/0xOucan/LeekWallet); the lending market that
borrows against these shares will live in `leek-lend`.

## Where this is, today

**Live on Mezo testnet (31611) since 2026-10-17.** Seven contracts, settling
in the MUSD Mezo's own borrow system mints, so MUSD obtained by borrowing
against BTC can be spent here. Addresses, the live state when recorded, and
both keys and what each can do are in [ADDRESSES.md](ADDRESSES.md).

| Piece | State |
|---|---|
| Contracts | **deployed and verified** on Mezo testnet; three verified on the explorer, all seven against the source (`./scripts/verify-bytecode.sh`) |
| Roles | split: a publisher key that can only publish, a deployer key that can do everything but publish |
| Price feed | runs; rehearsed against the live oracles; **not yet on the VPS** |
| Front end | **points at Mezo testnet**; a full buy -> redeem round trip completed on chain; onboarding, the faucet link and native borrowing are in the page; **not yet deployed to the VPS** |
| Leeknding (lending) | written, 95 tests, 8 invariants, **not deployed** — `leek-lend` |
| Air-gapped signing | the wallet draws Mezo transactions in BTC; the filmed demo is owed |

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
| `maxStaleness` | consumers must refuse an answer older than this; `updatedAt` is the publication time and no read touches it |
| Positive-answer check | a zero or negative price is refused at publication |
| Separated roles | publishing, pausing and administration are three roles; the publisher cannot pause and the guardian cannot publish |
| Monotonic rounds | ids increase by one, and history is immutable once written |

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
| `verify-bytecode.sh` | compares every deployed contract with a local build, masking immutables. No key, no explorer, anyone can reproduce it |
| `grant-publisher.sh` | grants `PUBLISHER_ROLE` to a dedicated key and revokes it from the deployer, confirming by reading `hasRole` |
| `sweep-publisher.sh` | sends all but a gas float from the publisher back to the deployer |
| `feed-env.sh` | writes `feed/.env` with the publisher's key taken out of the keystore and never shown |
| `borrow-musd.sh` | opens a trove on Mezo's native borrow system, so there is MUSD to buy shares with (the dapp now does this too, from the page) |
| `fund-backstop.sh` | donates MUSD to a vault's reserves to cover the H-1 shortfall, so every share can be redeemed |

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
