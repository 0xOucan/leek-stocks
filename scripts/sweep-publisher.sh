#!/usr/bin/env bash
#
# Move all but a gas float from the publisher back to the deployer.
#
# The publisher is a hot key: its private key sits in a file on a server that
# signs transactions all day. What it can *do* is already bounded to pushing
# prices inside an immutable per-round deviation bound, so the remaining
# question is how much it can *lose*, and the answer should be "the gas it was
# going to spend anyway".
#
# This leaves RESERVE behind and sends the rest home. On Mezo, where the base
# fee is around 130 wei, a 0.005 BTC float is months of publishing; the
# default here is deliberately generous rather than clever, because a feed
# that stops because it ran out of gas is a worse outcome than a slightly
# over-funded hot key.
#
#   ./scripts/sweep-publisher.sh                 # leave the default reserve
#   RESERVE=0.002ether ./scripts/sweep-publisher.sh
#   TO=0x... ./scripts/sweep-publisher.sh        # somewhere other than the deployer
#
# Read the balances it prints before confirming. Nothing is sent until you
# type yes.
set -euo pipefail
cd "$(dirname "$0")/.."

FROM_ACCOUNT=${FROM_ACCOUNT:-leek-publisher}
TO=${TO:-0x9c77c6fafc1eb0821F1De12972Ef0199C97C6e45}   # monad-deployer
RPC=${RPC:-https://rpc.test.mezo.org}
RESERVE=${RESERVE:-0.005ether}

fail() { printf 'STOP: %s\n' "$1" >&2; exit 1; }

PASSFILE=""
cleanup() { [[ -n "$PASSFILE" && -f "$PASSFILE" ]] && shred -u "$PASSFILE" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

dir=/dev/shm; [[ -d "$dir" && -w "$dir" ]] || dir="${TMPDIR:-/tmp}"
PASSFILE=$(mktemp "$dir/.leekpass.XXXXXX"); chmod 600 "$PASSFILE"
read -rsp "Keystore password for $FROM_ACCOUNT: " pw; echo
printf '%s' "$pw" > "$PASSFILE"; unset pw

FROM=$(cast wallet address --account "$FROM_ACCOUNT" --password-file "$PASSFILE")
BAL=$(cast balance "$FROM" --rpc-url "$RPC")
RESERVE_WEI=$(cast to-wei "${RESERVE%ether}")

# The fee for this transfer comes out of what is sent, not out of the reserve,
# so the reserve is what actually remains afterwards. 21000 gas is a plain
# transfer; the base fee is read rather than assumed because it is a chain
# parameter and this script should not carry a stale copy of one.
BASE_FEE=$(cast base-fee --rpc-url "$RPC")
FEE=$(( 21000 * (BASE_FEE * 2 + 1) ))     # double the base fee, as a margin
AMOUNT=$(( BAL - RESERVE_WEI - FEE ))

printf '\n'
printf 'from      %s (%s)\n' "$FROM" "$FROM_ACCOUNT"
printf 'to        %s\n' "$TO"
printf 'balance   %s BTC\n' "$(cast from-wei "$BAL")"
printf 'reserve   %s BTC stays behind\n' "$(cast from-wei "$RESERVE_WEI")"
printf 'fee       %s BTC at base fee %s wei\n' "$(cast from-wei "$FEE")" "$BASE_FEE"
printf 'sending   %s BTC\n\n' "$(cast from-wei "$AMOUNT")"

[[ "$AMOUNT" -gt 0 ]] || fail "nothing to sweep: the balance is at or below the reserve plus fees"
[[ "$TO" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "destination is not an address"
[[ "${TO,,}" != "${FROM,,}" ]] || fail "destination is the publisher itself"

read -r -p "Type yes to send: " answer
[[ "$answer" == "yes" ]] || fail "not confirmed"

# --async, then watch the balance. A receipt on this chain can be minutes
# late, and `cast send` reports that lag as a failure; the balance moving is
# the thing we actually wanted to know.
HASH=$(cast send "$TO" --value "$AMOUNT" --rpc-url "$RPC" \
  --account "$FROM_ACCOUNT" --password-file "$PASSFILE" --async)
echo "sent: $HASH"

for _ in $(seq 1 60); do
  NOW=$(cast balance "$FROM" --rpc-url "$RPC" 2>/dev/null || echo "$BAL")
  if [[ "$NOW" != "$BAL" ]]; then
    echo "publisher now holds $(cast from-wei "$NOW") BTC"
    echo "deployer now holds  $(cast from-wei "$(cast balance "$TO" --rpc-url "$RPC")") BTC"
    exit 0
  fi
  sleep 5
done
echo "the balance has not moved yet. Check $HASH; on this chain that often means late, not failed." >&2
