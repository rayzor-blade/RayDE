import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import puppeteer from "puppeteer-core";

const here = dirname(fileURLToPath(import.meta.url));
const binary = join(here, "../../../native/session/target/debug/rayde-session");
const dist = join(here, "../dist");
const chrome = ["/Applications/Chromium.app/Contents/MacOS/Chromium", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"].find(existsSync);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const freePort = () => new Promise((resolve) => { const s = createServer().listen(0, "127.0.0.1", () => { const { port } = s.address(); s.close(() => resolve(port)); }); });

async function until(check, what, ms = 8000) {
  const end = Date.now() + ms;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(40);
  }
}

function startServer(root, port, extra = []) {
  const child = spawn(binary, ["--root", root, "--port", String(port), "--token", "t", "--web", dist, ...extra], { stdio: "ignore" });
  return { child, stop: () => new Promise((resolve) => { child.once("exit", resolve); child.kill("SIGTERM"); }) };
}

describe("the browser client against the session server", { skip: chrome ? false : "no Chromium or Chrome is installed" }, () => {
  let browser;
  before(async () => { browser = await puppeteer.launch({ executablePath: chrome, headless: true, args: ["--no-sandbox"] }); });
  after(async () => { await browser?.close(); });

  async function open(port, hash = "token=t") {
    const page = await browser.newPage();
    await page.goto(`http://127.0.0.1:${port}/#${hash}`);
    await page.waitForFunction(() => window.demo?.client?.ready);
    return page;
  }
  const editor = (page) => page.$eval("#editor", (e) => e.value);

  test("edits in the page reach the file, and edits to the file reach the page", async () => {
    const root = mkdtempSync(join(tmpdir(), "sess-"));
    writeFileSync(join(root, "a.txt"), "hello");
    const port = await freePort(), server = startServer(root, port);
    try {
      await until(() => existsSync(binary), "binary");
      const page = await (async () => { for (let i = 0; i < 50; i++) { try { return await open(port); } catch { await sleep(100); } } throw new Error("page did not open"); })();
      await page.waitForSelector("#files button[data-path='a.txt']");
      await page.click("#files button[data-path='a.txt']");
      await until(async () => (await editor(page)) === "hello", "file text in the editor");
      await page.focus("#editor");
      await page.keyboard.press("End");
      await page.keyboard.type(", world");
      await until(() => readFileSync(join(root, "a.txt"), "utf8") === "hello, world", "the file to follow the page");
      writeFileSync(join(root, "a.txt"), "hello, brave world");
      await until(async () => (await editor(page)) === "hello, brave world", "the page to follow the file");
      await page.close();
    } finally { await server.stop(); }
  });

  test("edits made while the session is down are kept in the page and reach it when it is back, even from a new page", async () => {
    const root = mkdtempSync(join(tmpdir(), "sess-"));
    writeFileSync(join(root, "a.txt"), "base");
    const port = await freePort();
    let server = startServer(root, port);
    const page = await (async () => { for (let i = 0; i < 50; i++) { try { return await open(port); } catch { await sleep(100); } } throw new Error("page did not open"); })();
    await page.waitForSelector("#files button[data-path='a.txt']");
    await page.click("#files button[data-path='a.txt']");
    await until(async () => (await editor(page)) === "base", "file text");
    await server.stop();
    await until(() => page.evaluate(() => !window.demo.client.ready), "the page to notice");
    await page.focus("#editor");
    await page.keyboard.press("End");
    await page.keyboard.type(" + offline");
    assert.equal(await page.evaluate(() => window.demo.doc.unsent), true);
    // Give IndexedDB a moment, then drop the page: only the browser's storage remains.
    await sleep(300);
    await page.close();
    assert.equal(readFileSync(join(root, "a.txt"), "utf8"), "base");
    server = startServer(root, port);
    try {
      const second = await (async () => { for (let i = 0; i < 50; i++) { try { return await open(port); } catch { await sleep(100); } } throw new Error("page did not open"); })();
      await second.waitForSelector("#files button[data-path='a.txt']");
      await second.click("#files button[data-path='a.txt']");
      await until(() => readFileSync(join(root, "a.txt"), "utf8") === "base + offline", "the offline edit to reach the file");
      assert.equal(await editor(second), "base + offline");
      await second.close();
    } finally { await server.stop(); }
  });

  test("nothing is sent before signing in, and what was typed goes once the person has", async () => {
    const root = mkdtempSync(join(tmpdir(), "sess-"));
    writeFileSync(join(root, "a.txt"), "look");
    const port = await freePort();
    const secret = "edge-secret";
    const server = startServer(root, port, ["--auth-secret", secret, "--login-url", "https://play.example/login"]);
    try {
      const page = await (async () => { for (let i = 0; i < 50; i++) { try { return await open(port); } catch { await sleep(100); } } throw new Error("page did not open"); })();
      await page.waitForSelector("#files button[data-path='a.txt']");
      await page.click("#files button[data-path='a.txt']");
      await until(async () => (await editor(page)) === "look", "file text");
      await page.focus("#editor");
      await page.keyboard.press("End");
      await page.keyboard.type("!");
      await page.waitForSelector("#signin.on");
      assert.equal(await page.$eval("#login-link", (a) => a.href), "https://play.example/login");
      await sleep(400);
      assert.equal(readFileSync(join(root, "a.txt"), "utf8"), "look");
      const credential = execFileSync(binary, ["issue", "--auth-secret", secret, "--login", "darmie", "--id", "42"]).toString().trim();
      await page.type("#credential", credential);
      await page.click("#signin-go");
      await until(() => readFileSync(join(root, "a.txt"), "utf8") === "look!", "the edit to arrive after sign-in");
      await page.waitForFunction(() => document.querySelector("#who").textContent === "@darmie");
      await page.close();
    } finally { await server.stop(); }
  });
});
