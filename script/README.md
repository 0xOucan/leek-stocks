# Deployment

`DeployMezoTestnet.s.sol` deploys the whole stack for the two parody indices:
one `IndexOracle` per index with its first round published in the same
broadcast, one `ETFFactory`, then `registerIndex` and `deployETF` for
`GOLOGGLE` and `AMEZON`.

## Invocation

```sh
forge script script/DeployMezoTestnet.s.sol \
  --rpc-url mezo_testnet --account monad-deployer \
  --sender <address> --broadcast
```

`--account` names a keystore entry, so Foundry prompts for its password
interactively. **No private key and no password goes on a command line, in an
environment variable, or in this repository.** Drop `--broadcast` to simulate
first; the script reverts on a chain id other than 31611, so a wrong
`--rpc-url` fails before it spends anything.

## Parameters

Everything is a constant at the top of the script or one of these environment
variables, read in one place in `run()`:

| Variable | Default | Why you would set it |
|---|---|---|
| `SETTLEMENT_TOKEN` | real MUSD, `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` | a fork or a local chain |
| `ADMIN` | the sender | parameter changes, `registerIndex`, `deployETF` |
| `PUBLISHER` | the sender | the off-chain price service's key, and only that |
| `GUARDIAN` | the sender | pause authority; should be a multisig |
| `TREASURER` | the sender | may move accrued fees, nothing else |

The oracles are deployed with the sender as temporary admin so the first round
can be published in the same broadcast; the configured holders are then
granted their roles and the sender renounces what it held. `registerIndex` is
admin-gated, so if `ADMIN` is a separate key the script stops after the
oracles and the admin finishes the registration itself.

**A single-key deployment is for testnet only.** Findings M-1 and M-2 are
exactly this: one key that can push prices, pause the feed, raise the share
cap and withdraw fees is every centralisation risk in the audit report at
once. The script logs a warning when it detects that shape.

## Checklist

1. **Confirm `decimals()` on the live MUSD** (finding L-5). The vault caches
   it at construction and MUSD is upgradeable, so a changed value would
   misprice every trade by a power of ten. `forge test --match-path
   "test/fork/*"` asserts `symbol() == "MUSD"` and `decimals() == 18` against
   the deployed token, and the script itself reverts if the live value is not
   18. Re-pin the fork block if it has aged.
2. **Fund the sender with test BTC for gas.** Mezo's gas token is BTC with 18
   decimals, not ETH; a deployer holding only MUSD cannot send a transaction.
3. **Publish the first oracle round in this same reviewed step** (finding
   L-1). Round 1 is exempt from the deviation bound — it is the one answer a
   publisher sets freely — so it belongs in the deployment the reviewer read,
   not in a later transaction nobody looked at. The script does this; read the
   answer back on the explorer before anything consumes the feed.
4. **Check the role handover.** `vaultFor(symbol)`, then `hasRole` for admin,
   guardian and treasurer on the vault, and for publisher, guardian and admin
   on each oracle. The factory must hold nothing: it renounces
   `DEFAULT_ADMIN_ROLE` on each vault as the last step of `deployETF`.
5. **Verify the source on the explorer** afterwards, for every deployed
   address including the two `ETFShare`s and the two `IssuanceVault`s the
   factory created. The audit report's last checklist row is this one.
