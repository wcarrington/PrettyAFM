# PrettyAFM

A web chat app in the style of Apple's website that runs entirely on your Mac. Each message goes to the local model best suited to it:

- **Apple Foundation Model** (the on-device model built into macOS): summarizing, rewriting, extraction, tagging, short creative writing and conversation. It answers in well under a second.
- **Qwen via Ollama**: code, math, reasoning, factual knowledge, long documents and images.

You can attach PDFs by clicking the paperclip, dragging them onto the chat, or pasting them.

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

## PDFs

PDFKit extracts text page by page. Pages with no text layer, such as scans, are OCR'd on device with the Vision framework. How a PDF reaches the model depends on its size:

| Situation | What the model sees | Usually answered by |
|---|---|---|
| Fits the model's context window | The whole text, with `[Page N]` markers | Apple for short PDFs, otherwise Qwen |
| Too long, and you ask for a summary | Apple's model summarizes the PDF in ~2,800-token sections, combining them further if needed, then answers from the summaries | Apple |
| Too long, any other question | The opening plus the most relevant ~450-token passages, ranked by BM25 | Whichever model fits the selected passages |

Answers cite pages like "(p. 37)". A note under each answer says which pages were used.

Extracted text and section summaries are saved in `~/Library/Application Support/PrettyAFM/documents/`, keyed by the file's SHA-256 hash. Re-attaching the same file is instant, a second summary of the same PDF skips the section step, and conversations keep working after a server restart. Delete that folder to clear them.

Measured on a 16 GB M2 Pro with a 60-page, ~31K-token PDF:
- a fact-finding question took about 5 s;
- the first full summary took about 100 s (12 sections);
- repeat summaries took about 14 s.

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
  main.swift        API routes: /api/status, /api/chat (NDJSON stream), /api/pull, /api/documents
  HTTPServer.swift  Minimal Network.framework HTTP server (loopback only)
  Router.swift      Routing rules and on-device triage
  AppleModel.swift  FoundationModels session, streaming, fallback errors
  Ollama.swift      Ollama chat and pull streaming
  Documents.swift   PDF text extraction, Vision OCR, document storage
  DocumentContext.swift  Full text vs. section summaries vs. relevant passages for attached PDFs
  Models.swift      Shared types and the memory-based Qwen choice
Public/             Web UI (plain HTML/CSS/JS, no build step, no CDN)
```
