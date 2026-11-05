export const releasesURL = 'https://github.com/rayzor-blade/RayDE/releases';
const releaseAPI = 'https://api.github.com/repos/rayzor-blade/RayDE/releases?per_page=10';
const processors = {
  macos: [['aarch64', 'Apple silicon'], ['x86_64', 'Intel']],
  windows: [['x86_64', 'x86-64'], ['aarch64', 'ARM64']],
  linux: [['x86_64', 'x86-64'], ['aarch64', 'ARM64']]
};

export function browserPlatform(browser) {
  const agent = browser.userAgent ?? '';
  if (browser.userAgentData?.mobile || /Android|iPhone|iPad|iPod/.test(agent) || (browser.maxTouchPoints > 1 && /Mac/.test(browser.platform ?? ''))) return '';
  const platform = browser.userAgentData?.platform || browser.platform || agent;
  if (/Mac/i.test(platform)) return 'macos';
  if (/Win/i.test(platform)) return 'windows';
  if (/Linux/i.test(platform)) return 'linux';
  return '';
}

export async function browserArchitecture(browser) {
  const platform = browserPlatform(browser);
  if (!platform || typeof browser.userAgentData?.getHighEntropyValues !== 'function') return '';
  try {
    const hints = await browser.userAgentData.getHighEntropyValues(['architecture', 'bitness', 'wow64']);
    const bits = hints.bitness;
    if (hints.architecture === 'arm' && bits === '64') return 'aarch64';
    if (hints.architecture === 'x86' && (bits === '64' || platform === 'windows' && hints.wow64 === true)) return 'x86_64';
  } catch { /* Processor selection stays available when hints are denied. */ }
  return '';
}

export function previewDownload(releases, platform, architecture) {
  if (!processors[platform]?.some(([value]) => value === architecture)) return null;
  const suffix = `-${platform}-${architecture}.${platform === 'linux' ? 'tar.gz' : 'zip'}`;
  for (const release of releases) {
    if (release.draft || !Array.isArray(release.assets)) continue;
    for (const asset of release.assets) {
      if (asset.state !== 'uploaded' || !asset.name?.startsWith('rayde-') || !asset.name.endsWith(suffix)) continue;
      try {
        const url = new URL(asset.browser_download_url);
        if (url.origin !== 'https://github.com' || url.search || url.hash || url.username || url.password) continue;
        const parts = url.pathname.split('/');
        if (parts.length !== 7 || parts.slice(1, 5).join('/') !== 'rayzor-blade/RayDE/releases/download' || decodeURIComponent(parts[6]) !== asset.name) continue;
        return { url: url.href, name: asset.name, version: release.tag_name };
      } catch { /* Keep the release-list fallback for incomplete assets. */ }
    }
  }
  return null;
}

export function mountDownloads(document = globalThis.document, browser = globalThis.navigator) {
  const Observer = document.defaultView?.IntersectionObserver ?? globalThis.IntersectionObserver;
  const request = document.defaultView?.fetch?.bind(document.defaultView) ?? globalThis.fetch;
  const platform = document.querySelector('#preview-platform');
  const architecture = document.querySelector('#preview-architecture');
  const link = document.querySelector('#preview-download');
  const label = link.querySelector('[data-download-label]');
  const status = document.querySelector('#preview-download-status');
  let releases = null, loading = false, failed = false;
  const detectedPlatform = browserPlatform(browser);
  let detectedArchitecture = '', selectionChanged = false, detecting = !!detectedPlatform;

  function update() {
    const selected = releases && previewDownload(releases, platform.value, architecture.value);
    link.href = selected?.url ?? releasesURL;
    label.textContent = selected ? 'Get RayDE Preview' : 'View preview releases';
    if (loading) status.textContent = 'Finding published preview builds…';
    else if (failed) status.textContent = 'Check GitHub Releases for available preview builds.';
    else if (releases?.length === 0) status.textContent = 'Desktop previews have not been published yet. Try the live editor or build from source.';
    else if (!platform.value) status.textContent = 'Choose your desktop platform.';
    else if (!architecture.value) status.textContent = detecting && !selectionChanged ? 'Detecting your processor…' : platform.value === 'macos' ? 'Choose Apple silicon or Intel for your Mac.' : 'Choose your processor.';
    else if (!releases) status.textContent = 'Preview packages are portable downloads.';
    else if (!selected) status.textContent = 'No preview package is available for this platform and processor yet.';
    else status.textContent = `${selected.version} · ${platform.value === 'linux' ? 'tar.gz' : 'ZIP'} preview archive`;
  }

  function changePlatform() {
    const options = processors[platform.value] ?? [];
    const option = (value, text) => {
      const node = document.createElement('option'); node.value = value; node.textContent = text; return node;
    };
    architecture.replaceChildren(option('', 'Choose processor'), ...options.map(([value, text]) => option(value, text)));
    architecture.value = platform.value === detectedPlatform ? detectedArchitecture : '';
    architecture.disabled = !options.length;
    update();
  }

  platform.value = detectedPlatform;
  platform.addEventListener('change', () => { selectionChanged = true; changePlatform(); });
  architecture.addEventListener('change', () => { selectionChanged = true; update(); });
  document.querySelector('[data-preview-options]').hidden = false;
  status.hidden = false;
  changePlatform();
  browserArchitecture(browser).then(value => {
    detectedArchitecture = value; detecting = false;
    if (!selectionChanged) changePlatform(); else update();
  });

  const observer = new Observer(async entries => {
    if (!entries.some(entry => entry.isIntersecting)) return;
    observer.disconnect();
    loading = true; update();
    try {
      const response = await request(releaseAPI, { credentials: 'omit', referrerPolicy: 'no-referrer', signal: AbortSignal.timeout(5000) });
      if (!response.ok) throw new Error('Release lookup failed');
      const value = await response.json();
      if (!Array.isArray(value)) throw new Error('Invalid release list');
      releases = value;
    } catch { failed = true; }
    finally { loading = false; update(); }
  }, { rootMargin: '120px' });
  observer.observe(document.querySelector('#install'));
}

if (typeof document !== 'undefined' && document.querySelector('#preview-download')) mountDownloads();
