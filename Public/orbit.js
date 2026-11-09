// Concentric-circle animation behind the composer.
// Idle: dashed rings drift slowly outward, three dots orbit the main circle, the dotted ring breathes.
// Active (a reply is streaming): everything speeds up, and each burst of tokens sends a pulse ring outward.
(() => {
  const svg = document.getElementById("orbit");
  const stage = document.getElementById("stage");
  if (!svg || !stage) return;
  const NS = "http://www.w3.org/2000/svg";
  const make = (tag, cls, parent = svg) => {
    const n = document.createElementNS(NS, tag);
    if (cls) n.setAttribute("class", cls);
    parent.append(n);
    return n;
  };

  const RINGS = 9;
  const ringGroup = make("g");
  const rings = Array.from({ length: RINGS }, () => make("circle", "ring", ringGroup));
  const pulseGroup = make("g");
  const pulsePool = Array.from({ length: 6 }, () => make("circle", "pulse", pulseGroup));
  const dotted = make("circle", "dotted");
  const main = make("circle", "main");
  const dots = [make("circle", "dot-l"), make("circle", "dot-m"), make("circle", "dot-s")];

  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  let w = 0, h = 0, cx = 0, cy = 0, R = 0, targetR = 0, far = 0;
  let speed = 1, targetSpeed = 1, energy = 0, phase = 0, clock = 0, last = 0, lastPulse = -1;
  const pulses = []; // start times

  function measure() {
    const r = stage.getBoundingClientRect();
    w = r.width; h = r.height;
    svg.setAttribute("viewBox", `0 0 ${w} ${h}`);
    cx = w / 2; cy = h / 2;
    // On phones the circle is allowed to bleed past the sides so the composer and disclaimer fit inside it.
    targetR = w < 520 ? Math.min(w * 0.78, h * 0.37) : Math.max(150, Math.min(w * 0.44, h * 0.43, 560));
    if (!R) R = targetR;
    far = Math.hypot(w, h) / 2 + 40;
    stage.style.setProperty("--R", targetR.toFixed(1) + "px");
    if (reduce.matches) draw();
  }

  function draw() {
    const active = Math.min(1, (speed - 1) / 2.5);
    // Main circle breathes gently; token bursts swell it a little.
    const mainR = R * (1 + 0.008 * Math.sin(clock * 2.4) * active + 0.016 * energy);
    main.setAttribute("cx", cx); main.setAttribute("cy", cy); main.setAttribute("r", mainR);

    // The dotted ring drifts in and out just beyond the main circle.
    const dottedR = R * (1.075 + 0.055 * Math.sin(phase * 0.55));
    dotted.setAttribute("cx", cx); dotted.setAttribute("cy", cy); dotted.setAttribute("r", dottedR);

    // Dashed rings move outward and fade; one replaces the next seamlessly.
    const inner = R * 1.16;
    rings.forEach((c, i) => {
      const f = (i / RINGS + phase * 0.018) % 1;
      const r = inner + f * (far - inner);
      const fadeIn = Math.min(1, f / 0.08);
      c.setAttribute("cx", cx); c.setAttribute("cy", cy); c.setAttribute("r", r);
      c.style.opacity = (fadeIn * Math.pow(1 - f, 0.9) * (0.95 - 0.25 * (i % 2))).toFixed(3);
    });

    // Pulse rings: solid, quick, only while streaming.
    pulsePool.forEach((c, i) => {
      const t0 = pulses[i];
      if (t0 == null) { c.style.opacity = 0; return; }
      const f = (clock - t0) / 1.8;
      if (f >= 1) { c.style.opacity = 0; return; }
      c.setAttribute("cx", cx); c.setAttribute("cy", cy);
      c.setAttribute("r", mainR + f * R * 0.9);
      c.style.opacity = (0.55 * (1 - f) * (1 - f)).toFixed(3);
    });

    // Two dots ride the main circle together; a small one travels the dotted ring the other way.
    const a = -2.3 + phase * 0.16;
    const b = a + 0.38 + 0.1 * Math.sin(phase * 0.21);
    const c = 0.9 - phase * 0.09;
    const swell = 1 + 0.25 * energy;
    place(dots[0], a, mainR, 15 * swell * Math.min(1, R / 320) + 4);
    place(dots[1], b, mainR, 9 * swell * Math.min(1, R / 320) + 3);
    place(dots[2], c, dottedR, 4.5);
  }
  function place(dot, angle, radius, size) {
    dot.setAttribute("cx", cx + Math.cos(angle) * radius);
    dot.setAttribute("cy", cy + Math.sin(angle) * radius);
    dot.setAttribute("r", size);
  }

  function frame(now) {
    const dt = Math.min(0.05, last ? (now - last) / 1000 : 0.016);
    last = now;
    clock += dt;
    speed += (targetSpeed - speed) * Math.min(1, dt * 2.2);
    energy *= Math.exp(-dt * 2.6);
    R += (targetR - R) * Math.min(1, dt * 5);
    phase += dt * speed;
    draw();
    requestAnimationFrame(frame);
  }

  new ResizeObserver(measure).observe(stage);
  measure();
  if (reduce.matches) draw(); else requestAnimationFrame(frame);

  window.Orbit = {
    setActive(on) {
      targetSpeed = on ? 3.6 : 1;
      stage.classList.toggle("is-active", on);
      if (on) this.kick();
    },
    /** Call as output streams in: swells the circle and sends out a pulse ring (rate limited). */
    kick() {
      energy = Math.min(1.2, energy + 0.22);
      if (clock - lastPulse > 0.5) {
        lastPulse = clock;
        const slot = pulses.findIndex((t, i) => t == null || clock - t > 1.8);
        pulses[slot < 0 ? pulses.length % pulsePool.length : slot] = clock;
      }
    },
  };
})();
