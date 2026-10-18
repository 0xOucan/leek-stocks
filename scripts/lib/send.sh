# shellcheck shell=bash
#
# Sending a sequence of transactions on Mezo, without trusting a receipt.
#
# Two of Mezo's quirks pull in opposite directions and this file is the only
# place that resolves them:
#
#   1. `mezod` reports a Cosmos *sequence* rather than an Ethereum nonce, and
#      rejects a transaction built from a stale one. So a second transaction
#      sent immediately after a first is refused.
#   2. `eth_getTransactionReceipt` returns null for minutes after inclusion,
#      so `cast send` without `--async` waits and then reports a failure for a
#      transaction that succeeded.
#
# `forge script --slow` handles (1) by waiting for each receipt, which is why
# deploy-mezo.sh uses it. `cast send` has no `--slow` - passing it is an error,
# which is how this file came to exist - and waiting for a receipt runs into
# (2) anyway.
#
# So: send with `--async` to get the hash, then wait for the account's nonce to
# advance. An advanced nonce proves inclusion without asking for a receipt.
#
# Inclusion is not success: a mined transaction can still have reverted. The
# caller therefore checks the *effect* it wanted - an allowance, a balance, a
# pool address - which is a stronger confirmation than a receipt status, and
# the only one available here.

SEND_POLL_SECONDS=${SEND_POLL_SECONDS:-3}
SEND_POLL_ATTEMPTS=${SEND_POLL_ATTEMPTS:-80}

# send_and_confirm "<label>" <cast send args...>
# Requires ACCOUNT, RPC and ME to be set. Echoes the hash. Returns non-zero if
# the nonce never advances.
send_and_confirm () {
  local label=$1; shift
  local before after hash attempt

  before=$(cast nonce "$ME" --rpc-url "$RPC")
  printf '> %s\n' "$label"

  if ! hash=$(cast send --account "$ACCOUNT" --rpc-url "$RPC" --async "$@"); then
    printf '  FAILED to submit\n'
    return 1
  fi
  printf '  hash      %s\n' "$hash"
  printf '  explorer  https://explorer.test.mezo.org/tx/%s\n' "$hash"

  for (( attempt = 1; attempt <= SEND_POLL_ATTEMPTS; attempt++ )); do
    sleep "$SEND_POLL_SECONDS"
    after=$(cast nonce "$ME" --rpc-url "$RPC" 2>/dev/null || printf '%s' "$before")
    if [[ "$after" -gt "$before" ]]; then
      printf '  included  nonce %s -> %s\n' "$before" "$after"
      return 0
    fi
  done

  printf '  TIMED OUT after %ss. The transaction may still land; check the\n' \
    "$(( SEND_POLL_SECONDS * SEND_POLL_ATTEMPTS ))"
  printf '            explorer link above rather than assuming either way.\n'
  return 1
}

# expect_state "<what>" "<expected>" "<actual>"
# The effect check. Inclusion is not success, so every send is followed by one
# of these and the script stops rather than continuing on a false premise.
expect_state () {
  local what=$1 expected=$2 actual=$3
  if [[ "${expected,,}" == "${actual,,}" ]]; then
    printf '  confirmed %s\n' "$what"
    return 0
  fi
  printf '  WRONG     %s\n' "$what"
  printf '            expected %s\n' "$expected"
  printf '            actual   %s\n' "$actual"
  return 1
}
