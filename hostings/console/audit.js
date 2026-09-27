// -----------------------------------------------------------------------------
// The audit trail: every POST this page received, read from the journal by
// read_audit.sh. Read only. Asked when the tab is shown, not at load, because
// most visits never look at it.
//
// Search, filters, sorting and paging all happen here, over the at most 1000
// entries the script returns: one fetch, and every click after it is instant.
// -----------------------------------------------------------------------------

const AUDIT_PAGE_SIZE = 20;
const AUDIT = { rows: [], ok: true, col: 'when', asc: false, page: 0 };

function auditTarget(tg) {
  if (!tg || typeof tg !== 'object') return '';
  return Object.entries(tg).map(([k, v]) =>
    k + ': ' + (Array.isArray(v) ? v.join(', ') : v)).join('; ');
}

function auditWhen(e) {
  return new Date((e.when || 0) * 1000).toLocaleString();
}

function auditFillSelect(sel, values, allLabel) {
  const keep = sel.value;
  sel.innerHTML = `<option value="">${esc(allLabel)}</option>` +
    values.map(v => `<option value="${esc(v)}">${esc(v)}</option>`).join('');
  sel.value = values.includes(keep) ? keep : '';
}

async function loadAudit() {
  if (!document.getElementById('audit-body')) return;
  let data;
  try {
    const r = await fetch('?ask=audit', { headers: { 'Accept': 'application/json' } });
    data = await r.json();
  } catch (e) {
    data = { ok: false, entries: [] };
  }
  AUDIT.ok = !!data.ok;
  AUDIT.rows = (Array.isArray(data.entries) ? data.entries : []).map(e => ({
    ...e, targetText: auditTarget(e.target), whenText: auditWhen(e)
  }));

  const t = T[lang];
  const uniq = key => [...new Set(AUDIT.rows.map(e => e[key] || ''))].filter(Boolean).sort();
  auditFillSelect(document.getElementById('audit-user'), uniq('user'), t.aAllUsers);
  auditFillSelect(document.getElementById('audit-result'), uniq('result'), t.aAllResults);
  renderAudit();
}

function renderAudit() {
  const t = T[lang];
  const body = document.getElementById('audit-body');
  const note = document.getElementById('audit-note');
  const q = document.getElementById('audit-search').value.trim().toLowerCase();
  const user = document.getElementById('audit-user').value;
  const result = document.getElementById('audit-result').value;

  let rows = AUDIT.rows.filter(e =>
    (!user || e.user === user) &&
    (!result || e.result === result) &&
    (!q || [e.whenText, e.user, e.action, e.targetText, e.result]
             .join(' ').toLowerCase().includes(q)));

  const key = AUDIT.col === 'target' ? 'targetText' : AUDIT.col;
  rows.sort((a, b) => {
    const x = a[key] ?? '', y = b[key] ?? '';
    const c = typeof x === 'number' ? x - y : String(x).localeCompare(String(y));
    return AUDIT.asc ? c : -c;
  });

  const pages = Math.max(1, Math.ceil(rows.length / AUDIT_PAGE_SIZE));
  AUDIT.page = Math.min(AUDIT.page, pages - 1);
  const shown = rows.slice(AUDIT.page * AUDIT_PAGE_SIZE, (AUDIT.page + 1) * AUDIT_PAGE_SIZE);

  note.textContent = AUDIT.ok ? t.aNote : t.aUnreadable;
  document.getElementById('audit-search').placeholder = t.aSearch;
  document.getElementById('audit-page').textContent = t.aPage
    .replace('%p', AUDIT.page + 1).replace('%n', pages).replace('%c', rows.length);
  document.getElementById('audit-prev').disabled = AUDIT.page === 0;
  document.getElementById('audit-next').disabled = AUDIT.page >= pages - 1;

  document.querySelectorAll('th.audit-sort').forEach(th =>
    th.setAttribute('aria-sort', th.dataset.col === AUDIT.col
      ? (AUDIT.asc ? 'ascending' : 'descending') : 'none'));

  if (!shown.length) {
    body.innerHTML = `<tr><td colspan="5" class="note">${esc(AUDIT.rows.length ? t.aNoMatch : t.aNone)}</td></tr>`;
    return;
  }
  body.innerHTML = shown.map(e => {
    const cls = { ok: 'lv-ok', failed: 'lv-bad', refused: 'lv-warn' }[e.result] || 'lv-unknown';
    return `<tr><td>${esc(e.whenText)}</td><td>${esc(e.user || '')}</td>` +
           `<td><code>${esc(e.action || '')}</code></td>` +
           `<td>${esc(e.targetText)}</td>` +
           `<td class="audit-result"><span class="pill ${cls}">${esc(e.result || '')}</span></td></tr>`;
  }).join('');
}

// Any change to what is shown starts again at page one.
['audit-search', 'audit-user', 'audit-result'].forEach(id => {
  const el = document.getElementById(id);
  if (el) el.addEventListener(id === 'audit-search' ? 'input' : 'change',
    () => { AUDIT.page = 0; renderAudit(); });
});
document.querySelectorAll('th.audit-sort').forEach(th => th.addEventListener('click', () => {
  AUDIT.asc = th.dataset.col === AUDIT.col ? !AUDIT.asc : th.dataset.col !== 'when';
  AUDIT.col = th.dataset.col;
  AUDIT.page = 0;
  renderAudit();
}));
document.getElementById('audit-prev')?.addEventListener('click', () => { AUDIT.page--; renderAudit(); });
document.getElementById('audit-next')?.addEventListener('click', () => { AUDIT.page++; renderAudit(); });

// showTab() in cells.js calls loadAudit(), for a click and for a remembered tab.
