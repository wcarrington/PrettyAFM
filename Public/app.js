// PrettyAFM front end. Talks to the local Swift server: /api/status, /api/chat (NDJSON stream), /api/pull, /api/documents.
(() => {
  const $ = (s) => document.querySelector(s);
  const els = {
    app: $("#app"), messages: $("#messages"), panelEmpty: $("#panelEmpty"), form: $("#composer"), input: $("#input"),
    send: $("#sendBtn"), file: $("#fileInput"), attachments: $("#attachments"), accuracy: $("#accuracy"),
    newChat: $("#newChat"), segmented: $(".segmented"), greeting: $("#greeting"), stageStatus: $("#stageStatus"),
    suggestions: $("#suggestions"), search: $("#search"), pinnedList: $("#pinnedList"), recentList: $("#recentList"),
    pinnedGroup: $("#pinnedGroup"), recentGroup: $("#recentGroup"), viewAll: $("#viewAll"), sideEmpty: $("#sideEmpty"),
    panelTitle: $("#panelTitle"), pinBtn: $("#pinBtn"), panelClose: $("#panelClose"), panelTab: $("#panelTab"),
    stage: $("#stage"), scrim: $("#scrim"),
  };
  const STORE_KEY = "prettyafm.v2";
  const OLD_KEY = "prettyafm.v1";
  const RECENT_LIMIT = 7;
  const narrow = matchMedia("(max-width: 900px)");

  const state = {
    convos: [], currentId: null, mode: "auto", accuracy: "checked",
    pending: [], pendingDocs: [], status: null,
    stream: null,            // { controller, convo, reply } while a reply is streaming
    panelOpen: false, panelDismissed: false,
    groups: { pinned: true, recents: true }, viewAll: false, query: "",
  };
  const uiOf = new WeakMap(); // assistant message → live DOM handles

  const current = () => state.convos.find((c) => c.id === state.currentId) || null;
  const currentMessages = () => current()?.messages || [];

  // ── Persistence (best effort; private windows may refuse storage) ─────────
  function snapshot(dropImages) {
    const convos = state.convos.map((c) => ({
      ...c,
      messages: c.messages.map((m) => (dropImages && m.images?.length ? { ...m, images: [] } : m)),
    }));
    return JSON.stringify({ convos, currentId: state.currentId, mode: state.mode, accuracy: state.accuracy, groups: state.groups });
  }
  function save() {
    try { localStorage.setItem(STORE_KEY, snapshot(false)); }
    catch { try { localStorage.setItem(STORE_KEY, snapshot(true)); } catch { /* storage unavailable */ } }
  }
  function load() {
    let data = null;
    try { data = JSON.parse(localStorage.getItem(STORE_KEY) || "null"); } catch { /* ignore */ }
    if (!data) {
      // One-time move from the single-conversation format.
      try {
        const old = JSON.parse(localStorage.getItem(OLD_KEY) || "null");
        if (old) {
          const msgs = Array.isArray(old.messages) ? old.messages : [];
          data = { mode: old.mode, accuracy: old.accuracy || (old.think ? "deep" : "checked"), convos: [] };
          if (msgs.length) data.convos.push(newConvo(msgs));
        }
      } catch { /* ignore */ }
    }
    if (!data) return;
    state.mode = ["auto", "apple", "qwen"].includes(data.mode) ? data.mode : "auto";
    state.accuracy = ["fast", "checked", "deep"].includes(data.accuracy) ? data.accuracy : "checked";
    if (data.groups) state.groups = { pinned: data.groups.pinned !== false, recents: data.groups.recents !== false };
    state.convos = (Array.isArray(data.convos) ? data.convos : [])
      .filter((c) => c && c.id && Array.isArray(c.messages))
      .map((c) => ({
        ...c,
        messages: c.messages.filter((m) => m.role && typeof m.content === "string").map((m) => {
          // A reply that was streaming when the page closed is kept as stopped.
          if (m.streaming) { delete m.streaming; m.meta = { ...(m.meta || {}), stopped: true }; }
          return m;
        }),
      }));
    state.currentId = state.convos.some((c) => c.id === data.currentId) ? data.currentId : null;
  }

  function newConvo(messages = []) {
    const now = Date.now();
    const c = { id: `c${now.toString(36)}${Math.random().toString(36).slice(2, 7)}`, title: "", pinned: false, created: now, updated: now, messages };
    c.title = titleFor(c);
    return c;
  }
  function titleFor(c) {
    const first = c.messages.find((m) => m.role === "user");
    if (!first) return "New conversation";
    const text = first.content.replace(/\s+/g, " ").trim() || first.documents?.[0]?.name || "Image";
    return text.length > 60 ? text.slice(0, 57).trimEnd() + "…" : text;
  }

  // ── Small DOM helpers ─────────────────────────────────────────────────────
  function el(tag, cls, html) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html != null) n.innerHTML = html;
    return n;
  }
  const ICON = {
    pin: `<svg viewBox="0 0 20 20" width="15" height="15" aria-hidden="true"><path d="M7 3h6l-1 5 3 3H5l3-3zM10 11v6" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/></svg>`,
    trash: `<svg viewBox="0 0 20 20" width="15" height="15" aria-hidden="true"><path d="M4 6h12M8 6V4h4v2M6 6l1 10h6l1-10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/></svg>`,
    stack: `<svg viewBox="0 0 20 20" width="17" height="17" aria-hidden="true"><path d="M5 4h10M4 7h12M4.5 10h11a.5.5 0 01.5.5V16a1 1 0 01-1 1H5a1 1 0 01-1-1v-5.5a.5.5 0 01.5-.5z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  };

  // ── Messages (right panel) ───────────────────────────────────────────────
  const modelLabel = (backend, model) =>
    backend === "apple" ? "Apple Foundation Model" : model || state.status?.qwen?.displayName || "Qwen";

  function renderUser(m, draft = false) {
    const wrap = el("div", "msg msg-user" + (draft ? " draft" : ""));
    if (m.images?.length) {
      const t = el("div", "thumbs");
      m.images.forEach((src) => { const img = new Image(); img.src = src; img.alt = "Attached image"; t.append(img); });
      wrap.append(t);
    }
    if (m.documents?.length) {
      const d = el("div", "doc-row");
      m.documents.forEach((doc) => d.append(docChip(doc.name, doc.detail || `${doc.pages} page${doc.pages === 1 ? "" : "s"}`)));
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
    if (!meta?.seconds && meta?.seconds !== 0) return meta?.stopped ? "stopped" : "";
    const parts = [`${meta.seconds}s`];
    if (meta.tokensPerSecond) parts.push(`${meta.tokensPerSecond} tok/s`);
    if (meta.routingMs != null) parts.push(`routed in ${meta.routingMs} ms`);
    if (meta.stopped) parts.push("stopped");
    return parts.join(" · ");
  }

  /** Builds an assistant message node; while streaming, its handles are kept in uiOf. */
  function renderAssistant(m) {
    const wrap = el("div", "msg msg-assistant");
    const meta = m.meta || {};
    const chipHolder = el("div");
    chipHolder.append(routeChip({ backend: m.backend, ...meta }));
    const reason = el("p", "route-reason", ""); reason.textContent = meta.reason || "";
    const reroute = el("p", "reroute", ""); reroute.textContent = meta.reroute || "";
    const context = el("p", "context-note", ""); context.textContent = meta.context ? meta.context + "." : "";
    const thinking = el("details", "thinking");
    thinking.innerHTML = `<summary>Thought process</summary><div class="thinking-body"></div>`;
    if (m.thinking) thinking.querySelector(".thinking-body").textContent = m.thinking;
    else thinking.hidden = true;
    const answer = el("div", "answer");
    if (m.error && !m.content) { answer.innerHTML = `<p class="error-text"></p>`; answer.firstChild.textContent = m.error; }
    else {
      answer.innerHTML = window.renderMarkdown(m.content || "");
      if (m.error) { const p = el("p", "error-text"); p.textContent = m.error; answer.append(p); }
    }
    if (m.streaming) answer.classList.add("caret");
    const status = el("p", "status-line", ""); status.textContent = m.streaming ? m.statusText || "" : "";
    const review = el("p", "review-line"); renderReview(review, meta);
    const foot = el("div", "meta"); foot.textContent = m.streaming ? "" : metaLine(meta);
    wrap.append(chipHolder, reason, reroute, context, thinking, answer, status, review, foot);
    const ui = { wrap, chipHolder, reason, reroute, context, thinking, answer, status, review, foot };
    if (m.streaming) uiOf.set(m, ui);
    return ui;
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

  let draftNode = null;
  function renderMessages() {
    els.messages.querySelectorAll(".msg").forEach((n) => n.remove());
    draftNode = null;
    const msgs = currentMessages();
    for (const m of msgs) els.messages.append(m.role === "user" ? renderUser(m) : renderAssistant(m).wrap);
    renderDraft();
    scrollToEnd(true);
  }

  /** While typing, the panel previews the message that's about to be sent. */
  function renderDraft() {
    const text = els.input.value.trim();
    const docs = state.pendingDocs.filter((d) => d.status !== "error").map((d) => ({ name: d.name, detail: d.detail }));
    if (!text && !docs.length && !state.pending.length) { draftNode?.remove(); draftNode = null; }
    else {
      const node = renderUser({ content: text, documents: docs, images: state.pending }, true);
      if (draftNode) draftNode.replaceWith(node); else els.messages.append(node);
      draftNode = node;
      scrollToEnd();
    }
    els.panelEmpty.hidden = currentMessages().length > 0 || !!draftNode;
  }

  let pinned = true;
  els.messages.addEventListener("scroll", () => {
    const { scrollTop, scrollHeight, clientHeight } = els.messages;
    pinned = scrollHeight - scrollTop - clientHeight < 80;
  });
  function scrollToEnd(force) { if (force || pinned) els.messages.scrollTop = els.messages.scrollHeight; }

  // ── Left toolbar: pinned + recents ───────────────────────────────────────
  function matches(c, q) {
    if (!q) return true;
    q = q.toLowerCase();
    return c.title.toLowerCase().includes(q) || c.messages.some((m) => m.content?.toLowerCase().includes(q));
  }
  function convoItem(c) {
    const li = el("li", "convo" + (c.id === state.currentId ? " current" : ""));
    const open = el("button", "convo-open");
    open.type = "button";
    if (c.pinned) open.insertAdjacentHTML("beforeend", ICON.stack);
    const t = el("span", "t"); t.textContent = c.title; open.append(t);
    if (state.stream?.convo === c) open.append(el("span", "live"));
    open.title = c.title;
    open.addEventListener("click", () => openConvo(c.id));
    const actions = el("span", "convo-actions");
    const pin = el("button", "", ICON.pin);
    pin.type = "button"; pin.title = c.pinned ? "Unpin" : "Pin"; pin.setAttribute("aria-label", `${pin.title} ${c.title}`);
    pin.addEventListener("click", () => togglePin(c));
    const del = el("button", "", ICON.trash);
    del.type = "button"; del.title = "Delete"; del.setAttribute("aria-label", `Delete ${c.title}`);
    del.addEventListener("click", () => deleteConvo(c));
    actions.append(pin, del);
    li.append(open, actions);
    return li;
  }
  function renderSidebar() {
    const q = state.query.trim();
    const sorted = [...state.convos].filter((c) => c.messages.length && matches(c, q)).sort((a, b) => b.updated - a.updated);
    const pins = sorted.filter((c) => c.pinned);
    const recents = sorted.filter((c) => !c.pinned);
    const shown = q || state.viewAll ? recents : recents.slice(0, RECENT_LIMIT);
    els.pinnedList.replaceChildren(...pins.map(convoItem));
    els.recentList.replaceChildren(...shown.map(convoItem));
    els.pinnedGroup.hidden = !pins.length;
    els.recentGroup.hidden = !recents.length;
    els.viewAll.hidden = !!q || recents.length <= RECENT_LIMIT;
    els.viewAll.textContent = state.viewAll ? "Show less" : "View all";
    els.sideEmpty.hidden = !!(pins.length || recents.length);
    els.sideEmpty.textContent = q ? "No conversations match." : "Your conversations will appear here.";
    document.querySelectorAll(".group-head").forEach((b) => b.setAttribute("aria-expanded", String(state.groups[b.dataset.group])));
  }
  document.querySelectorAll(".group-head").forEach((b) => b.addEventListener("click", () => {
    state.groups[b.dataset.group] = !state.groups[b.dataset.group];
    save(); renderSidebar();
  }));
  els.viewAll.addEventListener("click", () => { state.viewAll = !state.viewAll; renderSidebar(); });
  els.search.addEventListener("input", () => { state.query = els.search.value; renderSidebar(); });

  function togglePin(c) {
    c.pinned = !c.pinned;
    save(); renderSidebar(); renderPanelHead();
  }
  function deleteConvo(c) {
    if (!confirm(`Delete “${c.title}”? This can't be undone.`)) return;
    if (state.stream?.convo === c) stop();
    state.convos = state.convos.filter((x) => x !== c);
    if (state.currentId === c.id) startNewChat();
    else { save(); renderSidebar(); }
  }

  function openConvo(id) {
    state.currentId = id;
    state.panelDismissed = false;
    save();
    renderAll();
    if (currentMessages().length) openPanel();
    closeSidebarSheet();
    if (!narrow.matches) els.input.focus();
  }
  function startNewChat() {
    state.currentId = null;
    state.panelDismissed = false;
    save();
    renderAll();
    closePanel(false);
    changeGreeting();
    closeSidebarSheet();
    els.input.focus();
  }
  els.newChat.addEventListener("click", startNewChat);

  // ── Right panel open/close ───────────────────────────────────────────────
  function openPanel() {
    state.panelOpen = true;
    els.app.classList.add("panel-open");
    updatePanelTab();
  }
  function closePanel(byUser) {
    state.panelOpen = false;
    if (byUser) state.panelDismissed = true;
    els.app.classList.remove("panel-open");
    updatePanelTab();
  }
  function updatePanelTab() {
    const hasContent = currentMessages().length > 0 || !!els.input.value.trim();
    els.panelTab.hidden = state.panelOpen || !hasContent;
  }
  function renderPanelHead() {
    const c = current();
    els.panelTitle.textContent = c?.title || "New conversation";
    els.pinBtn.hidden = !c || !c.messages.length;
    if (c) {
      els.pinBtn.setAttribute("aria-pressed", String(!!c.pinned));
      els.pinBtn.setAttribute("aria-label", c.pinned ? "Unpin conversation" : "Pin conversation");
    }
  }
  els.panelClose.addEventListener("click", () => closePanel(true));
  els.panelTab.addEventListener("click", () => { state.panelDismissed = false; openPanel(); });
  els.pinBtn.addEventListener("click", () => { const c = current(); if (c) togglePin(c); });

  // Mobile sheets
  $("#sideOpen").addEventListener("click", () => els.app.classList.add("side-open"));
  $("#sideClose").addEventListener("click", closeSidebarSheet);
  els.scrim.addEventListener("click", () => { closeSidebarSheet(); if (narrow.matches) closePanel(true); });
  function closeSidebarSheet() { els.app.classList.remove("side-open"); }
  // The scrim element is display:none above the breakpoint; unhide it for the CSS to control.
  els.scrim.hidden = false;

  // ── Greeting ─────────────────────────────────────────────────────────────
  let greetingText = "";
  function greetings() {
    const n = state.status?.userName || "";
    const h = new Date().getHours();
    const part = h < 12 ? "morning" : h < 17 ? "afternoon" : "evening";
    return n
      ? [`Hello, ${n}`, `Good ${part}, ${n}`, `Welcome back, ${n}`, `Hi, ${n}`, `What’s next, ${n}?`, `Ready when you are, ${n}`]
      : ["Hello", `Good ${part}`, "Welcome back", "What’s next?", "Ready when you are"];
  }
  function setGreeting(text) {
    if (text === greetingText) return;
    greetingText = text;
    const g = els.greeting;
    if (!g.textContent || matchMedia("(prefers-reduced-motion: reduce)").matches) { g.textContent = text; return; }
    g.classList.add("out");
    setTimeout(() => { g.textContent = text; g.classList.remove("out"); }, 450);
  }
  function changeGreeting(first = false) {
    const list = greetings();
    if (first) return setGreeting(list[0]);
    const options = list.filter((t) => t !== greetingText);
    setGreeting(options[Math.floor(Math.random() * options.length)]);
  }
  // Rotate occasionally while idle.
  setInterval(() => {
    if (!state.stream && !els.input.value && document.visibilityState === "visible") changeGreeting();
  }, 15000);

  // ── Mode + accuracy controls ─────────────────────────────────────────────
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

  // ── Composer ─────────────────────────────────────────────────────────────
  function autosize() {
    els.input.style.height = "auto";
    els.input.style.height = els.input.scrollHeight + "px";
    updateSend();
  }
  function updateSend() {
    const streaming = !!state.stream;
    els.send.classList.toggle("streaming", streaming);
    els.send.setAttribute("aria-label", streaming ? "Stop" : "Send");
    const uploading = state.pendingDocs.some((d) => d.status === "reading");
    const hasDocs = state.pendingDocs.some((d) => d.status === "ready");
    els.send.disabled = !streaming && (uploading || (!els.input.value.trim() && !state.pending.length && !hasDocs));
  }
  function onDraftChange() {
    autosize();
    renderDraft();
    // As soon as there's something to send, the conversation panel slides out (desktop).
    const hasDraft = els.input.value.trim() || state.pendingDocs.length || state.pending.length;
    if (hasDraft && !state.panelOpen && !state.panelDismissed && !narrow.matches) openPanel();
    updatePanelTab();
  }
  els.input.addEventListener("input", onDraftChange);
  els.input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); els.form.requestSubmit(); }
  });
  els.form.addEventListener("submit", (e) => {
    e.preventDefault();
    if (state.stream) return stop();
    if (state.pendingDocs.some((d) => d.status === "reading")) return;
    const docs = state.pendingDocs.filter((d) => d.status === "ready").map((d) => d.meta);
    let text = els.input.value.trim();
    if (!text && docs.length) text = "Summarize this document.";
    if (!text && !state.pending.length) return;
    const images = state.pending.slice();
    els.input.value = "";
    state.pending = [];
    state.pendingDocs = [];
    renderAttachments();
    autosize();
    send(text, images, docs);
  });
  document.querySelectorAll(".suggestion[data-prompt]").forEach((b) =>
    b.addEventListener("click", () => { if (!state.stream) send(b.dataset.prompt, [], []); }));
  document.querySelector(".suggestion-pdf").addEventListener("click", () => els.file.click());

  // ── Attachments ──────────────────────────────────────────────────────────
  const isPDF = (f) => f.type === "application/pdf" || /\.pdf$/i.test(f.name);

  async function addFiles(files) {
    for (const f of files) {
      if (isPDF(f)) uploadDocument(f);
      else if (f.type.startsWith("image/")) state.pending.push(await downscale(f, 1536));
    }
    renderAttachments();
    onDraftChange();
  }

  /** Uploads a PDF; the server extracts text (OCR for scans) and streams progress. */
  async function uploadDocument(file) {
    const entry = { name: file.name, status: "reading", detail: "Reading…", meta: null };
    state.pendingDocs.push(entry);
    renderAttachments();
    onDraftChange();
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
    renderDraft();
  }

  async function readNDJSON(res, onEvent) {
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    const consume = (final = false) => {
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) onEvent(JSON.parse(line));
      }
      if (final) {
        const line = buf.trim();
        buf = "";
        if (line) onEvent(JSON.parse(line));
      }
    };
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      consume();
    }
    buf += decoder.decode();
    consume(true);
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
      x.onclick = () => { state.pendingDocs.splice(i, 1); renderAttachments(); onDraftChange(); };
      f.append(x);
      return f;
    });
    els.attachments.replaceChildren(...docs, ...state.pending.map((src, i) => {
      const f = el("figure");
      const img = new Image(); img.src = src; img.alt = "Attachment";
      const x = el("button"); x.type = "button"; x.textContent = "×"; x.setAttribute("aria-label", "Remove image");
      x.onclick = () => { state.pending.splice(i, 1); renderAttachments(); onDraftChange(); };
      f.append(img, x);
      return f;
    }));
  }
  els.file.addEventListener("change", () => { addFiles([...els.file.files]); els.file.value = ""; });
  els.input.addEventListener("paste", (e) => {
    const files = [...(e.clipboardData?.files || [])].filter((f) => f.type.startsWith("image/") || isPDF(f));
    if (files.length) { e.preventDefault(); addFiles(files); }
  });
  // Drop files anywhere on the stage.
  const hasFiles = (e) => [...(e.dataTransfer?.items || [])].some((i) => i.kind === "file");
  els.stage.addEventListener("dragover", (e) => { if (hasFiles(e)) { e.preventDefault(); els.form.classList.add("dragging"); } });
  els.stage.addEventListener("dragleave", (e) => { if (!els.stage.contains(e.relatedTarget)) els.form.classList.remove("dragging"); });
  els.stage.addEventListener("drop", (e) => {
    els.form.classList.remove("dragging");
    if (!hasFiles(e)) return;
    e.preventDefault();
    addFiles([...e.dataTransfer.files]);
  });

  // Copy buttons on code blocks.
  els.messages.addEventListener("click", async (e) => {
    const btn = e.target.closest(".copy-btn");
    if (!btn) return;
    const code = btn.closest(".codeblock").querySelector("code").textContent;
    try { await navigator.clipboard.writeText(code); btn.textContent = "Copied"; } catch { btn.textContent = "Press ⌘C"; }
    setTimeout(() => (btn.textContent = "Copy"), 1500);
  });

  // ── Chat streaming ───────────────────────────────────────────────────────
  function stop() { state.stream?.controller.abort(); }

  function setStageStatus(text) {
    els.stageStatus.textContent = text;
  }

  async function send(text, images, documents = []) {
    if (state.stream) return;
    let convo = current();
    if (!convo) {
      convo = newConvo();
      state.convos.push(convo);
      state.currentId = convo.id;
    }
    const user = { role: "user", content: text, images, documents };
    convo.messages.push(user);
    if (convo.messages.length === 1) convo.title = titleFor(convo);

    // History for the server is taken before the reply placeholder is added.
    const history = convo.messages.map(({ role, content, images, backend, documents }) => ({
      role, content, backend: backend || undefined,
      images: images?.length ? images : undefined,
      documents: documents?.length ? documents.map((d) => d.id) : undefined,
    }));

    const reply = { role: "assistant", content: "", thinking: "", backend: null, meta: {}, streaming: true };
    convo.messages.push(reply);
    convo.updated = Date.now();
    const controller = new AbortController();
    state.stream = { controller, convo, reply };
    const started = performance.now();

    state.panelDismissed = false;
    renderAll();
    openPanel();
    pinned = true;
    scrollToEnd(true);
    save();
    window.Orbit?.setActive(true);
    setStageStatus("Choosing a model…");
    updateSend();

    // Re-render Markdown at most once per frame while streaming, into whichever node shows this reply now.
    let frame = 0;
    const paint = () => {
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        const ui = uiOf.get(reply);
        if (!ui) return;
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
    const writer = () => modelLabel(reply.backend, reply.meta.model);

    try {
      const res = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ messages: history, mode: state.mode, accuracy: state.accuracy }),
        signal: controller.signal,
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
      delete reply.streaming;
      delete reply.statusText;
      if (reply.meta.stopped && reply.meta.seconds == null) reply.meta.seconds = +((performance.now() - started) / 1000).toFixed(1);
      if (!reply.backend) reply.backend = reply.meta.backend || null;
      const ui = uiOf.get(reply);
      if (ui) ui.wrap.replaceWith(renderAssistant(reply).wrap);
      uiOf.delete(reply);
      convo.updated = Date.now();
      state.stream = null;
      window.Orbit?.setActive(false);
      setStageStatus("");
      updateSend();
      save();
      renderSidebar();
      scrollToEnd();
    }

    function handleEvent(e) {
      const ui = uiOf.get(reply);
      switch (e.type) {
        case "route":
          reply.backend = e.backend;
          Object.assign(reply.meta, { backend: e.backend, model: e.model, reason: e.reason, category: e.category, routingMs: e.routingMs });
          if (ui) { ui.chipHolder.replaceChildren(routeChip(reply.meta)); ui.reason.textContent = e.reason || ""; }
          setStageStatus(`${writer()} is ${state.accuracy === "deep" && e.backend === "qwen" ? "thinking" : "writing"}…`);
          break;
        case "reroute":
          reply.backend = e.backend;
          reply.content = "";
          Object.assign(reply.meta, { backend: e.backend, model: e.model, reroute: e.reason, category: null });
          if (ui) { ui.chipHolder.replaceChildren(routeChip(reply.meta)); ui.reroute.textContent = e.reason; }
          setStageStatus(`${writer()} is writing…`);
          paint();
          break;
        case "progress":
          if (ui) ui.reason.textContent = e.message;
          setStageStatus(e.message);
          scrollToEnd();
          break;
        case "status":
          reply.statusText = e.text;
          if (ui) ui.status.textContent = e.text;
          setStageStatus(e.text);
          scrollToEnd();
          break;
        case "review":
          reply.meta.review = { checked: e.checked, supported: e.supported, problems: e.problems, unconfirmed: e.unconfirmed, checker: e.checker, revised: e.revised };
          reply.statusText = "";
          if (ui) { ui.status.textContent = ""; renderReview(ui.review, reply.meta); }
          break;
        case "citations":
          reply.meta.citations = { corrected: e.corrected || 0, removed: e.removed || 0 };
          if (ui) renderReview(ui.review, reply.meta);
          break;
        case "context":
          reply.meta.context = e.text;
          if (ui) ui.context.textContent = e.text + ".";
          break;
        case "thinking": reply.thinking += e.text; window.Orbit?.kick(); paint(); break;
        case "delta": reply.content += e.text; window.Orbit?.kick(); paint(); break;
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

  function renderAll() {
    renderMessages();
    renderSidebar();
    renderPanelHead();
    els.suggestions.hidden = currentMessages().length > 0;
    updatePanelTab();
    updateSend();
  }

  // ── Status + model download ──────────────────────────────────────────────
  function setDot(row, cls) { row.querySelector(".dot").className = `dot ${cls}`; }

  async function refreshStatus() {
    let s;
    try { s = await (await fetch("/api/status")).json(); }
    catch {
      setDot($("#appleRow"), "bad"); setDot($("#qwenRow"), "bad");
      $("#modelNote").textContent = "The PrettyAFM server isn't responding.";
      return;
    }
    const hadName = state.status?.userName;
    state.status = s;
    if (!hadName && s.userName) changeGreeting(true);

    const appleOK = s.apple.available;
    setDot($("#appleRow"), appleOK ? "ok" : "bad");
    $("#appleRow").title = appleOK ? `Ready · ${(s.apple.contextTokens || 0).toLocaleString()} token context` : s.apple.reason;

    const q = s.qwen;
    $("#qwenName").textContent = q.displayName;
    const qwenOK = q.ollamaRunning && q.installed;
    setDot($("#qwenRow"), qwenOK ? "ok" : q.ollamaRunning ? "warn" : "bad");
    $("#qwenRow").title = `${q.model} · ${q.contextTokens.toLocaleString()} token context`;
    $("#downloadBox").hidden = !(q.ollamaRunning && !q.installed);

    const notes = [];
    if (!appleOK) notes.push(s.apple.reason);
    if (!q.ollamaRunning) notes.push("Ollama isn't running. Open Ollama or run “ollama serve”.");
    else if (!q.installed) notes.push(`${q.displayName} isn't downloaded yet.`);
    if (!notes.length) notes.push(`Both ready on this ${s.memoryGB} GB Mac.`);
    $("#modelNote").textContent = notes.join(" ");
  }

  $("#downloadBtn").addEventListener("click", async () => {
    const btn = $("#downloadBtn"), bar = $("#progressBar"), label = $("#progressLabel");
    btn.disabled = true;
    $("#progress").hidden = false;
    label.textContent = "Starting download…";
    try {
      const res = await fetch("/api/pull", { method: "POST" });
      await readNDJSON(res, (e) => {
        if (e.type === "progress") {
          if (e.total) {
            bar.style.width = ((e.completed || 0) / e.total * 100).toFixed(1) + "%";
            label.textContent = `${((e.completed || 0) / 1e9).toFixed(2)} of ${(e.total / 1e9).toFixed(2)} GB`;
          } else label.textContent = e.status.charAt(0).toUpperCase() + e.status.slice(1);
        } else if (e.type === "error") throw new Error(e.message);
      });
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
  changeGreeting(true);
  renderAll();
  if (currentMessages().length && !narrow.matches) openPanel();
  autosize();
  refreshStatus();
  setInterval(refreshStatus, 30000);
})();
