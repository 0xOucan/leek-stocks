#!/usr/bin/env bash
#
# Buy index shares from the keystore account.
#
# The dapp does this with a browser wallet, which is the user flow and the
# thing worth demonstrating. This exists for the operator flow: seeding a DEX
# pool needs shares *and* MUSD in the same account, and the account holding
# the key is not the one somebody has been clicking with. Without this, the
# only route from keystore MUSD to keystore shares is to import the key into
# a browser, which is the one thing this project will not do.
#
#   ./scripts/buy-shares.sh GOLOGGLE --shares 1              # dry run
#   ./scripts/buy-shares.sh GOLOGGLE --shares 1 --execute
#   ./scripts/buy-shares.sh GOLOGGLE --musd 200 --execute    # spend instead
#
# The approval is for the exact amount and is consumed by the buy, so no
# standing allowance is left behind - the same rule the dapp follows and the
# audit's "no infinite approvals" row asks for.
#
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT=${ACCOUNT:-monad-deployer}
RPC=${RPC:-https://rpc.test.mezo.org}
MUSD=0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af
BORROWER_OPERATIONS=0xa14cbA6DD12D537A8decc7dd3c4aC413B8711eba

declare -A SHARES=(
  [GOLOGGLE]=0x35e0c3df250a1ea46bde6eef2D6ad22C924FCB88
  [AMEZON]=0x239cC4EB08B92fdB486F00C93E2D47b38c0EBAd4
)
declare -A VAULTS=(
  [GOLOGGLE]=0x68A86E4503FCA82ac9eB229Be655E355A019bcC3
  [AMEZON]=0x87c6925798769012085b9a71FabA87c31F894f18
)

SYMBOL=${1:-}
WANT_SHARES=""
SPEND_MUSD=""
EXECUTE=0
SLIPPAGE_BPS=100
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shares) WANT_SHARES=$2; shift 2 ;;
    --musd) SPEND_MUSD=$2; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --slippage-bps) SLIPPAGE_BPS=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${VAULTS[$SYMBOL]:-}" ]] || {
  echo "usage: $0 {GOLOGGLE|AMEZON} (--shares N | --musd N) [--execute]" >&2; exit 1; }
[[ -n "$WANT_SHARES" || -n "$SPEND_MUSD" ]] || {
  echo "one of --shares or --musd is required" >&2; exit 1; }
[[ -z "$WANT_SHARES" || -z "$SPEND_MUSD" ]] || {
  echo "--shares and --musd are mutually exclusive" >&2; exit 1; }

VAULT=${VAULTS[$SYMBOL]}
SHARE=${SHARES[$SYMBOL]}

if [[ -n "${FROM:-}" ]]; then
  [[ "$FROM" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "FROM is not an address: $FROM" >&2; exit 1; }
  [[ "$EXECUTE" == "1" ]] && { echo "FROM is for dry runs only" >&2; exit 1; }
  ME=$FROM
else
  ME=$(cast wallet address --account "$ACCOUNT")
fi

say () { printf '%s\n' "$*"; }
rule () { printf -- '----------------------------------------------------------\n'; }

say "Buying $SYMBOL shares"
say "  vault   $VAULT"
say "  share   $SHARE"
say "  from    $ME"
rule

# --- refuse before computing anything from a broken vault ---------------
PAUSED=$(cast call "$VAULT" "paused()(bool)" --rpc-url "$RPC")
[[ "$PAUSED" == "false" ]] || { say "REFUSING: the vault is paused."; exit 1; }

VAULT_MUSD=$(cast call "$VAULT" "musd()(address)" --rpc-url "$RPC")
if [[ "${VAULT_MUSD,,}" != "${MUSD,,}" ]]; then
  say "REFUSING: this vault settles in $VAULT_MUSD, not $MUSD."
  say "Mezo testnet has several contracts called MUSD; see README."
  exit 1
fi
MINTABLE=$(cast call "$MUSD" "mintList(address)(bool)" "$BORROWER_OPERATIONS" --rpc-url "$RPC")
[[ "$MINTABLE" == "true" ]] || {
  say "REFUSING: mintList(BorrowerOperations) is $MINTABLE for the settlement token."; exit 1; }
say "settlement token agrees with the vault and is borrowable: ok"

PRICE=$(cast call "$VAULT" "price()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
[[ "$PRICE" =~ ^[0-9]+$ && "$PRICE" != "0" ]] || {
  say "REFUSING: no usable price. The feed may be stale."; exit 1; }

# The fee the caller will actually be charged. The redeployed vault exposes
# effectiveFeeBps, which applies a staking discount; the one deployed before
# that does not, and reverts. Fall back rather than assume either.
FEE=$(cast call "$VAULT" "effectiveFeeBps(address)(uint16)" "$ME" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}' || true)
if [[ "$FEE" =~ ^[0-9]+$ ]]; then
  say "fee           ${FEE} bps (effectiveFeeBps, staking discount applied)"
else
  FEE=$(cast call "$VAULT" "feeBps()(uint16)" --rpc-url "$RPC" | awk '{print $1}')
  say "fee           ${FEE} bps (feeBps; this vault has no effectiveFeeBps yet)"
fi

# --- amounts -------------------------------------------------------------
# buy() computes sharesOut = (musdAmount - fee) * 1e18 / price, so going the
# other way needs the gross-up: musd = shares * price / (1 - fee). Done in
# integer arithmetic, rounded up, or asking for exactly 1 share buys 0.999.
if [[ -n "$WANT_SHARES" ]]; then
  SHARE_WEI=$(cast to-wei "$WANT_SHARES" ether)
  MUSD_WEI=$(python3 -c "
shares = $SHARE_WEI
price = $PRICE
fee = $FEE
net = (shares * price + 10**18 - 1) // 10**18          # round up
print((net * 10000 + (10000 - fee) - 1) // (10000 - fee))")
else
  MUSD_WEI=$(cast to-wei "$SPEND_MUSD" ether)
fi

EXPECTED=$(python3 -c "
musd = $MUSD_WEI
fee = (musd * $FEE) // 10000
print(((musd - fee) * 10**18) // $PRICE)")
MIN_SHARES=$(python3 -c "print($EXPECTED * (10000 - $SLIPPAGE_BPS) // 10000)")

say "price         $(cast from-wei "$PRICE") MUSD per share"
say "spending      $(cast from-wei "$MUSD_WEI") MUSD"
say "expecting     $(cast from-wei "$EXPECTED") $SYMBOL"
say "minimum       $(cast from-wei "$MIN_SHARES") (slippage $SLIPPAGE_BPS bps)"
rule

# --- can it even happen --------------------------------------------------
BAL=$(cast call "$MUSD" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | awk '{print $1}')
say "you hold      $(cast from-wei "$BAL") MUSD"
python3 -c "import sys; sys.exit(0 if $BAL >= $MUSD_WEI else 1)" || {
  say "REFUSING: short $(python3 -c "print(($MUSD_WEI-$BAL)/10**18)") MUSD. Borrow more first:"
  say "  ./scripts/borrow-musd.sh"
  exit 1; }

SUPPLY=$(cast call "$SHARE" "totalSupply()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
CAP=$(cast call "$VAULT" "maxShares()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
python3 -c "import sys; sys.exit(0 if $SUPPLY + $EXPECTED <= $CAP else 1)" || {
  say "REFUSING: this would exceed maxShares ($(cast from-wei "$CAP"))."; exit 1; }
say "cap headroom  $(cast from-wei "$(python3 -c "print($CAP - $SUPPLY)")") shares"

if [[ "$EXECUTE" != "1" ]]; then
  rule
  say "Dry run. Nothing was signed. Re-run with --execute."
  exit 0
fi

rule
# shellcheck source=scripts/lib/send.sh
source "$(dirname "$0")/lib/send.sh"

# Exact amount, consumed by the buy. Never type(uint256).max.
send_and_confirm "approve $(cast from-wei "$MUSD_WEI") MUSD to the vault" \
  "$MUSD" "approve(address,uint256)" "$VAULT" "$MUSD_WEI"
ALLOWED=$(cast call "$MUSD" "allowance(address,address)(uint256)" "$ME" "$VAULT" --rpc-url "$RPC" | awk '{print $1}')
expect_state "allowance is $(cast from-wei "$MUSD_WEI") MUSD" "$MUSD_WEI" "$ALLOWED"

SHARES_BEFORE=$(cast call "$SHARE" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | awk '{print $1}')
send_and_confirm "buy" \
  "$VAULT" "buy(uint256,uint256)" "$MUSD_WEI" "$MIN_SHARES"

SHARES_AFTER=$(cast call "$SHARE" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | awk '{print $1}')
GAINED=$(python3 -c "print($SHARES_AFTER - $SHARES_BEFORE)")
say "  gained    $(cast from-wei "$GAINED") $SYMBOL"
python3 -c "import sys; sys.exit(0 if $GAINED >= $MIN_SHARES else 1)" || {
  say "  WRONG     fewer shares than the minimum of $(cast from-wei "$MIN_SHARES")"
  say "            The buy was included but did not do what was quoted."
  exit 1; }
# The allowance must be gone: the vault pulls exactly what it was approved,
# so anything left standing means the buy spent less than it was given.
LEFT=$(cast call "$MUSD" "allowance(address,address)(uint256)" "$ME" "$VAULT" --rpc-url "$RPC" | awk '{print $1}')
expect_state "no allowance left standing" "0" "$LEFT"

rule
say "Done. You now hold $(cast from-wei "$SHARES_AFTER") $SYMBOL."
say "Next:"
say "  ./scripts/create-pool.sh $SYMBOL --shares 1"
