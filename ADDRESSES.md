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
| Mezo testnet | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` | same, over `rpc.test.mezo.org`; also asserted by `test/fork/MezoFork.t.sol` at a pinned block | 2026-10-16 |
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

## Mezo's own lending (not ours)

Borrowing MUSD against BTC on Mezo is Mezo's protocol, and we integrate it
rather than reimplement it. The interface is in `mezo-org/musd`
(`IBorrowerOperations`): `openTrove`, `addColl`, `withdrawColl`,
`withdrawMUSD`, `repayMUSD`, `closeTrove`, `adjustTrove`, every parameter
statically typed.

**The deployed testnet addresses are not published** and are deliberately
absent here rather than guessed. Note the trap: `SCALE_TEST_ADDRESSES.md` in
that repository lists a full set, but its MUSD is `0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af`,
which is **not** the documented testnet MUSD above. That file is a different
deployment and must not be used as the testnet address book. Close the gap by
reading `BorrowerOperationsAddressAdded` from the MUSD contract (chunked: the
public RPC caps `eth_getLogs` at 10,000 blocks) or by taking the addresses from
the testnet dApp and confirming each against MUSD's `mintList`/`burnList`.

## Ours

Nothing is deployed yet. When it is, `script/DeployMezoTestnet.s.sol` prints
every address; record them here with the date and the explorer link, and
verify the sources on the explorer the same day.

| Contract | Network | Address | Verified |
|---|---|---|---|
| `IndexOracle` GOLOGGLE | Mezo testnet | — | — |
| `IndexOracle` AMEZON | Mezo testnet | — | — |
| `ETFFactory` | Mezo testnet | — | — |
| `ETFShare` / `IssuanceVault` GOLOGGLE | Mezo testnet | — | — |
| `ETFShare` / `IssuanceVault` AMEZON | Mezo testnet | — | — |
