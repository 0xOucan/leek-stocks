# leek-stocks

Parody index tokens, settled in **MUSD** on Mezo, with an oracle you can read
and a signing path that ends on hardware.

Built for the Mezo Buildathon, Track 1. The wallet that signs it is
[LeekWallet](https://github.com/0xOucan/LeekWallet); the lending market that
borrows against these shares will live in `leek-lend`.

## What this is, plainly

- **Parody indices.** `Gologgle`, `Amezon`. They are **not** tokenised shares
  of any real company, they are **not** backed by anything, and they track an
  index this project's own oracle publishes. Testnet only.
- **MUSD settlement.** Shares are priced and bought in MUSD, the real one at
  `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` on Mezo testnet.
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
