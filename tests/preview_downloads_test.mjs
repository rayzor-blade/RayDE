import assert from 'node:assert/strict';
import test from 'node:test';
import { browserPlatform, previewDownload } from '../site/assets/preview-downloads.mjs';

test('desktop selection follows the browser OS and leaves mobile visitors a choice', () => {
  assert.equal(browserPlatform({ userAgentData: { platform: 'Windows' }, platform: 'MacIntel' }), 'windows');
  assert.equal(browserPlatform({ platform: 'MacIntel' }), 'macos');
  assert.equal(browserPlatform({ platform: 'Linux x86_64' }), 'linux');
  assert.equal(browserPlatform({ platform: 'MacIntel', maxTouchPoints: 5 }), '');
  assert.equal(browserPlatform({ platform: 'Linux armv8l', userAgent: 'Android' }), '');
  assert.equal(browserPlatform({ platform: 'FreeBSD' }), '');
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
