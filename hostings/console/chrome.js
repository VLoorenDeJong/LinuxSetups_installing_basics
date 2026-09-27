// -----------------------------------------------------------------------------
// Language
// -----------------------------------------------------------------------------
function applyLang() {
  const t = T[lang];
  document.querySelectorAll('[data-i18n]').forEach(el => {
    // A button showing "running" keeps showing it. Its real label is parked in
    // data-label-html and goes back when the job ends.
    if (el.dataset.labelHtml) return;
    const v = t[el.dataset.i18n];
    if (v !== undefined) el.textContent = v;
  });
  document.querySelectorAll('[data-i18n-title]').forEach(el => {
    const v = t[el.dataset.i18nTitle];
    if (v !== undefined) el.title = v;
  });
  document.getElementById('lang-btn').textContent = lang === 'en' ? '🇬🇧 English' : '🇳🇱 Nederlands';
  document.documentElement.lang = lang;

  // Only the ones that name a kind. A button without one has its own label and
  // would otherwise be relabelled "undefined" on the first language switch.
  document.querySelectorAll('.add-btn[data-kind]').forEach(b => {
    // A plus, not the kind's own glyph. The button already says what it adds,
    // and the icon's job is to say that it ADDS.
    b.innerHTML = I.plus + '<span>' + esc(t.add[b.dataset.kind]) + '</span>';
  });

  const setAction = (id, icon, label) => {
    const b = document.getElementById(id);
    if (!b || b.dataset.labelHtml) return;
    b.innerHTML = `${icon}<span>${esc(label)}</span>`;
  };

  setAction('btn-update', I.update, t.updateBtn);
  setAction('btn-reboot', I.update, t.rebootBtn);
  // Relabelled on every language switch, like every other action button. They
  // carry an icon so the pane reads as controls rather than as three words.
  const svcAll = (id, icon, label) => {
    const b = document.getElementById(id);
    if (b) b.innerHTML = icon + '<span>' + esc(label) + '</span>';
  };
  svcAll('svc-start-all', I.play, t.svcAllStart);
  svcAll('svc-stop-all',  I.stop, t.svcAllStop);
  svcAll('btn-smb-reload', I.update, t.smbReload);
  setAction('btn-apply', I.apply, t.btnApplyLong);
  setAction('apply-go', I.apply, t.applyGo);
  setAction('apply-recheck', I.check, t.applyRecheck);

  document.getElementById('apply-title').textContent   = t.applyTitle;
  document.getElementById('apply-cancel').textContent  = t.cancel;

  render();
  if (drawer.classList.contains('open')) renderDrawerFields();
}


// DARK IS THE DEFAULT, and the toggle overrides it. The OS preference is not
// read: a light desktop used to give a light console, which is not what the
// page is for. Stored per browser, because it is a preference of the eye looking
// at the screen, not of the machine being managed.
const themeBtn = document.getElementById('theme-btn');

function currentTheme() {
  const stored = (() => { try { return localStorage.getItem('theme'); } catch (e) { return null; } })();
  if (stored === 'light' || stored === 'dark') return stored;
  return 'dark';
}

function applyTheme(t, remember) {
  document.documentElement.dataset.theme = t;
  themeBtn.setAttribute('aria-checked', t === 'dark' ? 'true' : 'false');
  if (remember) { try { localStorage.setItem('theme', t); } catch (e) {} }
}

applyTheme(currentTheme(), false);

themeBtn.addEventListener('click', () => {
  applyTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark', true);
});

document.getElementById('lang-btn').addEventListener('click', () => {
  lang = (lang === 'en') ? 'nl' : 'en';
  localStorage.setItem('hosting-managerg', lang);
  applyLang();
  // applyLang puts the dictionary's own text back into the update note, which
  // overwrites the count that was in it.
  refreshJobs();
});


// On a phone each row is a card, and a cell no longer sits under its column
// header, so every cell carries its header's text as a label.
function labelCells(table) {
  const heads = [...table.querySelectorAll('thead th')].map(th => th.textContent.replace(/\s+/g, ' ').trim());
  table.querySelectorAll('tbody tr').forEach(tr => {
    // Edit-mode tick columns sit first in the head and are absent from the rows.
    const offset = heads.length - tr.cells.length;
    if (offset < 0 || [...tr.cells].some(td => td.colSpan > 1)) return;
    tr.querySelector('td.name')?.classList.add('card-title');
    [...tr.cells].forEach((td, i) => {
      if (heads[i + offset]) td.dataset.label = heads[i + offset];
      else delete td.dataset.label;
    });
  });
}
document.querySelectorAll('table[data-table]').forEach(table => {
  labelCells(table);
  table.querySelectorAll('tbody').forEach(tb =>
    new MutationObserver(() => labelCells(table)).observe(tb, { childList: true }));
});
