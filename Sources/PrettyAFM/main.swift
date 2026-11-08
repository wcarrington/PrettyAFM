import Foundation

// MARK: Configuration

let args = CommandLine.arguments
func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let port = UInt16(argValue("--port") ?? ProcessInfo.processInfo.environment["LI_PORT"] ?? "8642") ?? 8642
let profile = QwenProfile.forThisMac()

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
    let think = body["think"] as? Bool ?? false

    do {
        try await conn.beginStream()

        // Attach PDF text (full, relevant passages, or on-device section summaries) to the latest user turn.
        let messages = try await DocumentContext.prepare(messages: messages, mode: mode, profile: profile) {
            try await conn.emit($0)
        }
        let last = messages[messages.count - 1]

        let started = Date()
        let decision = await Router.decide(messages: messages, mode: mode, think: think)
        var route = decision.json
        route["model"] = decision.backend == .apple ? "Apple Foundation Model" : profile.displayName
        route["routingMs"] = Int(Date().timeIntervalSince(started) * 1000)
        try await conn.emit(["type": "route"].merging(route) { a, _ in a })

        func runQwen() async throws {
            let t0 = Date()
            let stats = try await Ollama.chat(
                profile: profile, messages: messages, think: think,
                onThinking: { try await conn.emit(["type": "thinking", "text": $0]) },
                onDelta: { try await conn.emit(["type": "delta", "text": $0]) })
            try await conn.emit(["type": "done", "backend": "qwen", "outputTokens": stats.outputTokens,
                                 "tokensPerSecond": (stats.tokensPerSecond * 10).rounded() / 10,
                                 "seconds": (Date().timeIntervalSince(t0) * 10).rounded() / 10])
        }

        if decision.backend == .apple {
            let t0 = Date()
            do {
                let tokens = try await AppleModel.stream(history: Array(messages.dropLast()), prompt: last.fullContent) { text, replace in
                    try await conn.emit(["type": replace ? "replace" : "delta", "text": text])
                }
                let secs = Date().timeIntervalSince(t0)
                try await conn.emit(["type": "done", "backend": "apple", "outputTokens": tokens,
                                     "tokensPerSecond": secs > 0 ? (Double(tokens) / secs * 10).rounded() / 10 : 0,
                                     "seconds": (secs * 10).rounded() / 10])
            } catch {
                guard mode != "apple", let why = AppleModel.shouldFallBack(error) else { throw error }
                try await conn.emit(["type": "reroute", "backend": "qwen", "model": profile.displayName,
                                     "reason": why + " Qwen answered instead."])
                try await runQwen()
            }
        } else {
            try await runQwen()
        }
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
                 "ico": "image/x-icon", "json": "application/json"]

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
