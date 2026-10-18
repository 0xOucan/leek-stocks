# Audit report: leek-stocks, Wave 1 contracts

**Scope:** `src/IndexOracle.sol`, `src/ETFShare.sol`, `src/IssuanceVault.sol`,
`src/ETFFactory.sol`, `src/LeekStaking.sol`, `script/DeployMezoTestnet.s.sol`,
`script/ConfigureMezoTestnet.s.sol`, and `feed/src/{service,index-math}.ts`.
**Method:** the ethskills EVM audit checklists across the domains the routing
table selects for this code: **general, precision-math, erc20, access-control,
oracles, staking-rewards**, plus **erc4626** read and found not to apply (see
I-1). Round 1 was applied in-process; rounds 2 and 3 were run as parallel
sub-agents; round 4 in-process again.
**Severity scale:** Critical = direct loss of funds, no preconditions. High =
loss of funds under specific conditions, or permanent DoS. Medium = degraded
behaviour, trust-model violation, incorrect accounting, or owner-only fund
loss. Low = best practice, latent bug. Info = no security impact.

**Not an independent audit.** These findings were produced by the same process
that wrote the contracts, which is worth less than an outside review and is
recorded as such.

## Four rounds, and what each one found

This is the part of the report worth reading, because the pattern matters more
than any single finding.

| Round | Target | Outcome |
|---|---|---|
| 1 | The four original contracts | H-1 / H-1a (the solvency gap and its missing incentive), M-1, M-2, and seven Lows. Mostly design findings. |
| 2 | The same four, plus the new `LeekStaking` and the deploy scripts | **Two demonstrated drains of shareholder reserves**, a permanent oracle brick, a free fee discount, a redemption that staking could freeze, and two pre-existing deploy-script defects that had already mispriced the live feed. |
| 3 | **Round 2's fixes** | Three bugs *in the fixes*, one of which restored the attack the fix was for in full. |
| 4 | Rounds 2 and 3's fixes, plus the off-chain publisher | An absorbing floor on the oracle - the mirror image of the brick round 2 fixed - and a guardian power the admin could undo in the next block. |

**Round 3 is the finding.** Two of its three bugs were in code written to
close round 2's findings: a cooldown that reduced a one-hour wait to 35
seconds, and a `claim()` that was never gated at all. A patch is new code and
needs attacking as hard as the code it replaces. Every round since has
re-audited the previous round's diff first, and every round has found
something there.

**Round 4's two High findings are both mirror images.** `MAX_ANSWER` was added
in round 2 to stop one mistyped answer bricking the feed; nothing bounded the
*bottom*, where a multiplicative deviation bound is strictly worse than a
revert. `emergencyUnsetStaking` was added in round 2 to give the guardian a
remedy; nothing stopped the admin undoing it in the next block. Both times the
fix solved the instance and not the class.

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
| R2-1 | **Critical** | The share's role admin defaults let any admin mint without limit | **Fixed** |
| R2-2 | **Critical** | The deployer key retained every role after a split deployment | **Fixed** |
| R2-3 | High | A fee discount could be rented for one transaction | **Fixed** (cooldown) |
| R2-4 | High | One mistyped first answer bricked the feed permanently | **Fixed** (`MAX_ANSWER`) |
| R2-5 | High | The reward path could freeze every redemption | **Fixed** |
| R2-6 | High | The deploy script's default settlement token was the wrong MUSD | **Fixed** |
| R2-7 | High | The deployed feed opened at 2x the index's own base | **Fixed** |
| R2-8 | Medium | Index name squatting was permanent and unrecoverable | **Fixed** |
| R2-9 | Medium | Reward dust was re-offered and double-counted | **Fixed** (invariants) |
| R2-10 | Medium | The last claimant's whole reward was unwithdrawable | **Fixed** (invariants) |
| R3-1 | High | The cooldown fix reduced a 3600s wait to 35s | **Fixed** |
| R3-2 | High | `claim()` was not gated by the cooldown at all | **Fixed** |
| R3-3 | Medium | `_tryPayout` ignored the ERC-20 return value | **Fixed** |
| R3-4 | Medium | A typed `try ... returns (bool)` is uncatchable on empty returndata | **Fixed** |
| R3-5 | Low | The cooldown was usable as a 1-wei griefing weapon | **Fixed** |
| R3-6 | Low | A deploy-script assertion could not fire in the failing case | **Fixed** |
| R4-1 | **High** | Small oracle answers are absorbing, pinning the feed at dust | **Fixed** (`MIN_ANSWER`) |
| R4-2 | **High** | The admin could undo the guardian's rescue in the next block | **Fixed** (relock delay) |
| R4-3 | Medium | `guardian == treasurer` was documented but never enforced | **Fixed** |
| R4-4 | Medium | One slow publish starved the other oracle for a whole tick | **Fixed** (feed) |
| R4-5 | Low | The publisher did not know the oracle's cooldown existed | **Fixed** (feed) |
| R4-9 | Medium | Neither clock alone measures elapsed time; the first fix froze the feed | **Fixed** (feed) |
| R4-6 | **High** | The oracle's bound is a ratchet: 2 minutes to double the price | **Fixed** (window bound) |
| R4-7 | Low | Phase two accepts any oracle address, and is not idempotent | **Open** |
| R4-8 | Low | `ETFFactory.admin` is immutable while the admin role is transferable | **Open** |

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


# Round 2: the first re-audit, with `LeekStaking` in scope

## R2-1 The share's role admin defaults let any admin mint without limit

**Severity**: Critical — demonstrated drain of shareholder reserves
**Category**: access-control
**Location**: `ETFShare`, constructor

**Description**: OpenZeppelin v5's `AccessControl.getRoleAdmin` returns
`DEFAULT_ADMIN_ROLE` for every role unless `_setRoleAdmin` says otherwise.
`ETFShare` granted `MINTER_ROLE` to the vault and left the default in place,
so the share's admin could grant `MINTER_ROLE` to itself, mint shares against
no MUSD at all, and redeem them for the reserves other buyers had paid in.
Nothing in the vault is involved: `redeem` prices shares off the oracle, and
the MUSD is simply there.

**Proof of Concept**: `test/AdminTheft.t.sol`, seven tests, written to pass
*only after* the fix. Before it, the admin minted and redeemed its way to the
whole reserve balance.

**Recommendation**: **fixed.** `_setRoleAdmin(MINTER_ROLE, MINTER_ROLE)` and
the same for `BURNER_ROLE`, so each role administers itself and the vault is
the only address that can ever grant it. The constructor also now takes
`maxSupply_` and `mint` reverts with `CapExceeded`, which bounds the damage of
any future hole in the same place.

## R2-2 The deployer key retained every role after a split deployment

**Severity**: Critical — the whole point of the two-phase deployment
**Category**: access-control / deployment
**Location**: `script/DeployMezoTestnet.s.sol`

**Description**: Every grant/renounce pair in `_configureOracle` is
conditional on the configured holder differing from the deployer, and
`PUBLISHER`, `GUARDIAN` and `TREASURER` all defaulted to the **deployer**. So
a two-phase deployment run with only `ADMIN` set — the documented way to
disarm the deployment key — left the deployer holding `PUBLISHER_ROLE` and
`GUARDIAN_ROLE` on both oracles. The deployer could then walk the price and
drain the vault through R2-1's mechanism or simply by redeeming at a
manufactured price.

**Recommendation**: **fixed.** The three roles default to the **ADMIN**
whenever `ADMIN` is set to someone else, and an operator who genuinely wants
the deployer to keep publishing says so with `PUBLISHER=<deployer>`.

## R2-3 A fee discount could be rented for one transaction

**Severity**: High
**Category**: staking-rewards / flashloans
**Location**: `LeekStaking.stake` / `unstake`, `IssuanceVault.effectiveFeeBps`

**Description**: The discount was read from the live stake with no holding
period, so one transaction could stake MEZO, buy at the maximum discount,
unstake, and return the MEZO to wherever it was borrowed from. The discount
was free, and so was every staker's claim on revenue they had been exposed to
for zero blocks.

**Recommendation**: **fixed** by an unstake cooldown, which is also what
rounds 3's two High findings were about. See R3-1.

## R2-4 One mistyped first answer bricked the feed permanently

**Severity**: High (permanent DoS)
**Category**: oracles
**Location**: `IndexOracle.publish`

**Description**: The first answer had no bound of any kind (L-1). A first
answer of 1e75 makes every later `publish` overflow `previous * 10_000`, and
there is no way to reset a round or lower `_latestRound`, so one mistyped
number bricked the feed for good and with it both vaults.

**Recommendation**: **fixed.** `MAX_ANSWER = 1e30`, checked on every round
including the first. See R4-1 for the half of this that the fix missed.

## R2-5 The reward path could freeze every redemption

**Severity**: High (DoS on the exit)
**Category**: general / dos
**Location**: `IssuanceVault._routeRevenue`, `effectiveFeeBps`

**Description**: `redeem` routed the treasury share of its fee into the
staking contract with an unbounded call. A staking contract that reverted, or
simply consumed all the gas, made every redemption revert — holders could not
exit, and the only remedy was the admin function whose misuse caused it.

**Recommendation**: **fixed**, in layers: every call into staking is a
bounded low-level call (`STAKING_READ_GAS = 120_000`,
`STAKING_WRITE_GAS = 300_000`) whose failure falls back to `feesAccrued`; the
discount is independently clamped to `MAX_DISCOUNT_BPS`; and
`emergencyUnsetStaking` gives the guardian a remedy that does not require the
admin. `try/catch` alone is **not** a defence here, because it forwards all
but 1/64 of the remaining gas — explicit stipends are.

## R2-6 The deploy script's default settlement token was the wrong MUSD

**Severity**: High
**Category**: deployment
**Location**: `script/DeployMezoTestnet.s.sol`, `DEFAULT_SETTLEMENT_TOKEN`

**Description**: The default was `0x118917a4…`, the MUSD in Mezo's own docs —
which reports `symbol() == "MUSD"` and `decimals() == 18` and is therefore
indistinguishable by the checks we had, but whose
`mintList(BorrowerOperations)` is **false**. No user can obtain it by
borrowing, so a vault settling in it is unusable. The live deployment escaped
only because the correct address happened to be passed by hand.

**Recommendation**: **fixed.** The default is `0xf9BBcCC0…`, and the script
now *asserts* `mintList(BorrowerOperations) == true` on chain 31611 rather
than trusting a constant. The split is documented in `README.md` and
`ADDRESSES.md` and was reported to Mezo's developer channel.

## R2-7 The deployed feed opened at 2x the index's own base

**Severity**: High (mispricing, live)
**Category**: deployment / oracles
**Location**: `script/DeployMezoTestnet.s.sol`, first answers

**Description**: Both indices are based at 100, and the script published
first answers of `200e8` and `180e8`. Because the first answer is exempt from
the deviation bound and later rounds can only move 20%, the live feed had to
*walk down*: it was observed on chain at 200 → 160 → 128 → 102.4 → 99.71.
Shares minted in that window were priced up to **2x** their index value, for
four rounds.

**Recommendation**: **fixed.** Both first answers are `100e8`, matching the
recorded `baseBasket` constants. A first answer that disagrees with the
index's base is now the one deploy-time number worth checking twice.

## R2-8 Index name squatting was permanent and unrecoverable

**Severity**: Medium
**Location**: `ETFFactory.deployETF`

**Description**: `deployETF` was permissionless on the argument that the
configuration is already frozen by `registerIndex`. But the *caller* chose the
token name, and the mapping is written once with no way to overwrite it, so
anyone could permanently bind a registered symbol to a token called anything.

**Recommendation**: **fixed.** `deployETF` is `onlyRole(DEFAULT_ADMIN_ROLE)`.

## R2-9 and R2-10 Two accounting bugs the invariant suite found

**Severity**: Medium each
**Category**: precision-math / staking-rewards
**Location**: `LeekStaking.notifyReward`, `_payout`

**Description**: Both were found by `test/LeekStaking.invariants.t.sol`, not
by reading the code.

*R2-9*: `notifyReward` added only the *distributed* portion to `rewardsOwed`,
so the truncated remainder was measured as new revenue on the next call and
credited twice. The sum of every holder's `pending` exceeded the total MUSD
the contract had ever received.

*R2-10*: floor-of-sum exceeds sum-of-floors, so the last claimant was left one
wei short and their **entire** reward was unwithdrawable. My first attempt at
this was to loosen the invariant, which was the wrong instinct; the bound that
ships is *derived* (one wei per holder, from the floored reward debt), not
tuned until green.

**Recommendation**: **fixed.** `rewardsOwed += incoming` takes the whole
amount and the undistributable remainder is tracked in `unallocated`.

# Round 3: auditing round 2's fixes

## R3-1 The cooldown fix reduced a 3600s wait to 35 seconds

**Severity**: High — R2-3 restored in full
**Category**: staking-rewards
**Location**: `LeekStaking._update`

**Description**: The cooldown took the **maximum** of the instantaneous
fraction `cooldown * value / balanceAfter` across transfers. Every step inside
one transaction shares a timestamp, so the maximum is just the largest single
fraction. Growing a position in 1% steps — 144 of them, in one transaction —
cost a **35-second** wait instead of 3600. The flash-stake attack was back.

The unit test passed because it staked once in bulk, and the invariant handler
never built a geometric ladder either, so neither noticed. A handler that
cannot reach a shape removes that shape from the state space while everything
still reports green.

**Recommendation**: **fixed.** The cooldown *accumulates* from whichever is
later of the existing deadline and now:

```solidity
uint256 base = coolingUntil[to] > block.timestamp ? coolingUntil[to] : block.timestamp;
coolingUntil[to] = base + (cooldown * value) / balanceAfter;
```

The same 144-step ladder now costs 17,500 seconds.

## R3-2 `claim()` was not gated by the cooldown at all

**Severity**: High
**Location**: `LeekStaking.claim`

**Description**: Only `unstake` checked the cooldown, so the *reward* leg of
R2-3 stayed free: grow a position, take the distribution it entitles you to,
and wait only to withdraw the principal. The test asserting `claim()` worked
during a cooldown has been inverted.

**Recommendation**: **fixed.** `claim` and `unstake` are gated on the same
clock, and both revert with `StillCooling(secondsRemaining)`.

## R3-3 `_tryPayout` ignored the ERC-20 return value

**Severity**: Medium
**Location**: `LeekStaking._tryPayout`

**Description**: It checked whether the *call* succeeded, not what the token
returned. A token that returns `false` instead of reverting zeroed the
staker's `claimable`, paid them nothing, and left the MUSD for whoever staked
next. The whole reason for the low-level call is that MUSD is upgradeable, so
not decoding the return defeated its own purpose — and the identical bug had
been fixed in `_routeRevenue` minutes earlier and left here.

**Recommendation**: **fixed**, with SafeERC20's tolerance for empty
returndata:

```solidity
bool moved = ok && (ret.length == 0 || abi.decode(ret, (bool)));
```

`test/mocks/MockFalseToken.sol` and `FalseReturnPayoutTest` cover it.

## R3-4 A typed `try ... returns (bool)` is uncatchable on empty returndata

**Severity**: Medium (latent, and a Solidity fact worth recording)
**Location**: `IssuanceVault`, three call sites; `LeekStaking._tryPayout`

**Description**: Solidity decodes a *successful* external call's return data
in the calling frame, **outside** the `catch`. So
`try IERC20(musd).transfer(...) returns (bool ok)` against a token that
returns no data reverts, and the `catch` does not run. The comment at the site
claimed it "checked the return value, which is what SafeERC20 would have
done" — SafeERC20 *tolerates* empty returndata and this reverted on it.

**Proof of Concept**: `test/TryCatchDecode.t.sol`, two tests.

**Recommendation**: **fixed.** All four sites are bounded low-level calls with
explicit gas stipends and a tolerant decode. This also closes the
gas-exhaustion variant, because `effectiveFeeBps` runs before any state change
in both `buy` and `redeem`.

## R3-5 The cooldown was usable as a 1-wei griefing weapon

**Severity**: Low
**Location**: `LeekStaking._update`

**Description**: My first cooldown reset the deadline on *any* balance
increase, so anyone could send a staker 1 wei of sMEZO and restart their full
cooldown, indefinitely. Found while writing the tests, not by the audit.

**Recommendation**: **fixed** by the proportional extension above: 1 wei into
a large balance extends the deadline by approximately nothing. Covered by
`test/CooldownGrief.t.sol`. A self-transfer short-circuit and
`if (to == address(this)) revert SelfTransfer();` close the two degenerate
cases.

## R3-6 A deploy-script assertion could not fire in the failing case

**Severity**: Low (false assurance, which is worse than none)
**Location**: `script/DeployMezoTestnet.s.sol`

**Description**: The publisher check was wrapped in `if (publisher != deployer)`
— exactly never true in the case where the deployer kept the role —
`GUARDIAN_ROLE` was never checked at all, and the script printed "The deployer
holds no roles on the oracles." underneath. These assertions existed
specifically so that line would not be an unchecked claim.

**Recommendation**: **fixed.** One `_assertDeployerDisarmed` helper, called
for both oracles, checking all three roles unconditionally — one helper rather
than two near-identical blocks, because a role going missing from one of two
blocks is how this happened. Proved to fire by running with
`PUBLISHER=<deployer>`.

# Round 4: auditing rounds 2 and 3, and the off-chain publisher

## R4-1 Small oracle answers are absorbing, pinning the feed at dust

**Severity**: High (permanent DoS, and worse than the revert it replaced)
**Category**: oracles / precision-math
**Location**: `IndexOracle.publish`, `feed/src/index-math.ts`

**Description**: R2-4 bounded the top of the answer range and left the bottom
at `answer > 0`. But the deviation bound is **multiplicative**, so small
answers are absorbing: at `previous == 1` and 2000 bps the right-hand side of
`difference * 10_000 > previous * maxDeviationBps` is 2000, which an integer
`difference * 10_000` cannot be below without being zero. **The only answer
ever publishable again is 1.** There is no way to reset a round or lower
`_latestRound`.

And the off-chain half makes it quiet rather than loud: `decidePublish`
computes its own bound as `(last * bps) / 10_000n`, which truncates to **0**
for a small `last`, so every target clamps to the current value and the
heartbeat branch republishes the pinned answer every 1800s forever. The feed
therefore **never goes stale**, `price()` never reverts, no monitor fires, and
both vaults trade at a price of ~0 indefinitely. A reachable state — one
mistyped first answer — in which the protocol silently sells shares for
nothing.

**Proof of Concept**: `test_theFloorIsNotAbsorbing`,
`test_firstPublishIsExemptFromTheBoundButNotFromTheFloor` (inverted from a
test that *asserted* publishing 1 wei of price worked), and in the feed
`"the per-round bound is never zero, so a small answer is not absorbing"`.

**Recommendation**: **fixed**, on both sides.
`MIN_ANSWER = 1e6` — 0.01 index points at 8 decimals — checked on every round
including the first, which leaves four orders of magnitude of headroom below
an index based at 100 and a permissible move of 20,000 units at the floor, so
no reachable answer is absorbing. Belt and braces beside it, a one-unit step
is permitted unconditionally, so the bound can never again be arithmetically
unsatisfiable for any `previous`. Off chain the bound is floored at 1 and
every answer, including a first round, is raised to the oracle's own
`MIN_ANSWER` rather than sent to revert.

## R4-2 The admin could undo the guardian's rescue in the next block

**Severity**: High (the guardian's power was decorative)
**Category**: access-control
**Location**: `IssuanceVault.setStaking`

**Description**: `emergencyUnsetStaking` was added in round 2 so a guardian
could detach a staking contract that had frozen trading (R2-5) without
needing the admin — whose mistake is the likely cause. But `setStaking` is
admin-gated with no timelock, no cooldown and no awareness of what the
guardian had just done, so the admin could re-point the vault at the same
contract in the very next block, as often as the guardian unset it. The
remedy was not a remedy.

**Proof of Concept**:
`test_theAdminCannotUndoTheGuardiansRescueImmediately`.

**Recommendation**: **fixed.** `emergencyUnsetStaking` sets
`stakingLockedUntil = block.timestamp + STAKING_RELOCK_DELAY` (24 hours) and
emits `StakingRelockUntil`; `setStaking` reverts with
`StakingLocked(secondsRemaining)` inside that window. A fixed delay rather
than a governance timelock, because the asymmetry *is* the fix: detaching is
instant, re-attaching waits. Setting to **zero** stays allowed throughout, so
the lock can never trap the vault pointed at a hostile contract —
`test_unsettingToZeroIsNeverLocked`.

## R4-3 `guardian == treasurer` was documented but never enforced

**Severity**: Medium (trust-model violation)
**Location**: `ETFFactory.registerIndex`, both deploy scripts

**Description**: `registerIndex`'s comment has said "separate keys" since the
first version, and nothing checked it — while both deploy scripts defaulted
*both* roles to the admin. `emergencyUnsetStaking` was delegated to the
guardian on the explicit written argument that unsetting "cannot take value:
the treasury share simply accrues to `feesAccrued`, where only
`TREASURER_ROLE` can reach it". That argument is true only if the two differ.
One address holding both could unset staking, let trading continue looking
entirely normal while every staker's rewards quietly stopped growing, and
then withdraw the fees that accrued instead — leaving a single `StakingSet(0)`
in the log.

**Recommendation**: **fixed.** `registerIndex` reverts with
`SameHolder(address)`, and both deploy scripts `require` the two to differ
with a message naming what to set. `emergencyUnsetStaking` additionally
requires `paused`, so detaching is part of a declared incident rather than a
standing power: it does not stop a determined holder of both roles, but it
makes the step loud.

## R4-4 One slow publish starved the other oracle for a whole tick

**Severity**: Medium — the one that can take a vault down
**Category**: oracles / liveness
**Location**: `feed/src/service.ts`, `tick()`

**Description**: `tick()` loops over the indices **sequentially** and
`await`ed `waitForTransactionReceipt` with no timeout. Mezo's
`eth_getTransactionReceipt` returns null for minutes after a transaction is
already mined, so a single slow receipt on GOLOGGLE blocked AMEZON for the
entire tick — repeatedly, long enough to push AMEZON past `maxStaleness`, at
which point `price()` reverts and its vault stops trading, caused entirely by
the other index.

Separately, `setInterval` fires on a wall clock and does not await the
previous callback, so a tick slower than `INTERVAL_SECONDS` **overlapped** the
next one. Two overlapping ticks publish from the same key concurrently, and
Mezo rejects the loser as out of sequence — a self-inflicted error that reads
in `/prices` as an RPC fault.

**Recommendation**: **fixed**, and deliberately *not* by parallelising:
one key means one nonce sequence, and Mezo rejects out-of-sequence sends, so
concurrency would trade this bug for a worse one. Instead the receipt wait is
bounded (`RECEIPT_TIMEOUT_MS`, default 20s) and a timeout is **not** treated
as an error — the transaction is submitted either way, and the re-read below
it, or failing that the next tick, reports what actually landed. A `ticking`
flag makes an overlapping tick skip rather than queue, because the tick in
flight is already doing the skipped tick's work with fresher data.

## R4-5 The publisher did not know the oracle's cooldown existed

**Severity**: Low
**Location**: `feed/src/{service,index-math}.ts`

**Description**: `minRoundInterval` was added to the oracle in round 2 and
never reached the off-chain side, so after every restart the feed sent a
publish that reverted with `TooSoon` and surfaced in `/prices` as a feed
error.

**Recommendation**: **fixed.** `minRoundInterval` and `MIN_ANSWER` are in
`ORACLE_ABI`, read each tick, and passed to `decidePublish`, which holds with
a reason naming both numbers. A hold is not a failure and no longer reads as
one.

## R4-6 The oracle's deviation bound was a ratchet

**Severity**: High — reclassified up from Medium on measuring it
**Category**: oracles
**Location**: `IndexOracle.publish`, `feed/src/index-math.ts`

**Description**: The bound limits one step, not a sequence — M-1 restated with
numbers now that `minRoundInterval` exists. At 2000 bps and a 30-second
interval a compromised publisher doubles the price in **four rounds, 120
seconds**, and every one of those publishes is individually legal. There is no
single oversized step to catch. `maxStaleness` is an hour and gives a guardian
no brake at all: nothing goes stale while the walk is happening, because the
walk *is* fresh publishes.

It was filed Medium and left open on the argument that a cumulative bound is
"real design rather than a line". Measuring how fast the ratchet actually
turns is what moved it: 120 seconds is shorter than the time to notice an
alert, so in practice the guardian's pause did not exist for this attack.

**Recommendation**: **fixed.** A second bound, measured not from the previous
answer but from an anchor that refreshes only once `deviationWindow` has
elapsed. Inside a window the price may move `maxWindowDeviationBps` **in
total**, however many in-bound rounds it takes. Deployed at 20% per hour, so
one round may still use the whole budget — a genuine market gap gets through
in one step — while a sequence of them cannot.

The anchor refreshes lazily inside `publish` rather than needing to be
advanced by a call, because a window that only moves when somebody remembers
to move it is a window that stays open. It refreshes to the *previous*
published answer, so the budget is spent relative to where the feed was when
the window opened. `anchorAnswer` and `anchorAt` are public so an alert can be
built on the remaining budget.

**Checked after the per-round bound**, deliberately, for the same reason the
interval is checked before it: a publish should fail for the most immediate
reason. If one step is too large that is the fact worth reporting; only when
every individual step is legal does "this window's budget is spent" become the
real reason — and that is precisely the case this bound exists for.

**Measured, not predicted.** `test/Ratchet.t.sol` walks the price as fast as
the oracle permits and reports the wall clock: **11,010 seconds**, a little
over three hours, against 120 seconds before. My first assertion in that test
said *four* hours and failed at 3.06; the test now holds the bound to what it
actually delivers and the comments that claimed four hours are corrected.
Three other existing tests rejected themselves when this landed, which is the
bound working — each walked the price over several rounds inside one hour.

**The honest limit of this design.** The window is fixed rather than sliding,
so the budget can be spent at the end of one window and the whole of the next
budget immediately after it rolls: worst case is **twice the budget in a short
span, at a boundary, once**. Every step after that costs a further window,
which is why doubling still takes hours and why the figure is three rather
than four. That worst case is asserted directly in
`test_theWorstCaseAtAWindowBoundaryIsTwiceTheBudgetOnce` rather than left as a
claim in a comment. A true sliding bound needs the answer from exactly
`deviationWindow` ago, which means storing roughly 120 entries at a 30-second
interval, and that cost is not worth buying the last factor of two.

**Mirrored off chain**, because R4-5 is the same lesson: without it the
service would send a perfectly in-bound step that the oracle rejects with
`WindowDeviationTooLarge`, every tick, for the rest of the window — a
self-inflicted error reading in `/prices` as an RPC fault. `decidePublish`
clamps to whichever of the three bounds is tightest and names the one that
bit, and it accounts for the lazy refresh: the budget available to the next
publish is measured from `last` when the window is about to roll and from
`anchorAnswer` when it is not.

The constructor also rejects `deviationWindow <= minRoundInterval`, the
configuration in which the window expires between rounds and bounds nothing —
which would make this look implemented while doing nothing, and that is worse
than not having it.

## R4-9 Neither clock alone measures elapsed time correctly

**Severity**: Medium (liveness, and a fix that broke differently)
**Category**: oracles / liveness
**Location**: `feed/src/service.ts`, `elapsedSince`

**Description**: Two failures within an hour of each other, the second being
my own fix for the first.

`Date.now()` minus an on-chain timestamp compares two unrelated clocks. The
contract compares `block.timestamp` to `block.timestamp`, so all the skew
between the publisher's host and the chain lands in our number — and it can go
**negative**, which makes `secondsSinceLast < minRoundInterval` true forever.
The feed then stops publishing entirely while reporting a healthy hold, which
is the worst available failure: no error, no alert, and every consumer goes
stale an hour later.

Reading the latest block's timestamp instead is worse on an idle chain. Anvil
mines only when a transaction arrives, so with nothing happening the chain
clock is frozen: the local stack sat at `1s since the last round`
indefinitely and never produced a second round. Visible in the browser as a
stale oracle, an unreadable price and "Backing unknown".

**Recommendation**: **fixed** — the larger of the two. The quantity actually
wanted is the timestamp of the block that will *include* the publish, which is
in the future relative to the latest block, and the maximum predicts it better
in both cases. The asymmetry agrees: too small means the feed holds and stops,
too large means at worst one publish reverts with `TooSoon` and the next tick
corrects. `scripts/local-up.sh` also runs anvil with `--block-time 2`, because
a rehearsal that cannot publish proves nothing.

Worth recording as a finding rather than a commit note, because it is the
second time in this audit that a local run surfaced something no unit test
could: the first was R3-1's geometric ladder, which the handler could not
reach.

## R4-7 Phase two accepts any oracle address, and is not idempotent (open)

**Severity**: Low
**Location**: `script/ConfigureMezoTestnet.s.sol`

**Description**: `registerIndex` binds an oracle to a symbol permanently, and
phase two takes both addresses from the environment with no on-chain
validation — not `decimals`, `maxStaleness`, `maxDeviationBps`,
`minRoundInterval`, the admin role, the description, nor even
`gologgle != amezon`. Two environment variables transposed produce a
permanent, unrecoverable binding. The script is also all-or-nothing: a partial
landing (likely on Mezo, where a receipt can appear to fail for minutes after
succeeding) cannot be re-run.

**Recommendation**: **open.** It does not block today's deployment, which is
single-key and does not use phase two. Before any deployment that does: read
every parameter back off each oracle and `require` it, check `isFresh()` in
pre-flight, and make each step skip work already done.

## R4-8 `ETFFactory.admin` is immutable while the admin role is transferable (open)

**Severity**: Low (split authority)
**Location**: `ETFFactory`

**Description**: The stored `admin` address is immutable, but
`DEFAULT_ADMIN_ROLE` can be granted and renounced, so the two can disagree.
Anything reading `admin()` as the authority — a front end, a monitor — would
then be reading a stale answer.

**Recommendation**: **open.** Either derive it from the role or drop the
field. Low because nothing in the contracts reads it for an authorisation
decision; it is a correctness trap for readers.

## Slither

`slither . --filter-paths "lib|test"`, version 0.11.6, re-run after round 4
on 33 contracts with 102 detectors: **0 High, 0 Medium, 14 Low, 7
Informational**.

**Two corrections to earlier versions of this section.** The first said
slither "reports nothing above Low", which was false from the moment
`LeekStaking` entered the tree: it reported **2 High and 11 Medium**. The
second said those were "every one accepted with a reason", which was true but
left the reasons only here, in a document a reader of the code does not have
open.

They are now **suppressed at the source with the reason attached** — seven
`slither-disable-next-line` directives, each preceded by the paragraphs below,
in the file. This is deliberately not a `detectors_to_exclude` in a config
file: a global exclude of `incorrect-equality` would hide the next genuine
`balanceOf(x) == y` as well, and the point of the exercise is that a clean run
means something.

| Impact | Detector | Count | Action |
|---|---|---|---|
| High | `reentrancy-balance` | 2 | suppressed at the source, below |
| Medium | `incorrect-equality` | 8 | suppressed at the source, below |
| Medium | `reentrancy-no-eth` | 2 | suppressed at the source, below |
| Medium | `divide-before-multiply` | 1 | suppressed at the source, below |
| Low | `timestamp` | 8 | accepted (staleness, cooldowns and the deviation window are time comparisons) |
| Low | `return-bomb` | 2 | accepted; the returndata is bounded by the decode and the gas by the stipend |
| Low | `reentrancy-events`, `reentrancy-benign`, `missing-zero-check` | 4 | accepted |
| Informational | `low-level-calls`, `missing-inheritance`, `naming-convention`, `unindexed-event-address` | 7 | accepted |

**The two High findings are both the balance-delta measurement pattern**, and
both are there because of earlier findings in this report. `IssuanceVault.buy`
and `LeekStaking.stake` read `balanceOf(this)`, transfer, read again, and use
the difference — which is how a fee-on-transfer token is caught (L-2, and
`MockFeeToken`) rather than minting against MUSD that never arrived. Slither
sees a balance read before an external call and used in a condition after it,
which is the shape of a stale-balance bug and is in this case the shape of the
fix for one.

Accepted because reentrancy is not reachable: `buy`, `redeem`, `fund` and
`withdrawFees` all carry `nonReentrant`, and so do `stake`, `unstake`, `claim`
and `notifyReward`. OpenZeppelin's guard is one lock per contract, so there is
no sibling function to re-enter through — verified by reading the modifier
list rather than assumed. Were the lock ever removed, the direction matters:
a reentrant drain understates `received` and **reverts**; only a reentrant
*deposit* could overstate it, and the only two paths that add MUSD hold the
same lock.

`reentrancy-no-eth` x2 is the same argument. In `LeekStaking._tryPayout` the
writes after the external call are the **failure** bookkeeping — restoring
`rewardsOwed` and crediting `claimable` when the token refused — which has to
happen after the call because it is conditional on its result. In
`IssuanceVault.redeem`, `_routeRevenue` credits `feesAccrued` after its
bounded calls for the same reason: the fallback exists precisely for when the
call did not work. Both callers are `nonReentrant`.

`divide-before-multiply` in `notifyReward` is **deliberate and load-bearing**,
and reverting it would reintroduce R2-9. `distributed` must be the amount the
*floored* `perShare` actually credits, so the remainder can be tracked in
`unallocated` instead of being re-measured as new revenue on the next call:

```solidity
perShare = (incoming * ACC_PRECISION) / supply;
distributed = (perShare * supply) / ACC_PRECISION;
unallocated += incoming - distributed;
```

Computing `distributed` without the round trip through the division would
make it disagree with what holders can actually claim, which is the bug.

`incorrect-equality` x8 are all `== 0` on a token amount, a payout or
`ret.length`. The detector exists for strict equality against a **balance**,
where a donation breaks the comparison; none of these is a balance, and each
one is an early return on "nothing to do".

Round 1's six findings and their dispositions stand unchanged:

| Finding | Action |
|---|---|
| `divide-before-multiply` in `redeem` | **fixed.** The fee now comes from the undivided product, so the two divisions no longer compound |
| `reentrancy-no-eth` / `-benign` in `deployETF` | **fixed.** Registry state is written before the calls into the newly deployed vault, so the function is Checks-Effects-Interactions whatever it grows into |
| `reentrancy-events` in `deployETF` | **accepted.** `IndexDeployed` is emitted after the role handover because it announces a *finished* deployment; the callee is a contract constructed three lines above, so there is no untrusted code in the path |
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
| Unit + fuzz tests | done, **134 tests across 13 suites**, all passing. The proportionality fuzz needed 20,000 runs and four attempts: the assertion is only sound with cross-multiplication (never a ratio division) *and* a pending floor of 1e6, because `pending` is itself floored and a 192-wei share carries 0.3% truncation |
| Invariant tests | done. Five invariants over a bounded handler (buy, redeem, fund, price moves inside the oracle's bound, time passing, fee withdrawal): fees never exceed the balance, MUSD is conserved across every path, the cap holds whatever the price did, supply is held only by actors the vault minted to, and the oracle never regresses. 256 runs x 8192 calls, zero reverts |
| Fork test against real MUSD on Mezo testnet | done. `test/fork/MezoFork.t.sol`, pinned at block 16,198,929. Reads `symbol() == "MUSD"` and `decimals() == 18` off the deployed token (L-5), measures `transfer` and `transferFrom` on both sides to show no fee and no rebase (L-2), and buys and redeems through a vault deployed against it: 1000 MUSD at a 200e8 feed answer mints 4.975 shares, so the 8-to-18 decimal scaling is right on the real token. Skips with a reason when the RPC is unreachable |
| Gas snapshot | done |
| `slither`, every high/medium addressed | done; 0.11.6 in `.venv`. **33 results, including 2 High and 11 Medium, every one accepted with a reason above rather than none outstanding.** The earlier claim of "nothing above Low" is corrected in that section |
| Staking rewards: accumulator, reward debt, no flash advantage | done. `accMusdPerShare` + `rewardDebt`, `notifyReward` measuring its own balance, an accumulating unstake cooldown gating both `unstake` and `claim`, and 8 invariants over a handler that includes `growInSteps` — the shape R3-1 hid in |
| Every fix re-audited as new code | done from round 3 onward, and it is what found R3-1, R3-2, R4-1 and R4-2 |
| Invariant handler reaches every function it claims to | done, after R3-1. A handler that silently cannot reach a shape removes it from the state space while the suite still reports green |
| Verified source after deploy | pending deployment |
| **Open findings accepted before deployment** | R4-7 (phase-two validation, unused by this deployment) and R4-8 (the `admin` field). Neither is a path to funds, and neither is reachable by this deployment's single-key path. **R4-6, the ratchet, is closed** — it was the one this row previously said to close before anything else |
