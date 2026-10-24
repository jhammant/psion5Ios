// Glue between the native app and WindEmu's Emscripten build.
(function () {
  "use strict";

  const DEVICE_W = 695, DEVICE_H = 305;
  const device = document.getElementById("device");
  const statusEl = document.getElementById("status");

  function post(name, body) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name];
    if (handler) handler.postMessage(body);
  }

  function nativeLog(message) {
    post("log", String(message));
  }

  // Insets the app wants kept clear (the camera cutout), set via psion.setInsets.
  // The bottom inset is left out: the home indicator auto-hides.
  let insets = { top: 0, left: 0, right: 0 };

  // Where the 640x240 LCD sits inside the 695x280 digitiser.
  const LCD = { x: 45, y: 5, width: 640, height: 240 };

  // Scale the whole device to fill the screen. Emscripten maps touches
  // through getBoundingClientRect, so a CSS transform keeps taps accurate.
  // The app is told where the LCD ended up, so it can draw the Claude app
  // over it.
  function fit() {
    const w = innerWidth - insets.left - insets.right;
    const h = innerHeight - insets.top;
    const scale = Math.min(w / DEVICE_W, h / DEVICE_H);
    device.style.left = `${insets.left + w / 2}px`;
    device.style.top = `${insets.top + h / 2}px`;
    device.style.transform = `translate(-50%, -50%) scale(${scale})`;
    const r = device.getBoundingClientRect();
    post("layout", {
      x: r.left + LCD.x * scale, y: r.top + LCD.y * scale,
      width: LCD.width * scale, height: LCD.height * scale, scale,
    });
  }
  window.addEventListener("resize", fit);
  fit();

  // Claude takes Email's place on the silkscreen: the emulator has no modem,
  // so Email can't do anything. The slot is in cover.svg's units (its
  // 2896-wide viewBox spans the 695px device).
  const CLAUDE_SLOT = { left: 1562.5, right: 1895.83, top: 1000 };
  const CLAUDE_ICON = `<g transform="rotate(-6 1745 1100)">
    <defs>
      <pattern id="claude-dots" width="13" height="13" patternUnits="userSpaceOnUse" patternTransform="rotate(30)">
        <circle cx="4" cy="4" r="2.4"/></pattern>
      <path id="claude-bubble" d="M1652,1052 q0,-24 24,-24 h142 q24,0 24,24 v76 q0,24 -24,24 h-108 l-46,34 l12,-34 q-24,0 -24,-24 z"/>
    </defs>
    <use href="#claude-bubble" transform="translate(12,10)"/>
    <use href="#claude-bubble" fill="#ebebeb" stroke="#000" stroke-width="7" stroke-linejoin="round"/>
    <path d="M1662,1132 q4,12 16,14 h138 q16,0 18,-16 z" fill="url(#claude-dots)"/>
    <g transform="translate(1702,1084)" stroke="#000" stroke-linecap="round">
      <path d="M0,-32 V32 M-32,0 H32" stroke-width="10"/>
      <path d="M-20,-20 L20,20 M-20,20 L20,-20" stroke-width="8"/>
    </g>
    <path d="M1752,1066 h62 M1752,1086 h62 M1752,1106 h40" stroke="#000" stroke-width="7" stroke-linecap="round"/>
  </g>`;

  // Swaps Email's picture and label in cover.svg for Claude's. If the
  // artwork isn't laid out as expected, the original is shown unchanged.
  async function drawSilkscreen() {
    const cover = document.getElementById("cover");
    try {
      const svg = new DOMParser().parseFromString(await (await fetch("cover.svg")).text(), "image/svg+xml");
      const label = [...svg.querySelectorAll("text")].find((t) => t.textContent.trim() === "Email");
      const picture = [...svg.querySelectorAll("use")].find((use) => {
        const m = /matrix\(([^)]*)\)/.exec(use.getAttribute("transform") || "");
        const [a, b, c, d, e, f] = m ? m[1].split(/[\s,]+/).map(Number) : [1, 0, 0, 1, 0, 0];
        const x = parseFloat(use.getAttribute("x")) || 0, y = parseFloat(use.getAttribute("y")) || 0;
        const left = a * x + c * y + e, top = b * x + d * y + f;
        return left > CLAUDE_SLOT.left && left < CLAUDE_SLOT.right && top > CLAUDE_SLOT.top;
      });
      if (!label || !picture) throw new Error("Email icon not found");

      const icon = new DOMParser().parseFromString(
        `<svg xmlns="http://www.w3.org/2000/svg">${CLAUDE_ICON}</svg>`, "image/svg+xml").documentElement.firstElementChild;
      picture.replaceWith(svg.importNode(icon, true));
      label.textContent = "Claude";
      label.setAttribute("x", `${(CLAUDE_SLOT.left + CLAUDE_SLOT.right) / 2}px`);
      label.setAttribute("text-anchor", "middle");
      const blob = new Blob([new XMLSerializer().serializeToString(svg)], { type: "image/svg+xml" });
      cover.src = URL.createObjectURL(blob);
    } catch (e) {
      nativeLog("silkscreen left as it was: " + e.message);
      cover.src = "cover.svg";
    }
  }
  drawSilkscreen();

  document.getElementById("claude-icon").addEventListener("click", () => post("claude", "toggle"));
  // Touching the Psion while Claude is open (only the silkscreen is still
  // uncovered) closes Claude, as tapping another app's icon would.
  document.getElementById("canvas").addEventListener("pointerdown", () => post("claude", "psionTouched"), true);

  // The app intercepts hardware keys natively and replays them here, so it
  // can remap keys the Psion lacks. If WebKit ever delivers its own copy of a
  // key as well, drop it so nothing is typed twice.
  let nativeKeysSeen = false;
  for (const type of ["keydown", "keyup", "keypress"]) {
    window.addEventListener(type, (e) => {
      if (e.isTrusted && nativeKeysSeen) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    }, true);
  }

  window.psion = {
    setInsets(top, left, right) {
      insets = { top, left, right };
      fit();
    },

    // keyCode and location follow the DOM KeyboardEvent fields that
    // Emscripten's SDL layer reads (location 2 selects the right-hand key).
    key(keyCode, location, down) {
      nativeKeysSeen = true;
      queue.push({ keyCode, location, down });
      pump();
    },

    // Types text into whatever Psion app is open, as key presses. Returns how
    // many characters it could type; ones the Psion keyboard can't make are
    // skipped.
    typeText(text) {
      let typed = 0;
      const expanded = text.replace(/\r\n?/g, "\n").replace(/\u2026/g, "...");
      for (const ch of expanded) {
        const chord = chordFor(ch);
        if (!chord) continue;
        for (const [keyCode, location] of chord) queue.push({ keyCode, location, down: true });
        for (const [keyCode, location] of chord.slice().reverse()) queue.push({ keyCode, location, down: false });
        typed++;
      }
      typing = typed > 0;
      pump();
      return typed;
    },

    stopTyping() {
      queue.length = 0;
      for (const [id, k] of keyState) {
        if (!k.down) continue;
        k.down = false;
        k.since = performance.now();
        dispatchKey(Math.floor(id / 4), id % 4, false);
      }
      finishTyping();
    },
  };

  // How the Psion 5mx keyboard makes each character, worked out by typing
  // every Shift and Psion combination into Jotter. Psion+, opens Help, so
  // nothing here uses it.
  const SHIFT = [16, 1], PSION = [91, 1];
  const CHORDS = new Map();
  for (let i = 0; i < 26; i++) {
    CHORDS.set(String.fromCharCode(97 + i), [[65 + i, 0]]);
    CHORDS.set(String.fromCharCode(65 + i), [SHIFT, [65 + i, 0]]);
  }
  for (let d = 0; d < 10; d++) CHORDS.set(String(d), [[48 + d, 0]]);
  const PLAIN = { " ": 32, "\n": 13, "\t": 9, "'": 222, ",": 188, ".": 190 };
  const WITH_SHIFT = { "!": 49, '"': 50, "£": 51, "$": 52, "%": 53, "^": 54, "&": 55, "*": 56, "(": 57, ")": 48,
                       "~": 222, "/": 188, "?": 190 };
  const WITH_PSION = { "_": 49, "#": 50, "\\": 51, "@": 52, "<": 53, ">": 54, "[": 55, "]": 56, "{": 57, "}": 48,
                       ":": 222, ";": 76, "-": 79, "=": 80, "+": 73, "€": 69, "÷": 85, "×": 89 };
  for (const [ch, code] of Object.entries(PLAIN)) CHORDS.set(ch, [[code, 0]]);
  for (const [ch, code] of Object.entries(WITH_SHIFT)) CHORDS.set(ch, [SHIFT, [code, 0]]);
  for (const [ch, code] of Object.entries(WITH_PSION)) CHORDS.set(ch, [PSION, [code, 0]]);

  // Close stand-ins for characters the keyboard can't make.
  const SUBSTITUTES = {
    "\u2018": "'", "\u2019": "'", "\u201A": "'", "\u2032": "'", "`": "'",
    "\u201C": '"', "\u201D": '"', "\u201E": '"', "\u2033": '"',
    "\u2013": "-", "\u2014": "-", "\u2012": "-", "\u2212": "-", "\u2022": "-", "\u00B7": "-",
    "\u2026": "...", "\u00A0": " ", "|": "/",
  };

  function chordFor(ch) {
    if (CHORDS.has(ch)) return CHORDS.get(ch);
    const sub = SUBSTITUTES[ch];
    if (sub) return sub.length === 1 ? chordFor(sub) : null;
    // é -> e and so on.
    const base = ch.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
    return base !== ch && base.length === 1 ? chordFor(base) : null;
  }

  // WindEmu reads input once per 1/64 s frame and the Psion scans its
  // keyboard on its own timer, so it misses presses much shorter than that,
  // merges a quick "ll" into one l, and scrambles a burst of keys that all
  // arrive at once. Replay keys in order, holding each key down (and up,
  // between repeats) for MIN_KEY_MS and starting each character key at
  // least MIN_KEY_MS after the last. Normal typing is slower than this, so
  // it only adds delay to bursts.
  const MIN_KEY_MS = 40;
  const MODIFIERS = new Set([16, 17, 18, 91]);
  const queue = [];
  const keyState = new Map();
  let lastCharDown = -Infinity;
  let lastModifierChange = -Infinity;
  let timer = 0;
  let typing = false;

  function finishTyping() {
    if (!typing) return;
    typing = false;
    post("typing", false);
  }

  function pump() {
    while (queue.length) {
      const ev = queue[0];
      const id = ev.keyCode * 4 + ev.location;
      const k = keyState.get(id) || { down: false, since: -Infinity };
      if (ev.down === k.down) {
        queue.shift();
        continue;
      }
      const isModifier = MODIFIERS.has(ev.keyCode);
      const isChar = ev.down && !isModifier;
      let readyAt = k.since + MIN_KEY_MS;
      if (isChar) readyAt = Math.max(readyAt, lastCharDown + MIN_KEY_MS, lastModifierChange + MIN_KEY_MS);
      if (isModifier) readyAt = Math.max(readyAt, lastCharDown + MIN_KEY_MS);
      const wait = readyAt - performance.now();
      if (wait > 0) {
        if (!timer) timer = setTimeout(() => { timer = 0; pump(); }, wait);
        return;
      }
      queue.shift();
      k.down = ev.down;
      k.since = performance.now();
      keyState.set(id, k);
      if (isChar) lastCharDown = k.since;
      if (isModifier) lastModifierChange = k.since;
      dispatchKey(ev.keyCode, ev.location, ev.down);
    }
    finishTyping();
  }

  function dispatchKey(keyCode, location, down) {
    const e = new KeyboardEvent(down ? "keydown" : "keyup", { bubbles: true, cancelable: true, location });
    Object.defineProperty(e, "keyCode", { get: () => keyCode });
    Object.defineProperty(e, "which", { get: () => keyCode });
    document.dispatchEvent(e);
  }

  window.Module = {
    canvas: document.getElementById("canvas"),
    print: (text) => nativeLog(text),
    printErr: (text) => nativeLog("err: " + text),
    setStatus: (text) => {
      statusEl.textContent = text || "";
      statusEl.hidden = !text;
    },
    monitorRunDependencies(left) {
      if (left === 0) Module.setStatus("");
    },
    postRun: [() => { Module.setStatus(""); nativeLog("emulator running"); }],
  };

  window.addEventListener("error", (e) => {
    statusEl.hidden = false;
    statusEl.textContent = "Emulator failed to start: " + e.message;
    nativeLog("error: " + e.message);
  });
})();
