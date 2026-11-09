import Foundation

// MARK: Configuration

let args = CommandLine.arguments
func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let port = UInt16(argValue("--port") ?? ProcessInfo.processInfo.environment["LI_PORT"] ?? "8642") ?? 8642
let profile = QwenProfile.forThisMac()

// `PrettyAFM --print-config` reports what this Mac will use, without starting the server.
// The installer reads it so it downloads exactly the model the app expects.
if args.contains("--print-config") {
    var qwen: [String: Any] = ["model": profile.model, "displayName": profile.displayName, "contextTokens": profile.contextTokens]
    if let gb = profile.downloadGB { qwen["downloadGB"] = gb }
    var apple = AppleModel.status()
    if case .unavailable(let reason) = AppleModel.model.availability {
        apple["code"] = switch reason {
        case .deviceNotEligible: "deviceNotEligible"
        case .appleIntelligenceNotEnabled: "appleIntelligenceNotEnabled"
        case .modelNotReady: "modelNotReady"
        @unknown default: "unknown"
        }
    }
    let config: [String: Any] = ["memoryGB": profile.memoryGB, "qwen": qwen, "apple": apple]
    let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

let publicDir: URL = {
    if let p = argValue("--public") ?? ProcessInfo.processInfo.environment["LI_PUBLIC"] { return URL(fileURLWithPath: p) }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Public")
    if FileManager.default.fileExists(atPath: cwd.path) { return cwd }
    // Fall back to <repo>/Public relative to .build/<config>/PrettyAFM
    return URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Public")
}()

// MARK: Handlers

/// First name for the greeting ("Hello, Will"). LI_USER_NAME overrides; empty disables it.
let userFirstName: String = {
    if let n = ProcessInfo.processInfo.environment["LI_USER_NAME"] { return n }
    return NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
}()

func statusJSON() async -> [String: Any] {
    let installed = await Ollama.installedModels()
    let normalize: (String) -> String = { $0.hasSuffix(":latest") ? String($0.dropLast(7)) : $0 }
    let isInstalled = installed?.map(normalize).contains(normalize(profile.model)) ?? false
    return [
        "apple": AppleModel.status(),
        "qwen": [
            "model": profile.model,
            "displayName": profile.displayName,
            "contextTokens": profile.contextTokens,
            "note": profile.note,
            "ollamaRunning": installed != nil,
            "installed": isInstalled,
        ] as [String: Any],
        "memoryGB": profile.memoryGB,
        "userName": userFirstName,
    ]
}

func handleChat(_ req: HTTPRequest, _ conn: HTTPConnection) async {
    guard let body = req.json(),
          let raw = body["messages"] as? [[String: Any]] else {
        return await conn.respondJSON(["error": "Expected {messages: [...]}"], status: 400)
    }
    let messages = raw.compactMap(ChatMessage.init)
    guard messages.last?.role == "user" else {
        return await conn.respondJSON(["error": "The last message must be from the user."], status: 400)
    }
    let mode = body["mode"] as? String ?? "auto"
    // Accuracy: "fast" (no extra passes), "checked" (default: double-check answers about PDFs), "deep" (+ Qwen thinking).
    let accuracy = ["fast", "checked", "deep"].contains(body["accuracy"] as? String ?? "") ? body["accuracy"] as! String : "checked"
    let think = accuracy == "deep" || (body["think"] as? Bool ?? false)

    do {
        try await conn.beginStream()

        // Attach PDF text (full, relevant passages, or on-device section summaries) to the latest user turn.
        let prepared = try await DocumentContext.prepare(messages: messages, mode: mode, profile: profile) {
            try await conn.emit($0)
        }
        let messages = prepared.messages
        let last = messages[messages.count - 1]

        let started = Date()
        let decision = await Router.decide(messages: messages, mode: mode, think: think)
        var route = decision.json
        route["model"] = decision.backend == .apple ? "Apple Foundation Model" : profile.displayName
        route["routingMs"] = Int(Date().timeIntervalSince(started) * 1000)
        try await conn.emit(["type": "route"].merging(route) { a, _ in a })

        // ── Draft ──
        var answer = ""
        var drafter = decision.backend
        var done: [String: Any] = [:]
        let t0 = Date()

        func runQwen() async throws {
            drafter = .qwen
            let stats = try await Ollama.chat(
                profile: profile, messages: messages, think: think,
                onThinking: { try await conn.emit(["type": "thinking", "text": $0]) },
                onDelta: { answer += $0; try await conn.emit(["type": "delta", "text": $0]) })
            done = ["backend": "qwen", "outputTokens": stats.outputTokens,
                    "tokensPerSecond": (stats.tokensPerSecond * 10).rounded() / 10]
        }

        if decision.backend == .apple {
            do {
                let tokens = try await AppleModel.stream(history: Array(messages.dropLast()), prompt: last.fullContent) { text, replace in
                    answer = replace ? text : answer + text
                    try await conn.emit(["type": replace ? "replace" : "delta", "text": text])
                }
                let secs = Date().timeIntervalSince(t0)
                done = ["backend": "apple", "outputTokens": tokens,
                        "tokensPerSecond": secs > 0 ? (Double(tokens) / secs * 10).rounded() / 10 : 0]
            } catch {
                guard mode != "apple", let why = AppleModel.shouldFallBack(error) else { throw error }
                try await conn.emit(["type": "reroute", "backend": "qwen", "model": profile.displayName,
                                     "reason": why + " Qwen answered instead."])
                answer = ""
                try await runQwen()
            }
        } else {
            try await runQwen()
        }
        done["seconds"] = (Date().timeIntervalSince(t0) * 10).rounded() / 10

        // ── Double-check (answers grounded in PDFs) ──
        // Summaries are paraphrases, so they can't be checked quote-for-quote; skip that strategy.
        if accuracy != "fast", !prepared.docs.isEmpty, prepared.strategy != "summary", !answer.isEmpty {
            let v0 = Date()
            let review = try await Verifier.review(
                answer: answer, question: last.content, prepared: prepared, drafter: drafter, profile: profile,
                status: { try await conn.emit(["type": "status", "text": $0]) },
                onRevisionStart: { try await conn.emit(["type": "replace", "text": ""]) },
                onRevisionDelta: { try await conn.emit(["type": "delta", "text": $0]) })
            if let review {
                if let revised = review.revisedText { answer = revised }
                var r = review.json
                r["seconds"] = (Date().timeIntervalSince(v0) * 10).rounded() / 10
                try await conn.emit(["type": "review"].merging(r) { a, _ in a })
            }
        }

        // ── Citation check (always, deterministic) ──
        if !prepared.docs.isEmpty {
            let fixed = CitationCheck.check(answer, docs: prepared.docs)
            if fixed.changed {
                answer = fixed.text
                try await conn.emit(["type": "replace", "text": answer])
                try await conn.emit(["type": "citations", "corrected": fixed.corrected, "removed": fixed.removed])
            }
        }

        try await conn.emit(["type": "done"].merging(done) { a, _ in a })
    } catch {
        var message = error.localizedDescription
        if message.contains("not found") || message.contains("pull") {
            message = "\(profile.displayName) isn't downloaded yet. Click Download in the Models section."
        } else if (error as? URLError)?.code == .cannotConnectToHost {
            message = "Can't reach Ollama. Open the Ollama app or run `ollama serve`."
        }
        try? await conn.emit(["type": "error", "message": message])
    }
    conn.close()
}

/// POST /api/documents — raw PDF bytes in the body, file name in the X-Filename header (URL-encoded).
/// Streams extraction progress, then the document's metadata.
func handleDocumentUpload(_ req: HTTPRequest, _ conn: HTTPConnection) async {
    let rawName = req.headers["x-filename"].flatMap { $0.removingPercentEncoding } ?? "Document.pdf"
    let name = String(rawName.split(separator: "/").last ?? "Document.pdf").prefix(200)
    do {
        try await conn.beginStream()
        let doc = try await PDFExtractor.extract(data: req.body, name: String(name)) { page, total, ocr in
            try await conn.emit(["type": "progress", "page": page, "pages": total, "ocr": ocr])
        }
        try await conn.emit(["type": "done", "document": doc.meta])
    } catch {
        try? await conn.emit(["type": "error", "message": error.localizedDescription])
    }
    conn.close()
}

func handlePull(_ conn: HTTPConnection) async {
    do {
        try await conn.beginStream()
        try await Ollama.streamLines(path: "api/pull", body: ["model": profile.model, "stream": true]) { obj in
            var e: [String: Any] = ["type": "progress", "status": obj["status"] as? String ?? ""]
            if let c = obj["completed"] as? Int { e["completed"] = c }
            if let t = obj["total"] as? Int { e["total"] = t }
            try await conn.emit(e)
        }
        try await conn.emit(["type": "done"])
    } catch {
        try? await conn.emit(["type": "error", "message": error.localizedDescription])
    }
    conn.close()
}

let mimeTypes = ["html": "text/html; charset=utf-8", "css": "text/css; charset=utf-8",
                 "js": "text/javascript; charset=utf-8", "svg": "image/svg+xml", "png": "image/png",
                 "ico": "image/x-icon", "json": "application/json", "woff2": "font/woff2", "txt": "text/plain; charset=utf-8"]

func serveStatic(_ path: String, _ conn: HTTPConnection) async {
    let relative = path == "/" ? "index.html" : String(path.dropFirst())
    let file = publicDir.appending(path: relative).standardizedFileURL
    // Refuse anything that escapes the Public directory (e.g. /../Package.swift).
    guard file.path.hasPrefix(publicDir.standardizedFileURL.path + "/"),
          let data = try? Data(contentsOf: file) else {
        return await conn.respondJSON(["error": "Not found"], status: 404)
    }
    await conn.respond(contentType: mimeTypes[file.pathExtension] ?? "application/octet-stream", body: data)
}

// MARK: Start

let server = try HTTPServer(port: port) { req, conn in
    switch (req.method, req.path) {
    case ("GET", "/api/status"): await conn.respondJSON(await statusJSON())
    case ("POST", "/api/chat"): await handleChat(req, conn)
    case ("POST", "/api/pull"): await handlePull(conn)
    case ("POST", "/api/documents"): await handleDocumentUpload(req, conn)
    case ("GET", _): await serveStatic(req.path, conn)
    default: await conn.respondJSON(["error": "Method not allowed"], status: 405)
    }
}

server.start(onReady: {
    Task { await TriagePool.shared.warm() }
    let apple = AppleModel.isAvailable ? "available" : "unavailable"
    print("""

      PrettyAFM  →  http://localhost:\(port)

      Apple Foundation Model: \(apple)
      Qwen: \(profile.model)  (\(profile.memoryGB) GB Mac)

    """)
    if args.contains("--open") {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["http://localhost:\(port)"]; try? p.run()
    }
}, onFailure: { error in
    print("Server failed: \(error)"); exit(1)
})

RunLoop.main.run()
