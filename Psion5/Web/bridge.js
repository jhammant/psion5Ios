// Glue between the native app and WindEmu's Emscripten build.
(function () {
  "use strict";

  const DEVICE_W = 695, DEVICE_H = 305;
  const device = document.getElementById("device");
  const statusEl = document.getElementById("status");

  function nativeLog(message) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.log;
    if (handler) handler.postMessage(String(message));
  }

  // Insets the app wants kept clear (the camera cutout), set via psion.setInsets.
  // The bottom inset is left out: the home indicator auto-hides.
  let insets = { top: 0, left: 0, right: 0 };

  // Scale the whole device to fill the screen. Emscripten maps touches
  // through getBoundingClientRect, so a CSS transform keeps taps accurate.
  function fit() {
    const w = innerWidth - insets.left - insets.right;
    const h = innerHeight - insets.top;
    const scale = Math.min(w / DEVICE_W, h / DEVICE_H);
    device.style.left = `${insets.left + w / 2}px`;
    device.style.top = `${insets.top + h / 2}px`;
    device.style.transform = `translate(-50%, -50%) scale(${scale})`;
  }
  window.addEventListener("resize", fit);
  fit();

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
  };

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
