#!/bin/bash
# PrettyAFM installer: checks this Mac, installs what's missing, and verifies the result.
#
#   ./scripts/install.sh            interactive (asks before downloading or installing anything)
#   ./scripts/install.sh --dry-run  check everything and show the plan; change nothing
#   ./scripts/install.sh --yes      unattended; still stops on any failed safety check
#
# Safety rules this script follows:
#   • Never runs as root and never calls sudo.
#   • Installs Ollama only from ollama.com, and only after verifying its code signature,
#     its Team ID and Apple notarization.
#   • Never changes system settings. It reports problems and opens the right settings page.
#   • Checks free disk space before any large download and keeps a reserve free.
#   • Safe to re-run: every step checks first and skips work that's already done.

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
MIN_MACOS=26
MIN_SWIFT="6.2"
TESTED_OLLAMA="0.40.0"            # oldest Ollama this project has been tested with
OLLAMA_TEAM_ID="3MU9H2V9Y9"       # Developer ID: Infra Technologies, Inc (Ollama)
OLLAMA_URL="https://ollama.com/download/Ollama-darwin.zip"
OLLAMA_APP="/Applications/Ollama.app"
DISK_RESERVE_GB="${PRETTYAFM_DISK_RESERVE_GB:-10}"   # free space to leave after downloads
UNKNOWN_MODEL_GB=20               # assumed size when LI_QWEN_MODEL names a custom model

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$HOME/Library/Logs/PrettyAFM"
LOG="$LOG_DIR/install.log"

DRY_RUN=0; ASSUME_YES=0; SKIP_MODEL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --skip-model) SKIP_MODEL=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ── Output helpers ───────────────────────────────────────────────────────────
# Decide on color before stdout is redirected into the log.
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'; else B=; G=; Y=; R=; D=; N=; fi
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1
echo; echo "──── PrettyAFM install $(date '+%Y-%m-%d %H:%M:%S') ────"
ok()    { echo "  ${G}✓${N} $*"; }
warn()  { echo "  ${Y}!${N} $*"; WARNINGS=$((WARNINGS + 1)); }
fail()  { echo; echo "  ${R}✗ $*${N}"; echo "  ${D}Log: $LOG${N}"; exit 1; }
step()  { echo; echo "${B}$*${N}"; }
WARNINGS=0
PLAN=()   # actions that need confirmation

TMP="$(mktemp -d -t prettyafm-install)"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

version_ge() {  # version_ge 6.2.1 6.2  → true
  local IFS=.; local i a=($1) b=($2)
  for ((i = 0; i < ${#b[@]} || i < ${#a[@]}; i++)); do
    local x=${a[i]:-0} y=${b[i]:-0}
    ((10#${x%%[!0-9]*} > 10#${y%%[!0-9]*})) && return 0
    ((10#${x%%[!0-9]*} < 10#${y%%[!0-9]*})) && return 1
  done
  return 0
}

json() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }   # json <file> <key.path>

free_gb() { df -g "$HOME" | awk 'NR==2 { print $4 }'; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ ! -t 0 ]; then fail "No terminal available to confirm. Re-run with --yes to approve the plan above."; fi
  local reply; read -r -p "  $1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

ollama_bin() {
  if command -v ollama >/dev/null 2>&1; then command -v ollama
  elif [ -x "$OLLAMA_APP/Contents/Resources/ollama" ]; then echo "$OLLAMA_APP/Contents/Resources/ollama"
  fi
}

ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/version >/dev/null; }

# ── 1. This Mac ──────────────────────────────────────────────────────────────
step "1. Checking this Mac"

[ "$(id -u)" -eq 0 ] && fail "Don't run this as root or with sudo. Run it as your normal user."
ok "Running as $(id -un), not root"

[ "$(uname -m)" = "arm64" ] || fail "PrettyAFM needs an Apple silicon Mac (M1 or later). This Mac is $(uname -m)."
ok "Apple silicon ($(sysctl -n machdep.cpu.brand_string))"

MACOS="$(sw_vers -productVersion)"
version_ge "$MACOS" "$MIN_MACOS" || fail "macOS $MIN_MACOS or later is required for Apple's Foundation Models. This Mac has macOS $MACOS."
ok "macOS $MACOS"

MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
if [ "$MEM_GB" -lt 16 ]; then
  warn "${MEM_GB} GB of memory. PrettyAFM is designed for 16 GB or more; Qwen may be slow or fail to load."
else
  ok "${MEM_GB} GB unified memory"
fi

FREE=$(free_gb)
ok "${FREE} GB free disk space"

# ── 2. Swift toolchain ───────────────────────────────────────────────────────
step "2. Checking the Swift toolchain"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "  Xcode or the Command Line Tools are needed to build PrettyAFM."
  if [ "$DRY_RUN" = 1 ]; then
    PLAN+=("Install the Xcode Command Line Tools (opens Apple's installer)")
  elif confirm "Open Apple's installer for the Command Line Tools now?"; then
    xcode-select --install || true
    fail "Finish the Command Line Tools installation in the window that opened, then run this script again."
  else
    fail "Install Xcode from the App Store, or run: xcode-select --install"
  fi
else
  SWIFT_VERSION="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9.]+).*/\1/p' | head -1)"
  [ -n "$SWIFT_VERSION" ] || fail "Couldn't run swift. If Xcode was just installed, open it once to accept the license."
  version_ge "$SWIFT_VERSION" "$MIN_SWIFT" || fail "Swift $MIN_SWIFT or later is needed (found $SWIFT_VERSION). Update Xcode or the Command Line Tools."
  ok "Swift $SWIFT_VERSION ($(xcode-select -p))"

  echo 'import FoundationModels' > "$TMP/check.swift"
  if ! swiftc -typecheck "$TMP/check.swift" >"$TMP/check.log" 2>&1; then
    if grep -qi license "$TMP/check.log"; then
      fail "Xcode's license hasn't been accepted. Open Xcode once, or run: sudo xcodebuild -license accept"
    fi
    fail "This toolchain's SDK doesn't include FoundationModels. Install Xcode 26 or later."
  fi
  ok "FoundationModels SDK available"
fi

# ── 3. Ollama ────────────────────────────────────────────────────────────────
step "3. Checking Ollama"

OLLAMA="$(ollama_bin)"
NEED_OLLAMA=0
if [ -z "$OLLAMA" ]; then
  NEED_OLLAMA=1
  PLAN+=("Download Ollama from ollama.com (~230 MB), verify its signature, and install it in /Applications")
  echo "  Ollama isn't installed."
else
  OLLAMA_VERSION="$("$OLLAMA" --version 2>/dev/null | sed -nE 's/.*version is ([0-9.]+).*/\1/p' | head -1)"
  if [ -n "$OLLAMA_VERSION" ] && ! version_ge "$OLLAMA_VERSION" "$TESTED_OLLAMA"; then
    warn "Ollama $OLLAMA_VERSION is older than $TESTED_OLLAMA. Update it from the Ollama menu bar icon if the model download fails."
  else
    ok "Ollama ${OLLAMA_VERSION:-installed} ($OLLAMA)"
  fi
  if [ -d "$OLLAMA_APP" ]; then
    TEAM="$(codesign -dv "$OLLAMA_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    if [ "$TEAM" = "$OLLAMA_TEAM_ID" ]; then ok "Ollama.app is signed by Ollama (Team ID $TEAM)"
    else warn "Ollama.app's signature is unexpected (Team ID '${TEAM:-none}'). Consider reinstalling it from ollama.com."; fi
  fi
fi

# Privacy: PrettyAFM promises nothing leaves the Mac. Ollama must not be reachable from the network.
OLLAMA_HOST_SETTING="${OLLAMA_HOST:-$(launchctl getenv OLLAMA_HOST 2>/dev/null || true)}"
if lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 { print $9 }' | grep -qvE '^(127\.0\.0\.1|\[::1\]):11434$'; then
  warn "Ollama is listening on a network interface, not just this Mac. Other devices on your network could use it.
      To fix: remove OLLAMA_HOST from your environment (launchctl unsetenv OLLAMA_HOST) and restart Ollama."
elif [[ "$OLLAMA_HOST_SETTING" == 0.0.0.0* || "$OLLAMA_HOST_SETTING" == "::"* ]]; then
  warn "OLLAMA_HOST is set to $OLLAMA_HOST_SETTING, which exposes Ollama to your network the next time it starts."
elif [ "$NEED_OLLAMA" = 0 ]; then
  ok "Ollama is only reachable from this Mac"
fi

# ── 4. Build PrettyAFM ───────────────────────────────────────────────────────
step "4. Building PrettyAFM"

if [ "$DRY_RUN" = 1 ] && [ ! -x "$ROOT/.build/release/PrettyAFM" ]; then
  PLAN+=("Build PrettyAFM (swift build -c release)")
  echo "  Not built yet; will build."
  CONFIG_BIN="$ROOT/.build/debug/PrettyAFM"
  [ -x "$CONFIG_BIN" ] || CONFIG_BIN=""
else
  if [ "$DRY_RUN" = 0 ]; then
    echo "  Compiling (first build takes a minute)…"
    if ! (cd "$ROOT" && swift build -c release > "$TMP/build.log" 2>&1); then
      cat "$TMP/build.log"
      grep -qi license "$TMP/build.log" && fail "Xcode's license hasn't been accepted. Open Xcode once, or run: sudo xcodebuild -license accept"
      fail "Build failed (output above)."
    fi
    [ -x "$ROOT/.build/release/PrettyAFM" ] || fail "Build didn't produce .build/release/PrettyAFM. See $LOG."
  fi
  CONFIG_BIN="$ROOT/.build/release/PrettyAFM"
  ok "Built $CONFIG_BIN"
fi

# ── 5. Apple Intelligence + model choice (from the app itself) ──────────────
step "5. Checking Apple Intelligence and choosing the Qwen model"

MODEL=""; MODEL_GB=""
if [ -n "${CONFIG_BIN:-}" ]; then
  "$CONFIG_BIN" --print-config > "$TMP/config.json" || fail "PrettyAFM --print-config failed."
  MODEL="$(json "$TMP/config.json" qwen.model)"
  MODEL_GB="$(json "$TMP/config.json" qwen.downloadGB)"
  APPLE_OK="$(json "$TMP/config.json" apple.available)"
  APPLE_CODE="$(json "$TMP/config.json" apple.code)"
  if [ "$APPLE_OK" = "true" ]; then
    ok "Apple Intelligence is on; the on-device model is ready"
  else
    case "$APPLE_CODE" in
      appleIntelligenceNotEnabled)
        warn "Apple Intelligence is turned off. PrettyAFM will use Qwen for everything until you turn it on."
        echo "      Opening System Settings → Apple Intelligence & Siri…"
        [ "$DRY_RUN" = 0 ] && { open "x-apple.systempreferences:com.apple.Siri-Settings.extension" 2>/dev/null || open -b com.apple.systempreferences; } ;;
      modelNotReady)
        warn "Apple's on-device model is still downloading. It'll be used automatically once ready." ;;
      deviceNotEligible)
        warn "This Mac doesn't support Apple Intelligence. PrettyAFM will use Qwen for everything." ;;
      *) warn "Apple's on-device model is unavailable: $(json "$TMP/config.json" apple.reason)" ;;
    esac
  fi
  ok "This ${MEM_GB} GB Mac will use $(json "$TMP/config.json" qwen.displayName) ($MODEL)"
else
  echo "  (Model choice is shown after the first build.)"
fi

NEED_MODEL=0
if [ "$SKIP_MODEL" = 1 ]; then
  echo "  Skipping the model download (--skip-model)."
elif [ -n "$MODEL" ]; then
  if [ -n "$OLLAMA" ] && ollama_up && "$OLLAMA" show "$MODEL" >/dev/null 2>&1; then
    ok "$MODEL is already downloaded"
  else
    NEED_MODEL=1
    SIZE="${MODEL_GB:-$UNKNOWN_MODEL_GB}"
    SIZE_INT=$(printf '%.0f' "$SIZE")
    NEEDED=$((SIZE_INT + DISK_RESERVE_GB))
    if [ "$FREE" -lt "$NEEDED" ]; then
      fail "Not enough disk space for $MODEL: it's about ${SIZE_INT} GB, and ${DISK_RESERVE_GB} GB should stay free for macOS.
    Free up at least $((NEEDED - FREE)) GB, then run this again. (Use --skip-model to install everything else.)"
    fi
    PLAN+=("Download $MODEL with Ollama (~$(printf '%.1f' "$SIZE") GB; ${FREE} GB free)")
  fi
fi

# ── Plan + confirmation ─────────────────────────────────────────────────────
step "Plan"
if [ ${#PLAN[@]} -eq 0 ]; then
  ok "Nothing to install."
else
  for p in "${PLAN[@]}"; do echo "  • $p"; done
  if [ "$DRY_RUN" = 1 ]; then
    echo; echo "Dry run: nothing was changed."; exit 0
  fi
  echo
  confirm "Go ahead?" || { echo "  Cancelled. Nothing was changed."; exit 1; }
fi
[ "$DRY_RUN" = 1 ] && { echo; echo "Dry run: nothing was changed."; exit 0; }

# ── 6. Install Ollama (verified) ─────────────────────────────────────────────
if [ "$NEED_OLLAMA" = 1 ]; then
  step "6. Installing Ollama"
  [ -w /Applications ] || fail "Can't write to /Applications with this account. Install Ollama from https://ollama.com/download, then re-run."
  echo "  Downloading $OLLAMA_URL"
  curl -fL --proto '=https' --tlsv1.2 --retry 3 --progress-bar -o "$TMP/Ollama.zip" "$OLLAMA_URL" || fail "Download failed."
  ditto -x -k "$TMP/Ollama.zip" "$TMP/unzipped" || fail "Couldn't unpack the Ollama download."
  APP="$TMP/unzipped/Ollama.app"
  [ -d "$APP" ] || fail "The download didn't contain Ollama.app."

  codesign --verify --deep --strict "$APP" 2>/dev/null || fail "Ollama.app's code signature is invalid. Not installing it."
  TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [ "$TEAM" = "$OLLAMA_TEAM_ID" ] || fail "Ollama.app is signed by an unexpected developer (Team ID '${TEAM:-none}', expected $OLLAMA_TEAM_ID). Not installing it."
  spctl --assess --type execute "$APP" 2>/dev/null || fail "Gatekeeper rejected Ollama.app (not notarized). Not installing it."
  ok "Signature, Team ID ($TEAM) and notarization verified"

  ditto "$APP" "$OLLAMA_APP" || fail "Couldn't copy Ollama.app to /Applications."
  ok "Installed $OLLAMA_APP"
  OLLAMA="$OLLAMA_APP/Contents/Resources/ollama"
fi

# ── 7. Start Ollama ──────────────────────────────────────────────────────────
if [ "$NEED_MODEL" = 1 ] || ! ollama_up; then
  step "7. Starting Ollama"
  if ! ollama_up; then
    if [ -d "$OLLAMA_APP" ]; then open -ga "$OLLAMA_APP"; else ("$OLLAMA" serve >/dev/null 2>&1 &); fi
    for _ in $(seq 1 30); do ollama_up && break; sleep 1; done
  fi
  ollama_up || fail "Ollama didn't start. Open the Ollama app, then run this again."
  ok "Ollama is running"
fi

# ── 8. Download the model ────────────────────────────────────────────────────
if [ "$NEED_MODEL" = 1 ]; then
  step "8. Downloading $MODEL"
  # Re-check space right before downloading, in case it changed.
  NOW_FREE=$(free_gb)
  [ "$NOW_FREE" -ge "$NEEDED" ] || fail "Free disk space dropped to ${NOW_FREE} GB. Free up space and run this again."
  "$OLLAMA" pull "$MODEL" || fail "Downloading $MODEL failed. If Ollama says it needs updating, update it and run this again."
  ok "$MODEL downloaded (Ollama verified its checksums)"
fi

# ── 9. Smoke test ────────────────────────────────────────────────────────────
step "9. Verifying"
PORT=$((20000 + RANDOM % 20000))
"$ROOT/.build/release/PrettyAFM" --port "$PORT" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null || true   # no "Terminated" job message when we stop it
for _ in $(seq 1 20); do curl -sf --max-time 1 "http://127.0.0.1:$PORT/api/status" -o "$TMP/status.json" && break; sleep 0.5; done
[ -s "$TMP/status.json" ] || fail "PrettyAFM didn't start. Server output:
$(cat "$TMP/server.log")"
[ "$(json "$TMP/status.json" qwen.installed)" = "true" ] || [ "$SKIP_MODEL" = 1 ] || fail "PrettyAFM can't see $MODEL in Ollama."
ok "PrettyAFM starts and sees $( [ "$(json "$TMP/status.json" apple.available)" = "true" ] && echo "both models" || echo "Qwen only" )"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 { print $9 }' | grep -qv "^127.0.0.1:$PORT$"; then
  fail "PrettyAFM is listening beyond this Mac. This shouldn't happen; please report it."
fi
ok "PrettyAFM listens only on 127.0.0.1"
kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""

# ── Done ─────────────────────────────────────────────────────────────────────
echo
if [ "$WARNINGS" -gt 0 ]; then echo "${B}Installed, with $WARNINGS warning(s) above.${N}"; else echo "${B}${G}All set.${N}"; fi
echo "  Start PrettyAFM:  ./scripts/start.sh"
echo "  Log:              $LOG"
