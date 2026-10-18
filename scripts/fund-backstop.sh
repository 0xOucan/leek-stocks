#!/usr/bin/env bash
#
# Top up a vault's reserves so every share can be redeemed.
#
# This is audit finding H-1, made concrete. A share is priced from an index the
# vault does not hold: buyers pay today's price, and if the index rises the
# MUSD owed to redeemers grows while the MUSD in the vault does not. The vault
# does not pretend otherwise - `redeem` reverts rather than paying part of what
# it owes, and `coverageBps()` says how short it is - but the shortfall has to
# be covered by someone, and `fund()` is the permissionless way to do it.
#
#   ./scripts/fund-backstop.sh                    # cover the shortfall + 10%
#   AMOUNT=25 ./scripts/fund-backstop.sh          # a fixed number of MUSD
#   VAULT=0x... ./scripts/fund-backstop.sh        # the AMEZON vault
#
# The MUSD is a donation: `fund` adds to reserves and mints no shares, so it is
# not recoverable through redeem. On a demo account that is the point. In
# anything real the backstop is a liability someone has to own, which is why
# H-1 is a High and not an informational note.
#
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT=${ACCOUNT:-monad-deployer}
RPC=${RPC:-https://rpc.test.mezo.org}
CHAIN=31611
VAULT=${VAULT:-0xF13f191F1eaB90E5331DA292dA922E3b797B1824}   # GOLOGGLE
MUSD=0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af

fail() { printf 'STOP: %s\n' "$1" >&2; exit 1; }

got=$(cast chain-id --rpc-url "$RPC")
[[ "$got" == "$CHAIN" ]] || fail "chain id is $got, expected $CHAIN"

RES=$(cast call "$VAULT" "reserves()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
LIA=$(cast call "$VAULT" "liabilities()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
COV=$(cast call "$VAULT" "coverageBps()(uint256)" --rpc-url "$RPC" | awk '{print $1}')

if [[ -n "${AMOUNT:-}" ]]; then
  WEI=$(cast to-wei "$AMOUNT")
else
  if [[ "$LIA" -le "$RES" ]]; then
    printf 'reserves %s MUSD already cover liabilities %s (coverage %s bps). Nothing to do.\n' \
      "$(cast from-wei "$RES")" "$(cast from-wei "$LIA")" "$COV"
    exit 0
  fi
  # The shortfall plus a tenth. Not exact: the index moves between this read
  # and the transaction landing, and funding a penny short leaves redeem
  # reverting for the same reason it was reverting before.
  SHORT=$(( LIA - RES ))
  WEI=$(( SHORT + SHORT / 10 ))
  # A floor, because a shortfall of a few wei would otherwise send a
  # transaction that costs more in gas than it moves.
  MIN=$(cast to-wei 0.01)
  [[ "$WEI" -ge "$MIN" ]] && : || WEI=$MIN
fi

PASSFILE=""
cleanup() { [[ -n "$PASSFILE" && -f "$PASSFILE" ]] && shred -u "$PASSFILE" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
dir=/dev/shm; [[ -d "$dir" && -w "$dir" ]] || dir="${TMPDIR:-/tmp}"
PASSFILE=$(mktemp "$dir/.leekpass.XXXXXX"); chmod 600 "$PASSFILE"
read -rsp "Keystore password for $ACCOUNT: " pw; echo
printf '%s' "$pw" > "$PASSFILE"; unset pw

ME=$(cast wallet address --account "$ACCOUNT" --password-file "$PASSFILE")
HELD=$(cast call "$MUSD" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | awk '{print $1}')

printf '\n'
printf 'vault        %s\n' "$VAULT"
printf 'reserves     %s MUSD\n' "$(cast from-wei "$RES")"
printf 'liabilities  %s MUSD\n' "$(cast from-wei "$LIA")"
printf 'coverage     %s bps\n' "$COV"
printf 'funding      %s MUSD (a donation; it mints no shares)\n' "$(cast from-wei "$WEI")"
printf 'you hold     %s MUSD\n\n' "$(cast from-wei "$HELD")"

[[ "$HELD" -ge "$WEI" ]] || fail "not enough MUSD: holding $(cast from-wei "$HELD"), need $(cast from-wei "$WEI")"

read -r -p "Type yes to fund: " answer
[[ "$answer" == "yes" ]] || fail "not confirmed"

# approve, then fund. Exact amount rather than an unlimited allowance, for the
# same reason the dapp does it that way.
echo "approving..."
H1=$(cast send "$MUSD" "approve(address,uint256)" "$VAULT" "$WEI" --rpc-url "$RPC" \
  --account "$ACCOUNT" --password-file "$PASSFILE" --async)
echo "  $H1"
for _ in $(seq 1 60); do
  A=$(cast call "$MUSD" "allowance(address,address)(uint256)" "$ME" "$VAULT" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
  [[ -n "$A" && "$A" -ge "$WEI" ]] && break
  sleep 5
done
[[ -n "${A:-}" && "$A" -ge "$WEI" ]] || fail "the allowance has not appeared. Check $H1."

echo "funding..."
H2=$(cast send "$VAULT" "fund(uint256)" "$WEI" --rpc-url "$RPC" \
  --account "$ACCOUNT" --password-file "$PASSFILE" --async)
echo "  $H2"
for _ in $(seq 1 60); do
  NEW=$(cast call "$VAULT" "coverageBps()(uint256)" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
  if [[ -n "$NEW" && "$NEW" != "$COV" ]]; then
    printf '\ncoverage is now %s bps (was %s)\n' "$NEW" "$COV"
    printf 'reserves        %s MUSD\n' "$(cast from-wei "$(cast call "$VAULT" "reserves()(uint256)" --rpc-url "$RPC" | awk '{print $1}')")"
    exit 0
  fi
  sleep 5
done
echo "coverage has not changed yet. Check $H2; on this chain that often means late, not failed." >&2
