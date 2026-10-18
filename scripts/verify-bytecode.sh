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
    ("ETFFactory",    "0xB3A0965d4A4C47bf9AC180385bF99581CBE0c450"),
    ("IndexOracle",   "0x50fC20F69Da47c7d3Fb442A5FaF19889029319d9"),
    ("IndexOracle",   "0xC7ff2d4170564f388338248B08A7a375dCd179bC"),
    ("IssuanceVault", "0xF13f191F1eaB90E5331DA292dA922E3b797B1824"),
    ("ETFShare",      "0xa4220DF063149aa750bd54bEf578b244a3bc9Be7"),
    ("IssuanceVault", "0x4b6C535b6d298fB8a51E3577d7037340359d18E1"),
    ("ETFShare",      "0x6c4A0dEcA88C51a27E91841E7017f1bE654769aD"),
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
