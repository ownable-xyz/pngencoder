#!/usr/bin/env bash
#
# deploy.sh: interactive, step-by-step deployer for PNGEncoder.
#
# Walks you through deploying the PNGEncoder contract (which links, and so
# auto-deploys, the Deflate library) to a local dry run, Sepolia, or Ethereum
# mainnet, signing with a Ledger hardware wallet and stopping for confirmation
# at every step that touches a real chain.
#
# Safety model (checks & balances):
#   • refuses to run unless forge/cast are present and recent enough
#   • deploys a *known git commit*; warns loudly on a dirty tree
#   • builds fresh and (by default) runs the test suite before anything else
#   • verifies the RPC's chain id matches the network you chose (wrong-RPC guard)
#   • confirms the CREATE2 factory the library needs actually exists on-chain
#   • lets you pick the exact Ledger account and shows its balance
#   • ALWAYS simulates (dry-runs) before it broadcasts, and prints the cost
#   • requires an explicit typed confirmation, extra friction for mainnet
#   • signs on-device, deploys with --slow (one tx at a time); publishes source
#     to Etherscan only if you opt in with --verify (else verify later, privately)
#   • re-checks the deployed code and writes a durable deployment record
#
# Usage:
#   ./deploy.sh                     # fully interactive; pick the network from a menu
#   ./deploy.sh --dry-run           # simulate only, no chain, no Ledger required
#   ./deploy.sh --sepolia           # guided deploy to Sepolia
#   ./deploy.sh --mainnet           # guided deploy to Ethereum mainnet
#   ./deploy.sh --sepolia --rpc-url https://...   # override the RPC endpoint
#   ./deploy.sh --mainnet --hd-path "m/44'/60'/0'/0/0"   # preselect the account
#   ./deploy.sh --no-tests          # skip the test run in preflight (not advised)
#   ./deploy.sh --sepolia --verify  # opt in to publishing source on Etherscan at deploy time
#                                   #   (OFF by default: source is NOT published unless you pass
#                                   #    --verify. Publish later, when ready, with ./verify.sh)
#   ./deploy.sh --sepolia -y        # -y/--yes: skip the confirm prompt on testnets
#                                   #   (mainnet ALWAYS requires the typed confirmation)
#
# Environment (read if set; you're prompted otherwise):
#   SEPOLIA_RPC_URL, MAINNET_RPC_URL   RPC endpoints per network
#   ETHERSCAN_API_KEY                  used for --verify (single key, all chains)
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Setup                                                                         #
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load the local configuration and secrets from .env if the file exists (RPC
# URLs, ETHERSCAN_API_KEY). Git ignores .env. The --rpc-url flag overrides the
# endpoint that the file sets.
if [ -f .env ]; then set -a; . ./.env; set +a; fi

FORGE="${FORGE:-forge}"
CAST="${CAST:-cast}"

SCRIPT_TARGET="script/Deploy.s.sol:Deploy"
CONTRACT="PNGEncoder"
LIBRARY="Deflate"
# This is the deterministic deployment proxy (Arachnid). forge deploys linked
# libraries with CREATE2 through this factory. The factory must be on the target
# chain.
CREATE2_FACTORY="0x4e59b44847b379578588920cA78FbF26c0B4956C"

# These networks support Cancun. PNGEncoder uses MCOPY and does not run on a
# chain that does not support Cancun. The script sets the chain id and the
# explorer for each network name below.
MAINNET_CHAIN_ID=1
SEPOLIA_CHAIN_ID=11155111

TMPDIR_="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_"' EXIT

# --------------------------------------------------------------------------- #
# Pretty output                                                                 #
# --------------------------------------------------------------------------- #
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YLW=$'\033[33m'; BLU=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; RST=""
fi
STEP_N=0
step()   { STEP_N=$((STEP_N+1)); printf '\n%s━━ Step %d · %s%s\n' "$BOLD$BLU" "$STEP_N" "$*" "$RST"; }
info()   { printf '   %s\n' "$*"; }
kv()     { printf '   %s%-22s%s %s\n' "$DIM" "$1" "$RST" "$2"; }
ok()     { printf '   %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn()   { printf '   %s⚠ %s%s\n' "$YLW" "$*" "$RST"; }
die()    { printf '\n%s✗ %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }
rule()   { printf '%s──────────────────────────────────────────────────────────%s\n' "$DIM" "$RST"; }

ask() { # ask "prompt" -> echoes the reply
  local reply; read -r -p "   $(printf '%s?%s ' "$BLU" "$RST")$1 " reply || true; echo "$reply"
}
confirm() { # confirm "prompt"  -> returns 0 on y/yes
  local reply; reply="$(ask "$1 [y/N]")"; [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# --------------------------------------------------------------------------- #
# Argument parsing                                                              #
# --------------------------------------------------------------------------- #
NETWORK=""            # "", dry-run, sepolia, mainnet
RPC_OVERRIDE=""
HD_PATH=""
SENDER_OVERRIDE=""
RUN_TESTS=1
DO_VERIFY=0            # verification is OPT-IN: source is published only with --verify
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)          NETWORK="dry-run" ;;
    --sepolia)          NETWORK="sepolia" ;;
    --mainnet)          NETWORK="mainnet" ;;
    --network)          shift; NETWORK="${1:-}" ;;
    --rpc-url)          shift; RPC_OVERRIDE="${1:-}" ;;
    --hd-path|--path)   shift; HD_PATH="${1:-}" ;;
    --sender)           shift; SENDER_OVERRIDE="${1:-}" ;;
    --no-tests)         RUN_TESTS=0 ;;
    --verify)           DO_VERIFY=1 ;;
    --no-verify)        DO_VERIFY=0 ;;   # accepted for symmetry; verification is already off by default
    -y|--yes)           ASSUME_YES=1 ;;
    -h|--help)          sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
  shift
done

printf '%s\n' "$BOLD"
printf '   ┌─────────────────────────────────────────────┐\n'
printf '   │   PNGEncoder: guided contract deployment    │\n'
printf '   └─────────────────────────────────────────────┘%s\n' "$RST"

# --------------------------------------------------------------------------- #
# Step 1: tooling                                                               #
# --------------------------------------------------------------------------- #
step "Toolchain"
command -v "$FORGE" >/dev/null 2>&1 || die "forge not found on PATH. Install/upgrade with: foundryup -i stable"
command -v "$CAST"  >/dev/null 2>&1 || die "cast not found on PATH."
FORGE_VER="$("$FORGE" --version 2>/dev/null | head -1)"
FVER_MAJOR="$("$FORGE" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)"
kv "forge" "$FORGE_VER"
if [ "${FVER_MAJOR:-0}" -lt 1 ] 2>/dev/null; then
  die "foundry >= 1.0 is required (this repo targets the Cancun EVM). Run: foundryup -i stable"
fi
command -v python  >/dev/null 2>&1 && JSON=python  || { command -v python3 >/dev/null 2>&1 && JSON=python3 || die "python is required to parse deployment output."; }
ok "toolchain looks good"

# --------------------------------------------------------------------------- #
# Step 2: repository state                                                      #
# --------------------------------------------------------------------------- #
step "Repository & source state"
[ -f foundry.toml ] && [ -f "src/${CONTRACT}.sol" ] || die "run this from the pngencoder repo root (foundry.toml + src/${CONTRACT}.sol not found)."
if git rev-parse --git-dir >/dev/null 2>&1; then
  GIT_COMMIT="$(git rev-parse --short HEAD)"
  GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  kv "branch" "$GIT_BRANCH"
  kv "commit" "$GIT_COMMIT"
  if [ -n "$(git status --porcelain)" ]; then
    warn "working tree is DIRTY: you would be deploying uncommitted changes."
    git status --short | sed 's/^/       /'
    GIT_COMMIT="${GIT_COMMIT}-dirty"
  else
    ok "working tree clean, deploying a known commit"
  fi
else
  warn "not a git repository: cannot record the exact source revision."
  GIT_COMMIT="unknown"
fi

# --------------------------------------------------------------------------- #
# Step 3: build & test                                                          #
# --------------------------------------------------------------------------- #
step "Build & test"
info "building…"
"$FORGE" build >"$TMPDIR_"/build.log 2>&1 || { cat "$TMPDIR_"/build.log; die "forge build failed."; }
ok "compiled"
if [ "$RUN_TESTS" -eq 1 ]; then
  info "running tests (skip with --no-tests)…"
  if "$FORGE" test >"$TMPDIR_"/test.log 2>&1; then
    ok "tests passed  ($(grep -oE '[0-9]+ (passed|tests? passed)' "$TMPDIR_"/test.log | head -1))"
  else
    tail -30 "$TMPDIR_"/test.log | sed 's/^/       /'
    die "tests failed: refusing to deploy failing code. Override with --no-tests if you must."
  fi
else
  warn "skipping tests (--no-tests)"
fi

# --------------------------------------------------------------------------- #
# Step 4: network selection                                                     #
# --------------------------------------------------------------------------- #
step "Target network"
if [ -z "$NETWORK" ]; then
  info "Where do you want to deploy?"
  info "  ${BOLD}1${RST}) Dry run    : local simulation only, nothing is sent, no Ledger needed"
  info "  ${BOLD}2${RST}) Sepolia    : public testnet"
  info "  ${BOLD}3${RST}) Mainnet    : ${RED}${BOLD}Ethereum mainnet: real ETH${RST}"
  case "$(ask 'Select 1/2/3:')" in
    1) NETWORK="dry-run" ;;
    2) NETWORK="sepolia" ;;
    3) NETWORK="mainnet" ;;
    *) die "no valid network selected." ;;
  esac
fi

case "$NETWORK" in
  dry-run) IS_DRYRUN=1; CHAIN_ID=""; EXPLORER="" ;;
  sepolia) IS_DRYRUN=0; CHAIN_ID=$SEPOLIA_CHAIN_ID; EXPLORER="https://sepolia.etherscan.io"
           RPC_URL="${RPC_OVERRIDE:-${SEPOLIA_RPC_URL:-}}" ;;
  mainnet) IS_DRYRUN=0; CHAIN_ID=$MAINNET_CHAIN_ID;  EXPLORER="https://etherscan.io"
           RPC_URL="${RPC_OVERRIDE:-${MAINNET_RPC_URL:-}}" ;;
  *) die "unknown network: $NETWORK (expected dry-run | sepolia | mainnet)" ;;
esac
kv "network" "$NETWORK${CHAIN_ID:+  (chain id $CHAIN_ID)}"

# A dry run can simulate against a live RPC, but it does not require one.
if [ "$IS_DRYRUN" -eq 1 ]; then
  RPC_URL="${RPC_OVERRIDE:-}"
  [ -n "$RPC_URL" ] && info "simulating against provided RPC for realism" || info "simulating locally (no RPC)"
fi

# --------------------------------------------------------------------------- #
# Step 5: RPC & chain sanity (real networks)                                    #
# --------------------------------------------------------------------------- #
if [ "$IS_DRYRUN" -eq 0 ]; then
  step "RPC & chain checks"
  if [ -z "${RPC_URL:-}" ]; then
    warn "no RPC URL for $NETWORK (set ${NETWORK^^}_RPC_URL or pass --rpc-url)."
    RPC_URL="$(ask "Enter the ${NETWORK} RPC URL:")"
  fi
  [ -n "$RPC_URL" ] || die "an RPC URL is required to deploy to $NETWORK."
  info "checking RPC…"
  ACTUAL_CHAIN="$("$CAST" chain-id --rpc-url "$RPC_URL" 2>"$TMPDIR_"/rpc.err)" || { cat "$TMPDIR_"/rpc.err; die "could not reach the RPC endpoint."; }
  if [ "$ACTUAL_CHAIN" != "$CHAIN_ID" ]; then
    die "RPC chain id mismatch: you chose $NETWORK (chain $CHAIN_ID) but the RPC reports chain $ACTUAL_CHAIN. Aborting to avoid deploying to the wrong network."
  fi
  ok "RPC reachable and reports chain id $ACTUAL_CHAIN (matches $NETWORK)"
  # The linked Deflate library deploys with CREATE2 through the deterministic
  # factory.
  FCODE="$("$CAST" code "$CREATE2_FACTORY" --rpc-url "$RPC_URL" 2>/dev/null || echo 0x)"
  if [ "$FCODE" = "0x" ] || [ -z "$FCODE" ]; then
    die "the CREATE2 deployer $CREATE2_FACTORY is not present on this chain: forge cannot deploy the $LIBRARY library here."
  fi
  ok "CREATE2 deployment factory present (library linking will work)"
fi

# --------------------------------------------------------------------------- #
# Step 6: signer / account selection                                            #
# --------------------------------------------------------------------------- #
step "Deployer account"
resolve_addr() { # resolve_addr <hd-path> -> address (via Ledger)
  "$CAST" wallet address --ledger --mnemonic-derivation-path "$1" 2>"$TMPDIR_"/led.err
}
show_balance() { # show_balance <addr> ; prints "  (12.34 ETH)" when an RPC is known
  [ -n "${RPC_URL:-}" ] || { echo ""; return; }
  local bal; bal="$("$CAST" balance "$1" --ether --rpc-url "$RPC_URL" 2>/dev/null || echo '?')"
  printf '  (%s ETH)' "$bal"
}

pick_from_ledger() { # interactive scheme -> enumerate 5 -> select; sets SENDER + HD_PATH
  local scheme sel i p a
  info "Make sure your Ledger is plugged in, unlocked, with the Ethereum app open."
  info "Which derivation scheme does your account use?"
  info "  ${BOLD}1${RST}) Ledger Live    m/44'/60'/${BOLD}x${RST}'/0/0   ${DIM}(most common)${RST}"
  info "  ${BOLD}2${RST}) Legacy / MEW   m/44'/60'/0'/${BOLD}x${RST}"
  info "  ${BOLD}3${RST}) Custom path"
  case "$(ask 'Select 1/2/3:')" in
    1) scheme="m/44'/60'/%d'/0/0" ;;
    2) scheme="m/44'/60'/0'/%d" ;;
    3) HD_PATH="$(ask "Enter full derivation path (e.g. m/44'/60'/0'/0/0):")"
       [ -n "$HD_PATH" ] || die "no path entered."
       info "reading address from Ledger…"
       SENDER="$(resolve_addr "$HD_PATH")" || { cat "$TMPDIR_"/led.err; die "could not read address from Ledger."; }
       return ;;
    *) die "no valid scheme selected." ;;
  esac
  info "reading the first 10 accounts from your Ledger…"
  local -a paths=() addrs=()
  for i in 0 1 2 3 4 5 6 7 8 9; do
    p="$(printf "$scheme" "$i")"
    a="$(resolve_addr "$p")" || { cat "$TMPDIR_"/led.err; die "could not read from Ledger (is the Ethereum app open?)."; }
    paths+=("$p"); addrs+=("$a")
    printf '     %s%d%s) %s%s   %s%s%s\n' "$BOLD" "$((i+1))" "$RST" "$a" "$(show_balance "$a")" "$DIM" "$p" "$RST"
  done
  sel="$(ask 'Which account? (1-10):')"
  case "$sel" in
    1|2|3|4|5|6|7|8|9|10) HD_PATH="${paths[$((sel-1))]}"; SENDER="${addrs[$((sel-1))]}" ;;
    *) die "no valid account selected." ;;
  esac
}

if [ -n "$SENDER_OVERRIDE" ]; then
  SENDER="$SENDER_OVERRIDE"
  if [ "$IS_DRYRUN" -eq 0 ] && [ -z "$HD_PATH" ]; then
    die "--sender needs --hd-path too: the Ledger signs by derivation path. Pass --hd-path as well, or omit --sender to choose interactively."
  fi
elif [ -n "$HD_PATH" ]; then
  info "reading address for $HD_PATH from Ledger… (unlock it, open the Ethereum app)"
  SENDER="$(resolve_addr "$HD_PATH")" || { cat "$TMPDIR_"/led.err; die "could not read address from Ledger."; }
elif [ "$IS_DRYRUN" -eq 1 ]; then
  if confirm "Dry run: connect your Ledger to simulate from your real account?"; then
    pick_from_ledger
  else
    SENDER="0x000000000000000000000000000000000000dEaD"
    info "simulating from placeholder sender $SENDER"
  fi
else
  pick_from_ledger
fi
kv "deployer" "$SENDER"
[ -n "${HD_PATH:-}" ] && kv "derivation path" "$HD_PATH"
if [ "$IS_DRYRUN" -eq 0 ]; then
  warn "confirm this address matches what your Ledger screen will show when signing."
fi

# --------------------------------------------------------------------------- #
# Step 7: cost preview                                                          #
# --------------------------------------------------------------------------- #
step "Cost preview"
if [ -n "${RPC_URL:-}" ]; then
  GAS_PRICE_WEI="$("$CAST" gas-price --rpc-url "$RPC_URL" 2>/dev/null || echo 0)"
  GAS_PRICE_GWEI="$("$CAST" from-wei "$GAS_PRICE_WEI" gwei 2>/dev/null || echo '?')"
  kv "current gas price" "${GAS_PRICE_GWEI} gwei"
  if [ "$SENDER" != "0x000000000000000000000000000000000000dEaD" ]; then
    BAL_ETH="$("$CAST" balance "$SENDER" --ether --rpc-url "$RPC_URL" 2>/dev/null || echo '?')"
    kv "deployer balance" "${BAL_ETH} ETH"
  fi
else
  info "no RPC, skipping live gas/balance (local dry run)."
fi

# --------------------------------------------------------------------------- #
# Step 8: simulation (always)                                                   #
# --------------------------------------------------------------------------- #
step "Simulation (dry run)"
SIM_ARGS=("$SCRIPT_TARGET" --sender "$SENDER")
[ -n "${RPC_URL:-}" ] && SIM_ARGS+=(--rpc-url "$RPC_URL")
info "simulating: forge script ${SIM_ARGS[*]}"
if "$FORGE" script "${SIM_ARGS[@]}" >"$TMPDIR_"/sim.log 2>&1; then
  ok "simulation succeeded"
else
  tail -40 "$TMPDIR_"/sim.log | sed 's/^/       /'
  die "simulation failed. Not proceeding."
fi
SIM_GAS="$(grep -oE 'Estimated total gas used for script: [0-9]+' "$TMPDIR_"/sim.log | grep -oE '[0-9]+' | head -1 || true)"
SIM_ADDR="$(grep -oE 'PNGEncoder deployed at: 0x[0-9a-fA-F]{40}' "$TMPDIR_"/sim.log | grep -oE '0x[0-9a-fA-F]{40}' | head -1 || true)"
[ -n "$SIM_GAS" ]  && kv "estimated gas" "$SIM_GAS"
[ -n "$SIM_ADDR" ] && kv "simulated address" "$SIM_ADDR  ${DIM}(will differ on-chain)${RST}"
if [ -n "${RPC_URL:-}" ] && [ -n "$SIM_GAS" ] && [ "${GAS_PRICE_WEI:-0}" != "0" ]; then
  COST_WEI="$(( SIM_GAS * GAS_PRICE_WEI ))"
  COST_ETH="$("$CAST" from-wei "$COST_WEI" ether 2>/dev/null || echo '?')"
  kv "estimated cost" "~${COST_ETH} ETH  ${DIM}(at current gas price)${RST}"
fi

if [ "$IS_DRYRUN" -eq 1 ]; then
  rule
  ok "${BOLD}Dry run complete.${RST} Nothing was sent. Re-run with --sepolia or --mainnet to deploy."
  exit 0
fi

# --------------------------------------------------------------------------- #
# Step 9: confirmation                                                          #
# --------------------------------------------------------------------------- #
step "Confirm deployment"
rule
kv "network"  "$NETWORK  (chain id $CHAIN_ID)"
kv "contract" "$CONTRACT  (+ $LIBRARY library, 2 transactions)"
kv "deployer" "$SENDER"
kv "commit"   "$GIT_COMMIT"
[ -n "${BAL_ETH:-}" ]  && kv "balance" "${BAL_ETH} ETH"
[ -n "${COST_ETH:-}" ] && kv "est. cost" "~${COST_ETH} ETH"
VERIFY_KEY="${ETHERSCAN_API_KEY:-}"
if [ "$DO_VERIFY" -eq 1 ] && [ -z "$VERIFY_KEY" ]; then
  warn "ETHERSCAN_API_KEY not set: source will NOT be auto-verified."
  DO_VERIFY=0
fi
[ "$DO_VERIFY" -eq 1 ] && kv "verify" "yes (Etherscan — publishes source)" || kv "verify" "no (source stays private; publish later with ./verify.sh)"
rule

if [ "$NETWORK" = "mainnet" ]; then
  # Mainnet always requires the typed confirmation. -y/--yes does not skip it,
  # so a flag in an unattended run cannot spend real ETH. The signature on the
  # Ledger device is the second check, but this check stays with --yes.
  printf '   %s%sThis will spend real ETH on Ethereum mainnet.%s\n' "$RED" "$BOLD" "$RST"
  [ "$(ask "Type the word ${BOLD}mainnet${RST} to proceed:")" = "mainnet" ] || die "confirmation not matched. Aborting."
  confirm "Final check: broadcast to MAINNET now?" || die "aborted."
elif [ "$ASSUME_YES" -ne 1 ]; then
  confirm "Broadcast to ${NETWORK} now?" || die "aborted."
fi

# --------------------------------------------------------------------------- #
# Step 10: broadcast                                                            #
# --------------------------------------------------------------------------- #
step "Broadcast"
BROADCAST_ARGS=("$SCRIPT_TARGET"
  --rpc-url "$RPC_URL"
  --sender "$SENDER"
  --ledger --mnemonic-derivation-paths "$HD_PATH"
  --broadcast --slow)
if [ "$DO_VERIFY" -eq 1 ]; then
  BROADCAST_ARGS+=(--verify --etherscan-api-key "$VERIFY_KEY" --chain "$CHAIN_ID")
fi
info "sending. ${BOLD}Confirm each of the 2 transactions on your Ledger${RST} (Deflate, then PNGEncoder)."
info "running: forge script ${SCRIPT_TARGET} --broadcast --ledger …"
rule
if "$FORGE" script "${BROADCAST_ARGS[@]}" 2>&1 | tee "$TMPDIR_"/broadcast.log; then
  rule
  ok "broadcast finished"
else
  rule
  die "broadcast failed. See output above. Nothing was recorded; you can re-run (forge --resume may help if some txs landed)."
fi

# --------------------------------------------------------------------------- #
# Step 11: post-deploy checks & record                                          #
# --------------------------------------------------------------------------- #
step "Verify & record"
RUN_JSON="broadcast/Deploy.s.sol/${CHAIN_ID}/run-latest.json"
[ -f "$RUN_JSON" ] || die "could not find broadcast record at $RUN_JSON"

read -r ENC_ADDR LIB_ADDR ENC_TX LIB_TX < <("$JSON" - "$RUN_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
enc = lib = enc_tx = lib_tx = "-"
txs = d.get("transactions", [])
rcs = {r.get("transactionHash"): r for r in d.get("receipts", [])}
for t in txs:
    name = t.get("contractName"); addr = t.get("contractAddress"); h = t.get("hash")
    if name == "PNGEncoder": enc, enc_tx = addr, h
    elif name == "Deflate":  lib, lib_tx = addr, h
print(enc, lib, enc_tx, lib_tx)
PY
)

[ -n "$ENC_ADDR" ] && [ "$ENC_ADDR" != "-" ] || die "could not parse the PNGEncoder address from the broadcast record."
kv "$CONTRACT" "$ENC_ADDR"
kv "$LIBRARY"  "$LIB_ADDR"

# On-chain check: the deployed address must contain code.
ONCHAIN_CODE="$("$CAST" code "$ENC_ADDR" --rpc-url "$RPC_URL" 2>/dev/null || echo 0x)"
if [ "$ONCHAIN_CODE" = "0x" ] || [ -z "$ONCHAIN_CODE" ]; then
  die "no code found at $ENC_ADDR on-chain: deployment did not stick."
fi
ok "on-chain code present at $ENC_ADDR ($(( (${#ONCHAIN_CODE} - 2) / 2 )) bytes)"

mkdir -p deployments
RECORD="deployments/${NETWORK}.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
"$JSON" - "$RECORD" "$NETWORK" "$CHAIN_ID" "$GIT_COMMIT" "$SENDER" "${HD_PATH:-}" "$TS" "$ENC_ADDR" "$LIB_ADDR" "$ENC_TX" "$LIB_TX" <<'PY'
import json, sys
(_, out, network, chain, commit, deployer, hdpath, ts, enc, lib, enc_tx, lib_tx) = sys.argv
json.dump({
    "network": network, "chainId": int(chain), "commit": commit,
    "deployer": deployer, "derivationPath": hdpath, "timestamp": ts,
    "PNGEncoder": enc, "Deflate": lib,
    "txHashes": {"PNGEncoder": enc_tx, "Deflate": lib_tx},
}, open(out, "w"), indent=2)
open(out, "a").write("\n")
PY
ok "recorded to $RECORD"

step "Done"
rule
ok "${BOLD}${CONTRACT} deployed to ${NETWORK}${RST}"
kv "address" "$ENC_ADDR"
[ -n "$EXPLORER" ] && kv "explorer" "${EXPLORER}/address/${ENC_ADDR}"
if [ "$DO_VERIFY" -eq 1 ]; then
  info "Etherscan source verification was requested; confirm the ✓ in the broadcast output above."
else
  info "Source was ${BOLD}not published${RST} (verification is opt-in). Publish whenever you're ready:"
  info "    ${BOLD}./verify.sh ${NETWORK}${RST}   ${DIM}(or  .\\verify.ps1 ${NETWORK}  on PowerShell)${RST}"
fi
rule
