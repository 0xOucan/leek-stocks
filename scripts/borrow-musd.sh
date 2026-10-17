#!/usr/bin/env bash
#
# Borrow MUSD against native BTC on Mezo testnet, so there is something to buy
# shares with.
#
# The dapp settles in MUSD and mints nothing: a visitor needs MUSD that the
# live borrow system minted, which is obtained by opening a trove. This is that
# step, scripted, because the alternative is a web app that is awkward to
# reproduce and impossible to put in a runbook.
#
#   ./scripts/borrow-musd.sh                      # 1800 MUSD against 0.01 BTC
#   DEBT=2000 COLLATERAL=0.02 ./scripts/borrow-musd.sh
#
# You run this, not an agent: --account prompts for the keystore password and
# it never reaches a command line, an environment variable or a log.
#
# ---------------------------------------------------------------------------
# What this creates
#
# A trove is a debt position, not a swap. It holds your BTC as collateral and
# owes MUSD plus interest. To get the collateral back you repay. Nothing here
# closes a position, and nothing here is reversible by re-running it.
#
# On testnet BTC is priced at about $20,000,000, so the collateral needed for
# the 1800 MUSD minimum is worth about a ten-thousandth of a BTC. The default
# 0.01 BTC is wildly more than the 110% minimum demands - a ratio over 10,000%
# - deliberately: an underwater trove can be liquidated, and this is a demo
# account whose job is to still be there tomorrow, not to be capital efficient.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT=${ACCOUNT:-monad-deployer}
RPC=${RPC:-https://rpc.test.mezo.org}
CHAIN=31611
BORROWER_OPERATIONS=0xa14cbA6DD12D537A8decc7dd3c4aC413B8711eba
MUSD=0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af
ZERO=0x0000000000000000000000000000000000000000

DEBT=${DEBT:-1800}              # MUSD, whole units
COLLATERAL=${COLLATERAL:-0.01}  # BTC, whole units

fail() { printf 'STOP: %s\n' "$1" >&2; exit 1; }

got=$(cast chain-id --rpc-url "$RPC")
[[ "$got" == "$CHAIN" ]] || fail "chain id is $got, expected $CHAIN"

# openTrove(uint256 debtAmount, address upperHint, address lowerHint), payable.
#
# Established by matching selectors against the deployed bytecode, because the
# proxy's implementation is not verified on the explorer and no ABI is
# published. It is NOT Liquity v1's signature: there is no maxFeePercentage
# argument, and the collateral is msg.value rather than a parameter. The hints
# are insertion hints into the sorted trove list; zero is correct and simply
# costs a little more gas on a short list.
OPEN_TROVE="openTrove(uint256,address,address)"

DEBT_WEI=$(cast to-wei "$DEBT")
COLL_WEI=$(cast to-wei "$COLLATERAL")

MIN_DEBT=$(cast call "$BORROWER_OPERATIONS" "minNetDebt()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
[[ "$DEBT_WEI" -ge "$MIN_DEBT" ]] || fail "debt $DEBT MUSD is below the protocol minimum of $(cast from-wei "$MIN_DEBT") MUSD"

PASSFILE=""
cleanup() { [[ -n "$PASSFILE" && -f "$PASSFILE" ]] && shred -u "$PASSFILE" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
dir=/dev/shm; [[ -d "$dir" && -w "$dir" ]] || dir="${TMPDIR:-/tmp}"
PASSFILE=$(mktemp "$dir/.leekpass.XXXXXX"); chmod 600 "$PASSFILE"
read -rsp "Keystore password for $ACCOUNT: " pw; echo
printf '%s' "$pw" > "$PASSFILE"; unset pw

ME=$(cast wallet address --account "$ACCOUNT" --password-file "$PASSFILE")
BAL=$(cast balance "$ME" --rpc-url "$RPC")
HELD=$(cast call "$MUSD" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | awk '{print $1}')
PRICE=$(cast call 0xf28B0d5165b4ad9D5C04CdE1E37B400f8ca5A8cb "fetchPrice()(uint256)" --rpc-url "$RPC" | awk '{print $1}')

printf '\n'
printf 'borrower    %s (%s)\n' "$ME" "$ACCOUNT"
printf 'BTC held    %s\n' "$(cast from-wei "$BAL")"
printf 'MUSD held   %s\n' "$(cast from-wei "$HELD")"
printf 'BTC price   $%s (testnet)\n' "$(cast from-wei "$PRICE")"
printf 'collateral  %s BTC\n' "$COLLATERAL"
printf 'borrowing   %s MUSD (minimum %s)\n\n' "$DEBT" "$(cast from-wei "$MIN_DEBT")"

[[ "$BAL" -gt "$COLL_WEI" ]] || fail "not enough BTC: holding $(cast from-wei "$BAL"), need $COLLATERAL plus gas"

# Simulated before it is signed. A revert here costs nothing; a revert after
# the password prompt costs gas and explains little.
cast estimate "$BORROWER_OPERATIONS" "$OPEN_TROVE" "$DEBT_WEI" "$ZERO" "$ZERO" \
  --value "$COLL_WEI" --from "$ME" --rpc-url "$RPC" >/dev/null \
  || fail "the call reverts in simulation. An existing trove for this address is the usual reason - this opens one, it does not adjust one."

cat <<WARN
This opens a DEBT POSITION. Your $COLLATERAL BTC becomes collateral and the
trove owes $DEBT MUSD plus interest until it is repaid. Re-running this does
not top it up; it reverts, because the address already has a trove.

WARN
read -r -p "Type yes to borrow: " answer
[[ "$answer" == "yes" ]] || fail "not confirmed"

# --async and then watch the balance, because Mezo answers
# eth_getTransactionReceipt with null for minutes after inclusion and `cast
# send` reports that lag as a failure. The MUSD arriving is the outcome we
# care about.
HASH=$(cast send "$BORROWER_OPERATIONS" "$OPEN_TROVE" "$DEBT_WEI" "$ZERO" "$ZERO" \
  --value "$COLL_WEI" --rpc-url "$RPC" \
  --account "$ACCOUNT" --password-file "$PASSFILE" --async)
echo "sent: $HASH"
echo "explorer: https://explorer.test.mezo.org/tx/$HASH"

for _ in $(seq 1 60); do
  NOW=$(cast call "$MUSD" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
  if [[ -n "$NOW" && "$NOW" != "$HELD" ]]; then
    printf '\nMUSD balance is now %s\n' "$(cast from-wei "$NOW")"
    printf 'BTC left           %s\n' "$(cast from-wei "$(cast balance "$ME" --rpc-url "$RPC")")"
    cat <<NEXT

Next: open the dapp, connect this address, and buy shares. The vault settles
in this MUSD - $MUSD - and the page asks for an
approval before the first buy.
NEXT
    exit 0
  fi
  sleep 5
done
echo "the balance has not moved yet. Check $HASH; on this chain that often means late, not failed." >&2
