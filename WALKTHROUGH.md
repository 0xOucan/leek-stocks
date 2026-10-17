# LeekStonks on Mezo testnet: the whole flow, from an empty wallet

Two audiences, one document. If you are a judge or a tester, read part 1 and
stop. If you are the operator, part 2 is the signing checklist that has to be
green before this is deployed anywhere, and part 3 is what is known to be
awkward so that an awkward thing is not mistaken for a broken one.

Everything below is **testnet**. The index names are invented and belong to no
company. Nothing here is a security.

---

## Part 1 — For a tester

Six steps. The page works out which one you are on from chain state and offers
only that one, so you can stop and come back and it will still be right.

| # | Step | Where |
|---|---|---|
| 1 | Connect a wallet | the page |
| 2 | Switch to Mezo Testnet (chain **31611**) | the page offers the button |
| 3 | Claim test BTC | [faucet.test.mezo.org](https://faucet.test.mezo.org) |
| 4 | Borrow MUSD against that BTC | the page |
| 5 | Approve, then buy shares | the page |
| 6 | Redeem back to MUSD | the page |

**Gas on Mezo is BTC, not ether.** The same BTC is also the collateral in step
4, so one faucet claim covers both.

**Step 4 creates a loan, not a swap.** You lock BTC, Mezo's own borrow market
mints MUSD against it, and the BTC comes back when the debt is repaid. Two
things about it surprise everyone, so the page states both before you sign:

- The protocol minimum is **1800 MUSD** per position. There is no smaller one.
- Your **debt is larger than what you receive**. 200 MUSD of it is the
  protocol's liquidation reserve, held against the position and cancelled when
  it closes, plus an issuance fee. Neither reaches your wallet.

On testnet BTC is priced at about **$20,000,000**, so the collateral a 1800
MUSD borrow needs is a fraction of a thousandth of a BTC. The page suggests a
figure at twice the 150% ratio it requires, which is far above the protocol's
110% liquidation threshold on purpose.

Once you hold a position you can also **repay**, **borrow more** against the
same collateral, or **close** it and take the BTC back. All three are on the
same panel.

### Why redeeming can be refused

A share is priced from an index the vault does not hold, so the MUSD paid in
by buyers can be less than the MUSD owed to redeemers. When reserves are
short, redemption **reverts rather than paying part of what is owed**. The
vault's cover is on screen before you commit, and the shortfall is named in
MUSD rather than hinted at. This is audit finding H-1 and it is deliberate.

---

## Part 2 — The signing checklist (operator)

Every write path has been simulated with `cast` and asserted in unit tests.
**Simulation is not signing.** A `writeContract` through a browser wallet, with
`value` on a payable function, against a chain whose receipts arrive late, is a
different thing from an `eth_estimateGas`. This part exists because "it
simulated fine" is not evidence that a user can do it.

Use a wallet that has **no position yet**. Record every hash.

| # | Action | Contract | Expect | Hash |
|---|---|---|---|---|
| 1 | Connect | — | address and `Mezo Testnet` badge | — |
| 2 | Switch network | — | wallet adds chain 31611 if missing; gas shows as **BTC** | — |
| 3 | Faucet | — | native balance > 0; the gas step ticks itself within 5s | — |
| 4 | **openTrove** | `BorrowerOperations` | MUSD arrives; debt ≈ borrow + 200 + fee | |
| 5 | **approve** MUSD | the settlement MUSD | allowance equals the exact amount, not unlimited | |
| 6 | **buy** | the vault | shares arrive; reserves rise | |
| 7 | **approve** shares | the share token | a *different* token from step 5 | |
| 8 | **redeem** | the vault | MUSD returns, less two fees | |
| 9 | **repayMUSD** | `BorrowerOperations` | debt falls; **no approval step** | |
| 10 | **withdrawMUSD** | `BorrowerOperations` | debt rises, ratio falls | |
| 11 | **closeTrove** | `BorrowerOperations` | all BTC returns, debt gone | |

Steps 9–11 need the position to still be open, so run 11 last.

### Addresses these must hit

Read them from the chain, not from this file:

```sh
R=https://rpc.test.mezo.org
cast call 0x68A86E4503FCA82ac9eB229Be655E355A019bcC3 "musd()(address)" --rpc-url $R
# must be 0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af — the MUSD
# BorrowerOperations can mint. Mezo testnet has FIVE contracts reporting MUSD
# with 18 decimals and this is the only one obtainable by borrowing.
```

### Then, and only then, the hardware wallet

The point of doing it with an external wallet first is that a failure there is
a failure in the dapp, and a failure after this is a failure in LeekWallet.
Mixing the two means debugging both at once.

---

## Part 3 — Known-awkward, not broken

**A transaction that looks stuck.** Mezo answers
`eth_getTransactionReceipt` with `null` for minutes after a transaction is
already in a block. A wallet or a script reporting a timeout here is usually
reporting lag, not failure. Check the explorer or the balance before retrying,
because retrying a transaction that landed is how you end up with two.

**A repay ceiling in single digits.** A position's *net* debt — the debt less
the 200 MUSD reserve — must stay at or above the 1800 minimum. A trove opened
at exactly 1800 can therefore only repay the interest sitting on top of it. A
"maximum 9.02 MUSD" against a 2009 MUSD debt is correct; closing is the only
way further down.

**Closing refused for a few MUSD.** Closing needs the whole net debt in your
wallet, and a wallet that borrowed 1800 and spent it holds less than 1800. The
gap is the interest and fee already paid. Redeem shares back to MUSD and it
clears; the page names the figure.

**A price marked `synthetic`.** The feed's source was unreachable and it is
publishing its deterministic series instead. Correct behaviour, labelled
loudly, and not a market price.

**Both oracles stale after the feed stops.** `price()` reverts outside the
vault's staleness window, so buying and redeeming revert too until a new round
is published. Restart the feed and it clears on the next publish.
