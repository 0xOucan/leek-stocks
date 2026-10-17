# Addresses

**Never trust an address in a document, including this one.** Every entry below
says how it was verified and when. Re-verify before you send anything to it:

```sh
cast code <address> --rpc-url <rpc>            # empty output means no contract
cast call <address> "symbol()(string)" --rpc-url <rpc>
cast call <address> "decimals()(uint8)" --rpc-url <rpc>
```

An address that is wrong is funds that are gone, and the failure is silent: a
transfer to a plausible-looking address with no contract behind it succeeds.
Addresses here are EIP-55 checksummed, which catches a typo but not a
substitution.

## Mezo

| Chain | Id | Gas token | RPC | Explorer |
|---|---|---|---|---|
| Mezo mainnet | 31612 | **BTC**, 18 decimals | `https://mezo.drpc.org`, `https://mezo-mainnet.boar.network` | `https://explorer.mezo.org` |
| Mezo testnet | 31611 | **BTC**, 18 decimals | `https://rpc.test.mezo.org` (single operator) | `https://explorer.test.mezo.org` |

Chain ids read live on **2026-10-16** by `eth_chainId`: `0x7b7c` on mainnet
through dRPC and Boar, `0x7b7b` on testnet. Gas is BTC, not ether, on both.

## MUSD

| Network | Address | How verified | When |
|---|---|---|---|
| Mezo mainnet | `0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186` | `symbol()` = MUSD, `decimals()` = 18, over dRPC; cross-checked against Mezo's published contracts reference | 2026-10-16 |
| **Mezo testnet (what we settle in)** | `0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af` | `symbol()` = MUSD, `decimals()` = 18, and **`mintList(BorrowerOperations)` = true**, so this is the one a user can obtain by borrowing. Read back from each deployed vault with `musd()`. | 2026-10-17 |
| Mezo testnet (the documented one, **not** used) | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` | `symbol()` = MUSD and `decimals()` = 18 over `rpc.test.mezo.org`, and asserted by `test/fork/MezoFork.t.sol` at a pinned block — but `mintList(BorrowerOperations)` is **false**, so nobody can obtain it by borrowing. See the two-MUSD table below. | 2026-10-17 |
| Ethereum | `0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186` | `symbol()` = MUSD on an Ethereum RPC | 2026-10-16 |
| Base | `0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186` | `symbol()` = MUSD on a Base RPC | 2026-10-16 |
| **BNB Chain** | **none** | `eth_getCode` at the address above returned empty on BNB | 2026-10-16 |

One address on three chains because Wormhole NTT carries it, which is a
property of that bridge and not a general rule: most tokens differ per chain,
so never reuse an address across chains without reading it there.

**No MUSD exists on any testnet except Mezo's.** Checked by `eth_getCode` on
Sepolia, Base Sepolia and BSC testnet: all empty. That is why the markets on
those chains use mock tokens under the `leek` prefix.

## MEZO

| Network | Address | How verified | When |
|---|---|---|---|
| Mezo mainnet | `0x7B7c000000000000000000000000000000000001` | `symbol()` = MEZO, `decimals()` = 18 | 2026-10-16 |
| Ethereum, Base, BSC | `0x8e4cbBcc33dB6c0a18561fDE1F6bA35906d4848b` | `symbol()` = MEZO on each chain's own RPC | 2026-10-16 |
| Sepolia, Base Sepolia | same address, contract present | `eth_getCode` non-empty; symbol confirmed on Sepolia | 2026-10-16 |
| BSC testnet | **none** | `eth_getCode` empty | 2026-10-16 |

No testnet MEZO address is published in Mezo's contracts reference; the faucet
hands out test MEZO, so the address can be read from a faucet transaction.

## Two MUSD contracts on Mezo testnet, and which one to use

**Resolved on 2026-10-17 by asking the chain.** There are two live tokens on
Mezo testnet (31611) that both answer `symbol() = "MUSD"` with 18 decimals:

| Address | Code size | `BorrowerOperations` may mint it | What it is |
|---|---|---|---|
| `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` | 6,438 bytes | **no** (`mintList = false`) | the one Mezo's public contracts reference lists as "Testnet MUSD" |
| `0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af` | 9,011 bytes | **yes** (`mintList = true`) | the one the **live borrow system** mints, named "Mezo USD" |

Evidence, reproducible:

```sh
R=https://rpc.test.mezo.org
# The deployed BorrowerOperations names its own token and trove manager.
cast call 0xa14cbA6DD12D537A8decc7dd3c4aC413B8711eba "musd()(address)" --rpc-url $R
#   -> 0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af
cast call 0xa14cbA6DD12D537A8decc7dd3c4aC413B8711eba "troveManager()(address)" --rpc-url $R
#   -> 0x7FE0A5a7EeBD88530c58824475edEae33424671F   (matches the file below)
# And only one of the two tokens grants it mint rights.
cast call 0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af "mintList(address)(bool)"   0xa14cbA6DD12D537A8decc7dd3c4aC413B8711eba --rpc-url $R   # true
cast call 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503 "mintList(address)(bool)"   0xa14cbA6DD12D537A8decc7dd3c4aC413B8711eba --rpc-url $R   # false
```

So `SCALE_TEST_ADDRESSES.md` in `mezo-org/musd` is **not** stale or wrong: its
addresses are live on Mezo testnet and they are the borrow system's. What is
misleading is reading either source alone. The documented address is a
different deployment of the same token contract, and the borrow system cannot
mint it.

**Which one we settle in, and why.** The vault's settlement token is a
constructor parameter, so this is a deployment choice rather than a code
change. Settling in **`0xf9BBcC…`**, the borrowable one, is what makes the
whole demo join up: borrow MUSD against BTC through Mezo's own protocol, then
buy a parody index with it, then approve the purchase on hardware that decoded
the calldata itself. Settling in the documented token would leave a user who
borrowed holding the wrong MUSD, and the error would be a plain allowance
failure that explains nothing.

**Confirm before deploying** by re-running the two `mintList` calls above: if
Mezo redeploys the trove system, the answer moves and this section is stale.

## Mezo's own lending (not ours)

Borrowing MUSD against BTC on Mezo is Mezo's protocol, and we integrate it
rather than reimplement it. The interface is in `mezo-org/musd`
(`IBorrowerOperations`): `openTrove`, `addColl`, `withdrawColl`,
`withdrawMUSD`, `repayMUSD`, `closeTrove`, `adjustTrove`, every parameter
statically typed.

**Deployed on Mezo testnet, confirmed live on 2026-10-17** by `eth_getCode`
and by the cross-checks in the section above. These come from
`SCALE_TEST_ADDRESSES.md` in `mezo-org/musd`, and the chain agrees with them:

| Contract | Address |
|---|---|
| `BorrowerOperations` | `0xa14cbA6DD12D537A8decc7dd3c4aC413B8711eba` |
| `TroveManager` | `0x7FE0A5a7EeBD88530c58824475edEae33424671F` |
| `MUSD` (the borrowable one) | `0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af` |
| `PriceFeed` | `0xf28B0d5165b4ad9D5C04CdE1E37B400f8ca5A8cb` |
| `StabilityPool` | `0xCfdb903cD2Dc14E24e78130A63b20Ba65107262A` |
| `HintHelpers` | `0x8ed65f0Df4B1145f8E6D298735d0F77bFb5f0136` |
| `InterestRateManager` | `0x25D5267a70Ee9a4801BcBDBABe513034926a8559` |

`BorrowerOperations` and `TroveManager` are 1,160 bytes each, which is proxy
size, so the implementations behind them can change without these addresses
changing. Verify with `cast call` before relying on any of them, and prefer
asking a contract for its peers (as above) over trusting a list.

### What the front end calls, and the parameters it reads

The dapp opens positions here directly (`web/src/mezoBorrow.ts`), so these are
load-bearing. Every one was recovered by calling the live contract, because
the implementation behind the proxy is **not verified** and publishes no ABI.

```
openTrove(uint256 debtAmount, address upperHint, address lowerHint)  payable
  selector 0x2f3a6d98
```

**This is not Liquity v1's signature**, which is what the documentation and
every model will tell you: there is no `maxFeePercentage`, and the collateral
is `msg.value` rather than an argument. The hints are insertion points into
the sorted trove list; zero is always correct and merely costs gas.

Read, never hardcoded, because all four are governance-settable or move:

| Call | On | Value on 2026-10-17 | Means |
|---|---|---|---|
| `minNetDebt()` | `BorrowerOperations` | `1800e18` | smallest borrow accepted |
| `MCR()` | `BorrowerOperations` | `1.1e18` | 110%; liquidatable below |
| `CCR()` | `BorrowerOperations` | `1.5e18` | the system's recovery threshold |
| `MUSD_GAS_COMPENSATION()` | both | `200e18` | added to the **debt**, held as the liquidation reserve, returned on close |
| `fetchPrice()` | `PriceFeed` | `2e25` | MUSD per BTC — **$20,000,000** on testnet |
| `getTroveStatus(address)` | `TroveManager` | `0`/`1` | 0 nonExistent, 1 active, 2 closedByOwner, 3 closedByLiquidation |
| `getTroveDebt` / `getTroveColl` | `TroveManager` | — | the position |

**There is no readable issuance fee.** Every getter Liquity v1 would expose —
`getBorrowingFee`, `getBorrowingRate`, `getBorrowingFeeWithDecay`,
`borrowingFeeFloor` — reverts or does not exist here. Opening an 1800 MUSD
trove produced a debt of 2009.0138 MUSD (1800 + 200 + 9.01), so the fee is
0.5%; the front end quotes 1% instead, because a quote that understates the
debt understates the collateral needed and the cost of being wrong in that
direction is a liquidation.

One address holds at most one trove: a second `openTrove` reverts. The page
reads `getTroveStatus` and shows the existing position instead of a form.

## Ours

Nothing is deployed yet. When it is, `script/DeployMezoTestnet.s.sol` prints
every address; record them here with the date and the explorer link, and
verify the sources on the explorer the same day.

**Deployed to Mezo testnet (31611) on 2026-10-17**, settling in the
**borrowable** MUSD (`0xf9BBcC…`), from `0x9c77c6fafc1eb0821F1De12972Ef0199C97C6e45`.

| Contract | Address | Explorer verification | Bytecode |
|---|---|---|---|
| `ETFFactory` | `0xCdF824BF8ed17285e40DB081131Cb3e7eC92b084` | **verified** | matches |
| `IndexOracle` GOLOGGLE | `0x7fCb1ed8d6fAaEF00AA5A0104A062299ab7D5BF6` | **verified** | matches |
| `IndexOracle` AMEZON | `0x5Ed8205bA3DC7075099cFC4b2D4b7f2fF8a9cf9D` | **verified** | matches |
| `IssuanceVault` GOLOGGLE | `0x68A86E4503FCA82ac9eB229Be655E355A019bcC3` | not indexed | matches |
| `ETFShare` GOLOGGLE | `0x35e0c3df250a1ea46bde6eef2D6ad22C924FCB88` | not indexed | matches |
| `IssuanceVault` AMEZON | `0x87c6925798769012085b9a71FabA87c31F894f18` | not indexed | matches |
| `ETFShare` AMEZON | `0x239cC4EB08B92fdB486F00C93E2D47b38c0EBAd4` | not indexed | matches |

Live state when recorded: GOLOGGLE oracle at round 1, answer `2e10` (200.00000000
at 8 decimals); its vault prices a share at `200e18`; `feeBps` 50,
`reserveShareBps` 5000, `coverageBps` 10000, reserves 0 because nobody has
bought yet. `musd()` on both vaults returns `0xf9BBcC…`.

### Keys, and what each one can do

Set on 2026-10-17, verified by reading `hasRole` on both oracles:

| Keystore | Address | Holds | Can therefore |
|---|---|---|---|
| `monad-deployer` | `0x9c77c6fafc1eb0821F1De12972Ef0199C97C6e45` | `DEFAULT_ADMIN_ROLE`, guardian, treasurer | pause, move fees, reconfigure, grant roles — **not** publish |
| `leek-publisher` | `0x843914e5BBdbE92296F2c3D895D424301b3517fC` | `PUBLISHER_ROLE` only | push prices, inside an immutable 20% per-round bound |

The deployer's publisher rights were **revoked** on both oracles, so the only
key that can move a price is the one with nothing else on it — which is the
key that has to live on a server. The deployer keeps admin, so it can grant
them back if the publisher key is ever lost.

`scripts/sweep-publisher.sh` sends all but a gas float back to the deployer,
because a hot key should hold only what it burns.

### Why four of them are "not indexed" rather than verified

Mezo's testnet explorer **never indexed the contracts the factory deployed**.
Its API answers `is_contract: false` for all four, with no creation
transaction, although `eth_getCode` returns their code. Blockscout therefore
has nothing to match a submission against, and `forge verify-contract` returns
`Fail - Unable to verify` for exactly those four while succeeding for the
three deployed directly from the account. An indexer limitation, not a
property of the contracts.

**So they are verified against the source instead of against the explorer:**

```sh
./scripts/verify-bytecode.sh
```

It compares each deployed runtime bytecode with a local `forge build`, masking
the immutable regions the compiler reports — solc writes immutable *values*
into runtime code, which is why two vaults from identical source differ in
exactly those bytes and a naive comparison fails at identical lengths. All
seven match, every unmasked byte. Anyone can reproduce it from this repository
with no key and no explorer.

Retry the explorer verification later if the indexer catches up; nothing is
lost by it staying unindexed, except convenience.
