// PrettyAFM front end. Talks to the local Swift server: /api/status, /api/chat (NDJSON stream), /api/pull.
(() => {
  const $ = (s) => document.querySelector(s);
  const els = {
    messages: $("#messages"), empty: $("#empty"), form: $("#composer"), input: $("#input"),
    send: $("#sendBtn"), file: $("#fileInput"), attachments: $("#attachments"), accuracy: $("#accuracy"),
    newChat: $("#newChat"), segmented: $(".segmented"), navStatus: $("#navStatus"),
  };
  const STORE_KEY = "prettyafm.v1";

  const state = { messages: [], mode: "auto", accuracy: "checked", pending: [], pendingDocs: [], controller: null, status: null };

  // ── Persistence (best effort; private windows may refuse storage) ─────────
  function save() {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify({ messages: state.messages, mode: state.mode, accuracy: state.accuracy }));
    } catch {
      // Quota exceeded: usually large images. Keep the text, drop the images.
      try {
        const light = state.messages.map((m) => ({ ...m, images: [] }));
        localStorage.setItem(STORE_KEY, JSON.stringify({ messages: light, mode: state.mode, accuracy: state.accuracy }));
      } catch { /* storage unavailable */ }
    }
  }
  function load() {
    try {
      const data = JSON.parse(localStorage.getItem(STORE_KEY) || "null");
      if (data) {
        state.messages = Array.isArray(data.messages) ? data.messages.filter((m) => m.role && typeof m.content === "string") : [];
        state.mode = ["auto", "apple", "qwen"].includes(data.mode) ? data.mode : "auto";
        // Older saves had a Think switch; it maps to Deep.
        state.accuracy = ["fast", "checked", "deep"].includes(data.accuracy) ? data.accuracy : data.think ? "deep" : "checked";
      }
    } catch { /* ignore */ }
  }

  // ── Rendering ─────────────────────────────────────────────────────────────
  const modelLabel = (backend, model) =>
    backend === "apple" ? "Apple Foundation Model" : model || state.status?.qwen?.displayName || "Qwen";

  function el(tag, cls, html) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html != null) n.innerHTML = html;
    return n;
  }

  function renderUser(m) {
    const wrap = el("div", "msg msg-user");
    if (m.images?.length) {
      const t = el("div", "thumbs");
      m.images.forEach((src) => { const img = new Image(); img.src = src; img.alt = "Attached image"; t.append(img); });
      wrap.append(t);
    }
    if (m.documents?.length) {
      const d = el("div", "doc-row");
      m.documents.forEach((doc) => d.append(docChip(doc.name, `${doc.pages} page${doc.pages === 1 ? "" : "s"}`)));
      wrap.append(d);
    }
    if (m.content) { const b = el("div", "bubble"); b.textContent = m.content; wrap.append(b); }
    return wrap;
  }

  function docChip(name, detail, cls = "") {
    const c = el("div", `doc-chip ${cls}`);
    c.innerHTML = `<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M6 2.75h8.2L19.25 7.8V20a1.25 1.25 0 01-1.25 1.25H6A1.25 1.25 0 014.75 20V4A1.25 1.25 0 016 2.75z" fill="currentColor" opacity=".14"/><path d="M14 2.75V8h5.25M6 2.75h8.2L19.25 7.8V20a1.25 1.25 0 01-1.25 1.25H6A1.25 1.25 0 014.75 20V4A1.25 1.25 0 016 2.75z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg><span class="doc-text"><span class="doc-name"></span><span class="doc-detail"></span></span>`;
    c.querySelector(".doc-name").textContent = name;
    c.querySelector(".doc-detail").textContent = detail;
    return c;
  }

  function routeChip(meta) {
    const chip = el("div", `route route-${meta.backend || "pending"}`);
    chip.append(el("span", "route-dot"));
    const name = el("span");
    name.textContent = meta.backend ? modelLabel(meta.backend, meta.model) : "Choosing a model…";
    chip.append(name);
    if (meta.category) { const c = el("span", "route-cat"); c.textContent = "· " + meta.category; chip.append(c); }
    if (meta.reason) chip.title = meta.reason;
    return chip;
  }

  function metaLine(meta) {
    if (!meta?.seconds && meta?.seconds !== 0) return "";
    const parts = [`${meta.seconds}s`];
    if (meta.tokensPerSecond) parts.push(`${meta.tokensPerSecond} tok/s`);
    if (meta.routingMs != null) parts.push(`routed in ${meta.routingMs} ms`);
    if (meta.stopped) parts.push("stopped");
    return parts.join(" · ");
  }

  /** Builds an assistant message node and returns handles for live updates. */
  function renderAssistant(m) {
    const wrap = el("div", "msg msg-assistant");
    const meta = m.meta || {};
    const chipHolder = el("div");
    chipHolder.append(routeChip({ backend: m.backend, ...meta }));
    wrap.append(chipHolder);

    const reason = el("p", "route-reason");
    if (meta.reason) reason.textContent = meta.reason;
    wrap.append(reason);

    const reroute = el("p", "reroute");
    if (meta.reroute) reroute.textContent = meta.reroute;
    wrap.append(reroute);

    const context = el("p", "context-note");
    if (meta.context) context.textContent = meta.context + ".";
    wrap.append(context);

    const thinking = el("details", "thinking");
    thinking.innerHTML = `<summary>Thought process</summary><div class="thinking-body"></div>`;
    if (m.thinking) thinking.querySelector(".thinking-body").textContent = m.thinking;
    else thinking.hidden = true;
    wrap.append(thinking);

    const answer = el("div", "answer");
    answer.innerHTML = m.error ? `<p class="error-text"></p>` : window.renderMarkdown(m.content || "");
    if (m.error) answer.firstChild.textContent = m.error;
    wrap.append(answer);

    const status = el("p", "status-line");
    wrap.append(status);

    const review = el("p", "review-line");
    renderReview(review, meta);
    wrap.append(review);

    const foot = el("div", "meta", "");
    foot.textContent = metaLine(meta);
    wrap.append(foot);

    return { wrap, chipHolder, reason, reroute, context, thinking, answer, status, review, foot };
  }

  /** One line summarizing the double-check and citation fixes. */
  function renderReview(node, meta) {
    const parts = [];
    let cls = "";
    const r = meta.review;
    if (r) {
      const who = r.checker === "apple" ? "Apple's model" : state.status?.qwen?.displayName || "Qwen";
      if (r.revised) {
        parts.push(`Revised after ${who} found ${r.problems} claim${r.problems === 1 ? "" : "s"} the document doesn't support`);
        cls = "revised";
      } else {
        parts.push(`Checked by ${who}: ${r.supported} of ${r.checked} claim${r.checked === 1 ? "" : "s"} confirmed in the document`);
        cls = r.unconfirmed ? "" : "ok";
      }
    }
    const c = meta.citations;
    if (c) {
      const bits = [];
      if (c.corrected) bits.push(`corrected ${c.corrected} page reference${c.corrected === 1 ? "" : "s"}`);
      if (c.removed) bits.push(`removed ${c.removed} that matched no page`);
      if (bits.length) parts.push(bits.join(", ").replace(/^./, (x) => (parts.length ? x : x.toUpperCase())));
    }
    node.textContent = parts.length ? parts.join("; ") + "." : "";
    node.className = `review-line ${cls}`;
  }

  function renderAll() {
    els.messages.querySelectorAll(".msg").forEach((n) => n.remove());
    els.empty.hidden = state.messages.length > 0;
    for (const m of state.messages) els.messages.append(m.role === "user" ? renderUser(m) : renderAssistant(m).wrap);
    scrollToEnd(true);
  }

  let pinned = true;
  els.messages.addEventListener("scroll", () => {
    const { scrollTop, scrollHeight, clientHeight } = els.messages;
    pinned = scrollHeight - scrollTop - clientHeight < 80;
  });
  function scrollToEnd(force) { if (force || pinned) els.messages.scrollTop = els.messages.scrollHeight; }

  // ── Mode + think controls ────────────────────────────────────────────────
  function setMode(mode) {
    state.mode = mode;
    const buttons = [...els.segmented.querySelectorAll("button")];
    buttons.forEach((b) => b.setAttribute("aria-checked", String(b.dataset.mode === mode)));
    const idx = buttons.findIndex((b) => b.dataset.mode === mode);
    els.segmented.querySelector(".seg-thumb").style.transform = `translateX(${idx * 100}%)`;
    save();
  }
  els.segmented.addEventListener("click", (e) => { const b = e.target.closest("button"); if (b) setMode(b.dataset.mode); });
  els.segmented.addEventListener("keydown", (e) => {
    const order = ["auto", "apple", "qwen"];
    const i = order.indexOf(state.mode);
    if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
      e.preventDefault();
      const next = order[(i + (e.key === "ArrowRight" ? 1 : 2)) % 3];
      setMode(next);
      els.segmented.querySelector(`[data-mode="${next}"]`).focus();
    }
  });
  els.accuracy.addEventListener("change", () => { state.accuracy = els.accuracy.value; save(); });

  els.newChat.addEventListener("click", () => {
    stop();
    state.messages = [];
    save();
    renderAll();
    els.input.focus();
  });

  // ── Composer ─────────────────────────────────────────────────────────────
  function autosize() {
    els.input.style.height = "auto";
    els.input.style.height = Math.min(els.input.scrollHeight, 200) + "px";
    updateSend();
  }
  function updateSend() {
    const streaming = !!state.controller;
    els.send.classList.toggle("streaming", streaming);
    els.send.setAttribute("aria-label", streaming ? "Stop" : "Send");
    const uploading = state.pendingDocs.some((d) => d.status === "reading");
    const hasDocs = state.pendingDocs.some((d) => d.status === "ready");
    els.send.disabled = !streaming && (uploading || (!els.input.value.trim() && !state.pending.length && !hasDocs));
  }
  els.input.addEventListener("input", autosize);
  els.input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); els.form.requestSubmit(); }
  });
  els.form.addEventListener("submit", (e) => {
    e.preventDefault();
    if (state.controller) return stop();
    if (state.pendingDocs.some((d) => d.status === "reading")) return;
    const docs = state.pendingDocs.filter((d) => d.status === "ready").map((d) => d.meta);
    let text = els.input.value.trim();
    if (!text && docs.length) text = "Summarize this document.";
    if (!text && !state.pending.length) return;
    send(text, state.pending.slice(), docs);
    els.input.value = "";
    state.pending = [];
    state.pendingDocs = [];
    renderAttachments();
    autosize();
  });
  document.querySelectorAll(".suggestion[data-prompt]").forEach((b) =>
    b.addEventListener("click", () => { if (!state.controller) send(b.dataset.prompt, [], []); }));
  document.querySelector(".suggestion-pdf").addEventListener("click", () => els.file.click());

  // Images: downscale to keep requests small and fast.
  const isPDF = (f) => f.type === "application/pdf" || /\.pdf$/i.test(f.name);

  async function addFiles(files) {
    for (const f of files) {
      if (isPDF(f)) uploadDocument(f);
      else if (f.type.startsWith("image/")) state.pending.push(await downscale(f, 1536));
    }
    renderAttachments();
    updateSend();
  }

  /** Uploads a PDF; the server extracts text (OCR for scans) and streams progress. */
  async function uploadDocument(file) {
    const entry = { name: file.name, status: "reading", detail: "Reading…", meta: null };
    state.pendingDocs.push(entry);
    renderAttachments();
    try {
      if (file.size > 60 * 1024 * 1024) throw new Error("PDFs must be under 60 MB.");
      const res = await fetch("/api/documents", {
        method: "POST",
        headers: { "Content-Type": "application/pdf", "X-Filename": encodeURIComponent(file.name) },
        body: file,
      });
      if (!res.ok || !res.body) throw new Error((await res.json().catch(() => ({}))).error || `Upload failed (${res.status})`);
      await readNDJSON(res, (e) => {
        if (e.type === "progress") {
          entry.detail = e.ocr ? `Scanning page ${e.page} of ${e.pages}…` : `Reading page ${e.page} of ${e.pages}…`;
        } else if (e.type === "done") {
          entry.meta = { id: e.document.id, name: e.document.name, pages: e.document.pages };
          entry.status = "ready";
          const p = e.document.pages;
          entry.detail = `${p} page${p === 1 ? "" : "s"}` + (e.document.ocrPages ? ` · ${e.document.ocrPages} scanned` : "");
        } else if (e.type === "error") throw new Error(e.message);
        renderAttachments();
      });
      if (entry.status !== "ready") throw new Error("Upload ended early.");
    } catch (err) {
      entry.status = "error";
      entry.detail = err instanceof TypeError ? "Can't reach the server." : err.message;
    }
    renderAttachments();
    updateSend();
  }

  async function readNDJSON(res, onEvent) {
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) onEvent(JSON.parse(line));
      }
    }
  }
  function downscale(file, max) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => {
        const scale = Math.min(1, max / Math.max(img.width, img.height));
        const c = document.createElement("canvas");
        c.width = Math.round(img.width * scale); c.height = Math.round(img.height * scale);
        c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(img.src);
        resolve(c.toDataURL("image/jpeg", 0.88));
      };
      img.onerror = reject;
      img.src = URL.createObjectURL(file);
    });
  }
  function renderAttachments() {
    els.attachments.hidden = !state.pending.length && !state.pendingDocs.length;
    const docs = state.pendingDocs.map((d, i) => {
      const f = el("figure", "doc-attachment");
      f.append(docChip(d.name, d.detail, d.status));
      const x = el("button"); x.type = "button"; x.textContent = "×"; x.setAttribute("aria-label", `Remove ${d.name}`);
      x.onclick = () => { state.pendingDocs.splice(i, 1); renderAttachments(); updateSend(); };
      f.append(x);
      return f;
    });
    els.attachments.replaceChildren(...docs, ...state.pending.map((src, i) => {
      const f = el("figure");
      const img = new Image(); img.src = src; img.alt = "Attachment";
      const x = el("button"); x.type = "button"; x.textContent = "×"; x.setAttribute("aria-label", "Remove image");
      x.onclick = () => { state.pending.splice(i, 1); renderAttachments(); updateSend(); };
      f.append(img, x);
      return f;
    }));
  }
  els.file.addEventListener("change", () => { addFiles([...els.file.files]); els.file.value = ""; });
  els.input.addEventListener("paste", (e) => {
    const files = [...(e.clipboardData?.files || [])].filter((f) => f.type.startsWith("image/") || isPDF(f));
    if (files.length) { e.preventDefault(); addFiles(files); }
  });
  const row = $(".composer-row");
  ["dragenter", "dragover"].forEach((t) => row.addEventListener(t, (e) => { e.preventDefault(); row.classList.add("dragging"); }));
  ["dragleave", "drop"].forEach((t) => row.addEventListener(t, () => row.classList.remove("dragging")));
  row.addEventListener("drop", (e) => { e.preventDefault(); addFiles([...e.dataTransfer.files]); });
  // Dropping anywhere on the chat card works too.
  const card = document.querySelector(".chat-card");
  card.addEventListener("dragover", (e) => { if ([...e.dataTransfer.items].some((i) => i.kind === "file")) e.preventDefault(); });
  card.addEventListener("drop", (e) => { if (e.target.closest(".composer-row")) return; e.preventDefault(); addFiles([...e.dataTransfer.files]); });

  // Copy buttons on code blocks.
  els.messages.addEventListener("click", async (e) => {
    const btn = e.target.closest(".copy-btn");
    if (!btn) return;
    const code = btn.closest(".codeblock").querySelector("code").textContent;
    try { await navigator.clipboard.writeText(code); btn.textContent = "Copied"; } catch { btn.textContent = "Press ⌘C"; }
    setTimeout(() => (btn.textContent = "Copy"), 1500);
  });

  // ── Chat streaming ───────────────────────────────────────────────────────
  function stop() { state.controller?.abort(); }

  async function send(text, images, documents = []) {
    els.empty.hidden = true;
    const user = { role: "user", content: text, images, documents };
    state.messages.push(user);
    els.messages.append(renderUser(user));

    const reply = { role: "assistant", content: "", thinking: "", backend: null, meta: {} };
    const ui = renderAssistant(reply);
    ui.answer.classList.add("caret");
    els.messages.append(ui.wrap);
    pinned = true;
    scrollToEnd(true);

    state.controller = new AbortController();
    const started = performance.now();
    updateSend();

    // Re-render Markdown at most once per frame while streaming.
    let frame = 0;
    const paint = () => {
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        ui.answer.innerHTML = window.renderMarkdown(reply.content);
        if (reply.thinking) {
          ui.thinking.hidden = false;
          const body = ui.thinking.querySelector(".thinking-body");
          body.textContent = reply.thinking;
          body.scrollTop = body.scrollHeight;
        }
        scrollToEnd();
      });
    };

    const history = state.messages.map(({ role, content, images, backend, documents }) => ({
      role, content, backend: backend || undefined,
      images: images?.length ? images : undefined,
      documents: documents?.length ? documents.map((d) => d.id) : undefined,
    }));

    try {
      const res = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ messages: history, mode: state.mode, accuracy: state.accuracy }),
        signal: state.controller.signal,
      });
      if (!res.ok || !res.body) {
        const err = await res.json().catch(() => ({}));
        throw new Error(err.error || `Server returned ${res.status}`);
      }
      await readNDJSON(res, handleEvent);
    } catch (err) {
      if (err.name === "AbortError") reply.meta.stopped = true;
      else reply.error = friendlyError(err);
    } finally {
      if (frame) cancelAnimationFrame(frame), (frame = 0);
      ui.answer.classList.remove("caret");
      ui.status.textContent = "";
      if (reply.error && !reply.content) {
        ui.answer.innerHTML = `<p class="error-text"></p>`;
        ui.answer.firstChild.textContent = reply.error;
      } else {
        ui.answer.innerHTML = window.renderMarkdown(reply.content);
        if (reply.error) { const p = el("p", "error-text"); p.textContent = reply.error; ui.answer.append(p); }
      }
      if (reply.meta.stopped && reply.meta.seconds == null) reply.meta.seconds = +((performance.now() - started) / 1000).toFixed(1);
      ui.foot.textContent = metaLine(reply.meta);
      if (!reply.backend) reply.backend = reply.meta.backend || null;
      state.messages.push(reply);
      state.controller = null;
      updateSend();
      save();
      scrollToEnd();
    }

    function handleEvent(e) {
      switch (e.type) {
        case "route":
          reply.backend = e.backend;
          Object.assign(reply.meta, { backend: e.backend, model: e.model, reason: e.reason, category: e.category, routingMs: e.routingMs });
          ui.chipHolder.replaceChildren(routeChip(reply.meta));
          ui.reason.textContent = e.reason || "";
          break;
        case "reroute":
          reply.backend = e.backend;
          reply.content = "";
          Object.assign(reply.meta, { backend: e.backend, model: e.model, reroute: e.reason, category: null });
          ui.chipHolder.replaceChildren(routeChip(reply.meta));
          ui.reroute.textContent = e.reason;
          paint();
          break;
        case "progress": ui.reason.textContent = e.message; scrollToEnd(); break;
        case "status": ui.status.textContent = e.text; scrollToEnd(); break;
        case "review":
          reply.meta.review = { checked: e.checked, supported: e.supported, problems: e.problems, unconfirmed: e.unconfirmed, checker: e.checker, revised: e.revised };
          ui.status.textContent = "";
          renderReview(ui.review, reply.meta);
          break;
        case "citations":
          reply.meta.citations = { corrected: e.corrected || 0, removed: e.removed || 0 };
          renderReview(ui.review, reply.meta);
          break;
        case "context":
          reply.meta.context = e.text;
          ui.context.textContent = e.text + ".";
          break;
        case "thinking": reply.thinking += e.text; paint(); break;
        case "delta": reply.content += e.text; paint(); break;
        case "replace": reply.content = e.text; paint(); break;
        case "done": Object.assign(reply.meta, { seconds: e.seconds, tokensPerSecond: e.tokensPerSecond }); break;
        case "error": reply.error = e.message; break;
      }
    }
  }
  function friendlyError(err) {
    if (err instanceof TypeError) return "Can't reach the PrettyAFM server. Is it still running?";
    return err.message || String(err);
  }

  // ── Status + model download ──────────────────────────────────────────────
  function setStatus(node, cls, text) {
    node.replaceChildren(el("span", `dot ${cls}`), document.createTextNode(text));
  }

  async function refreshStatus() {
    let s;
    try { s = await (await fetch("/api/status")).json(); }
    catch { setStatus(els.navStatus, "bad", "Server offline"); return; }
    state.status = s;

    const appleOK = s.apple.available;
    setStatus($("#appleStatus"), appleOK ? "ok" : "bad", appleOK ? "Ready on this Mac" : s.apple.reason);
    $("#appleCtx").textContent = (s.apple.contextTokens || 0).toLocaleString();

    const q = s.qwen;
    $("#qwenName").textContent = q.displayName;
    $("#qwenTag").textContent = q.model;
    $("#qwenCtx").textContent = q.contextTokens.toLocaleString();
    $("#qwenNote").textContent = `Runs through Ollama. ${q.note}`;
    const qwenOK = q.ollamaRunning && q.installed;
    setStatus($("#qwenStatus"), qwenOK ? "ok" : q.ollamaRunning ? "warn" : "bad",
      !q.ollamaRunning ? "Ollama isn't running. Open Ollama or run “ollama serve”." :
      q.installed ? "Downloaded and ready" : "Not downloaded yet");
    $("#downloadBox").hidden = !(q.ollamaRunning && !q.installed);

    $("#memoryLine").textContent =
      `This Mac has ${s.memoryGB} GB of unified memory, so PrettyAFM pairs Apple's on-device model with ${q.displayName}.`;

    const ready = [appleOK && "Apple", qwenOK && "Qwen"].filter(Boolean);
    setStatus(els.navStatus, ready.length === 2 ? "ok" : ready.length ? "warn" : "bad",
      ready.length === 2 ? "Both models ready" : ready.length ? `${ready[0]} only` : "No models ready");
  }

  $("#downloadBtn").addEventListener("click", async () => {
    const btn = $("#downloadBtn"), bar = $("#progressBar"), label = $("#progressLabel");
    btn.disabled = true;
    $("#progress").hidden = false;
    label.textContent = "Starting download…";
    try {
      const res = await fetch("/api/pull", { method: "POST" });
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let nl;
        while ((nl = buf.indexOf("\n")) >= 0) {
          const e = JSON.parse(buf.slice(0, nl)); buf = buf.slice(nl + 1);
          if (e.type === "progress") {
            if (e.total) {
              const pct = (e.completed || 0) / e.total * 100;
              bar.style.width = pct.toFixed(1) + "%";
              label.textContent = `${(e.completed / 1e9).toFixed(2)} of ${(e.total / 1e9).toFixed(2)} GB`;
            } else label.textContent = e.status.charAt(0).toUpperCase() + e.status.slice(1);
          } else if (e.type === "error") throw new Error(e.message);
        }
      }
      label.textContent = "Done.";
    } catch (err) {
      label.textContent = "Download failed: " + err.message;
      btn.disabled = false;
    }
    refreshStatus();
  });

  // ── Boot ─────────────────────────────────────────────────────────────────
  load();
  setMode(state.mode);
  els.accuracy.value = state.accuracy;
  renderAll();
  autosize();
  refreshStatus();
  setInterval(refreshStatus, 30000);
})();
