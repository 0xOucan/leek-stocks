#!/usr/bin/env bash
#
# Bring the whole of LeekDefi up on a local chain, so it can be clicked.
#
# Anvil, the contracts, the feed and the dapp, wired together, in one command.
# Nothing here touches a public network and nothing costs anything: the keys
# below are Anvil's own, published in its documentation, and they are safe
# *only* because this chain has no value on it. They must never appear in a
# command aimed at anything else, which is why they live in this script and
# nowhere near the deployment path.
#
# Usage:
#   ./scripts/local-up.sh            # bring everything up and stay running
#   ./scripts/local-up.sh --no-dapp  # contracts and feed only
#
# Ctrl-C stops everything it started.

set -euo pipefail
cd "$(dirname "$0")/.."

CHAIN_ID=31337
RPC=http://127.0.0.1:8545
FEED_PORT=8787
# Anvil account 0. A published test key; see the note above.
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
WANT_DAPP=1
[[ "${1:-}" == "--no-dapp" ]] && WANT_DAPP=0

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need anvil; need forge; need cast; need node

PIDS=()
cleanup() {
  echo
  echo "== stopping"
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "== anvil on :8545 (chain $CHAIN_ID)"
anvil --port 8545 --chain-id "$CHAIN_ID" --silent &
PIDS+=($!)
for _ in $(seq 1 50); do
  cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 0.2
done
cast chain-id --rpc-url "$RPC" >/dev/null || { echo "anvil did not come up" >&2; exit 1; }

echo "== contracts"
# ALLOW_CHAIN_ID is the deploy script's deliberate rehearsal escape: the same
# script that deploys to Mezo, run here, rather than a second copy of its
# constants that can drift from it.
export ALLOW_CHAIN_ID="$CHAIN_ID"
# A mock settlement token, because the real MUSD only exists on Mezo. 18
# decimals, like the real one, so the scaling path is the same.
# Parsed from `forge create`'s human output, because this Foundry (1.4.4)
# ignores --json for `create` and prints "Deployed to: 0x...". Two earlier
# versions of this line parsed a JSON shape that never arrives, found nothing,
# and left SETTLEMENT_TOKEN empty - at which point the deploy
# script fell back to the REAL Mezo MUSD address and failed against a chain
# that has no such contract. Hence the guard below: an empty address must stop
# the run, not be passed on as a default.
MUSD=$(forge create test/mocks/MockMUSD.sol:MockMUSD \
  --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast \
  --constructor-args 18 2>&1 \
  | grep -iE 'deployed ?to' | grep -oE '0x[0-9a-fA-F]{40}' | head -1)
[[ -n "$MUSD" ]] || { echo "could not read the mock token's address" >&2; exit 1; }
echo "   leekMUSD (mock)   $MUSD"
export SETTLEMENT_TOKEN="$MUSD"

forge script script/DeployMezoTestnet.s.sol \
  --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast \
  >/tmp/leekdefi-deploy.log 2>&1 || { tail -30 /tmp/leekdefi-deploy.log; exit 1; }

pick() {
  grep -E "$1" /tmp/leekdefi-deploy.log | grep -oE '0x[0-9a-fA-F]{40}' | head -1
}
FACTORY=$(pick "factory")
ORACLE_G=$(pick "GOLOGGLE oracle")
ORACLE_A=$(pick "AMEZON oracle")
VAULT_G=$(pick "GOLOGGLE vault")
VAULT_A=$(pick "AMEZON vault")
SHARE_G=$(pick "GOLOGGLE share")
SHARE_A=$(pick "AMEZON share")
for pair in "factory:$FACTORY" "GOLOGGLE oracle:$ORACLE_G" "AMEZON oracle:$ORACLE_A" \
            "GOLOGGLE vault:$VAULT_G" "AMEZON vault:$VAULT_A" \
            "GOLOGGLE share:$SHARE_G" "AMEZON share:$SHARE_A"; do
  [[ -n "${pair#*:}" ]] || { echo "could not read ${pair%%:*} from the deploy log" >&2; exit 1; }
done
echo "   factory           $FACTORY"
echo "   GOLOGGLE vault    $VAULT_G"
echo "   AMEZON vault      $VAULT_A"

# Mint the clicker some MUSD. Without it the first thing a visitor sees is a
# buy button that cannot work, which looks like a bug in the page.
cast send "$MUSD" "mint(address,uint256)" "$DEPLOYER" 1000000000000000000000000 \
  --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" >/dev/null
echo "   minted 1,000,000 mock MUSD to $DEPLOYER"

echo "== feed on :$FEED_PORT (synthetic prices, chain $CHAIN_ID)"
( cd feed && [ -d node_modules ] || npm ci --silent --no-audit --no-fund ) || true
env -C feed \
  PUBLISHER_PRIVATE_KEY="$DEPLOYER_KEY" \
  ORACLE_GOLOGGLE="$ORACLE_G" ORACLE_AMEZON="$ORACLE_A" \
  RPC_URL="$RPC" CHAIN_ID="$CHAIN_ID" \
  SYNTHETIC=1 INTERVAL_SECONDS=10 HEARTBEAT_SECONDS=30 THRESHOLD_BPS=25 \
  HTTP_PORT="$FEED_PORT" \
  node --experimental-strip-types --disable-warning=ExperimentalWarning src/main.ts &
PIDS+=($!)
sleep 4
curl -fsS "http://127.0.0.1:$FEED_PORT/healthz" >/dev/null && echo "   feed healthy" || echo "   feed not answering yet"

if [[ "$WANT_DAPP" == 1 ]]; then
  # A dev-only env file, never committed: .env is git-ignored and this one is
  # written fresh each run so a stale address cannot survive a redeploy.
  cat > web/.env.local <<ENV
VITE_CHAIN_ID=$CHAIN_ID
VITE_RPC_URL=$RPC
VITE_FEED_URL=/prices
VITE_PUBLIC_URL=http://127.0.0.1:5173
VITE_MUSD=$MUSD
VITE_VAULT_GOLOGGLE=$VAULT_G
VITE_VAULT_AMEZON=$VAULT_A
VITE_SHARE_GOLOGGLE=$SHARE_G
VITE_SHARE_AMEZON=$SHARE_A
ENV
  echo "== dapp on :5173"
  ( cd web && [ -d node_modules ] || npm ci --silent --no-audit --no-fund ) || true
  env -C web npm run dev -- --host 127.0.0.1 &
  PIDS+=($!)
  sleep 3
  cat <<INFO

   Open http://127.0.0.1:5173

   In the wallet: add a network with RPC $RPC and chain id $CHAIN_ID,
   then import Anvil's account 0. Its key is in this script - safe here
   and nowhere else.

INFO
fi

echo "== running. Ctrl-C to stop everything."
wait
