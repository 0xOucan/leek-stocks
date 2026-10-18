#!/usr/bin/env bash
#
# Take the addresses a deploy just printed and write them everywhere they are
# needed, in one step.
#
# Why this exists: a deployment lands eight addresses that then have to appear,
# identically, in ADDRESSES.md, web/deploy/Dockerfile, web/scripts/
# check-bundle.mjs and the feed's secrets file on the VPS. The first redeploy
# was done by hand and the whole preamble of ADDRESSES.md - "an address that is
# wrong is funds that are gone, and the failure is silent" - is about exactly
# the mistake that transcription invites. This reads the log, verifies each
# address has code on chain and answers the call it should, and only then
# edits.
#
# Usage:
#   ./scripts/record-deployment.sh /tmp/leekstonks-mezo-deploy.log
#
# It changes tracked files and does not commit. Read `git diff` before you do.

set -euo pipefail
cd "$(dirname "$0")/.."

LOG=${1:-/tmp/leekstonks-mezo-deploy.log}
RPC=${RPC:-https://rpc.test.mezo.org}
[[ -f "$LOG" ]] || { echo "no such log: $LOG" >&2; exit 1; }

fail() { printf 'STOP: %s\n' "$1" >&2; exit 1; }

# The LAST occurrence, not the first. A run that needed --resume prints the
# banner once per attempt, and the earlier ones are simulations whose
# addresses may differ from what landed.
pick() {
  grep -E "^  $1 " "$LOG" | grep -oE '0x[0-9a-fA-F]{40}' | tail -1
}

STAKING=$(pick "staking \(sMEZO\)")
FACTORY=$(pick "factory")
ORACLE_G=$(pick "GOLOGGLE oracle")
ORACLE_A=$(pick "AMEZON oracle")
SHARE_G=$(pick "GOLOGGLE share")
SHARE_A=$(pick "AMEZON share")
VAULT_G=$(pick "GOLOGGLE vault")
VAULT_A=$(pick "AMEZON vault")
MEZO=$(pick "MEZO token")
MUSD=$(pick "settlement token")

for pair in "staking:$STAKING" "factory:$FACTORY" \
            "GOLOGGLE oracle:$ORACLE_G" "AMEZON oracle:$ORACLE_A" \
            "GOLOGGLE share:$SHARE_G" "AMEZON share:$SHARE_A" \
            "GOLOGGLE vault:$VAULT_G" "AMEZON vault:$VAULT_A" \
            "MEZO:$MEZO" "MUSD:$MUSD"; do
  [[ -n "${pair#*:}" ]] || fail "could not read ${pair%%:*} from $LOG"
done

echo "== read from $LOG"
printf '   %-18s %s\n' staking "$STAKING" factory "$FACTORY" \
  "GOLOGGLE oracle" "$ORACLE_G" "GOLOGGLE share" "$SHARE_G" "GOLOGGLE vault" "$VAULT_G" \
  "AMEZON oracle" "$ORACLE_A" "AMEZON share" "$SHARE_A" "AMEZON vault" "$VAULT_A" \
  MEZO "$MEZO" MUSD "$MUSD"

# Verified against the chain before anything is written. A log can be stale,
# truncated, or from a run that was abandoned; code at the address and a call
# that answers cannot be.
echo
echo "== verifying on chain"
has_code() {
  local out
  out=$(cast code "$1" --rpc-url "$RPC")
  [[ "$out" != "0x" && -n "$out" ]] || fail "no contract at $2 ($1)"
}
for pair in "staking:$STAKING" "factory:$FACTORY" "GOLOGGLE oracle:$ORACLE_G" \
            "AMEZON oracle:$ORACLE_A" "GOLOGGLE share:$SHARE_G" "AMEZON share:$SHARE_A" \
            "GOLOGGLE vault:$VAULT_G" "AMEZON vault:$VAULT_A"; do
  has_code "${pair#*:}" "${pair%%:*}"
done
echo "   every address has code"

# And that they are the contracts the log claims, not merely contracts. A
# transposed pair of env vars produces two live addresses and a vault bound to
# the wrong index, which is the failure mode ConfigureMezoTestnet has an open
# audit finding about.
check() {
  local got
  got=$(cast call "$1" "$2" --rpc-url "$RPC" 2>/dev/null | tr -d '"')
  [[ "${got,,}" == "${3,,}" ]] || fail "$4: expected $3, got $got"
  printf '   %s\n' "$4"
}
check "$VAULT_G" "share()(address)"   "$SHARE_G"  "the GOLOGGLE vault's share is the GOLOGGLE share"
check "$VAULT_A" "share()(address)"   "$SHARE_A"  "the AMEZON vault's share is the AMEZON share"
check "$VAULT_G" "oracle()(address)"  "$ORACLE_G" "the GOLOGGLE vault reads the GOLOGGLE oracle"
check "$VAULT_A" "oracle()(address)"  "$ORACLE_A" "the AMEZON vault reads the AMEZON oracle"
check "$VAULT_G" "musd()(address)"    "$MUSD"     "the GOLOGGLE vault settles in the right MUSD"
check "$VAULT_A" "musd()(address)"    "$MUSD"     "the AMEZON vault settles in the right MUSD"
check "$VAULT_G" "staking()(address)" "$STAKING"  "the GOLOGGLE vault is wired to staking"
check "$VAULT_A" "staking()(address)" "$STAKING"  "the AMEZON vault is wired to staking"
check "$STAKING" "mezo()(address)"    "$MEZO"     "staking takes MEZO"
check "$STAKING" "musd()(address)"    "$MUSD"     "staking pays MUSD"

# The two oracles must not be the same contract. Both report the same
# interface, so nothing downstream would notice, and both indices would then
# print one price.
[[ "${ORACLE_G,,}" != "${ORACLE_A,,}" ]] || fail "both indices are bound to the same oracle"
[[ "${SHARE_G,,}" != "${SHARE_A,,}" ]] || fail "both indices are bound to the same share token"
echo "   the two indices are distinct"

echo
echo "== writing"
sub() {
  # $1 file, $2 old address, $3 new address. Case-insensitive, because the
  # log's casing is the compiler's and a file's is EIP-55.
  local file=$1 old=$2 new=$3
  [[ "${old,,}" == "${new,,}" ]] && return 0
  grep -qiF "$old" "$file" || return 0
  python3 - "$file" "$old" "$new" <<'PY'
import re, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
out = re.sub(re.escape(old), new, text, flags=re.IGNORECASE)
open(path, "w").write(out)
PY
  echo "   $file: $old -> $new"
}

# The addresses the previous deployment left in the tree. Read from the files
# rather than hardcoded, so this script keeps working across redeployments.
OLD_VAULT_G=$(grep -oE 'ARG VITE_VAULT_GOLOGGLE="0x[0-9a-fA-F]{40}' web/deploy/Dockerfile | grep -oE '0x[0-9a-fA-F]{40}')
OLD_VAULT_A=$(grep -oE 'ARG VITE_VAULT_AMEZON="0x[0-9a-fA-F]{40}' web/deploy/Dockerfile | grep -oE '0x[0-9a-fA-F]{40}')
OLD_SHARE_G=$(grep -oE 'ARG VITE_SHARE_GOLOGGLE="0x[0-9a-fA-F]{40}' web/deploy/Dockerfile | grep -oE '0x[0-9a-fA-F]{40}')
OLD_SHARE_A=$(grep -oE 'ARG VITE_SHARE_AMEZON="0x[0-9a-fA-F]{40}' web/deploy/Dockerfile | grep -oE '0x[0-9a-fA-F]{40}')
# The oracles are not build args - nothing in the dapp reads them directly,
# the vault reports its own - but they are recorded in ADDRESSES.md and they
# are what goes in the feed's secrets file, so they are substituted too.
OLD_ORACLE_G=$(grep -E '^\| `IndexOracle` GOLOGGLE' ADDRESSES.md | grep -oE '0x[0-9a-fA-F]{40}' | head -1)
OLD_ORACLE_A=$(grep -E '^\| `IndexOracle` AMEZON' ADDRESSES.md | grep -oE '0x[0-9a-fA-F]{40}' | head -1)

for f in web/deploy/Dockerfile web/scripts/check-bundle.mjs ADDRESSES.md README.md DEPLOY-BRIEF.md DEPLOYMENT.md; do
  [[ -f "$f" ]] || continue
  sub "$f" "$OLD_VAULT_G" "$VAULT_G"
  sub "$f" "$OLD_VAULT_A" "$VAULT_A"
  sub "$f" "$OLD_SHARE_G" "$SHARE_G"
  sub "$f" "$OLD_SHARE_A" "$SHARE_A"
  [[ -n "$OLD_ORACLE_G" ]] && sub "$f" "$OLD_ORACLE_G" "$ORACLE_G"
  [[ -n "$OLD_ORACLE_A" ]] && sub "$f" "$OLD_ORACLE_A" "$ORACLE_A"
done

# The staking address is new rather than a replacement, so it is set rather
# than substituted.
python3 - "$STAKING" "$MEZO" <<'PY'
import sys
staking, mezo = sys.argv[1], sys.argv[2]

p = "web/deploy/Dockerfile"
s = open(p).read()
import re
s = re.sub(r'ARG VITE_STAKING="[^"]*"', f'ARG VITE_STAKING="{staking}"', s)
s = re.sub(r'ARG VITE_MEZO="[^"]*"', f'ARG VITE_MEZO="{mezo}"', s)
open(p, "w").write(s)
print(f"   {p}: VITE_STAKING={staking}, VITE_MEZO={mezo}")

p = "web/scripts/check-bundle.mjs"
s = open(p).read()
key = '"MEZO fee-discount staking"'
if key in s:
    s = re.sub(r'"MEZO fee-discount staking": "0x[0-9a-fA-F]{40}"',
               f'"MEZO fee-discount staking": "{staking}"', s)
else:
    anchor = '  "Mezo BorrowerOperations":'
    s = s.replace(anchor, f'  "MEZO fee-discount staking": "{staking}",\n{anchor}', 1)
open(p, "w").write(s)
print(f"   {p}: requires the staking address")
PY

echo
echo "== next"
cat <<NEXT
   1. git diff, then commit.
   2. Rebuild the dapp image with the new build args. The defaults in
      web/deploy/Dockerfile now carry them, so a plain build is correct, but
      check-bundle.mjs is what proves it rather than this script.
   3. Put the two new oracle addresses in the feed's secrets file on the VPS:
        ORACLE_GOLOGGLE=$ORACLE_G
        ORACLE_AMEZON=$ORACLE_A
      Nothing else in that file changes. The publisher key is unchanged and
      must not be re-entered.
   4. Grant PUBLISHER_ROLE on both oracles to the production publisher if the
      deploy did not: ./scripts/grant-publisher.sh
   5. List the GOLOGGLE/MUSD pool once: ./scripts/create-pool.sh
NEXT
