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
recorded as such. `slither` has not been run: it is not installed on the
build machine, and the testing checklist makes static analysis a gate before
deployment. **That gate is open.**

## Summary

| ID | Severity | Title | Status |
|---|---|---|---|
| H-1 | High | A synthetic issuer is insolvent when the index rises | **Accepted, bounded, documented** |
| M-1 | Medium | The oracle is a single operator | Accepted, documented |
| M-2 | Medium | The admin may raise the share cap without limit | Accepted |
| L-1 | Low | First published answer is unbounded | Accepted |
| L-2 | Low | A fee-on-transfer or rebasing settlement token would break accounting | Mitigated by scope |
| L-3 | Low | Redemption reverts rather than paying partially | By design |
| I-1 | Info | Not ERC-4626, deliberately | — |
| I-2 | Info | `price()` reverts, so reads are not fail-soft | By design |

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
| Invariant tests | **owed** — the vault is stateful; a handler-based suite asserting reserves/liabilities bounds is the next test to write |
| Fork test against real MUSD on Mezo testnet | **owed** before deployment |
| Gas snapshot | done |
| `slither`, no unaddressed high/medium | **owed — not installed** |
| Verified source after deploy | pending deployment |
