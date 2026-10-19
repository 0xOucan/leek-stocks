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
  [GOLOGGLE]=0xa4220DF063149aa750bd54bEf578b244a3bc9Be7
  [AMEZON]=0x6c4A0dEcA88C51a27E91841E7017f1bE654769aD
)
declare -A VAULTS=(
  [GOLOGGLE]=0xF13f191F1eaB90E5331DA292dA922E3b797B1824
  [AMEZON]=0x4b6C535b6d298fB8a51E3577d7037340359d18E1
)

TARGETS=("${1:-GOLOGGLE}" "${2:-}")
[[ -z "${1:-}" ]] && TARGETS=(GOLOGGLE AMEZON)

FAILED=0
# A check that could not be RUN is its own outcome: neither a pass nor a
# failure of the thing being checked.
UNCHECKED=0
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

  # A price this script could not FETCH is not a price the vault cannot
  # READ, and the two want opposite responses: retry the first, investigate
  # the second. `2>/dev/null ... || echo ""` collapsed them, so one dropped
  # connection on a flaky link printed "oracle unreadable" about an oracle
  # that was answering normally and failed a pool that was priced to 0 bps.
  # The website made the same mistake about the same figure; see
  # renderSolvencyPanel in web/src/app.ts.
  ORACLE=""
  ORACLE_ERR=""
  for attempt in 1 2 3; do
    if ORACLE_ERR=$(cast call "$VAULT" "price()(uint256)" --rpc-url "$RPC" 2>&1); then
      ORACLE=$(awk '{print $1}' <<<"$ORACLE_ERR")
      break
    fi
    [[ $attempt -lt 3 ]] && sleep 2
  done

  if [[ -z "$ORACLE" || ! "$ORACLE" =~ ^[0-9]+$ ]]; then
    # `execution reverted` is the vault refusing to price: a stale round, or
    # an oracle that has never published. Anything else is the network.
    if grep -qi "revert" <<<"$ORACLE_ERR"; then
      echo "  oracle          the vault REFUSED to price a share, so the pool"
      echo "                  cannot be checked. A round older than MAX_STALENESS"
      echo "                  does this; check the feed is publishing."
      FAILED=1
    else
      echo "  oracle          could not be reached after 3 attempts, so the pool"
      echo "                  price was NOT checked. This is the connection, not"
      echo "                  the pool and not the oracle. Re-run."
      echo "                  ${ORACLE_ERR%%$'\n'*}"
      UNCHECKED=1
    fi
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
if [[ "$FAILED" != "0" ]]; then
  echo "verify-pool: problems above"
  exit 1
elif [[ "$UNCHECKED" != "0" ]]; then
  # Exit 2, not 0 and not 1: nothing is wrong with the pool and nothing was
  # proved about it either. Saying "ok" here would be a claim this run cannot
  # support.
  echo "verify-pool: NOT fully checked - see above. Nothing failed; re-run."
  exit 2
else
  echo "verify-pool: ok"
fi
