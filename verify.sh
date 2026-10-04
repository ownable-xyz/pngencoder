#!/usr/bin/env bash
#
# verify.sh: publish the source of a deployed PNGEncoder (Etherscan
# verification).
#
# Verification is independent of the deploy. deploy.sh does not publish the
# source unless you give --verify. Thus you can deploy first and publish the
# source later with this script.
#
# This script reads the deployment record that deploy.sh wrote. It verifies the
# Deflate library and the PNGEncoder. It gives the address of the linked
# library, so that the compiled bytecode is the same as the deployed bytecode.
#
# Usage:
#   ./verify.sh sepolia          # verify the recorded sepolia deployment
#   ./verify.sh mainnet
#   ./verify.sh                  # if exactly one deployments/*.json exists, use it
#
# This script requires ETHERSCAN_API_KEY (from .env or the environment). Run it
# from the repository root at the same commit that you deployed. Verification
# compiles the working tree again. A different commit gives different bytecode,
# which does not match the on-chain bytecode.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f .env ] && { set -a; . ./.env; set +a; }

FORGE="${FORGE:-forge}"
command -v "$FORGE" >/dev/null 2>&1 || { echo "forge not found on PATH." >&2; exit 1; }
command -v python  >/dev/null 2>&1 && PY=python || PY=python3
strip() { printf '%s' "${1//$'\r'/}"; }   # defend against a stray CRLF in the record

# The free tier of Etherscan limits the rate of status requests (a small number
# of calls each second). The default --watch interval of forge can go above this
# limit. --delay increases the time between requests, and --retries permits more
# requests. Set VERIFY_DELAY / VERIFY_RETRIES to change these values. Increase
# the delay if your plan has a lower limit. Decrease the delay if your plan has
# a higher limit.
VERIFY_DELAY="${VERIFY_DELAY:-5}"
VERIFY_RETRIES="${VERIFY_RETRIES:-20}"

# --- find the deployment record ---------------------------------------------
NET="${1:-}"
if [ -z "$NET" ]; then
  shopt -s nullglob; recs=(deployments/*.json); shopt -u nullglob
  [ "${#recs[@]}" -eq 1 ] || { echo "usage: ./verify.sh <network>   (records: ${recs[*]:-none found})" >&2; exit 1; }
  NET="$(basename "${recs[0]}" .json)"
fi
REC="deployments/${NET}.json"
[ -f "$REC" ] || { echo "no deployment record at $REC" >&2; exit 1; }
[ -n "${ETHERSCAN_API_KEY:-}" ] || { echo "ETHERSCAN_API_KEY not set (put it in .env or the environment)." >&2; exit 1; }

read -r ENC LIB CHAIN COMMIT < <("$PY" - "$REC" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d["PNGEncoder"], d["Deflate"], d["chainId"], d.get("commit", "?"))
PY
)
ENC="$(strip "$ENC")"; LIB="$(strip "$LIB")"; CHAIN="$(strip "$CHAIN")"; COMMIT="$(strip "$COMMIT")"

echo "network:         $NET (chain $CHAIN)"
echo "PNGEncoder:      $ENC"
echo "Deflate:         $LIB"
echo "recorded commit: $COMMIT"

# --- commit check: verification compiles the current working tree again -----
CUR="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
DIRTY=""; [ -n "$(git status --porcelain 2>/dev/null)" ] && DIRTY=" (dirty)"
if [ "$COMMIT" != "?" ] && [ "${COMMIT%-dirty}" != "$CUR" ]; then
  echo
  echo "WARNING: current commit ${CUR}${DIRTY} differs from the deployed commit ${COMMIT}."
  echo "         Verification recompiles the working tree; check out ${COMMIT} first,"
  echo "         or the recompiled bytecode won't match what's on-chain."
  read -r -p "Proceed anyway? [y/N] " a; [[ "$a" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "aborted."; exit 1; }
fi

# --- verify the two contracts (forge reads the settings from foundry.toml) ---
echo
echo "==> verifying Deflate library… (polling every ${VERIFY_DELAY}s, up to ${VERIFY_RETRIES}x)"
"$FORGE" verify-contract "$LIB" "src/Deflate.sol:Deflate" \
  --chain "$CHAIN" --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch --retries "$VERIFY_RETRIES" --delay "$VERIFY_DELAY"

# Wait between the two contracts, so that the requests stay below the shared
# rate limit.
sleep "$VERIFY_DELAY"

echo
echo "==> verifying PNGEncoder (linked against Deflate @ $LIB)…"
"$FORGE" verify-contract "$ENC" "src/PNGEncoder.sol:PNGEncoder" \
  --libraries "src/Deflate.sol:Deflate:$LIB" \
  --chain "$CHAIN" --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch --retries "$VERIFY_RETRIES" --delay "$VERIFY_DELAY"

echo
echo "done — both contracts submitted for verification on chain $CHAIN."
