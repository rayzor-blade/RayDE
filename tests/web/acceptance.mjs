// Landing acceptance against a deployed (or local) landing page, driven through real browsers.
//
//   RAYDE_ACCEPT_URL=https://host/ node tests/web/acceptance.mjs
//
// Without RAYDE_ACCEPT_URL it serves the offline sample locally, which has no demo admission, so every remote check reports "skip". A check that
// cannot be observed from outside the canvas editor is reported as "skip" with the reason, never as a pass.
//   RAYDE_ACCEPT_CAPACITY=N   also open N+1 visitors and expect the last to be refused while its editor stays usable
//   RAYDE_ACCEPT_OUT=dir      reports and screenshots (default bin/web/acceptance)
//   CHROME=path               browser executable
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createRequire} from 'node:module';
import {mkdir, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';

const root = resolve(import.meta.dirname, '../..');
const out = resolve(process.env.RAYDE_ACCEPT_OUT ?? join(root, 'bin/web/acceptance'));
const puppeteer = createRequire(join(root, 'web/session/package.json'))('puppeteer-core');
const pause = ms => new Promise(r => setTimeout(r, ms));
const LIVE_TIMEOUT = 120000;
const MAIN = /\/src\/Main\.hx$/;

await mkdir(out, {recursive: true});

let server = null;
async function base() {
  if (process.env.RAYDE_ACCEPT_URL) return new URL(process.env.RAYDE_ACCEPT_URL).href;
  server = spawn('python3', ['scripts/serve-site.py', '--port', '0', '--offline'], {cwd: root, stdio: ['ignore', 'pipe', 'inherit']});
  return new Promise((ok, fail) => {
    const timer = setTimeout(() => fail(Error('The local landing page did not start.')), 20000);
    let text = '';
    server.stdout.on('data', bytes => {
      text += bytes;
      const line = text.split('\n').find(l => l.startsWith('RayDE landing page: '));
      if (line) { clearTimeout(timer); ok(line.slice(20).trim()); }
    });
  });
}

const results = [];
const facts = {};
async function check(name, run) {
  const started = Date.now();
  try {
    const outcome = await run();
    if (outcome?.skip) results.push({name, status: 'skip', ms: Date.now() - started, detail: outcome.skip});
    else results.push({name, status: 'pass', ms: Date.now() - started, detail: outcome?.detail});
  } catch (error) {
    results.push({name, status: 'fail', ms: Date.now() - started, detail: String(error?.message ?? error)});
  }
}
function expect(condition, message) { if (!condition) throw Error(message); }

const url = await base();
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true, args: ['--no-sandbox', '--enable-unsafe-webgpu'], defaultViewport: {width: 1440, height: 900}
});

/** A visitor: its own cookies and storage, with every page error and failed request kept. */
async function visitor(label) {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  const problems = [];
  await page.evaluateOnNewDocument(() => Object.defineProperty(navigator, 'hardwareConcurrency', {value: 4}));
  page.on('pageerror', error => problems.push('error ' + error));
  page.on('response', response => {
    if (response.request().headers()['x-acceptance-probe']) return; // our own status calls may legitimately be refused
    if (response.status() >= 400 && !response.url().endsWith('/favicon.ico')) problems.push(response.status() + ' ' + new URL(response.url()).pathname);
  });
  return {label, context, page, problems, started: Date.now()};
}
const isLive = page => page.waitForFunction(() => document.querySelector('#demo-state')?.hasAttribute('data-live'), {timeout: LIVE_TIMEOUT});
const editorOf = async page => (await page.$('#editor')).contentFrame();
const modifier = frame => frame.evaluate(() => /mac/i.test(navigator.userAgentData?.platform ?? navigator.platform) ? 'Meta' : 'Control');
const demoCall = (page, action) => page.evaluate(async action => {
  const response = await fetch('/api/demo/' + action, {method: action === 'status' ? 'GET' : 'POST', credentials: 'same-origin', cache: 'no-store', headers: {'X-Acceptance-Probe': '1'}});
  let body = null;
  try { body = await response.json(); } catch { /* not JSON */ }
  return {status: response.status, body};
}, action);
/** The browser-stored text of the demo's Main.hx, or null while the page keeps no such file (a remote-only workspace is not readable from here). */
const storedMain = frame => frame.evaluate(pattern => new Promise(resolve => {
  const request = indexedDB.open('rayde-page', 1);
  request.onerror = () => resolve(null);
  request.onsuccess = () => {
    if (!request.result.objectStoreNames.contains('files')) return resolve(null);
    const read = request.result.transaction('files').objectStore('files').getAll();
    read.onsuccess = () => {
      const entry = read.result.find(item => !item.directory && new RegExp(pattern).test(item.path));
      resolve(entry?.data ? atob(entry.data) : null);
    };
    read.onerror = () => resolve(null);
  };
}), MAIN.source);
async function replaceMain(page, text) {
  const frame = await editorOf(page);
  await pause(1500); // the canvas takes its first frame after the status line hides
  await (await frame.$('#screen')).click({offset: {x: 300, y: 210}});
  const key = await modifier(frame);
  await page.keyboard.down(key); await page.keyboard.press('a'); await page.keyboard.up(key);
  await page.keyboard.type(text, {delay: 5});
  await saveMain(page);
  return frame;
}
async function saveMain(page) {
  const frame = await editorOf(page), key = await modifier(frame);
  await page.keyboard.down(key); await page.keyboard.press('s'); await page.keyboard.up(key);
}
async function storedHas(frame, marker, wanted = true) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    if (((await storedMain(frame)) ?? '').includes(marker) === wanted) return;
    await pause(250);
  }
  throw Error(`Main.hx ${wanted ? 'never held' : 'still holds'} ${marker}`);
}

const first = {};
try {
  await check('static: isolation headers and an HTML that waits for no data', async () => {
    const probe = await visitor('static');
    const response = await probe.page.goto(url, {waitUntil: 'load'});
    const headers = response.headers();
    expect(response.status() === 200, 'status ' + response.status());
    expect(headers['cross-origin-opener-policy'] === 'same-origin', 'COOP is ' + headers['cross-origin-opener-policy']);
    expect(/require-corp|credentialless/.test(headers['cross-origin-embedder-policy'] ?? ''), 'COEP is ' + headers['cross-origin-embedder-policy']);
    expect(await probe.page.evaluate(() => crossOriginIsolated), 'the page is not cross-origin isolated');
    const paint = await probe.page.evaluate(() => new Promise(done => {
      const read = () => performance.getEntriesByType('paint').find(entry => entry.name === 'first-contentful-paint')?.startTime;
      const stop = Date.now() + 5000;
      const look = () => read() !== undefined || Date.now() > stop ? done(read()) : setTimeout(look, 100);
      look();
    }));
    expect(paint !== undefined, 'the browser reported no first contentful paint');
    facts.firstContentfulPaintMs = Math.round(paint);
    await probe.page.screenshot({path: join(out, 'static.png')});
    await probe.context.close();
    return {detail: `first contentful paint ${facts.firstContentfulPaintMs} ms`};
  });

  await check('mobile: no runtime fetch and no overflow', async () => {
    for (const width of [320, 390, 768]) {
      const probe = await visitor('mobile');
      const requests = [];
      probe.page.on('request', request => requests.push(new URL(request.url()).pathname));
      await probe.page.setViewport({width, height: 844, isMobile: true, deviceScaleFactor: 1});
      await probe.page.goto(url, {waitUntil: 'networkidle0'});
      expect(!requests.some(path => /\.wasm$|\/(ashui-host|worker|thread|gpu-worker)/.test(path)), `width ${width} loaded the runtime`);
      expect(!requests.some(path => path.startsWith('/api/demo/')), `width ${width} asked for demo compute`);
      expect(await probe.page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `width ${width} overflows`);
      await probe.context.close();
    }
  });

  await check('desktop: the live editor appears without admission on its path', async () => {
    first.v = await visitor('first');
    await first.v.page.goto(url);
    await isLive(first.v.page);
    facts.liveEditorMs = Date.now() - first.v.started;
    const frame = await editorOf(first.v.page);
    expect(await frame.$$eval('canvas', nodes => nodes.length) === 1, 'the editor does not draw exactly one canvas');
    await first.v.page.screenshot({path: join(out, 'live.png')});
    return {detail: `live after ${facts.liveEditorMs} ms`};
  });

  await check('remote: a lease is granted, bounded and private', async () => {
    const {page} = first.v;
    const opened = await demoCall(page, 'status');
    facts.hasAdmission = opened.status !== 404;
    if (!facts.hasAdmission) return {skip: 'this host has no demo admission'};
    expect(opened.status === 200 || opened.status === 202, 'status call returned ' + opened.status);
    const deadline = Date.now() + 180000;
    let state = opened.body;
    while (state?.status !== 'ready' && Date.now() < deadline) {
      await pause(1000);
      state = (await demoCall(page, 'status')).body;
    }
    expect(state?.status === 'ready', 'the remote session never became ready: ' + JSON.stringify(state));
    facts.remoteReadyMs = Date.now() - first.v.started;
    first.id = state.id;
    expect(state.expires * 1000 - Date.now() <= 15 * 60 * 1000 + 5000, 'the lease outlives its 15 minute cap');
    expect(state.idleUntil - Date.now() <= 5 * 60 * 1000 + 5000, 'the idle deadline is past 5 minutes');
    const cookie = (await first.v.context.cookies()).find(c => c.name === 'rayde_demo');
    expect(cookie?.httpOnly && cookie.sameSite === 'Strict' && cookie.path === '/api/demo', 'the lease cookie is not HttpOnly, Strict and scoped');
    if (new URL(url).protocol === 'https:') expect(cookie.secure, 'the lease cookie is not Secure');
    return {detail: `ready after ${facts.remoteReadyMs} ms; ${JSON.stringify({release: state.release, expires: state.expires})}`};
  });

  await check('edit: type, save, undo and keep the edit across reload', async () => {
    const {page} = first.v;
    await pause(1500);
    if ((await storedMain(await editorOf(page))) === null) return {skip: 'the page keeps no Main.hx in browser storage here, so the edit cannot be read back from outside'};
    first.marker = 'Accept' + Date.now();
    const frame = await replaceMain(page, `class Main { static function main() { trace("${first.marker}"); } }`);
    await storedHas(frame, first.marker);
    await page.keyboard.type(' // undone', {delay: 5});
    const key = await modifier(frame);
    for (let i = 0; i < 12; i++) { await page.keyboard.down(key); await page.keyboard.press('z'); await page.keyboard.up(key); }
    await saveMain(page);
    await storedHas(frame, '// undone', false);
    await storedHas(frame, first.marker);
    await page.reload();
    await isLive(page);
    await storedHas(await editorOf(page), first.marker);
    await page.screenshot({path: join(out, 'edited.png')});
  });

  await check('recovery: going offline and back keeps the edit and the lease', async () => {
    const {page} = first.v;
    if ((await demoCall(page, 'status')).status === 404) return {skip: 'this host has no demo admission'};
    if (!first.marker) return {skip: 'no readable edit to keep, see the edit check'};
    await page.setOfflineMode(true);
    await pause(3000);
    await page.setOfflineMode(false);
    const deadline = Date.now() + 60000;
    let status = 0;
    while (Date.now() < deadline && status !== 200) { await pause(1000); status = (await demoCall(page, 'status')).status; }
    expect(status === 200, 'the lease was not reachable again: ' + status);
    await storedHas(await editorOf(page), first.marker);
  });

  await check('isolation: a second visitor gets another session and none of the first edits', async () => {
    const second = await visitor('second');
    await second.page.goto(url);
    await isLive(second.page);
    const remote = await demoCall(second.page, 'status');
    if (remote.status === 404) { await second.context.close(); return {skip: 'this host has no demo admission'}; }
    expect(remote.body?.id && remote.body.id !== first.id, 'the second visitor shares the first visitor session');
    if (first.marker) expect(!((await storedMain(await editorOf(second.page))) ?? '').includes(first.marker), 'the first visitor edit leaked');
    await second.page.screenshot({path: join(out, 'second.png')});
    await second.context.close();
  });

  await check('capacity: a full pool refuses politely and the editor still works', async () => {
    const capacity = Number(process.env.RAYDE_ACCEPT_CAPACITY ?? 0);
    if (!capacity) return {skip: 'set RAYDE_ACCEPT_CAPACITY to the configured DEMO_MAX_SESSIONS'};
    const held = [];
    try {
      for (let i = 0; i < capacity; i++) {
        const v = await visitor('pool' + i);
        await v.page.goto(url);
        await isLive(v.page);
        held.push(v);
      }
      const over = await visitor('over');
      held.push(over);
      await over.page.goto(url);
      await isLive(over.page);
      const reply = await demoCall(over.page, 'open');
      expect([429, 503].includes(reply.status), 'the pool was not full: ' + reply.status);
      expect(typeof reply.body?.message === 'string' || typeof reply.body?.error === 'string', 'a refusal without a message');
      await over.page.screenshot({path: join(out, 'full.png')});
      return {detail: `refused with ${reply.status}`};
    } finally {
      for (const v of held) await v.context.close().catch(() => {});
    }
  });

  await check('end: leaving releases the lease', async () => {
    const {page} = first.v;
    if ((await demoCall(page, 'status')).status === 404) return {skip: 'this host has no demo admission'};
    const ended = await demoCall(page, 'end');
    expect(ended.status === 200, 'end returned ' + ended.status);
    const after = await demoCall(page, 'status');
    expect([401, 410].includes(after.status), 'the lease still answers after end: ' + after.status);
  });

  for (const name of ['terminal and Output', 'extensions: every built-in contribution', 'LSP: hover, goto, actions', 'cached app preview, source edit and rebuild', 'Git sidebar and graph']) {
    await check(name, async () => ({skip: 'the editor is one canvas with no in-page hook; needs a probe in the page, see git-bug 4fc81d5'}));
  }

  // Without admission the page's own demo and session calls are refused by design.
  const problems = (first.v?.problems ?? []).filter(line => facts.hasAdmission !== false || !/ \/api\//.test(line));
  await check('no page errors or failed requests during the first visit', async () => {
    expect(problems.length === 0, problems.slice(0, 8).join('; '));
  });
} finally {
  const report = {url, when: new Date().toISOString(), facts, results};
  await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
  for (const r of results) console.log(`${r.status.toUpperCase().padEnd(4)} ${r.name}${r.detail ? ' — ' + r.detail : ''}`);
  console.log(JSON.stringify(facts));
  await browser.close();
  if (server && server.exitCode === null) { const ended = once(server, 'exit'); server.kill('SIGINT'); await ended; }
}
process.exit(results.some(r => r.status === 'fail') ? 1 : 0);
