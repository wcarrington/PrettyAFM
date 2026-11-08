#!/bin/zsh
# Builds (release) and starts PrettyAFM, pulling the right Qwen model on first run.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v ollama >/dev/null; then
  echo "Ollama is required: https://ollama.com/download" >&2; exit 1
fi
if ! curl -sf http://127.0.0.1:11434/api/tags >/dev/null; then
  echo "Starting Ollama…"; (ollama serve >/dev/null 2>&1 &); sleep 2
fi

swift build -c release
exec .build/release/PrettyAFM --open "$@"
