#!/bin/zsh
# Starts PrettyAFM. Run ./scripts/install.sh first; this script only builds and launches.
set -euo pipefail
cd "$(dirname "$0")/.."

ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/version >/dev/null; }

if ! ollama_up; then
  if [[ -d /Applications/Ollama.app ]]; then
    echo "Starting Ollama…"; open -ga /Applications/Ollama.app
  elif command -v ollama >/dev/null; then
    (ollama serve >/dev/null 2>&1 &)
  else
    echo "Ollama isn't installed. Run ./scripts/install.sh first." >&2; exit 1
  fi
  for _ in {1..30}; do ollama_up && break; sleep 1; done
  ollama_up || { echo "Ollama didn't start. Open the Ollama app and try again." >&2; exit 1; }
fi

swift build -c release 2>&1 | grep -E "error:|Build complete" || true
[[ -x .build/release/PrettyAFM ]] || { echo "Build failed. Run ./scripts/install.sh for diagnostics." >&2; exit 1; }
exec .build/release/PrettyAFM --open "$@"
