#!/usr/bin/env node
// Check and screenshot the news page in headless Chrome, driven over the DevTools protocol.
//
// Usage: node shoot_page.mjs --page <news-YYYY-MM-DD-HHMM.html> --out <dir>
//          [--chrome <path>] [--port 9388]
//
// Chrome is --chrome, else $CHROME_PATH, else the first chrome, chromium, or msedge found on PATH.
// Writes <dir>/desktop.png (1280px) and <dir>/mobile.png (390px). Prints:
//   - image load status, and whether any image box changes size once images load
//   - whether the page overflows horizontally at 390px
// Exit 1 if the 390px page overflows or an image box shifts when its image loads.
//
// Setup, once: cd <skill>/scripts && npm install

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { PNG } from "pngjs";

const CHROME_NAMES = ["chrome", "google-chrome", "chromium", "chromium-browser", "msedge"];

function findChrome() {
  const exts = process.platform === "win32" ? ["", ".exe"] : [""];
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    for (const name of CHROME_NAMES) {
      for (const ext of exts) {
        const candidate = join(dir, name + ext);
        if (existsSync(candidate)) return candidate;
      }
    }
  }
  return null;
}

const { values } = parseArgs({
  options: {
    page: { type: "string" },
    out: { type: "string" },
    chrome: { type: "string" },
    port: { type: "string", default: "9388" },
  },
});
if (!values.page || !values.out) throw new Error("--page and --out are required");
const CHROME = values.chrome || process.env.CHROME_PATH || findChrome();
if (!CHROME) throw new Error("no Chrome found: pass --chrome or set CHROME_PATH");

const PAGE = pathToFileURL(resolve(values.page)).href;
const OUT = resolve(values.out);
mkdirSync(OUT, { recursive: true });
const PORT = Number(values.port);
const PROXY = "http://127.0.0.1:7890";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const profile = mkdtempSync(join(tmpdir(), "news-shoot-"));

// The hot-linked images need the local proxy. A fresh headless profile does not inherit
// the Windows system proxy, so it is passed explicitly.
const proc = spawn(CHROME, [
  "--headless=new",
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${profile}`,
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-gpu",
  "--hide-scrollbars",
  `--proxy-server=${PROXY}`,
  "about:blank",
], { stdio: "ignore" });
process.on("exit", () => proc.kill());

let wsUrl;
for (let i = 0; i < 80; i++) {
  try {
    const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
    const p = list.find((t) => t.type === "page" && t.url === "about:blank");
    if (p) { wsUrl = p.webSocketDebuggerUrl; break; }
  } catch {}
  await sleep(250);
}
if (!wsUrl) { console.error("no CDP target: check the Chrome path and --port"); process.exit(1); }

const ws = new WebSocket(wsUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let id = 0;
const pending = new Map();
const listeners = [];
ws.addEventListener("message", (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) {
    const { resolve: ok, reject } = pending.get(m.id);
    pending.delete(m.id);
    m.error ? reject(new Error(JSON.stringify(m.error))) : ok(m.result);
  } else if (m.method) for (const l of listeners) l(m);
});
function send(method, params = {}, timeoutMs = 90000) {
  const msgId = ++id;
  ws.send(JSON.stringify({ id: msgId, method, params }));
  return new Promise((ok, fail) => {
    const t = setTimeout(() => { pending.delete(msgId); fail(new Error(`TIMEOUT ${method}`)); }, timeoutMs);
    pending.set(msgId, { resolve: (v) => { clearTimeout(t); ok(v); }, reject: (e) => { clearTimeout(t); fail(e); } });
  });
}
function once(method, timeout = 60000) {
  return new Promise((ok, fail) => {
    const t = setTimeout(() => fail(new Error(`timeout ${method}`)), timeout);
    const l = (m) => { if (m.method === method) { clearTimeout(t); listeners.splice(listeners.indexOf(l), 1); ok(m.params); } };
    listeners.push(l);
  });
}
async function ev(expr, awaitPromise = false) {
  const r = await send("Runtime.evaluate", { expression: expr, awaitPromise, returnByValue: true });
  if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
  return r.result.value;
}

await send("Page.enable");
await send("Runtime.enable");
await send("Network.enable");

const BOXES = `(() => [...document.querySelectorAll('.fig')].map((f, i) => {
  const img = f.querySelector('img');
  const r = f.getBoundingClientRect();
  return {
    i,
    title: img ? img.getAttribute('alt') : null,
    host: img ? new URL(img.src).host : null,
    w: Math.round(r.width * 100) / 100,
    h: Math.round(r.height * 100) / 100,
    loaded: img ? img.complete && img.naturalWidth > 0 : null,
  };
}))()`;

const OVERFLOW = `({
  scrollWidth: document.documentElement.scrollWidth,
  innerWidth: window.innerWidth,
  scrollHeight: document.documentElement.scrollHeight,
  articles: document.querySelectorAll('article').length
})`;

// Scroll through the page so every lazy image is requested, then wait for each to settle.
const SETTLE = `(async () => {
  const step = window.innerHeight;
  for (let y = 0; y <= document.documentElement.scrollHeight; y += step) {
    window.scrollTo(0, y);
    await new Promise(r => setTimeout(r, 100));
  }
  window.scrollTo(0, 0);
  const imgs = [...document.images];
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline && !imgs.every(i => i.complete)) {
    await new Promise(r => setTimeout(r, 500));
  }
  await new Promise(r => setTimeout(r, 500));
  return { total: imgs.length, loaded: imgs.filter(i => i.naturalWidth > 0).length };
})()`;

async function setViewport(width, height) {
  await send("Emulation.setDeviceMetricsOverride", {
    width, height, deviceScaleFactor: 1, mobile: width < 768,
  });
}

async function open(width, { blockImages }) {
  await setViewport(width, 900);
  await send("Network.setCacheDisabled", { cacheDisabled: true });
  await send("Network.setBlockedURLs", {
    urls: blockImages ? ["*.jpg*", "*.png*", "*.webp*", "*.gif*"] : [],
  });
  const loaded = once("Page.loadEventFired");
  await send("Page.navigate", { url: PAGE });
  await loaded;
}

// ---- image boxes: empty first, then loaded -------------------------------
await open(1280, { blockImages: true });
await ev(SETTLE, true);
const before = await ev(BOXES);

await open(1280, { blockImages: false });
const settled = await ev(SETTLE, true);
const after = await ev(BOXES);

const shifted = before.filter((b) => {
  const a = after.find((x) => x.i === b.i);
  return a.w !== b.w || a.h !== b.h;
});
console.log(`articles: ${(await ev(OVERFLOW)).articles}`);
console.log(`images loaded: ${settled.loaded}/${settled.total}`);
for (const b of after.filter((x) => !x.loaded)) console.log(`  NOT LOADED: ${b.host} ${b.title}`);
console.log(`image boxes that changed size once images loaded: ${shifted.length}`);

// ---- screenshots, in viewport-height tiles -------------------------------
// One full-height capture wedges this Chromium's renderer once images are decoded. Tiles
// captured while scrolling are stitched back together.
async function shoot(width, viewportHeight, file) {
  await open(width, { blockImages: false });
  await ev(SETTLE, true);
  const full = await ev(OVERFLOW);

  const tiles = [];
  for (let y = 0; y < full.scrollHeight; y += viewportHeight) {
    const target = Math.min(y, full.scrollHeight - viewportHeight);
    await ev(`window.scrollTo(0, ${target})`);
    await sleep(350);
    const actualY = await ev("Math.round(window.scrollY)");
    const { data } = await send("Page.captureScreenshot", { format: "png" }, 60000);
    tiles.push({ png: PNG.sync.read(Buffer.from(data, "base64")), y: actualY });
  }

  const out = new PNG({ width, height: full.scrollHeight });
  const written = new Uint8Array(full.scrollHeight);
  for (const t of tiles) {
    for (let row = 0; row < t.png.height; row++) {
      const y = t.y + row;
      if (y < 0 || y >= full.scrollHeight || written[y]) continue;
      written[y] = 1;
      t.png.data.copy(out.data, y * width * 4, row * width * 4, (row + 1) * width * 4);
    }
  }
  const uncovered = [...written].filter((v) => !v).length;
  writeFileSync(join(OUT, file), PNG.sync.write(out));
  await ev("window.scrollTo(0, 0)");
  console.log(`${file}: ${width}px, page ${full.scrollWidth}x${full.scrollHeight}, ${tiles.length} tiles, uncovered rows: ${uncovered}`);
  return full;
}

const desktop = await shoot(1280, 900, "desktop.png");
const mobile = await shoot(390, 844, "mobile.png");

const overflows = mobile.scrollWidth !== mobile.innerWidth;
console.log(`390px scrollWidth ${mobile.scrollWidth} vs innerWidth ${mobile.innerWidth}: ${overflows ? "OVERFLOW" : "ok"}`);
console.log(`1280px scrollWidth ${desktop.scrollWidth} vs innerWidth ${desktop.innerWidth} (informational)`);

proc.kill();
process.exitCode = overflows || shifted.length ? 1 : 0;
