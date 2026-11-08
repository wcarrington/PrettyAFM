// Minimal, XSS-safe Markdown renderer for model output.
// Everything is HTML-escaped first; only a known set of constructs is turned back into markup.
(function () {
  const esc = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  const TEX = {
    "\\cdot": "·", "\\times": "×", "\\div": "÷", "\\pm": "±", "\\le": "≤", "\\leq": "≤", "\\ge": "≥", "\\geq": "≥",
    "\\ne": "≠", "\\neq": "≠", "\\approx": "≈", "\\infty": "∞", "\\to": "→", "\\rightarrow": "→", "\\leftarrow": "←",
    "\\Rightarrow": "⇒", "\\in": "∈", "\\sum": "∑", "\\prod": "∏", "\\int": "∫", "\\partial": "∂", "\\sqrt": "√",
    "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ", "\\Delta": "Δ", "\\epsilon": "ε", "\\theta": "θ",
    "\\lambda": "λ", "\\mu": "μ", "\\pi": "π", "\\sigma": "σ", "\\Sigma": "Σ", "\\phi": "φ", "\\omega": "ω", "\\Omega": "Ω",
    "\\log": "log", "\\ln": "ln", "\\sin": "sin", "\\cos": "cos", "\\tan": "tan", "\\max": "max", "\\min": "min",
    "\\ldots": "…", "\\dots": "…", "\\cdots": "⋯", "\\quad": " ", "\\,": " ", "\\;": " ", "\\left": "", "\\right": "",
  };

  // Light LaTeX → Unicode/HTML. Input is already escaped.
  function tex(s) {
    s = s.replace(/\\(?:text|mathrm|mathbf|operatorname)\{([^{}]*)\}/g, "$1");
    s = s.replace(/\\frac\{([^{}]*)\}\{([^{}]*)\}/g, "($1)/($2)");
    s = s.replace(/\\sqrt\{([^{}]*)\}/g, "√($1)");
    s = s.replace(/\\[A-Za-z]+|\\[,;]/g, (m) => (m in TEX ? TEX[m] : m.slice(1)));
    s = s.replace(/\^\{([^{}]*)\}|\^(\S)/g, (_, a, b) => `<sup>${a ?? b}</sup>`);
    s = s.replace(/_\{([^{}]*)\}|_([A-Za-z0-9])/g, (_, a, b) => `<sub>${a ?? b}</sub>`);
    return s.replace(/[{}]/g, "");
  }

  function inline(text) {
    const stash = [];
    const keep = (html) => `\u0001${stash.push(html) - 1}\u0001`;
    let s = esc(text);
    s = s.replace(/`([^`\n]+)`/g, (_, c) => keep(`<code>${c}</code>`));
    // Inline math only when it actually looks like math, so "$5 and $10" stays as text.
    s = s.replace(/\\\((.+?)\\\)/g, (_, m) => keep(`<span class="math">${tex(m)}</span>`));
    s = s.replace(/\$([^\s$](?:[^$\n]*?[^\s$])?)\$/g, (all, m) =>
      /[\\^_{}=+]/.test(m) || /^[A-Za-z]$/.test(m) ? keep(`<span class="math">${tex(m)}</span>`) : all);
    s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, (_, t, u) =>
      keep(`<a href="${u}" target="_blank" rel="noopener noreferrer">${t}</a>`));
    s = s.replace(/\*\*(.+?)\*\*|__(.+?)__/g, (_, a, b) => `<strong>${a ?? b}</strong>`);
    s = s.replace(/(^|[^*\w])\*(?!\s)(.+?)(?<!\s)\*(?!\*)/g, "$1<em>$2</em>");
    s = s.replace(/(^|\W)_(?!\s)(.+?)(?<!\s)_(?!\w)/g, "$1<em>$2</em>");
    s = s.replace(/~~(.+?)~~/g, "<del>$1</del>");
    return s.replace(/\u0001(\d+)\u0001/g, (_, i) => stash[+i]);
  }

  function table(rows) {
    const cells = (r) => r.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
    const head = cells(rows[0]);
    const body = rows.slice(2).map(cells);
    return `<table><thead><tr>${head.map((h) => `<th>${inline(h)}</th>`).join("")}</tr></thead><tbody>${body
      .map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join("")}</tr>`).join("")}</tbody></table>`;
  }

  function render(src) {
    const lines = src.replace(/\r\n?/g, "\n").split("\n");
    const out = [];
    let para = [];
    let list = null; // { type, items }

    const flushPara = () => { if (para.length) { out.push(`<p>${para.map(inline).join("<br>")}</p>`); para = []; } };
    const flushList = () => {
      if (list) { out.push(`<${list.type}>${list.items.map((i) => `<li>${inline(i)}</li>`).join("")}</${list.type}>`); list = null; }
    };
    const flush = () => { flushPara(); flushList(); };

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];

      const fence = line.match(/^\s*(```|~~~)\s*([\w+#.-]*)/);
      if (fence) {
        flush();
        const code = [];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith(fence[1])) code.push(lines[i++]);
        const lang = fence[2] || "";
        out.push(`<div class="codeblock"><div class="codeblock-head"><span>${esc(lang)}</span><button class="copy-btn" type="button">Copy</button></div><pre><code>${esc(code.join("\n"))}</code></pre></div>`);
        continue;
      }

      if (/^\s*\$\$/.test(line)) {
        flush();
        let body = line.replace(/^\s*\$\$/, "");
        if (body.trim().endsWith("$$")) body = body.replace(/\$\$\s*$/, "");
        else { while (++i < lines.length && !lines[i].includes("$$")) body += " " + lines[i]; if (i < lines.length) body += " " + lines[i].replace(/\$\$.*/, ""); }
        out.push(`<p class="math math-block">${tex(esc(body.trim()))}</p>`);
        continue;
      }

      if (/^\s*\|.*\|\s*$/.test(line) && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1] || "")) {
        flush();
        const rows = [line];
        while (i + 1 < lines.length && /^\s*\|/.test(lines[i + 1])) rows.push(lines[++i]);
        out.push(table(rows));
        continue;
      }

      let m;
      if ((m = line.match(/^(#{1,6})\s+(.*)$/))) { flush(); const n = Math.min(m[1].length + 1, 4); out.push(`<h${n}>${inline(m[2])}</h${n}>`); continue; }
      if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { flush(); out.push("<hr>"); continue; }
      if ((m = line.match(/^\s*>\s?(.*)$/))) { flush(); out.push(`<blockquote>${inline(m[1])}</blockquote>`); continue; }
      if ((m = line.match(/^\s*[-*+•]\s+(.*)$/))) {
        flushPara(); if (list && list.type !== "ul") flushList(); list ??= { type: "ul", items: [] }; list.items.push(m[1]); continue;
      }
      if ((m = line.match(/^\s*\d+[.)]\s+(.*)$/))) {
        flushPara(); if (list && list.type !== "ol") flushList(); list ??= { type: "ol", items: [] }; list.items.push(m[1]); continue;
      }
      if (!line.trim()) { flush(); continue; }
      if (list && /^\s{2,}\S/.test(line)) { list.items[list.items.length - 1] += " " + line.trim(); continue; }
      flushList();
      para.push(line);
    }
    flush();
    return out.join("");
  }

  window.renderMarkdown = render;
})();
