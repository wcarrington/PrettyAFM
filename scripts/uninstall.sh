#!/bin/bash
# Removes what PrettyAFM added. Asks before each step; nothing outside this list is touched.
#
#   ./scripts/uninstall.sh                 interactive
#   ./scripts/uninstall.sh --remove-ollama also offer to remove Ollama.app and ALL its models
#
# Kept unless you choose otherwise: Ollama itself, models PrettyAFM didn't download, this source folder.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$HOME/Library/Application Support/PrettyAFM"
LOGS="$HOME/Library/Logs/PrettyAFM"
REMOVE_OLLAMA=0
[ "${1:-}" = "--remove-ollama" ] && REMOVE_OLLAMA=1

[ "$(id -u)" -eq 0 ] && { echo "Don't run this as root."; exit 1; }
[ -t 0 ] || { echo "Run this from a terminal; it asks before deleting anything."; exit 1; }

ask() { local r; read -r -p "$1 [y/N] " r; [[ "$r" =~ ^[Yy]$ ]]; }
OLLAMA="$(command -v ollama || echo /Applications/Ollama.app/Contents/Resources/ollama)"

# Stop a running PrettyAFM server first.
pkill -f "$ROOT/.build/.*/PrettyAFM" 2>/dev/null && echo "Stopped PrettyAFM." || true

# The Qwen model this Mac uses (asked from the app, so it matches what was installed).
if [ -x "$ROOT/.build/release/PrettyAFM" ] && [ -x "$OLLAMA" ]; then
  MODEL="$("$ROOT/.build/release/PrettyAFM" --print-config | plutil -extract qwen.model raw -o - - 2>/dev/null || true)"
  if [ -n "$MODEL" ] && "$OLLAMA" show "$MODEL" >/dev/null 2>&1; then
    ask "Remove the $MODEL model from Ollama?" && "$OLLAMA" rm "$MODEL"
  fi
fi

if [ -d "$DATA" ]; then
  echo "Saved PDF text and summaries: $(du -sh "$DATA" | cut -f1) in $DATA"
  ask "Delete them?" && rm -rf "$DATA"
fi

[ -d "$LOGS" ] && ask "Delete install logs in $LOGS?" && rm -rf "$LOGS"
[ -d "$ROOT/.build" ] && ask "Delete build output ($(du -sh "$ROOT/.build" | cut -f1))?" && rm -rf "$ROOT/.build"

if [ "$REMOVE_OLLAMA" = 1 ] && [ -d /Applications/Ollama.app ]; then
  echo
  echo "Removing Ollama also deletes ALL its downloaded models (~/.ollama), including ones other apps use:"
  du -sh "$HOME/.ollama" 2>/dev/null || true
  if ask "Remove Ollama.app and ~/.ollama?"; then
    osascript -e 'quit app "Ollama"' 2>/dev/null || true
    sleep 2
    rm -rf /Applications/Ollama.app "$HOME/.ollama"
    [ -L /usr/local/bin/ollama ] && echo "Note: /usr/local/bin/ollama is a leftover link. Remove it with: sudo rm /usr/local/bin/ollama"
  fi
fi

echo "Done. Browser history for PrettyAFM (saved chats) can be cleared from your browser's site data for localhost:8642."
