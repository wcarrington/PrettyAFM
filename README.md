# PrettyAFM

A web chat app in the style of Apple's website that runs entirely on your Mac. Each message goes to the local model best suited to it:

- **Apple Foundation Model** (the on-device model built into macOS): summarizing, rewriting, extraction, tagging, short creative writing and conversation. It answers in well under a second.
- **Qwen via Ollama**: code, math, reasoning, factual knowledge, long documents and images.

Nothing leaves your Mac. The server listens on `127.0.0.1` only.

## Requirements

- Apple silicon Mac with 16 GB or more, macOS 26 or later, and Apple Intelligence turned on
- Xcode 26+ (or the Swift 6.2+ toolchain)
- [Ollama](https://ollama.com/download)

## Run

```sh
./scripts/start.sh            # release build, opens http://localhost:8642
# or, during development:
swift run PrettyAFM --open
```

If the Qwen model isn't downloaded yet, click **Download** in the app's **Models** section, or run `ollama pull <tag>` yourself.

## Which Qwen model is used

Qwen 3.8 is only published as a 27B model (18 GB or more), so it can't run on 16 GB Macs. PrettyAFM checks your Mac's memory at startup:

| Unified memory | Model | Ollama tag | Download | Context |
|---|---|---|---|---|
| 16–24 GB | Qwen 3.5 9B (4-bit) | `qwen3.5:9b-q4_K_M` | 6.6 GB | 16K |
| 32–48 GB | Qwen 3.8 27B (4-bit) | `qwen3.8:27b-q4_K_M` | 18 GB | 32K |
| 64 GB+ | Qwen 3.8 27B (8-bit) | `qwen3.8:27b-q8_0` | 30 GB | 64K |

## How routing works

The router lives in `Sources/PrettyAFM/Router.swift`. It applies these checks in order:

1. **Manual override.** The Auto / Apple / Qwen control in the chat toolbar.
2. **Rules.** Images, Think mode, code, math, and conversations over ~70% of Apple's 8K-token window go to Qwen. Greetings go to Apple.
3. **Follow-ups.** Messages of 8 words or fewer stay with the model that gave the previous answer.
4. **On-device triage.** Apple's model sorts the request into one of 15 categories using guided generation (`@Generable`). Each category maps to a backend. A pre-warmed session keeps this under a second.
5. **Fallback.** If Apple's model exceeds its context window, trips a safety guardrail, or doesn't support the language, Qwen answers instead and the UI shows a note saying so.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `LI_PORT` / `--port` | `8642` | HTTP port |
| `LI_QWEN_MODEL` | by memory | Use a different Ollama model tag |
| `LI_QWEN_CTX` | by memory | Qwen context length (`num_ctx`) |
| `LI_APPLE_BUDGET` | `0.7` | Share of Apple's context window a conversation may use before it goes to Qwen |
| `OLLAMA_HOST_URL` | `http://127.0.0.1:11434` | Ollama address |

## Layout

```
Sources/PrettyAFM/
  main.swift        API routes: /api/status, /api/chat (NDJSON stream), /api/pull
  HTTPServer.swift  Minimal Network.framework HTTP server (loopback only)
  Router.swift      Routing rules and on-device triage
  AppleModel.swift  FoundationModels session, streaming, fallback errors
  Ollama.swift      Ollama chat and pull streaming
  Models.swift      Shared types and the memory-based Qwen choice
Public/             Web UI (plain HTML/CSS/JS, no build step, no CDN)
```
