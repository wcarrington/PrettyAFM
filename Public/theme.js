// Light / dark / match-system. Loaded in <head> so the right theme applies before first paint.
(() => {
  const KEY = "prettyafm.theme";
  const root = document.documentElement;
  const system = matchMedia("(prefers-color-scheme: dark)");
  let choice = "system";
  try { choice = localStorage.getItem(KEY) || "system"; } catch { /* storage unavailable */ }
  if (!["system", "light", "dark"].includes(choice)) choice = "system";

  function apply() {
    const theme = choice === "system" ? (system.matches ? "dark" : "light") : choice;
    root.dataset.theme = theme;
    root.style.colorScheme = theme;
    document.querySelectorAll("[data-theme-choice]").forEach((b) =>
      b.setAttribute("aria-checked", String(b.dataset.themeChoice === choice)));
  }
  apply();
  system.addEventListener("change", apply);
  document.addEventListener("DOMContentLoaded", apply);
  document.addEventListener("click", (e) => {
    const b = e.target.closest("[data-theme-choice]");
    if (!b) return;
    choice = b.dataset.themeChoice;
    try { localStorage.setItem(KEY, choice); } catch { /* ignore */ }
    apply();
  });
  // Arrow keys move between the three options.
  document.addEventListener("keydown", (e) => {
    const b = e.target.closest?.("[data-theme-choice]");
    if (!b || (e.key !== "ArrowLeft" && e.key !== "ArrowRight")) return;
    e.preventDefault();
    const all = [...b.parentElement.querySelectorAll("[data-theme-choice]")];
    const next = all[(all.indexOf(b) + (e.key === "ArrowRight" ? 1 : all.length - 1)) % all.length];
    next.focus(); next.click();
  });
})();
