# Audit report: leek-stocks, Wave 1 contracts

**Scope:** `src/IndexOracle.sol`, `src/ETFShare.sol`, `src/IssuanceVault.sol`,
`src/ETFFactory.sol` at the commit that adds them.
**Method:** the ethskills EVM audit checklists, applied in-process rather than
by parallel sub-agents, across the domains the routing table selects for this
code: **general, precision-math, erc20, access-control, oracles**, plus
**erc4626** read and found not to apply (see I-1).
**Severity scale:** Critical = direct loss of funds, no preconditions. High =
loss of funds under specific conditions, or permanent DoS. Medium = degraded
behaviour, trust-model violation, incorrect accounting, or owner-only fund
loss. Low = best practice, latent bug. Info = no security impact.

**Not an independent audit.** These findings were produced by the same process
that wrote the contracts, which is worth less than an outside review and is
recorded as such. `slither` 0.11.6 has been run and its findings are
in the Slither section below. The last open gate, a **fork test against the
real MUSD on Mezo testnet**, is now `test/fork/MezoFork.t.sol`: see the
checklist row below for what it proves.

## Summary

| ID | Severity | Title | Status |
|---|---|---|---|
| H-1 | High | A synthetic issuer is insolvent when the index rises | **Accepted, bounded, documented** |
| H-1a | High | Nobody is paid to fund the backstop | **Mechanism added**: every fee splits into reserves |
| M-1 | Medium | The oracle is a single operator | Accepted, documented |
| M-2 | Medium | The admin may raise the share cap without limit | Accepted |
| L-1 | Low | First published answer is unbounded | Accepted |
| L-2 | Low | A fee-on-transfer or rebasing settlement token would break accounting | Mitigated by scope |
| L-3 | Low | Redemption reverts rather than paying partially | By design |
| L-4 | Low | `reserves()` counts donated MUSD | By design, documented |
| L-5 | Low | MUSD's decimals are cached, and MUSD is upgradeable | Accepted, deploy-time check |
| L-6 | Low | The fee rounds in the user's favour | Accepted |
| I-1 | Info | Not ERC-4626, deliberately | — |
| I-4 | Info | Flash loans cannot move this oracle | — |
| I-2 | Info | `price()` reverts, so reads are not fail-soft | By design |
| I-3 | Info | Modifier order on `withdrawFees` | **Fixed** |

## H-1 A synthetic issuer is insolvent when the index rises

**Severity**: High
**Category**: general / defi-lending (solvency)
**Location**: `IssuanceVault.buy()`, `IssuanceVault.redeem()`

**Description**: Shares are minted against MUSD at the oracle price, but the
vault holds MUSD, not the index. If the index rises, the MUSD owed to
redeemers exceeds the MUSD paid in by buyers. The vault is then solvent only
for whoever redeems first, which is first-come-first-served on other people's
deposits — the shape of a loss, not of a product.

**Proof of Concept**: buy 1000 MUSD of shares at 200; the oracle publishes
240 (within its 20% bound); redemption of those shares owes 1194 MUSD against
995 in reserves. `test_redeemRevertsWhenReservesAreShort` demonstrates exactly
this, including the revert that stops the partial payout.

**Recommendation**: do not present this as a product. The contract bounds the
damage three ways, and all three are implemented: redemption **reverts** with
`InsufficientReserves(owed, available)` rather than draining reserves,
`maxShares` caps total exposure, and `fund()` lets a treasury make redeemers
whole. `reserves()` and `liabilities()` are public so the gap is visible
before anyone commits. A real version needs a funded counterparty — the Wave 2
lending market, or a hedged reserve — and the README must say that it is a
testnet demonstration of issuance and hardware signing, not a fund.

## H-1a Nobody is paid to fund the backstop

**Severity**: High (incentive, inseparable from H-1)
**Category**: general / protocol design
**Location**: `IssuanceVault.fund()`

**Description**: H-1's mitigation is that a treasury may top up reserves with
`fund()`. But a contract is a state machine that only advances when somebody
pays gas to advance it, and `fund()` pays its caller nothing. So the mitigation
depends on goodwill, which is not a mechanism. If the index rallies and no one
funds, redemption stays reverted and holders are stuck with an asset they
cannot exit.

**Proof of Concept**: `test_redeemRevertsWhenReservesAreShort` shows the
revert, and the recovery in that test happens only because the test itself
calls `fund()`. On chain, nothing makes that call happen.

**Recommendation**: **fixed, and the fix is a mechanism rather than a habit.**
A configurable `reserveShareBps` splits every fee: that share stays in
reserves, the remainder reaches the treasury. The backstop therefore grows on
every trade with nobody deciding to be generous, and the deployment sets it to
50%. `coverageBps()` makes the gap a number rather than an inference, and the
fork test asserts on live MUSD that a fresh buy leaves coverage above 100%.

It stays a High finding rather than becoming Info, because fees repair the gap
in proportion to volume and a fast index rally still outruns them. `fund()`
remains for a deliberate top-up and still pays its caller nothing. The honest
claim is that the shortfall is now self-repairing, not that it is covered. The
real answer is still a funded counterparty — fees routed to
reserves until a target ratio is met, or a funded counterparty such as the
lending market taking the other side of the exposure. Design that before
anyone's money is at stake, not after.

## I-4 Flash loans cannot move this oracle

**Severity**: Info
**Category**: oracles / flashloans

**Description**: The flash-loan attack that dominates DeFi oracle incidents —
borrow, move a pool, read the moved price, repay, all in one transaction —
does not apply here, and it is worth writing down why rather than leaving it
to be rediscovered. The price is **pushed** by an off-chain publisher, so it
cannot be moved inside a transaction at all: no pool, no reserves, no
`getReserves()`, no spot read. What replaces that risk is the publisher
itself, which is M-1. Any future change that derives a price from on-chain
liquidity reintroduces the whole class, and would need a TWAP at minimum.

## M-1 The oracle is a single operator

**Severity**: Medium (trust-model)
**Category**: oracles / access-control
**Location**: `IndexOracle.publish()`

**Description**: One key holding `PUBLISHER_ROLE` sets the price every
consumer prices against. A compromised publisher can walk the price in 20%
steps per round until it is anything they like.

**Proof of Concept**: no exploit needed; it follows from the design. The
bound only limits the size of a single step, not a sequence of them.

**Recommendation**: implemented so far — an immutable per-round deviation
bound, a separate guardian who can pause, a positive-answer check, a staleness
field no read touches. Unimplemented and worth doing before any real value:
several independent publishers with a median, a cooldown between rounds so a
walk takes time a guardian can react in, and the guardian as a multisig.
Stated plainly in the README, which is the minimum this deserves.

## M-2 The admin may raise the share cap without limit

**Severity**: Medium (owner-only risk)
**Category**: access-control
**Location**: `IssuanceVault.setMaxShares()`

**Description**: `maxShares` is the only bound on H-1's exposure, and the
admin can set it arbitrarily high at any time, including after users hold
shares.

**Recommendation**: accepted for a testnet demo. For anything further: make
raises timelocked, or make the cap immutable per deployment and require a new
vault to change it.

## L-1 First published answer is unbounded

**Severity**: Low
**Category**: oracles
**Location**: `IndexOracle.publish()`, first round

**Description**: With no previous answer there is nothing to deviate from, so
round 1 may be any positive value. A wrong first price is a wrong starting
point for every bound that follows.

**Proof of Concept**: `test_firstPublishIsExemptFromTheBound` publishes 1 wei
of price successfully.

**Recommendation**: deploy and publish the first round in one reviewed
transaction, and check the value on the explorer before anything consumes the
feed. A constructor-supplied first answer would make this structural.

## L-2 A fee-on-transfer or rebasing settlement token would break accounting

**Severity**: Low
**Category**: erc20
**Location**: `IssuanceVault.buy()`, `fund()`

**Description**: `buy()` credits fees and mints shares from the *requested*
amount, not from the balance delta. With a fee-on-transfer token the vault
would receive less than it accounted for; with a rebasing token reserves
would drift from liabilities silently.

**Recommendation**: MUSD is a plain 18-decimal ERC-20 with no transfer fee, so
the scope excludes the case; the settlement token is immutable per vault, so
it cannot be swapped for a hostile one later. If a different token is ever
used, measure the balance before and after and credit the delta.

## L-3 Redemption reverts rather than paying partially

**Severity**: Low (availability)
**Category**: dos
**Location**: `IssuanceVault.redeem()`

**Description**: When reserves are short, every redemption reverts until the
vault is funded, so holders cannot exit at all rather than exiting at a
discount.

**Recommendation**: kept. A partial payout silently converts a solvency
problem into a sequencing race, and the revert names both numbers so the
shortfall is legible. A pro-rata exit mode is the fix if this ever needs to
degrade gracefully, and it belongs with the funded counterparty from H-1.

## I-1 Not ERC-4626, deliberately

**Severity**: Info
**Category**: erc4626

**Description**: The erc4626 checklist (inflation attack, share/asset
rounding, virtual offsets) was read and does not apply: a share here is not a
claim on assets held, so `assets/supply` is not the share price. Implementing
4626 would advertise a solvency guarantee the design does not have, which
would be worse than not implementing it. The first-depositor inflation attack
is absent for the same reason: the price comes from the oracle, not from a
balance an attacker can seed.

## I-2 `price()` reverts, so reads are not fail-soft

**Severity**: Info
**Category**: oracles

**Description**: The oracle checklist suggests wrapping feed calls in
try/catch so a disabled feed cannot brick a protocol. Here `price()` reverts
on a stale, non-positive or incomplete round, and `buy`/`redeem` therefore
revert too. That is the intended behaviour: minting or redeeming at an unknown
price is worse than being unavailable, and `fund()` — the path that makes
redeemers whole — deliberately does **not** read the price, so a dead feed
cannot block the backstop.

## L-4 `reserves()` counts donated MUSD

**Severity**: Low (accounting)
**Category**: general (donation attacks)
**Location**: `IssuanceVault.reserves()`

**Description**: `reserves()` is `balanceOf(this) - feesAccrued`, so MUSD
transferred in directly counts without passing through `fund()` and without an
event.

**Proof of Concept**: transfer MUSD to the vault; `reserves()` rises and
`liabilities()` does not.

**Recommendation**: kept, and the reason is written at the function. Nothing
mints against this number — shares are priced by the oracle, not by the
balance — so a donation cannot inflate a share price or dilute a holder; it
can only make redeemers better off. This is why the ERC-4626 first-depositor
inflation attack has no analogue here. `fund()` exists so a deliberate top-up
is observable; an off-chain monitor should watch transfers as well.

## L-5 MUSD's decimals are cached, and MUSD is upgradeable

**Severity**: Low
**Category**: erc20 / precision-math
**Location**: `IssuanceVault` constructor, `musdDecimals`

**Description**: `decimals()` is read once at construction. MUSD is an
upgradeable contract (`initialize`, not a constructor), so a future
implementation could in principle report different decimals while the vault
keeps scaling by the old value, mispricing every trade by a power of ten.

**Recommendation**: accepted. An ERC-20 that changes its decimals breaks every
integrator simultaneously, and reading it per trade costs an external call on
the hot path. Recorded so that the assumption is explicit rather than
invisible. A deployment checklist item: confirm `decimals()` on the live MUSD
immediately before deploying a vault against it.

## L-6 The fee rounds in the user's favour

**Severity**: Low
**Category**: precision-math
**Location**: `IssuanceVault.buy()`, `redeem()`

**Description**: both fees divide down, so the protocol under-charges by up to
one wei per trade. Shares minted and MUSD paid out also round down, which is
in the protocol's favour, so the two directions do not combine into a dust
extraction cycle: a buy-then-redeem round trip always loses, which
`testFuzz_roundTripNeverProfits` asserts over 1000 runs.

**Recommendation**: kept. Rounding the fee up would be more correct for a
revenue-taking protocol and is a one-line change if this ever charges real
fees.

## I-3 Modifier order on `withdrawFees` (fixed)

**Severity**: Info
**Category**: general

**Description**: `nonReentrant` was declared after `onlyRole`. The checklist
requires the guard to be the first modifier, since earlier modifiers run
before the lock is taken. A role check cannot re-enter, so nothing was
exploitable, but the order is now guard-first.

## Slither

`slither . --filter-paths "lib|test"`, version 0.11.6, run on this commit.
Nine results on the first pass; four addressed, five accepted. Re-running
after the fixes leaves four, all accepted below:

| Finding | Action |
|---|---|
| `divide-before-multiply` in `redeem` | **fixed.** The fee now comes from the undivided product, so the two divisions no longer compound |
| `reentrancy-no-eth` / `-benign` in `deployETF` | **fixed.** Registry state is written before the calls into the newly deployed vault, so the function is Checks-Effects-Interactions whatever it grows into |
| `reentrancy-events` in `deployETF` | **accepted.** `IndexDeployed` is emitted after the role handover because it announces a *finished* deployment; emitting it earlier would log a pair that is not yet configured. The callee is a contract constructed three lines above, so there is no untrusted code in the path |
| `unindexed-event-address` on the factory's events | **fixed.** `oracle`, `share` and `vault` are indexed |
| `timestamp` on `isFresh()` and `price()` | **accepted.** Staleness is a time comparison by definition; the tolerance is an hour, far beyond the drift a validator can manufacture |
| `naming-convention` on `getRoundData(uint80 _roundId)` | **accepted.** The parameter name comes from Chainlink's published interface, and renaming it would make ours differ from the thing it is compatible with |

## Checklist status

| Item | State |
|---|---|
| Access control on every privileged function | done; three separate roles per vault, named in the registry |
| Reentrancy: CEI plus `nonReentrant` | done on `buy`, `redeem`, `fund`, `withdrawFees` |
| Oracle: positive answer, `startedAt > 0`, `answeredInRound >= roundId`, staleness, `decimals()` read not assumed | done in `IssuanceVault.price()` |
| No hardcoded `1e18` for the token | done; `musdDecimals` read at construction and scaled |
| Multiply before divide, basis points | done |
| SafeERC20 | done |
| Exact approvals, no infinite approvals in contract code | done (the test uses one for convenience only) |
| Input validation: zero address, zero amount, empty string | done |
| Events on every state change | done |
| Unit + fuzz tests, 1000 runs | done, 34 tests |
| Invariant tests | done. Five invariants over a bounded handler (buy, redeem, fund, price moves inside the oracle's bound, time passing, fee withdrawal): fees never exceed the balance, MUSD is conserved across every path, the cap holds whatever the price did, supply is held only by actors the vault minted to, and the oracle never regresses. 256 runs x 8192 calls, zero reverts |
| Fork test against real MUSD on Mezo testnet | done. `test/fork/MezoFork.t.sol`, pinned at block 16,198,929. Reads `symbol() == "MUSD"` and `decimals() == 18` off the deployed token (L-5), measures `transfer` and `transferFrom` on both sides to show no fee and no rebase (L-2), and buys and redeems through a vault deployed against it: 1000 MUSD at a 200e8 feed answer mints 4.975 shares, so the 8-to-18 decimal scaling is right on the real token. Skips with a reason when the RPC is unreachable |
| Gas snapshot | done |
| `slither`, no unaddressed high/medium | done; 0.11.6 installed in `.venv`. Four findings fixed, five accepted with reasons above. No high or medium outstanding |
| Verified source after deploy | pending deployment |
