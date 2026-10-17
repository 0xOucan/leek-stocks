#!/usr/bin/env bash
#
# Deploy LeekStonks to Mezo testnet, with every pre-flight the audit asked for.
#
# You run this, not an agent: `--account` makes Foundry prompt for the
# keystore password, you type it, and it never touches a command line, an
# environment variable, a log or this file. If a tool ever asks you to pass
# `--private-key` instead, that is the habit this script exists to avoid.
#
# Usage:
#   ./scripts/deploy-mezo.sh                 # checks, then asks before deploying
#   ./scripts/deploy-mezo.sh --checks-only   # pre-flight only, deploys nothing
#
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT=${ACCOUNT:-monad-deployer}
RPC=https://rpc.test.mezo.org
CHAIN=31611
VERIFIER_URL=https://api.explorer.test.mezo.org/api

# The MUSD the live borrow system mints, which is the one a user can obtain by
# borrowing against BTC on Mezo. Not the address Mezo's public contracts
# reference lists: that token exists, reports MUSD and 18 decimals, and
# BorrowerOperations cannot mint it. Settling in it would leave anyone who
# borrowed holding the wrong MUSD, failing with an allowance error that
# explains nothing. See ADDRESSES.md for the mintList evidence.
MUSD=0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af
BORROWER_OPERATIONS=0xa14cbA6DD12D537A8decc7dd3c4aC413B8711eba

CHECKS_ONLY=0
RESUME=0
case "${1:-}" in
  --checks-only) CHECKS_ONLY=1 ;;
  # Continue a run whose transactions were sent but whose receipts were not
  # collected. Mezo's RPC answers eth_getTransactionReceipt with null for a
  # short window after a transaction is already in a block, and Foundry treats
  # that null as a failure. The transactions are real; --resume picks up where
  # the broadcast stopped instead of starting over and orphaning what landed.
  --resume) RESUME=1 ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; exit 1 ;;
esac

say() { printf '\n== %s\n' "$1"; }
fail() { printf 'STOP: %s\n' "$1" >&2; exit 1; }

say "the chain"
got=$(cast chain-id --rpc-url "$RPC")
[[ "$got" == "$CHAIN" ]] || fail "chain id is $got, expected $CHAIN"
echo "   chain id $got, base fee $(cast base-fee --rpc-url "$RPC") wei"

say "previous attempts"
# An abandoned contract from a failed run is harmless but confusing: the
# addresses in a half-finished log are the ones simulation predicted, not what
# exists. Say so plainly rather than letting someone record them.
NONCE=$(cast nonce "$(cast wallet address --account "$ACCOUNT" 2>/dev/null || echo 0x0000000000000000000000000000000000000000)" --rpc-url "$RPC" 2>/dev/null || echo 0)
if [[ "$NONCE" != "0" ]]; then
  cat <<WARN
   This account has sent $NONCE transaction(s) before. If an earlier deploy
   failed part-way, whatever it left behind is orphaned: a fresh run deploys
   fresh contracts at new addresses, and only the final log's addresses are
   real. Record nothing from a failed run.
WARN
fi

say "the deployer"
# Asked of the keystore rather than assumed, because deploying from the wrong
# address is a mistake that is only obvious afterwards. This prompts for the
# password; nothing is signed yet.
SENDER=$(cast wallet address --account "$ACCOUNT")
echo "   $ACCOUNT is $SENDER"
BAL=$(cast balance "$SENDER" --rpc-url "$RPC")
echo "   balance $(cast from-wei "$BAL") BTC"
[[ "$BAL" != "0" ]] || fail "no BTC for gas. Mezo charges gas in BTC, not ether."

say "the settlement token"
# The audit's finding L-5: decimals are cached by the vault at construction,
# so they are confirmed against the live token immediately before deploying.
sym=$(cast call "$MUSD" "symbol()(string)" --rpc-url "$RPC")
dec=$(cast call "$MUSD" "decimals()(uint8)" --rpc-url "$RPC")
echo "   $MUSD reports $sym with $dec decimals"
[[ "$dec" == "18" ]] || fail "MUSD reports $dec decimals, not 18"
code=$(cast code "$MUSD" --rpc-url "$RPC" | head -c 12)
[[ "$code" != "0x" ]] || fail "no contract at the settlement token address"

# The reason this address and not the documented one: only this token lets the
# borrow system mint. Re-checked every run, because a redeployment on Mezo's
# side moves the answer and this script would otherwise keep a stale choice.
mintable=$(cast call "$MUSD" "mintList(address)(bool)" "$BORROWER_OPERATIONS" --rpc-url "$RPC")
echo "   BorrowerOperations may mint it: $mintable"
[[ "$mintable" == "true" ]] || fail \
  "the live borrow system cannot mint this token any more. Re-check ADDRESSES.md before deploying."

say "the build"
forge build >/dev/null
forge test >/dev/null && echo "   tests pass"

if [[ "$CHECKS_ONLY" == 1 ]]; then
  say "checks only, nothing deployed"
  exit 0
fi

cat <<PLAN

== about to deploy, for real, to Mezo testnet

   sender        $SENDER
   settlement    $MUSD ($sym)
   two indices   GOLOGGLE, AMEZON
   fee           50 bps, half of it retained in reserves
   roles         all four to the sender unless ADMIN/PUBLISHER/GUARDIAN/
                 TREASURER are set in the environment. One key holding all
                 four is testnet-only; the script warns about it too.
   verification  blockscout at $VERIFIER_URL

PLAN
if [[ "$RESUME" == 1 ]]; then
  echo "   RESUMING a previous broadcast; already-sent transactions are not repeated."
else
  read -r -p "Type yes to deploy: " answer
  [[ "$answer" == "yes" ]] || fail "not confirmed"
fi

say "deploying"
# --slow sends one transaction at a time and waits for each receipt.
#
# Not a precaution: without it this deploy fails on Mezo. Foundry pipelines
# broadcasts by signing several transactions with consecutive nonces and
# sending them together, which an Ethereum mempool queues by nonce. Mezo is
# Cosmos-based - mezod is a fork of Evmos - and its ante handler checks the
# account *sequence* on arrival instead, so a transaction that turns up with
# sequence 1 while the account is still at 0 is rejected outright rather than
# held: "invalid nonce; got 1, expected 0: invalid sequence". The first run
# here landed one contract and lost the rest to exactly that.
# --timeout, because the receipt is the flaky part. On Mezo a transaction can
# be in a block while eth_getTransactionReceipt still answers null, and
# Foundry reads that null as "failed to receive a receipt" and stops. It is
# not failure: the first --slow attempt here was reported as an error and the
# contract it deployed is on chain with status 1. A longer window lets the
# node catch up rather than abandoning a broadcast that worked.
EXTRA=()
[[ "$RESUME" == 1 ]] && EXTRA+=(--resume)

SETTLEMENT_TOKEN="$MUSD" forge script script/DeployMezoTestnet.s.sol \
  --rpc-url "$RPC" \
  --account "$ACCOUNT" \
  --sender "$SENDER" \
  --broadcast --slow --timeout 300 "${EXTRA[@]}" \
  --verify --verifier blockscout --verifier-url "$VERIFIER_URL" \
  | tee /tmp/leekstonks-mezo-deploy.log

cat <<'AFTER'

== next, in this order

  1. Copy every address from the log above into ADDRESSES.md with today's date.
  2. Check each one is a contract:  cast code <address> --rpc-url https://rpc.test.mezo.org
  3. Confirm the first oracle round:  cast call <oracle> "latestRoundData()(uint80,int256,uint256,uint256,uint80)"
  4. Open each in https://explorer.test.mezo.org and confirm the source verified.
  5. Put the oracle addresses and the publisher key in the feed's secrets file,
     mode 0600, on the VPS. Never in this repository.

  The full runbook, including Cloudflare and both vpsinfra projects, is in
  DEPLOYMENT.md.
AFTER
