#!/usr/bin/env bash
#
# Verify deployed contracts by comparing their bytecode with a local build.
#
# Why this exists: Mezo's testnet explorer never indexed the contracts the
# factory deployed. It reports `is_contract: false` for them with no creation
# transaction, so Blockscout verification cannot match them however the
# arguments are supplied - `forge verify-contract` answers "Fail - Unable to
# verify" for exactly those four and succeeds for the three deployed directly.
# That is an indexer limitation, not a property of the contracts, and the way
# around it is to check the thing itself rather than the explorer's view of it.
#
# Immutables are masked before comparing, because solc writes their values
# into runtime code: two vaults built from identical source differ only in
# those bytes, which is why a naive byte-for-byte comparison fails with
# identical lengths. The offsets come from the compiler's own
# immutableReferences, and every unmasked byte must match.
#
# Read-only. No keys, no transactions.
set -euo pipefail
cd "$(dirname "$0")/.."
RPC=${RPC:-https://rpc.test.mezo.org}

forge build >/dev/null

python3 - "$RPC" <<'PY'
import json, subprocess, sys
rpc = sys.argv[1]
# The deployment recorded in ADDRESSES.md.
pairs = [
    ("ETFFactory",    "0xCdF824BF8ed17285e40DB081131Cb3e7eC92b084"),
    ("IndexOracle",   "0x7fCb1ed8d6fAaEF00AA5A0104A062299ab7D5BF6"),
    ("IndexOracle",   "0x5Ed8205bA3DC7075099cFC4b2D4b7f2fF8a9cf9D"),
    ("IssuanceVault", "0x68A86E4503FCA82ac9eB229Be655E355A019bcC3"),
    ("ETFShare",      "0x35e0c3df250a1ea46bde6eef2D6ad22C924FCB88"),
    ("IssuanceVault", "0x87c6925798769012085b9a71FabA87c31F894f18"),
    ("ETFShare",      "0x239cC4EB08B92fdB486F00C93E2D47b38c0EBAd4"),
]
failed = 0
for name, addr in pairs:
    art = json.load(open(f"out/{name}.sol/{name}.json"))["deployedBytecode"]
    local = bytearray(bytes.fromhex(art["object"][2:]))
    got = subprocess.run(["cast", "code", addr, "--rpc-url", rpc],
                         capture_output=True, text=True, timeout=60).stdout.strip()
    if not got or got == "0x":
        print(f"{name:14} {addr}  NO CODE ON CHAIN")
        failed += 1
        continue
    onchain = bytearray(bytes.fromhex(got[2:]))
    if len(local) != len(onchain):
        print(f"{name:14} {addr}  LENGTH DIFFERS ({len(onchain)} on chain, {len(local)} local)")
        failed += 1
        continue
    masked = 0
    for spots in art.get("immutableReferences", {}).values():
        for spot in spots:
            s, l = spot["start"], spot["length"]
            local[s:s+l] = b"\x00" * l
            onchain[s:s+l] = b"\x00" * l
            masked += l
    if bytes(local) == bytes(onchain):
        print(f"{name:14} {addr}  matches the local build ({masked} immutable bytes masked)")
    else:
        where = [i for i in range(len(local)) if local[i] != onchain[i]][:5]
        print(f"{name:14} {addr}  DIFFERS at offsets {where}")
        failed += 1
print()
print("all seven match" if failed == 0 else f"{failed} contract(s) did not match")
sys.exit(1 if failed else 0)
PY
