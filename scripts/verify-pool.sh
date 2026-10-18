#!/usr/bin/env bash
#
# Check that a listed pool is real, solvent and priced where it should be.
#
# This exists because `cast send` on Mezo cannot tell you whether it worked:
# eth_getTransactionReceipt returns null for minutes after inclusion, so the
# tool prints a failure for a transaction that succeeded. The only honest
# confirmation is reading the resulting state, which is what this does.
#
# It also checks the thing a creation script cannot: that the pool's own price
# still agrees with the oracle. A basic pool has no oracle and a testnet has no
# arbitrage, so a pool can sit mispriced indefinitely and the only person who
# notices is whoever trades into it.
#
#   ./scripts/verify-pool.sh GOLOGGLE
#   ./scripts/verify-pool.sh              # both
#
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=${RPC:-https://rpc.test.mezo.org}
ROUTER=0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9
POOL_FACTORY=0x4947243CC818b627A5D06d14C4eCe7398A23Ce1A
MUSD=0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af

declare -A SHARES=(
  [GOLOGGLE]=0x35e0c3df250a1ea46bde6eef2D6ad22C924FCB88
  [AMEZON]=0x239cC4EB08B92fdB486F00C93E2D47b38c0EBAd4
)
declare -A VAULTS=(
  [GOLOGGLE]=0x68A86E4503FCA82ac9eB229Be655E355A019bcC3
  [AMEZON]=0x87c6925798769012085b9a71FabA87c31F894f18
)

TARGETS=("${1:-GOLOGGLE}" "${2:-}")
[[ -z "${1:-}" ]] && TARGETS=(GOLOGGLE AMEZON)

FAILED=0
for SYMBOL in "${TARGETS[@]}"; do
  [[ -n "$SYMBOL" ]] || continue
  SHARE=${SHARES[$SYMBOL]:-}
  VAULT=${VAULTS[$SYMBOL]:-}
  [[ -n "$SHARE" ]] || { echo "unknown index: $SYMBOL" >&2; exit 1; }

  printf -- '=== %s / MUSD ===\n' "$SYMBOL"

  POOL=$(cast call "$POOL_FACTORY" "getPool(address,address,bool)(address)" \
    "$SHARE" "$MUSD" false --rpc-url "$RPC")
  if [[ "$POOL" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "  NOT LISTED - no pool for this pair"
    FAILED=1
    continue
  fi
  echo "  pool            $POOL"

  # The factory agreeing is not enough: a pool the router cannot route to is
  # unreachable from the UI and from every integrator.
  PREDICTED=$(cast call "$ROUTER" "poolFor(address,address,bool,address)(address)" \
    "$SHARE" "$MUSD" false "$POOL_FACTORY" --rpc-url "$RPC")
  if [[ "${PREDICTED,,}" != "${POOL,,}" ]]; then
    echo "  MISMATCH        the router routes to $PREDICTED, not to this pool"
    FAILED=1
  else
    echo "  router agrees   yes"
  fi

  T0=$(cast call "$POOL" "token0()(address)" --rpc-url "$RPC")
  T1=$(cast call "$POOL" "token1()(address)" --rpc-url "$RPC")
  STABLE=$(cast call "$POOL" "stable()(bool)" --rpc-url "$RPC")
  echo "  token0/token1   $T0 / $T1  (stable=$STABLE)"

  # Which side is which: the factory sorts by address, so neither order can be
  # assumed and reading the wrong one inverts the price.
  RES=$(cast call "$POOL" "getReserves()(uint256,uint256,uint256)" --rpc-url "$RPC")
  R0=$(echo "$RES" | sed -n 1p | awk '{print $1}')
  R1=$(echo "$RES" | sed -n 2p | awk '{print $1}')
  if [[ "${T0,,}" == "${SHARE,,}" ]]; then
    SHARE_RES=$R0; MUSD_RES=$R1
  else
    SHARE_RES=$R1; MUSD_RES=$R0
  fi
  echo "  reserves        $(cast from-wei "$SHARE_RES") $SYMBOL / $(cast from-wei "$MUSD_RES") MUSD"

  if [[ "$SHARE_RES" == "0" || "$MUSD_RES" == "0" ]]; then
    echo "  EMPTY           a pool with one empty side cannot be traded"
    FAILED=1
    continue
  fi

  ORACLE=$(cast call "$VAULT" "price()(uint256)" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}' || echo "")
  if [[ -z "$ORACLE" || ! "$ORACLE" =~ ^[0-9]+$ ]]; then
    echo "  oracle          unreadable, so the pool price cannot be checked"
    FAILED=1
    continue
  fi

  python3 - "$SHARE_RES" "$MUSD_RES" "$ORACLE" <<'PY'
import sys
share, musd, oracle = (int(a) for a in sys.argv[1:4])
pool = musd * 10**18 // share
drift = abs(pool - oracle) * 10_000 // oracle
print(f"  pool price      {pool/10**18:.6f} MUSD per share")
print(f"  oracle price    {oracle/10**18:.6f} MUSD per share")
print(f"  drift           {drift} bps")
# 300 bps: wider than the 30 bps swap fee plus ordinary rounding, narrow
# enough that a real mispricing is not called healthy.
if drift > 300:
    print("  MISPRICED       the pool disagrees with the oracle by more than")
    print("                  300 bps. On a testnet nobody arbitrages this, so")
    print("                  it stays wrong until someone rebalances it.")
    sys.exit(1)
print("  priced           within tolerance of the oracle")
PY
  [[ $? -eq 0 ]] || FAILED=1

  SUPPLY=$(cast call "$POOL" "totalSupply()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  echo "  LP supply       $(cast from-wei "$SUPPLY")"
done

printf -- '----------------------------------------------------------\n'
if [[ "$FAILED" == "0" ]]; then
  echo "verify-pool: ok"
else
  echo "verify-pool: problems above"
  exit 1
fi
