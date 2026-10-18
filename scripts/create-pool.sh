#!/usr/bin/env bash
#
# List an index share on Mezo's own DEX, paired with borrowable MUSD.
#
# Why this and not a loop contract: Mezo's `openTrove` takes no borrower
# argument, so a trove belongs to `msg.sender` and nothing else. A contract
# that opened one on a user's behalf would own it, pooling every user's
# collateral and debt into a single position with a single liquidation price.
# Listing the share instead composes with a protocol Mezo already runs, needs
# no contract of ours, and makes the share tradeable without touching the
# vault.
#
# **Read this before running it.** The first deposit sets the pool's price.
# There is no oracle on a basic pool and no arbitrage on a testnet, so a
# lopsided first deposit is not corrected by anybody - it simply becomes the
# price, and whoever trades next takes the loss. The script therefore quotes
# the oracle, computes the matching MUSD for the shares you are depositing,
# and refuses to continue if the two disagree by more than --tolerance-bps.
#
#   ./scripts/create-pool.sh GOLOGGLE --shares 1                 # dry run
#   ./scripts/create-pool.sh GOLOGGLE --shares 1 --execute
#
# Needs: the share balance, the MUSD to match it, and BTC for gas. Get MUSD by
# borrowing (scripts/borrow-musd.sh) and shares by buying - both are the real
# user flow, which is the point.
#
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT=${ACCOUNT:-monad-deployer}
RPC=${RPC:-https://rpc.test.mezo.org}

# Mezo testnet, from mezo.org/docs/developers/mezo-pools. Verified to have
# code with `cast code` on 2026-10-17; the mainnet addresses in the same table
# are different and have none here, which is a mistake worth not repeating.
ROUTER=0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9
POOL_FACTORY=0x4947243CC818b627A5D06d14C4eCe7398A23Ce1A

# The MUSD BorrowerOperations can mint, which is the only one a user can
# obtain by borrowing. Mezo testnet has a second contract also called MUSD
# (0x118917a4...) that the official MUSD/BTC pool uses and that returns false
# for mintList(BorrowerOperations). Pairing against that one would list a
# market nobody holding borrowed MUSD could trade. See README.
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
SHARE_AMOUNT=""
EXECUTE=0
TOLERANCE_BPS=100
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shares) SHARE_AMOUNT=$2; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --tolerance-bps) TOLERANCE_BPS=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${SHARES[$SYMBOL]:-}" ]] || {
  echo "usage: $0 {GOLOGGLE|AMEZON} --shares N [--execute] [--tolerance-bps N]" >&2
  exit 1; }
[[ -n "$SHARE_AMOUNT" ]] || { echo "--shares is required" >&2; exit 1; }

SHARE=${SHARES[$SYMBOL]}
VAULT=${VAULTS[$SYMBOL]}
# FROM lets a dry run be checked against any address - the wallet that
# actually holds the shares and MUSD is usually not the keystore account, and
# `cast wallet address` would otherwise prompt for a password just to print a
# balance. --execute always signs with ACCOUNT.
if [[ -n "${FROM:-}" ]]; then
  # Validated here rather than left to cast: a mistyped address surfaces as
  # "parser error: odd number of digits" from somewhere in the middle of the
  # run, after several reads have already been made against it.
  [[ "$FROM" =~ ^0x[0-9a-fA-F]{40}$ ]] || {
    echo "FROM is not a 20-byte address: $FROM" >&2; exit 1; }
  ME=$FROM
  [[ "$EXECUTE" == "1" ]] && { echo "FROM is for dry runs only; --execute signs with ACCOUNT" >&2; exit 1; }
else
  ME=$(cast wallet address --account "$ACCOUNT")
fi

say () { printf '%s\n' "$*"; }
rule () { printf -- '----------------------------------------------------------\n'; }

say "Listing $SYMBOL / MUSD on Mezo's basic-pool DEX"
say "  router        $ROUTER"
say "  pool factory  $POOL_FACTORY"
say "  share         $SHARE"
say "  MUSD          $MUSD"
say "  from          $ME"
rule

# --- the settlement token has to be the borrowable one -------------------
MINTABLE=$(cast call "$MUSD" "mintList(address)(bool)" "$BORROWER_OPERATIONS" --rpc-url "$RPC")
if [[ "$MINTABLE" != "true" ]]; then
  say "REFUSING: mintList(BorrowerOperations) is $MINTABLE for $MUSD."
  say "A pool against an MUSD nobody can borrow is a market nobody can trade."
  exit 1
fi
say "settlement MUSD is mintable by BorrowerOperations: ok"

# --- what the share is actually worth, from the vault --------------------
PRICE=$(cast call "$VAULT" "price()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
[[ "$PRICE" =~ ^[0-9]+$ && "$PRICE" != "0" ]] || {
  say "REFUSING: the vault has no usable price, so there is nothing to seed at."
  exit 1; }

SHARE_WEI=$(cast to-wei "$SHARE_AMOUNT" ether)
# musd = shares * price / 1e18, in MUSD wei. Both are 18 decimals.
MUSD_WEI=$(python3 -c "print(($SHARE_WEI * $PRICE) // 10**18)")

say "oracle price   $(cast from-wei "$PRICE") MUSD per share"
say "depositing     $SHARE_AMOUNT $SYMBOL  +  $(cast from-wei "$MUSD_WEI") MUSD"
say "implied pool price matches the oracle by construction"
rule

# --- balances, before anything is signed --------------------------------
SHARE_BAL=$(cast call "$SHARE" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | awk '{print $1}')
MUSD_BAL=$(cast call "$MUSD" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | awk '{print $1}')
say "you hold       $(cast from-wei "$SHARE_BAL") $SYMBOL, $(cast from-wei "$MUSD_BAL") MUSD"
SHORT=0
python3 -c "import sys; sys.exit(0 if $SHARE_BAL >= $SHARE_WEI else 1)" || {
  say "  short $(python3 -c "print(($SHARE_WEI-$SHARE_BAL)/10**18)") $SYMBOL - buy more first"; SHORT=1; }
python3 -c "import sys; sys.exit(0 if $MUSD_BAL >= $MUSD_WEI else 1)" || {
  say "  short $(python3 -c "print(($MUSD_WEI-$MUSD_BAL)/10**18)") MUSD - borrow more first"; SHORT=1; }
[[ "$SHORT" == "0" ]] || { say "REFUSING: not enough to seed the pool."; exit 1; }

# --- where the pool will be, and whether it exists ----------------------
PREDICTED=$(cast call "$ROUTER" "poolFor(address,address,bool,address)(address)" \
  "$SHARE" "$MUSD" false "$POOL_FACTORY" --rpc-url "$RPC")
EXISTING=$(cast call "$POOL_FACTORY" "getPool(address,address,bool)(address)" \
  "$SHARE" "$MUSD" false --rpc-url "$RPC")
say "pool address   $PREDICTED"
if [[ "$EXISTING" == "0x0000000000000000000000000000000000000000" ]]; then
  say "               does not exist yet; addLiquidity will create it"
else
  say "               already exists, so this adds to it at the current ratio"
  say "WARNING: an existing pool has its own price. The amounts above are"
  say "         quoted from the oracle, not from the pool, so check the quote"
  say "         below before executing."
fi
rule

# --- the router's own quote ---------------------------------------------
QUOTE=$(cast call "$ROUTER" \
  "quoteAddLiquidity(address,address,bool,address,uint256,uint256)(uint256,uint256,uint256)" \
  "$SHARE" "$MUSD" false "$POOL_FACTORY" "$SHARE_WEI" "$MUSD_WEI" --rpc-url "$RPC")
Q_SHARE=$(echo "$QUOTE" | sed -n 1p | awk '{print $1}')
Q_MUSD=$(echo "$QUOTE" | sed -n 2p | awk '{print $1}')
Q_LP=$(echo "$QUOTE" | sed -n 3p | awk '{print $1}')
say "router quote   takes $(cast from-wei "$Q_SHARE") $SYMBOL and $(cast from-wei "$Q_MUSD") MUSD"
say "               mints $(cast from-wei "$Q_LP") LP"

# The router may take less than offered if the pool already has a ratio. A
# large gap means the pool price has drifted from the oracle, and seeding or
# adding at that point donates the difference to whoever trades next.
DRIFT=$(python3 -c "
offered = $SHARE_WEI + $MUSD_WEI
taken = $Q_SHARE + $Q_MUSD
print(0 if offered == 0 else abs(offered - taken) * 10000 // offered)")
say "               differs from the offer by ${DRIFT} bps (tolerance $TOLERANCE_BPS)"
if (( DRIFT > TOLERANCE_BPS )); then
  say "REFUSING: the router would take materially less than offered, which"
  say "          means the pool's price disagrees with the oracle. Re-check"
  say "          the ratio, or raise --tolerance-bps deliberately."
  exit 1
fi
rule

if [[ "$EXECUTE" != "1" ]]; then
  say "Dry run. Nothing was signed. Re-run with --execute to send:"
  say "  1. approve $SYMBOL to the router"
  say "  2. approve MUSD to the router"
  say "  3. addLiquidity, which creates the pool if it does not exist"
  exit 0
fi

DEADLINE=$(python3 -c "import time; print(int(time.time()) + 1200)")

# --slow throughout: Mezo reports a sequence rather than a nonce and rejects
# a second transaction built from a stale one. --async because
# eth_getTransactionReceipt returns null for minutes after inclusion, so
# waiting for a receipt reports a failure that did not happen.
send () {
  say "> $1"
  shift
  cast send --account "$ACCOUNT" --rpc-url "$RPC" --slow --async "$@"
}

send "approve $SYMBOL to the router" \
  "$SHARE" "approve(address,uint256)" "$ROUTER" "$SHARE_WEI"
send "approve MUSD to the router" \
  "$MUSD" "approve(address,uint256)" "$ROUTER" "$MUSD_WEI"

# Minimums at 99% of the quote: the pool is new or nearly so, and a slippage
# bound of zero is how a first deposit gets sandwiched on a chain where
# anybody is watching.
MIN_SHARE=$(python3 -c "print($Q_SHARE * 99 // 100)")
MIN_MUSD=$(python3 -c "print($Q_MUSD * 99 // 100)")

send "addLiquidity (creates the pool)" \
  "$ROUTER" \
  "addLiquidity(address,address,bool,uint256,uint256,uint256,uint256,address,uint256)" \
  "$SHARE" "$MUSD" false "$SHARE_WEI" "$MUSD_WEI" "$MIN_SHARE" "$MIN_MUSD" "$ME" "$DEADLINE"

rule
say "Sent. Receipts lag on Mezo, so verify rather than trusting the output:"
say "  ./scripts/verify-pool.sh $SYMBOL"
