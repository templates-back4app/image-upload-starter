// Stack: Node.js 22+ (built-in WebSocket) + headless Chrome over the DevTools protocol | File: web-check.mjs
// Drives web/ exactly as a user would: sign up, pick a file with the file input, click Upload, and read the timings the
// page itself prints from performance.now(). Also takes the screenshots. No test framework, no browser package.
// usage: node web-check.mjs <page-url> <out-dir> <file>...   (CHROME=/path/to/chrome to override the binary)
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";

const [pageUrl, outDir, ...files] = process.argv.slice(2);
if (!pageUrl || !outDir || files.length === 0) { console.error("usage: node web-check.mjs <page-url> <out-dir> <file>..."); process.exit(2); }
mkdirSync(outDir, { recursive: true });
const CHROME = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = 9333;
const chrome = spawn(CHROME, [`--headless=new`, `--remote-debugging-port=${PORT}`, `--user-data-dir=${mkdtempSync(join(tmpdir(), "cdp-"))}`,
  "--window-size=800,1000", "--hide-scrollbars", "--no-first-run", "--no-default-browser-check", "about:blank"], { stdio: "ignore" });
process.on("exit", () => chrome.kill());

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  try { target = (await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json()).find((t) => t.type === "page"); } catch { await sleep(200); }
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0; const pending = new Map(); const events = [];
ws.onmessage = (m) => { const msg = JSON.parse(m.data); if (msg.id) { pending.get(msg.id)?.(msg); pending.delete(msg.id); } else events.push(msg); };
const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pending.set(i, (m) => (m.error ? rej(new Error(m.error.message)) : res(m.result))); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = async (expression) => (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result.value;
const waitFor = async (expression, timeoutMs = 120000) => { const t0 = Date.now(); while (Date.now() - t0 < timeoutMs) { if (await evaluate(expression)) return true; await sleep(100); } throw new Error(`timeout waiting for ${expression}`); };
const shot = async (name) => {
  const { data } = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
  writeFileSync(join(outDir, name), Buffer.from(data, "base64")); console.log(`screenshot ${name}`);
  // where the App ID appears in text, so the caller can blur it (device pixels, 2x)
  const rects = await evaluate(`(() => { const id = window.APP_ID; const out = []; const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n; (n = w.nextNode());) { let i = -1; while ((i = n.data.indexOf(id, i + 1)) >= 0) { const r = document.createRange(); r.setStart(n, i); r.setEnd(n, i + id.length);
      for (const b of r.getClientRects()) out.push([Math.floor(b.left * 2), Math.floor(b.top * 2), Math.ceil(b.right * 2), Math.ceil(b.bottom * 2)].join(",")); } } return out; })()`);
  writeFileSync(join(outDir, name.replace(/\.png$/, ".blur")), rects.join(" "));
};

await send("Page.enable"); await send("Runtime.enable"); await send("DOM.enable");
// 800 CSS px at 2x = 1600 px screenshots with the 640 px page filling the frame
await send("Emulation.setDeviceMetricsOverride", { width: 800, height: 1000, deviceScaleFactor: 2, mobile: false });
await send("Page.navigate", { url: pageUrl });
await waitFor(`document.readyState === "complete" && !!document.querySelector("#signup")`);
await sleep(300);
await shot("1-start.png");

const user = `pix${Math.floor(Math.random() * 90000 + 10000)}`;
console.log(`user ${user}`);
await evaluate(`(() => { const f = document.querySelector("#signup"); f.username.value = ${JSON.stringify(user)}; f.email.value = ${JSON.stringify(user + "@example.com")}; f.password.value = "correct-horse-" + Date.now(); f.querySelector("button.primary").click(); })()`);
await waitFor(`!document.querySelector("#me").hidden || document.querySelector("#status").className === "err"`);
if (await evaluate(`document.querySelector("#me").hidden`)) { console.error(`signup failed: ${await evaluate(`document.querySelector("#status").textContent`)}`); chrome.kill(); process.exit(1); }
console.log(`signup: ${await evaluate(`document.querySelector("#status").textContent`)}`);

const results = [];
for (const file of files) {
  const { root } = await send("DOM.getDocument");
  const { nodeId } = await send("DOM.querySelector", { nodeId: root.nodeId, selector: "input[name=file]" });
  await send("DOM.setFileInputFiles", { nodeId, files: [file] });
  await evaluate(`(() => { document.querySelector("#upload").caption.value = ${JSON.stringify("from the page: " + basename(file))}; document.querySelector("#upload button.primary").click(); })()`);
  await waitFor(`/^(uploaded|\\d+ )/.test(document.querySelector("#status").textContent) && document.querySelector("#status").className !== ""`);
  const text = await evaluate(`document.querySelector("#status").textContent`);
  console.log(`${basename(file)}: ${text.split("\n")[0]}`);
  results.push({ file: basename(file), status: text.split("\n")[0], at: new Date().toISOString() });
  await sleep(500);
}
await waitFor(`Array.from(document.images).every((i) => i.complete)`, 30000);
await sleep(500);
await shot("2-uploaded.png");
writeFileSync(join(outDir, "results.json"), JSON.stringify(results, null, 2));
console.log("done"); ws.close(); chrome.kill(); process.exit(0);
