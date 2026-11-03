// xwindow's page agent. A program in a page opens a window, and the window is
// the page's canvas. The program's host imports this module on the page's
// thread, where the canvas's events fire, and calls
// `start({ memory, address, canvas })` with the program's shared memory and
// the address of its block: a mailbox, then 24 bytes on a queue, then 44
// bytes on a redraw word.
//
// The agent serves the mailbox, whose commands the generated wire
// (xwindow_wire.mjs) runs against the page's objects. It posts each event it
// sees to the queue as an XwEvent, which the program reads without a call.
// Positions and sizes it posts are in physical pixels.

import { Wire, Queue, serve, post_XwEvent } from "./xwindow_wire.mjs";

const QUEUE = 24;
const REDRAW = 44;

// The page's objects, under the handles the program names them by.
const WINDOW = 1;
const DOCUMENT = 2;
const CANVAS = 3;
const STYLE = 4;
const AGENT = 5;

const PHASE = { STARTED: 0, MOVED: 1, ENDED: 2, CANCELLED: 3 };

const encoder = new TextEncoder();

// A UTF-16 index in `text` as a UTF-8 byte offset, for an IME's cursor.
const utf8Offset = (text, index) => (index < 0 ? -1 : encoder.encode(text.slice(0, index)).length);

export function start({ memory, address, canvas }) {
  if (!canvas) {
    console.error("xwindow: the host gave the agent no canvas");
    return;
  }
  const queue = new Queue(memory, address + QUEUE);

  // The ring the program reads its events from is finite, and a program busy in a long collection or a shader build reads none
  // for a while. Events that only say where the pointer is, or add to how far a wheel or a pinch has gone, are held once the
  // ring is three quarters full: the newest position, the sums of the rest. They go in when the program has read some. Any other
  // event, a press, a key, a resize, the redraw, has the whole ring, and the held ones go in first, so none of those is lost
  // and a press still lands where the pointer was.
  const room = () => {
    const w = new Int32Array(memory.buffer, address + QUEUE, 5);
    const tail = Atomics.load(w, 0) >>> 0, head = Atomics.load(w, 1) >>> 0, capacity = Atomics.load(w, 3) >>> 0;
    return { free: capacity - ((tail - head + capacity) % capacity) - 4, capacity };
  };
  const held = new Map();
  // What an event is held under, or null for one that is never held.
  const holdKey = (e) => {
    switch (e.kind) {
      case "cursor-moved": return `move ${e.device}`;
      case "touch": return e.phase === PHASE.MOVED ? `touch ${e.device}` : null;
      case "touchpad-pressure": return "pressure";
      case "mouse-motion": return "motion";
      case "mouse-wheel": return `wheel ${e.unit}`;
      case "pinch-gesture": return e.phase === PHASE.ENDED ? null : "pinch";
      default: return null;
    }
  };
  const hold = (key, e) => {
    const before = held.get(key);
    if (before && (e.kind === "mouse-motion" || e.kind === "mouse-wheel")) {
      e = { ...e, x: before.x + e.x, y: before.y + e.y };
    } else if (before && e.kind === "pinch-gesture") {
      e = { ...e, phase: before.phase, scale: before.scale + e.scale };
    }
    held.set(key, e);
  };
  // Posts what was held, oldest first, as far as the ring has room.
  const release = () => {
    for (const [key, e] of held) {
      if (!post_XwEvent(queue, e)) return false;
      held.delete(key);
    }
    return true;
  };
  let warned = 0;
  const post = (event) => {
    const key = holdKey(event);
    if (key !== null) {
      const { free, capacity } = room();
      if (held.size > 0 || free < capacity / 4) {
        hold(key, event);
        if (free >= capacity / 4) release();
        return true;
      }
    } else if (held.size > 0) {
      release();
    }
    const posted = post_XwEvent(queue, event);
    if (!posted && Date.now() - warned > 2000) {
      warned = Date.now();
      console.warn(`xwindow: the program is not reading its events, and ${event.kind} was lost`);
    }
    return posted;
  };
  const ratio = () => globalThis.devicePixelRatio || 1;
  const at = (e) => [e.offsetX * ratio(), e.offsetY * ratio()];
  const modifiers = (e) =>
    (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);
  const touch = (e) => e.pointerType === "touch";

  canvas.hidden = false;
  if (canvas.tabIndex < 0) canvas.tabIndex = 0;
  canvas.style.touchAction = "none"; // pointer events for touch, not scrolling
  canvas.style.outline = "none";

  // Requests a browser takes only during a user's input wait for the next.
  let gated = [];
  const settle = (request) => {
    try {
      const done = request();
      if (done && done.catch) done.catch(() => {});
    } catch {}
  };
  const gate = (request) => {
    if (navigator.userActivation?.isActive) settle(request);
    else gated.push(request);
  };
  const runGated = () => {
    const now = gated;
    gated = [];
    now.forEach(settle);
  };

  // Size and scale. The canvas's drawing buffer may belong to a GPU agent by
  // now, which sizes it from the size posted here.
  let size = [0, 0];
  const resized = (width, height) => {
    width = Math.max(1, Math.round(width));
    height = Math.max(1, Math.round(height));
    if (width === size[0] && height === size[1]) return;
    size = [width, height];
    post({ kind: "resized", width, height, scale: ratio() });
  };
  const measure = () => {
    const rect = canvas.getBoundingClientRect();
    resized(rect.width * ratio(), rect.height * ratio());
  };
  new ResizeObserver((entries) => {
    for (const entry of entries) {
      const box = entry.devicePixelContentBoxSize?.[0];
      if (box) resized(box.inlineSize, box.blockSize);
      else resized(entry.contentRect.width * ratio(), entry.contentRect.height * ratio());
    }
  }).observe(canvas);
  const screenChanged = () => post({ kind: "screen", width: screen.width, height: screen.height });
  globalThis.addEventListener("resize", screenChanged);
  // A change of scale: the query for the current resolution stops matching.
  const watchScale = () => {
    const query = globalThis.matchMedia(`(resolution: ${ratio()}dppx)`);
    query.addEventListener("change", () => {
      post({ kind: "scale-factor-changed", scale: ratio() });
      watchScale();
    }, { once: true });
  };

  // The canvas and the IME's textarea are one window: focus moving between
  // them is no change.
  let hasFocus = null;
  const focused = (on) => {
    if (on === hasFocus) return;
    hasFocus = on;
    post({ kind: "focused", on });
  };
  const focusChange = (on) => (e) => {
    if (e.relatedTarget && (e.relatedTarget === canvas || e.relatedTarget === textarea)) return;
    focused(on);
  };
  canvas.addEventListener("focus", focusChange(true));
  canvas.addEventListener("blur", focusChange(false));
  document.addEventListener("visibilitychange", () =>
    post({ kind: "occluded", on: document.visibilityState === "hidden" }));
  globalThis.addEventListener("pagehide", (e) =>
    post({ kind: e.persisted ? "suspended" : "close-requested" }));
  globalThis.addEventListener("pageshow", (e) => {
    if (e.persisted) post({ kind: "resumed" });
  });
  const dark = globalThis.matchMedia("(prefers-color-scheme: dark)");
  dark.addEventListener("change", () => post({ kind: "theme-changed", on: dark.matches }));
  document.addEventListener("fullscreenchange", () =>
    post({ kind: "fullscreen-changed", on: document.fullscreenElement === canvas }));

  // Pointers. A touch is a pointer of type touch; its force is its pressure.
  canvas.addEventListener("pointerenter", (e) => {
    if (!touch(e)) post({ kind: "cursor-entered", device: e.pointerId });
  });
  canvas.addEventListener("pointerleave", (e) => {
    if (!touch(e)) post({ kind: "cursor-left", device: e.pointerId });
  });
  canvas.addEventListener("pointermove", (e) => {
    const coalesced = e.getCoalescedEvents ? e.getCoalescedEvents() : [];
    for (const m of coalesced.length ? coalesced : [e]) {
      const [x, y] = at(m);
      if (touch(m)) {
        post({ kind: "touch", device: m.pointerId, phase: PHASE.MOVED, x, y, pressure: m.pressure });
      } else {
        post({ kind: "cursor-moved", device: m.pointerId, x, y });
      }
      if (document.pointerLockElement === canvas) {
        post({ kind: "mouse-motion", x: m.movementX * ratio(), y: m.movementY * ratio() });
      }
    }
    // A mouse reports 0.5 while a button is down; anything else is a
    // pressure-sensitive surface.
    if (e.pointerType === "mouse" && e.pressure !== 0 && e.pressure !== 0.5) {
      post({ kind: "touchpad-pressure", pressure: e.pressure, stage: e.pressure > 0.5 ? 2 : 1 });
    }
  });
  const button = (pressed) => (e) => {
    if (pressed) {
      if (document.activeElement !== imeTarget()) imeTarget().focus();
      runGated();
    }
    const [x, y] = at(e);
    if (touch(e)) {
      const phase = pressed ? PHASE.STARTED : PHASE.ENDED;
      post({ kind: "touch", device: e.pointerId, phase, x, y, pressure: e.pressure });
    } else {
      post({ kind: "mouse-input", device: e.pointerId, button: e.button, on: pressed });
    }
  };
  canvas.addEventListener("pointerdown", button(true));
  canvas.addEventListener("pointerup", button(false));
  canvas.addEventListener("pointercancel", (e) => {
    if (touch(e)) post({ kind: "touch", device: e.pointerId, phase: PHASE.CANCELLED, x: 0, y: 0 });
  });
  canvas.addEventListener("contextmenu", (e) => e.preventDefault());

  // The wheel, and the trackpad pinch browsers report as a wheel with control.
  let pinching = null;
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    if (e.ctrlKey && e.deltaMode === 0) {
      const phase = pinching ? PHASE.MOVED : PHASE.STARTED;
      clearTimeout(pinching);
      pinching = setTimeout(() => {
        pinching = null;
        post({ kind: "pinch-gesture", phase: PHASE.ENDED, scale: 0 });
      }, 150);
      post({ kind: "pinch-gesture", phase, scale: -e.deltaY / 100 });
      return;
    }
    const scale = e.deltaMode === 0 ? ratio() : 1;
    post({ kind: "mouse-wheel", unit: e.deltaMode, x: e.deltaX * scale, y: e.deltaY * scale });
  }, { passive: false });

  // Keys, and the modifiers they change, with the side each is held on. None
  // are held to begin with.
  let lastModifiers = 0;
  let sides = 0;
  const SIDE = { Shift: 1, Control: 4, Alt: 16, Meta: 64 };
  // The paste shortcut's presses, which the paste that follows stands for.
  const pasteKey = (e) =>
    (((e.key === "v" || e.key === "V") && (e.ctrlKey || e.metaKey) && !e.altKey) ||
      (e.key === "Insert" && e.shiftKey));
  const pasteCodes = new Set();
  const key = (pressed) => (e) => {
    if (pressed) runGated();
    if (pressed && pasteKey(e)) {
      pasteCodes.add(e.code);
      return;
    }
    if (!pressed && pasteCodes.delete(e.code)) return;
    const side = SIDE[e.key];
    if (side && (e.location === 1 || e.location === 2)) {
      const bit = e.location === 1 ? side : side * 2;
      sides = pressed ? sides | bit : sides & ~bit;
    }
    post({
      kind: "keyboard-input",
      on: pressed,
      code: e.code,
      key: e.key,
      location: e.location,
      repeat: e.repeat,
      synthetic: !e.isTrusted,
    });
    const mods = modifiers(e);
    if (((mods << 8) | sides) !== lastModifiers) {
      lastModifiers = (mods << 8) | sides;
      post({ kind: "modifiers-changed", modifiers: mods, sides });
    }
    // Keys the program handles should not also scroll or navigate the page.
    // While text input is allowed they keep their default action, which is
    // how typed text reaches the input method.
    if (!e.metaKey && !e.ctrlKey && !imeAllowed) e.preventDefault();
  };
  const listenKeys = (target) => {
    target.addEventListener("keydown", key(true));
    target.addEventListener("keyup", key(false));
  };
  listenKeys(canvas);

  // Text input through an input method: EditContext where the browser has
  // it, elsewhere a textarea out of sight that takes focus from the canvas
  // while text input is allowed.
  let editContext = null;
  let textarea = null;
  let imeAllowed = false;
  let imeArea = [0, 0, 1, 1];
  const imeTarget = () => (textarea && !textarea.disabled ? textarea : canvas);
  const preedit = (text, start, end) =>
    post({ kind: "ime-preedit", text, start: utf8Offset(text, start), end: utf8Offset(text, end) });
  const commit = (text) => post({ kind: "ime-commit", text });
  const placeIme = () => {
    const rect = canvas.getBoundingClientRect();
    const [x, y, w, h] = imeArea;
    const bounds = new DOMRect(rect.left + x, rect.top + y, w, h);
    if (editContext) {
      editContext.updateControlBounds(rect);
      editContext.updateSelectionBounds(bounds);
    }
    if (textarea) {
      Object.assign(textarea.style, {
        left: `${bounds.left + globalThis.scrollX}px`,
        top: `${bounds.top + globalThis.scrollY}px`,
        height: `${Math.max(1, bounds.height)}px`,
      });
    }
  };
  const allowIme = (allowed) => {
    imeAllowed = allowed;
    if (!allowed) {
      if (canvas.editContext) canvas.editContext = null;
      if (textarea) {
        const had = document.activeElement === textarea;
        textarea.disabled = true;
        if (had) canvas.focus();
      }
      post({ kind: "ime-disabled" });
      return;
    }
    if ("EditContext" in globalThis) {
      if (!editContext) {
        editContext = new EditContext();
        let composing = false;
        const clear = () => {
          editContext.updateText(0, editContext.text.length, "");
          editContext.updateSelection(0, 0);
        };
        editContext.addEventListener("compositionstart", () => { composing = true; });
        editContext.addEventListener("compositionend", () => {
          composing = false;
          commit(editContext.text);
          clear();
        });
        editContext.addEventListener("textupdate", () => {
          const text = editContext.text;
          if (composing) preedit(text, editContext.selectionStart, editContext.selectionEnd);
          else {
            commit(text);
            clear();
          }
        });
      }
      canvas.editContext = editContext;
    } else {
      if (!textarea) {
        textarea = document.createElement("textarea");
        textarea.setAttribute("autocomplete", "off");
        textarea.setAttribute("autocapitalize", "off");
        textarea.setAttribute("spellcheck", "false");
        Object.assign(textarea.style, {
          position: "absolute", width: "1px", opacity: "0", padding: "0", border: "0",
          resize: "none", overflow: "hidden", pointerEvents: "none",
        });
        document.body.appendChild(textarea);
        listenKeys(textarea);
        textarea.addEventListener("focus", focusChange(true));
        textarea.addEventListener("blur", focusChange(false));
        textarea.addEventListener("compositionupdate", (e) => {
          const text = e.data || "";
          preedit(text, text.length, text.length);
        });
        textarea.addEventListener("compositionend", (e) => {
          commit(e.data || "");
          textarea.value = "";
        });
        textarea.addEventListener("input", (e) => {
          if (!e.isComposing && e.data) commit(e.data);
          if (!e.isComposing) textarea.value = "";
        });
      }
      textarea.disabled = false;
      if (document.activeElement === canvas) textarea.focus();
    }
    placeIme();
    post({ kind: "ime-enabled" });
  };

  // A paste is how a page reads the clipboard. Each type's bytes go in
  // pieces small enough for the queue, the first of each marked, waiting for
  // room when it is full; then the paste itself. Pastes go in turn.
  const PIECE = 12288;
  const base64 = (bytes) => {
    let text = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    }
    return btoa(text);
  };
  const send = (event) =>
    new Promise((done) => {
      const again = () => (post(event) ? done() : setTimeout(again, 16));
      again();
    });
  let pasting = Promise.resolve();
  document.addEventListener(
    "paste",
    (e) => {
      if (document.activeElement !== canvas && document.activeElement !== textarea) return;
      e.preventDefault();
      const data = e.clipboardData;
      // Read now: the event's data is gone once it returns, its files are not.
      const texts = [...(data?.types || [])]
        .filter((type) => type !== "Files")
        .map((type) => [type, encoder.encode(data.getData(type))]);
      const files = [...(data?.files || [])];
      pasting = pasting.then(async () => {
        const read = (file) => file.arrayBuffer().then((b) => [file.type || "application/octet-stream", new Uint8Array(b)]);
        for (const [type, bytes] of texts.concat(await Promise.all(files.map(read)))) {
          for (let at = 0; at === 0 || at < bytes.length; at += PIECE) {
            await send({ kind: "paste-data", key: type, on: at === 0, text: base64(bytes.subarray(at, at + PIECE)) });
          }
        }
        await send({ kind: "paste" });
      });
    },
    true,
  );

  // Files dragged onto the canvas. A page learns a file's name only when it
  // is dropped, and never its path.
  canvas.addEventListener("dragenter", (e) => {
    e.preventDefault();
    for (const item of e.dataTransfer?.items || []) {
      if (item.kind === "file") post({ kind: "hovered-file", text: "" });
    }
  });
  canvas.addEventListener("dragover", (e) => e.preventDefault());
  canvas.addEventListener("dragleave", (e) => {
    if (!canvas.contains(e.relatedTarget)) post({ kind: "hovered-file-cancelled" });
  });
  canvas.addEventListener("drop", (e) => {
    e.preventDefault();
    for (const file of e.dataTransfer?.files || []) post({ kind: "dropped-file", text: file.name });
  });

  // A command that sizes the canvas posts the size it lays out to, so the
  // program has it once its commands have run, not a frame later. A canvas the
  // page sizes, marked data-xwindow="fit", is the window's size whatever the
  // program asks of it: the window is what the page lays out.
  const cssSize = (w, h, first, second) => {
    if (canvas.dataset.xwindow === "fit") return;
    canvas.style[first] = w > 0 ? `${w}px` : "";
    canvas.style[second] = h > 0 ? `${h}px` : "";
    if (!canvas.hidden) measure();
  };

  // The representations a write is gathering.
  let clipboardItems = [];


  // Gamepad state is sampled on the page thread; a failed post is retried.
  let gamepadsEnabled = false;
  let gamepadSerial = 0;
  const gamepads = new Map();
  const disconnected = [];
  const disconnectGamepad = (index) => {
    const previous = gamepads.get(index);
    if (previous) {
      disconnected.push({ kind: "gamepad-disconnected", device: previous.device });
      gamepads.delete(index);
    }
  };
  globalThis.addEventListener("gamepaddisconnected", (event) => disconnectGamepad(event.gamepad.index));
  // A slot may reconnect between samples; its next connection gets a new token.
  globalThis.addEventListener("gamepadconnected", (event) => disconnectGamepad(event.gamepad.index));
  const sampleGamepads = () => {
    if (!gamepadsEnabled) return;
    while (disconnected.length && post(disconnected[0])) disconnected.shift();
    let pads;
    try { pads = navigator.getGamepads(); } catch { return; }
    const present = new Set();
    for (const pad of pads) {
      if (!pad || !pad.connected) continue;
      present.add(pad.index);
      let entry = gamepads.get(pad.index);
      if (!entry) { entry = { device: ++gamepadSerial, last: "" }; gamepads.set(pad.index, entry); }
      const standard = pad.mapping === "standard";
      const buttons = standard ? pad.buttons.slice(0, 17) : [];
      const record = {
        kind: "gamepad-snapshot", device: entry.device, gamepadIndex: pad.index,
        text: pad.id, gamepadButtons: buttons.map((b) => b.value),
        gamepadAxes: standard ? Array.from(pad.axes).slice(0, 4) : [],
        gamepadPressed: buttons.reduce((mask, b, i) => mask | (b.pressed ? 1 << i : 0), 0),
        gamepadRumble: Boolean(pad.vibrationActuator?.playEffect &&
          (!pad.vibrationActuator.effects || pad.vibrationActuator.effects.includes("dual-rumble"))),
      };
      const signature = JSON.stringify(record);
      if (entry.last !== signature && post(record)) entry.last = signature;
    }
    for (const index of gamepads.keys()) if (!present.has(index)) disconnectGamepad(index);
    while (disconnected.length && post(disconnected[0])) disconnected.shift();
  };

  // XwAgent, which the program's commands call.
  const agent = {
    enableGamepads: () => {
      let available = typeof navigator.getGamepads === "function", error = "";
      if (available) { try { navigator.getGamepads(); } catch (e) { available = false; error = String(e.message || e); } }
      if (!available && !error) error = "The browser Gamepad API is unavailable";
      gamepadsEnabled = available;
      post({ kind: "gamepad-status", on: available, text: error });
      sampleGamepads();
    },
    rumbleGamepad: (index, strong, weak, seconds) => {
      let accepted = false;
      try {
        const pad = navigator.getGamepads()[index], actuator = pad?.vibrationActuator;
        if (pad?.connected && actuator?.playEffect) {
          const pending = seconds === 0 && actuator.reset ? actuator.reset() : actuator.playEffect("dual-rumble", {
            duration: seconds * 1000, strongMagnitude: strong, weakMagnitude: weak,
          });
          pending?.catch(() => {});
          accepted = true;
        }
      } catch {}
      post({ kind: "gamepad-rumble", on: accepted });
    },
    setSize: (w, h) => cssSize(w, h, "width", "height"),
    setMinSize: (w, h) => cssSize(w, h, "minWidth", "minHeight"),
    setMaxSize: (w, h) => cssSize(w, h, "maxWidth", "maxHeight"),
    setVisible: (visible) => { canvas.hidden = !visible; },
    setFullscreen: (on) => {
      if (on) gate(() => canvas.requestFullscreen());
      else if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    },
    setCursorGrab: (locked) => {
      if (locked) gate(() => canvas.requestPointerLock());
      else if (document.pointerLockElement === canvas) document.exitPointerLock();
    },
    // The pixels are the program's memory, read while this command runs.
    setCursorImage: (rgba, width, height, hotX, hotY) => {
      const pixels = new Uint8ClampedArray(rgba.length);
      pixels.set(rgba);
      const image = new OffscreenCanvas(width, height);
      image.getContext("2d").putImageData(new ImageData(pixels, width, height), 0, 0);
      image.convertToBlob().then((blob) => {
        canvas.style.cursor = `url(${URL.createObjectURL(blob)}) ${hotX} ${hotY}, auto`;
      });
    },
    focus: () => imeTarget().focus(),
    setImeAllowed: allowIme,
    setImeArea: (x, y, w, h) => {
      imeArea = [x, y, w, h];
      placeIme();
    },
    // A browser writes the clipboard only in answer to the user.
    writeClipboard: (text) => gate(() => navigator.clipboard?.writeText(text)),
    // Copied now, from the program's memory, and written together.
    clipboardItem: (type, bytes) => clipboardItems.push([type, new Blob([bytes.slice()], { type })]),
    writeClipboardItems: () => {
      const items = Object.fromEntries(clipboardItems);
      clipboardItems = [];
      gate(() => navigator.clipboard?.write([new ClipboardItem(items)]));
    },
  };

  // A redraw the program asked for since the last frame is answered in this
  // one.
  const frame = () => {
    sampleGamepads();
    const words = new Int32Array(memory.buffer, address + REDRAW, 1);
    // Taken only once it is posted: one the ring had no room for is asked for again at the next frame.
    if (Atomics.exchange(words, 0, 0) !== 0 && !post({ kind: "redraw-requested" })) Atomics.store(words, 0, 1);
    if (held.size > 0 && room().free >= room().capacity / 4) release();
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);

  // The window as it is.
  screenChanged();
  watchScale();
  measure();
  focused(document.activeElement === canvas);
  post({ kind: "theme-changed", on: dark.matches });

  const wire = new Wire(memory, new Map([
    [WINDOW, globalThis],
    [DOCUMENT, document],
    [CANVAS, canvas],
    [STYLE, canvas.style],
    [AGENT, agent],
  ]));
  serve(wire, address);
}
