import assert from 'node:assert/strict';
import test from 'node:test';
import { browserPlatform, browserArchitecture, previewDownload, mountDownloads } from '../site/assets/preview-downloads.mjs';

test('desktop selection follows the browser OS and leaves mobile visitors a choice', () => {
  assert.equal(browserPlatform({ userAgentData: { platform: 'Windows' }, platform: 'MacIntel' }), 'windows');
  assert.equal(browserPlatform({ platform: 'MacIntel' }), 'macos');
  assert.equal(browserPlatform({ platform: 'Linux x86_64' }), 'linux');
  assert.equal(browserPlatform({ platform: 'MacIntel', maxTouchPoints: 5 }), '');
  assert.equal(browserPlatform({ platform: 'Linux armv8l', userAgent: 'Android' }), '');
  assert.equal(browserPlatform({ platform: 'FreeBSD' }), '');
  assert.equal(browserPlatform({ userAgentData: { platform: 'Linux', mobile: true } }), '');
});

function hinted(platform, hints) {
  return {platform:'MacIntel', userAgentData:{platform, async getHighEntropyValues(requested) {
    assert.deepEqual(requested, ['architecture', 'bitness', 'wow64']);
    return hints;
  }}};
}

test('CPU hints distinguish Apple silicon, Intel and desktop architectures', async () => {
  assert.equal(await browserArchitecture(hinted('macOS', {architecture:'arm', bitness:'64'})), 'aarch64');
  assert.equal(await browserArchitecture(hinted('macOS', {architecture:'x86', bitness:'64'})), 'x86_64');
  assert.equal(await browserArchitecture(hinted('Windows', {architecture:'arm', bitness:'64'})), 'aarch64');
  assert.equal(await browserArchitecture(hinted('Linux', {architecture:'x86', bitness:'64'})), 'x86_64');
  assert.equal(await browserArchitecture(hinted('Windows', {architecture:'x86', bitness:'32', wow64:true})), 'x86_64');
});

test('withheld or unsupported CPU information keeps the manual choice', async () => {
  assert.equal(await browserArchitecture({platform:'MacIntel', userAgent:'Macintosh; Intel Mac OS X 10_15_7'}), '');
  assert.equal(await browserArchitecture(hinted('macOS', {})), '');
  assert.equal(await browserArchitecture(hinted('Linux', {architecture:'arm', bitness:'32'})), '');
  assert.equal(await browserArchitecture(hinted('Windows', {architecture:'x86', bitness:'32'})), '');
  assert.equal(await browserArchitecture(hinted('Linux', {architecture:'riscv', bitness:'64'})), '');
  assert.equal(await browserArchitecture({platform:'MacIntel', userAgentData:{platform:'macOS', getHighEntropyValues:async () => {throw Error('Blocked');}}}), '');
  assert.equal(await browserArchitecture({platform:'MacIntel', maxTouchPoints:5, userAgentData:{platform:'macOS', getHighEntropyValues:() => {throw Error('Mobile requested CPU hints');}}}), '');
});

function picker(browser, releases = []) {
  const elements = new Map();
  for (const selector of ['#preview-platform','#preview-architecture','#preview-download','[data-download-label]','#preview-download-status','[data-preview-options]','#install']) {
    elements.set(selector, {value:'',hidden:true,listeners:new Map(),addEventListener(name, action) {this.listeners.set(name, action);},replaceChildren(...children) {this.children=children;this.value=children[0]?.value??'';}});
  }
  elements.get('#preview-download').querySelector = selector => elements.get(selector);
  let intersect, requests = 0;
  const document = {
    querySelector:selector => elements.get(selector), createElement:() => ({}),
    defaultView:{IntersectionObserver:class {constructor(callback) {intersect=callback;} disconnect() {} observe() {}},fetch:async () => {requests++;return{ok:true,json:async () => releases};}}
  };
  mountDownloads(document, browser);
  return {get:selector => elements.get(selector), visible:() => intersect([{isIntersecting:true}]), requests:() => requests,
    change(selector, value) {const node=elements.get(selector);node.value=value;node.listeners.get('change')();}};
}

const settled = () => new Promise(resolve => setImmediate(resolve));

test('download controls become usable immediately and automatically select the native package', async () => {
  const ui=picker(hinted('macOS',{architecture:'arm',bitness:'64'}),[{tag_name:'v0.1.0-preview.1',assets:[asset('macos','aarch64')]}]);
  assert.equal(ui.get('[data-preview-options]').hidden,false);
  assert.equal(ui.get('#preview-platform').value,'macos');
  assert.equal(ui.requests(),0,'Hardware detection must not wait for release discovery');
  await settled();
  assert.equal(ui.get('#preview-architecture').value,'aarch64');
  await ui.visible();
  assert.match(ui.get('#preview-download').href,/macos-aarch64.zip$/);
});

test('late CPU detection cannot overwrite a visitor processor or platform selection', async () => {
  let resolve;
  const browser={platform:'MacIntel',userAgentData:{platform:'macOS',getHighEntropyValues:() => new Promise(done => resolve=done)}};
  const cpu=picker(browser);cpu.change('#preview-architecture','x86_64');resolve({architecture:'arm',bitness:'64'});await settled();
  assert.equal(cpu.get('#preview-architecture').value,'x86_64');
  const os=picker(browser);os.change('#preview-platform','windows');os.change('#preview-architecture','x86_64');resolve({architecture:'arm',bitness:'64'});await settled();
  assert.equal(os.get('#preview-platform').value,'windows');
  assert.equal(os.get('#preview-architecture').value,'x86_64');
});

test('unknown CPU stays unselected and detected ARM cannot silently receive an x86 build', async () => {
  const unknown=picker({platform:'Win32'});await settled();
  assert.equal(unknown.get('#preview-architecture').value,'');
  const arm=picker(hinted('Linux',{architecture:'arm',bitness:'64'}),[{assets:[asset('linux','x86_64')]}]);await settled();await arm.visible();
  assert.equal(arm.get('#preview-architecture').value,'aarch64');
  assert.equal(arm.get('#preview-download').href,'https://github.com/rayzor-blade/RayDE/releases');
  assert.match(arm.get('#preview-download-status').textContent,/No preview package/);
});

function asset(platform, arch, overrides = {}) {
  const name = `rayde-0.1.0-preview.1-${platform}-${arch}.${platform === 'linux' ? 'tar.gz' : 'zip'}`;
  return { name, state: 'uploaded', browser_download_url: `https://github.com/rayzor-blade/RayDE/releases/download/v0.1.0-preview.1/${name}`, ...overrides };
}

test('downloads require the selected platform and CPU, including preview releases', () => {
  const releases = [{ tag_name: 'v0.1.0-preview.1', prerelease: true, assets: [asset('macos', 'aarch64'), asset('macos', 'x86_64'), asset('linux', 'x86_64'), asset('windows', 'x86_64')] }];
  assert.match(previewDownload(releases, 'macos', 'aarch64').name, /macos-aarch64.zip$/);
  assert.match(previewDownload(releases, 'macos', 'x86_64').name, /macos-x86_64.zip$/);
  assert.match(previewDownload(releases, 'linux', 'x86_64').name, /linux-x86_64.tar.gz$/);
  assert.match(previewDownload(releases, 'windows', 'x86_64').name, /windows-x86_64.zip$/);
  assert.equal(previewDownload(releases, 'macos', ''), null);
  assert.equal(previewDownload(releases, 'windows', 'aarch64'), null);
  assert.equal(previewDownload([], 'linux', 'x86_64'), null);
});

test('drafts, partial uploads and unrelated download URLs are never offered', () => {
  assert.equal(previewDownload([{ draft: true, assets: [asset('macos', 'aarch64')] }], 'macos', 'aarch64'), null);
  for (const overrides of [
    { state: 'uploading' },
    { browser_download_url: 'https://example.org/rayde-macos-aarch64.zip' },
    { browser_download_url: 'https://github.com/other/repo/releases/download/v1/rayde-0.1.0-preview.1-macos-aarch64.zip' },
    { browser_download_url: 'https://github.com/rayzor-blade/RayDE/releases/download/v1/other.zip' }
  ]) assert.equal(previewDownload([{ assets: [asset('macos', 'aarch64', overrides)] }], 'macos', 'aarch64'), null);
});
