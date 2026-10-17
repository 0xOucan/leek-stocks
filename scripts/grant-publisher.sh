#!/usr/bin/env bash
#
# Give a dedicated address PUBLISHER_ROLE on both oracles, and optionally take
# it away from the deployer.
#
# Why not just run the feed with the deployer's key: the feed signs
# transactions continuously, so it is a hot wallet by definition, and its key
# has to sit in a file on a server. The deployer key holds admin, guardian and
# treasurer on everything we have deployed. Putting that key on a VPS would
# mean a compromised server could pause the feed, move the fees and
# reconfigure the vaults — rather than only push prices inside an immutable
# per-round bound, which is all PUBLISHER_ROLE can do (audit finding M-1).
#
# So: generate a key that exists only for this, grant it the one role, fund it
# with gas, and keep the deployer key where it is.
#
#   cast wallet new                      # on your machine, not here
#   ./scripts/grant-publisher.sh 0xThePublisherAddress
#   ./scripts/grant-publisher.sh 0xThePublisherAddress --revoke-deployer
#
# The private key goes into the feed's secrets file on the VPS, mode 0600, and
# nowhere else. Never into this repository, a command line or a chat message.
#
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT=${ACCOUNT:-monad-deployer}
RPC=${RPC:-https://rpc.test.mezo.org}
ORACLES=(
  0x7fCb1ed8d6fAaEF00AA5A0104A062299ab7D5BF6   # GOLOGGLE / MUSD
  0x5Ed8205bA3DC7075099cFC4b2D4b7f2fF8a9cf9D   # AMEZON / MUSD
)
# keccak256("PUBLISHER_ROLE")
PUBLISHER_ROLE=$(cast keccak "PUBLISHER_ROLE")

PUBLISHER=${1:-}
REVOKE=0
[[ "${2:-}" == "--revoke-deployer" ]] && REVOKE=1
[[ "$PUBLISHER" =~ ^0x[0-9a-fA-F]{40}$ ]] || {
  echo "usage: $0 0xPublisherAddress [--revoke-deployer]" >&2; exit 1; }

PASSFILE=""
cleanup() { [[ -n "$PASSFILE" && -f "$PASSFILE" ]] && shred -u "$PASSFILE" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

dir=/dev/shm; [[ -d "$dir" && -w "$dir" ]] || dir="${TMPDIR:-/tmp}"
PASSFILE=$(mktemp "$dir/.leekpass.XXXXXX"); chmod 600 "$PASSFILE"
read -rsp "Keystore password for $ACCOUNT: " pw; echo
printf '%s' "$pw" > "$PASSFILE"; unset pw

SENDER=$(cast wallet address --account "$ACCOUNT" --password-file "$PASSFILE")
echo "admin     $SENDER"
echo "publisher $PUBLISHER"
echo "role      $PUBLISHER_ROLE"

# Confirmed by reading the state afterwards, not by waiting for a receipt.
#
# Mezo answers eth_getTransactionReceipt with null for minutes after a
# transaction is in a block, so `cast send` blocks and then reports a failure
# that did not happen. --async returns the hash immediately and the loop below
# polls hasRole, which is the thing we actually care about: a role that reads
# true is granted whether or not a receipt is available yet.
wait_for() {   # address, expected (true|false)
  local oracle=$1 want=$2
  for _ in $(seq 1 60); do
    [[ "$(cast call "$oracle" "hasRole(bytes32,address)(bool)" "$PUBLISHER_ROLE" "$PUBLISHER" --rpc-url "$RPC" 2>/dev/null)" == "$want" ]] && return 0
    sleep 5
  done
  return 1
}

for oracle in "${ORACLES[@]}"; do
  echo
  echo "== $oracle"
  if [[ "$(cast call "$oracle" "hasRole(bytes32,address)(bool)" "$PUBLISHER_ROLE" "$PUBLISHER" --rpc-url "$RPC")" == "true" ]]; then
    echo "   already granted"
  else
    hash=$(cast send "$oracle" "grantRole(bytes32,address)" "$PUBLISHER_ROLE" "$PUBLISHER" \
      --rpc-url "$RPC" --account "$ACCOUNT" --password-file "$PASSFILE" --async)
    echo "   grant sent: $hash"
    wait_for "$oracle" true && echo "   hasRole is now true" || { echo "   role did not appear; check $hash" >&2; exit 1; }
  fi

  if [[ "$REVOKE" == 1 ]]; then
    # The deployer keeps DEFAULT_ADMIN_ROLE, so it can always grant the role
    # back. Dropping its own publisher rights means a compromised deployer key
    # cannot quietly move prices, and that the only key that can is the one
    # with nothing else on it.
    if [[ "$(cast call "$oracle" "hasRole(bytes32,address)(bool)" "$PUBLISHER_ROLE" "$SENDER" --rpc-url "$RPC")" == "true" ]]; then
      hash=$(cast send "$oracle" "revokeRole(bytes32,address)" "$PUBLISHER_ROLE" "$SENDER" \
        --rpc-url "$RPC" --account "$ACCOUNT" --password-file "$PASSFILE" --async)
      echo "   revoke from deployer sent: $hash"
      for _ in $(seq 1 60); do
        [[ "$(cast call "$oracle" "hasRole(bytes32,address)(bool)" "$PUBLISHER_ROLE" "$SENDER" --rpc-url "$RPC" 2>/dev/null)" == "false" ]] && break
        sleep 5
      done
      echo "   deployer publisher rights: $(cast call "$oracle" "hasRole(bytes32,address)(bool)" "$PUBLISHER_ROLE" "$SENDER" --rpc-url "$RPC")"
    else
      echo "   deployer already has no publisher rights"
    fi
  fi
done

cat <<NEXT

== next

  Fund the publisher with a little BTC for gas. Mezo's base fee is about 130
  wei, so a few thousandths of a BTC publishes for months:

    cast send $PUBLISHER --value 0.005ether --rpc-url $RPC --account $ACCOUNT \
      --async

  That prompts for the password. Sending it from your wallet works just as
  well.

  --async matters here. Without it, `cast send` waits for a receipt, and Mezo
  answers eth_getTransactionReceipt with null for minutes after a transaction
  is already in a block - so it prints

    Error: server returned a null response when a non-null response was expected

  and the transfer has landed anyway. Confirm by reading the balance, which is
  the thing you actually wanted to know:

    cast balance $PUBLISHER --rpc-url $RPC

  Then put the publisher's PRIVATE key in the feed's secrets file on the VPS:

    /srv/oucan/secrets/projects/leekdefi-feed.env   (mode 0600)
      PUBLISHER_PRIVATE_KEY=0x...
      ORACLE_GOLOGGLE=${ORACLES[0]}
      ORACLE_AMEZON=${ORACLES[1]}
      RPC_URL=$RPC
      CHAIN_ID=31611

  Nowhere else: not in this repository, not in a command line, not in a chat.
NEXT
