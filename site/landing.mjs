import { saveConnection, previewConnection } from './dist/rayde_connection.mjs';

const frame = document.querySelector('#editor');
const poster = document.querySelector('.editor-poster');
const state = document.querySelector('#demo-state');
const detail = document.querySelector('#demo-detail');
const desktop = matchMedia('(min-width: 900px)');
let connection = null;
const legacy = new URL(location.href);
if (legacy.searchParams.has('session')) {
  try {
    connection = saveConnection({
      version: 1, endpoint: legacy.searchParams.get('session'), project: legacy.searchParams.get('project') ?? '',
      token: new URLSearchParams(legacy.hash.slice(1)).get('token') ?? '', environment: legacy.searchParams.getAll('env').filter(entry => !/^RAYDE_(VISITOR|STANDALONE)=/.test(entry))
    });
    for (const key of ['session', 'project', 'env']) legacy.searchParams.delete(key);
    if (new URLSearchParams(legacy.hash.slice(1)).has('token')) legacy.hash = '';
    history.replaceState(null, '', legacy);
  } catch { /* A storage-denied browser can still use its explicit session URL. */ }
}
// The preview host owns its preset; stale standalone settings must not replace it.
connection = await previewConnection() ?? connection;
const editor = new URL('./dist/index.html', import.meta.url);
editor.search = location.search;
const connected = editor.searchParams.has('session') || !!connection?.endpoint;
if (!connected) editor.searchParams.set('demo', '1');
const authenticated = new URLSearchParams(location.hash.slice(1)).has('token');
if (authenticated) editor.hash = location.hash;
detail.textContent = connected ? 'Connected workspace. Tools and extensions run on the session host.' : 'Browser sample. Builds and extensions are available in a hosted workspace.';
for (const link of document.querySelectorAll('.editor-link')) link.href = editor.href;
let loading = false;
function start() {
  if (loading || !desktop.matches) return;
  if (!globalThis.crossOriginIsolated || !navigator.gpu) {
    state.textContent = 'Editor preview';
    detail.textContent = 'The live demo needs WebGPU and cross-origin isolation. Open the full editor in a supported browser.';
    return;
  }
  loading = true;
  state.textContent = 'Starting the editor…';
  frame.hidden = false;
  frame.onload = () => {
    const status = frame.contentDocument?.querySelector('#status');
    if (!status) return;
    const update = () => {
      if (status.hidden) {
        poster.hidden = true;
        state.textContent = connected ? 'Live editor' : 'Browser sample'; state.dataset.live = '';
        observer.disconnect();
      } else if (status.classList.contains('failed')) {
        state.textContent = 'Editor unavailable';
        detail.textContent = status.querySelector('#status-detail')?.textContent || 'Open the full editor to retry.';
      }
    };
    const observer = new MutationObserver(update);
    observer.observe(status, { attributes: true, childList: true, subtree: true });
    update();
  };
  frame.src = editor.href;
}
function deviceChanged() {
  if (!desktop.matches) {
    if (loading) { frame.hidden = true; frame.removeAttribute('src'); loading = false; delete state.dataset.live; }
    poster.hidden = false;
    state.textContent = 'Desktop editor preview';
    detail.textContent = 'Visit on a larger screen to try the interactive editor.';
  } else if (!loading) start();
}
new IntersectionObserver(entries => {
  if (entries.some(entry => entry.isIntersecting)) deviceChanged();
}, { rootMargin: '160px' }).observe(frame.parentElement);
desktop.addEventListener('change', deviceChanged);
if (!desktop.matches) deviceChanged();
for (const link of document.querySelectorAll('[data-try-editor]')) {
  link.addEventListener('click', () => { start(); });
}
// Section navigation must not replace a connected workspace's token fragment.
if (authenticated) for (const link of document.querySelectorAll('a[href^="#"]')) {
  link.addEventListener('click', event => {
    const target = document.querySelector(link.getAttribute('href'));
    if (target) { event.preventDefault(); target.scrollIntoView(); }
  });
}

