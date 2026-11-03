// Report the app's window title after its first frame, without polling an idle preview.
if (parent !== globalThis && document.referrer) {
  const origin = new URL(document.referrer).origin;
  let sent = null, scheduled = false;
  const publish = () => {
    scheduled = false;
    const status = document.querySelector('#status');
    if (document.querySelector('meta[name="ashui-module"]') && status && !status.hidden && !status.classList.contains('fading')) return;
    const title = document.title.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 256);
    if (!title || title === sent) return;
    sent = title;
    parent.postMessage({type: 'rayde-preview-title', title}, origin);
  };
  const changed = () => { if (!scheduled) { scheduled = true; requestAnimationFrame(publish); } };
  const observer = new MutationObserver(changed);
  observer.observe(document.head, {childList: true, subtree: true, characterData: true});
  const status = document.querySelector('#status');
  if (status) observer.observe(status, {attributes: true, attributeFilter: ['class', 'hidden']});
  addEventListener('pagehide', () => observer.disconnect(), {once: true});
  changed();
}
