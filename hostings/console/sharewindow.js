// The share write window's countdown. The end time comes from the server, so
// a slow page or a sleeping laptop never shows more time than is left.
(function () {
  const el = document.getElementById('share-window-left');
  if (!el) return;
  const ends = Number(el.dataset.ends) * 1000;
  const pad = n => String(n).padStart(2, '0');
  function tick() {
    const left = Math.max(0, Math.round((ends - Date.now()) / 1000));
    const h = Math.floor(left / 3600), m = Math.floor(left % 3600 / 60), s = left % 60;
    el.textContent = (h ? h + ':' + pad(m) : m) + ':' + pad(s);
    // A few seconds' grace for the close timer, then show what it did.
    if (left === 0) { setTimeout(() => location.reload(), 5000); return; }
    setTimeout(tick, 1000);
  }
  tick();
})();
