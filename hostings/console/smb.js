// -----------------------------------------------------------------------------
// Shared folders
//
// The model is the section list itself, not a parsed share. A section nobody
// touched is written back exactly as it was read, which is why [www] keeps its
// 0775 and [running_csharp_projects] keeps its 2775: rebuilding both from one
// template would silently drop the setgid bit that the deploys depend on.
// -----------------------------------------------------------------------------
let smbSections = SMB_SECTIONS.map(s => ({ ...s }));
let smbEditing = null;          // index into smbSections, or null for a new one
let smbDirty = false;

const smbDrawer = document.getElementById('smb-drawer');

const smbShares = () => smbSections
  .map((s, i) => ({ ...s, i }))
  .filter(s => !s.reserved && s.name !== '' && !s.removed);

// The lines every existing share here agrees on. Read from a real one rather
// than written out, so a new share matches whatever the machine already does.
function smbTemplate(name, path) {
  const model = smbSections.find(s => !s.reserved && s.name !== '' && s.path);
  const forceUser = model ? (model.raw.match(/^\s*force user\s*=\s*(.+?)\s*$/mi) || [])[1] : null;
  const forceGroup = model ? (model.raw.match(/^\s*force group\s*=\s*(.+?)\s*$/mi) || [])[1] : null;
  return [
    '[' + name + ']',
    '   comment              = ' + name,
    '   path                 = ' + path,
    '   writeable            = yes',
    '   browseable           = yes',
    '   guest ok             = yes',
    '   force group          = ' + (forceGroup || 'www-data'),
    '   force user           = ' + (forceUser || 'root'),
    '   force directory mode = 0775',
    '   force create mode    = 0664',
    ''
  ].join('\n');
}

// One line rewritten, the rest untouched. A share with no path line at all
// cannot be edited here, and the drawer refuses to open on one.
function smbSetPath(sec, path) {
  sec.raw = sec.raw.replace(/^(\s*path\s*=\s*).+$/mi, '$1' + path);
  sec.path = path;
}

// Switching a share off comments out every line of its section, and switching
// it on takes the marker off again. The text is otherwise untouched, so the
// share comes back exactly as it was rather than being rebuilt from fields.
//
// `#OFF ` rather than a bare `#`, because smb.conf is full of ordinary
// comments and nothing could tell a switched-off share from a note somebody
// wrote. smb_sections() in index.php reads the same marker.
function smbSetEnabled(i, on) {
  const s = smbSections[i];
  if (!s || s.reserved) return;
  const want = on ? 'yes' : 'no';
  if ((s.enabled || 'yes') === want) return;

  s.raw = on
    ? s.raw.split('\n').map(l => l.replace(/^#OFF /, '')).join('\n')
    : s.raw.split('\n').map(l => (l === '' ? l : '#OFF ' + l)).join('\n');
  s.enabled = want;
  s.dirty = true;
  smbDirty = true;
}

function smbSerialise() {
  return smbSections
    .filter(s => !s.removed)
    .map(s => s.raw)
    .join('\n')
    .replace(/\n{3,}$/, '\n\n');
}

function renderSmb() {
  const t = T[lang];
  // Removed shares stay on screen, struck through, until the save that follows
  // reloads the page: the same as a removed mailbox or website. smbShares() is
  // still used for the name-collision check, where a removed share's name is
  // free again, so the display list is built here instead of from it.
  const list = smbSections
    .map((s, i) => ({ ...s, i }))
    .filter(s => !s.reserved && s.name !== '')
    .sort((a, b) =>
      SORT.smb.col === 0
        ? (SORT.smb.asc ? 1 : -1) * a.name.localeCompare(b.name)
        : (SORT.smb.asc ? 1 : -1) * String(a.path || '').localeCompare(String(b.path || '')));

  document.getElementById('smb-body').innerHTML = list.map(s =>
    '<tr class="' + [s.removed ? 'gone' : (s.dirty ? 'edited' : ''),
                     (s.enabled === 'no' && !s.removed) ? 'off' : ''].filter(Boolean).join(' ') +
      '" data-smb="' + s.i + '" data-smb-row="' + s.i + '">' +
      '<td class="name">' + esc(s.name) + '</td>' +
      '<td>' + (s.path ? esc(s.path) : '<span class="dash">&mdash;</span>') + '</td>' +
      '<td><span class="row-actions">' +
        '<button class="icon-btn" type="button" data-smb-edit="' + s.i + '"' +
                ' title="' + esc(t.aEdit) + '" aria-label="' + esc(t.aEdit) + '">' + I.edit + '</button>' +
        '<button class="icon-btn danger" type="button" data-smb-del="' + s.i + '"' +
                ' title="' + esc(t.smbDelete) + '" aria-label="' + esc(t.smbDelete) + '">' + I.trash + '</button>' +
      '</span></td>' +
    '</tr>').join('');

  const count = document.getElementById('count-smb');
  if (count) { count.textContent = list.length; }

  document.getElementById('btn-smb-save').disabled = !smbDirty;
  document.getElementById('smb-field').value = smbSerialise();
}

function openSmbDrawer(index) {
  smbEditing = index;
  const s = index === null ? null : smbSections[index];
  document.getElementById('smb-drawer-title').textContent =
    index === null ? T[lang].smbDrawerAdd : T[lang].smbDrawerEdit;
  document.getElementById('smb-name').value = s ? s.name : '';
  document.getElementById('smb-path').value = s && s.path ? s.path : '';
  // Renaming is allowed: in smb.conf it is one line, the [name] header, and no
  // file moves. What it costs is outside this machine, and the drawer says so.
  document.getElementById("smb-name").readOnly = false;
  document.getElementById('smb-drawer-problem').hidden = true;
  smbAclLastPath = null;   // so re-opening a drawer re-reads the folder
  smbPreview();
  // Opened at the folder the share already points at, so editing one starts
  // where it is rather than at the roots.
  smbPick(s && s.path ? s.path.replace(new RegExp("/$"), "") : "");
  smbDrawer.classList.add('open');
  scrim.classList.add('open');
  document.body.classList.add('locked');
  document.getElementById(index === null ? 'smb-name' : 'smb-path').focus();
}

function closeSmbDrawer() {
  smbDrawer.classList.remove('open');
  scrim.classList.remove('open');
  document.body.classList.remove('locked');
  smbEditing = null;
}

function smbProblem() {
  const t = T[lang];
  const name = document.getElementById('smb-name').value.trim();
  const path = document.getElementById('smb-path').value.trim();

  if (!name) return t.smbNeedName;
  // Samba allows more than this, but a share reached from Windows Explorer with
  // a space or a slash in its name is a support call, not a feature.
  if (!/^[A-Za-z0-9._-]+$/.test(name)) return t.smbBadName;
  if (SMB_RESERVED_JS.includes(name.toLowerCase())) return t.smbReservedName;
  // Its own name is not a clash with itself, so an edit that only changes the
  // folder is not refused.
  if (smbShares().some(s => s.i !== smbEditing && s.name.toLowerCase() === name.toLowerCase())) {
    return t.smbExists;
  }
  if (!path) return t.smbNeedPath;
  if (!path.startsWith('/')) return t.smbBadPath;
  return null;
}

function smbPreview() {
  const t = T[lang];
  const p = smbProblem();
  const box = document.getElementById('smb-drawer-problem');
  box.hidden = !p;
  if (p) { box.textContent = p; }
  document.getElementById('smb-drawer-save').disabled = !!p;

  const name = document.getElementById('smb-name').value.trim();
  document.getElementById('smb-drawer-preview').textContent =
    p ? '' : t.smbPreview(location.hostname, name);

  // Only while the name has actually been changed, so it is a consequence
  // rather than a standing warning nobody reads.
  const original = smbEditing === null ? null : smbSections[smbEditing].name;
  document.getElementById("smb-rename-note").hidden = original === null || original === name;

  // The boxes describe the folder in the box, so they are re-read whenever it
  // changes rather than only when the drawer opens.
  const p2 = document.getElementById("smb-path").value.trim();
  if (p2 !== smbAclLastPath) { smbAclLastPath = p2; smbReadAccess(p2); }
}

['input', 'change'].forEach(ev =>
  document.getElementById('smb-drawer').addEventListener(ev, smbPreview));

document.getElementById('add-smb').addEventListener('click',
  () => { leaveEditModeForAdd(); openSmbDrawer(null); });
document.getElementById('smb-drawer-cancel').addEventListener('click', closeSmbDrawer);
document.getElementById('smb-drawer-close').addEventListener('click', closeSmbDrawer);

document.getElementById('smb-drawer-save').addEventListener('click', async () => {
  if (smbProblem()) return;
  const name = document.getElementById('smb-name').value.trim();
  const path = document.getElementById('smb-path').value.trim();

  if (smbEditing === null) {
    smbSections.push({ name: name, raw: smbTemplate(name, path), path: path, reserved: false, dirty: true });
  } else {
    const sec = smbSections[smbEditing];
    if (sec.name !== name) {
      // One line, the section header. Everything else in the block, including a
      // comment somebody wrote by hand, is left exactly as it was.
      sec.raw = sec.raw.split(String.fromCharCode(10)).map(l => {
        const s = l.trim();
        return (s.startsWith("[") && s.endsWith("]")) ? "[" + name + "]" : l;
      }).join(String.fromCharCode(10));
      sec.name = name;
    }
    smbSetPath(sec, path);
    sec.dirty = true;
  }
  smbDirty = true;
  closeSmbDrawer();
  renderSmb();

  // Keep it means keep it, the same as the row drawer's Keep this change: the
  // share goes to the machine now rather than waiting behind a second button.
  // The row sweeps and the page locks while it runs.
  document.querySelectorAll('#smb-body tr').forEach(tr => {
    if (tr.querySelector('.name') && tr.querySelector('.name').textContent === name) {
      tr.classList.add('working');
    }
    tr.querySelectorAll('button').forEach(b => { b.disabled = true; });
  });
  document.body.classList.add('locked');

  // The folder's permissions first, then the config. A share saved onto a
  // folder its group cannot enter serves an empty list and reads as broken.
  await smbApplyAccess();

  document.getElementById('btn-smb-save').click();
});

document.getElementById('smb-body').addEventListener('click', e => {
  const ed = e.target.closest('[data-smb-edit]');
  if (ed) {
    const i = Number(ed.dataset.smbEdit);
    if (!smbSections[i].path) { alert(T[lang].smbNoPathLine); return; }
    openSmbDrawer(i);
    return;
  }
  const del = e.target.closest('[data-smb-del]');
  if (del) {
    const i = Number(del.dataset.smbDel);
    // Removing a share does NOT remove the folder, the same as removing a
    // website leaves its files. Said in the confirm, not only in the note.
    if (!confirm(T[lang].smbDelConfirm(smbSections[i].name, smbSections[i].path || ''))) return;
    smbSections[i].removed = true;
    smbDirty = true;
    renderSmb();

    // The confirm WAS the second press, so this goes to the machine now. Its own
    // row sweeps, the same as removing a mailbox, rather than the whole table
    // greying: the struck-through row is the thing worth watching.
    document.querySelectorAll(`tr[data-smb="${i}"]`).forEach(tr => {
      tr.classList.add('working');
      tr.querySelectorAll('button').forEach(b => { b.disabled = true; });
    });
    document.body.classList.add('locked');
    document.getElementById('btn-smb-save').click();
  }
});



// The folder's permissions, which are not in smb.conf and are not published
// with it. Read whenever the path changes, so the boxes always describe the
// folder currently in the box rather than the one the drawer opened on.
let smbAclFor = null;      // the path the boxes currently describe
let smbAclLastPath = null; // what smbPreview last asked about, so it asks once
let smbAclProtected = false;

const aclBoxes = () => ['acl-r', 'acl-w', 'acl-x'].map(id => document.getElementById(id));

function aclSetBoxes(rwx, enabled) {
  const [r, w, x] = aclBoxes();
  r.checked = rwx.indexOf('r') !== -1;
  w.checked = rwx.indexOf('w') !== -1;
  x.checked = rwx.indexOf('x') !== -1;
  [r, w, x].forEach(b => { b.disabled = !enabled; });
  document.getElementById('acl-deep').disabled = !enabled;
}

function aclWanted() {
  const [r, w, x] = aclBoxes();
  return (r.checked ? 'r' : '-') + (w.checked ? 'w' : '-') + (x.checked ? 'x' : '-');
}

async function smbReadAccess(path) {
  const t = T[lang];
  const state = document.getElementById('smb-acl-state');
  const prot = document.getElementById('smb-acl-protected');

  smbAclFor = null;
  smbAclProtected = false;
  prot.hidden = true;

  if (!path || !path.startsWith('/')) {
    state.textContent = '';
    aclSetBoxes('---', false);
    return;
  }

  state.textContent = t.smbPickLoading;
  let data;
  try {
    const r = await fetch('?access=' + encodeURIComponent(path), { headers: { 'Accept': 'application/json' } });
    data = await r.json();
  } catch (_) {
    data = { error: t.smbPickFailed };
  }

  if (data.error) {
    state.textContent = data.error;
    aclSetBoxes('---', false);
    return;
  }

  smbAclFor = data.path;
  smbAclProtected = !!data.protected;
  aclSetBoxes(data.rwx || '---', !smbAclProtected);
  state.textContent = t.aclNow(data.owner, data.group, data.mode);

  if (smbAclProtected) {
    prot.hidden = false;
    prot.textContent = t.aclProtected(data.owner);
  }
}

// Its own press. A permission is not part of the config, so it is not published
// with it, and it is applied before the share is saved: a share whose folder
// the group cannot enter serves an empty list.
async function smbApplyAccess() {
  if (!smbAclFor || smbAclProtected) return true;
  const body = new URLSearchParams({ action: 'setaccess', path: smbAclFor, rwx: aclWanted() });
  // Off unless asked for: recursing rewrites modes somebody may have set
  // deliberately on files this has never seen.
  if (document.getElementById('acl-deep').checked) { body.set('deep', '1'); }
  try {
    const r = await fetch(location.pathname, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
      redirect: 'follow'
    });
    return r.ok;
  } catch (_) {
    return false;
  }
}

// The picker walks one level at a time, because that is what the lister
// returns. Clicking a folder both fills the box and steps into it: the folder
// you can see is the folder you get, and going deeper is the same gesture.
let smbPickAt = '';
let smbRoots = [];

// Where "up" stops. The lister refuses anything outside the roots, so a parent
// that is not inside one is not a folder to show: it is the roots list.
function smbInsideRoot(p) {
  return smbRoots.some(r => p === r || p.startsWith(r + '/'));
}

async function smbPick(where) {
  const list = document.getElementById('smb-pick-list');
  const here = document.getElementById('smb-pick-here');
  const t = T[lang];

  list.innerHTML = '<li class="note picker-empty">' + esc(t.smbPickLoading) + '</li>';
  let data;
  try {
    const r = await fetch('?folders=' + encodeURIComponent(where), { headers: { 'Accept': 'application/json' } });
    data = await r.json();
  } catch (_) {
    data = { error: t.smbPickFailed };
  }

  if (Array.isArray(data.roots)) { smbRoots = data.roots; }

  if (data.error) {
    here.textContent = where || '/';
    list.innerHTML = '<li class="note picker-empty">' + esc(data.error) + '</li>';
    document.getElementById('smb-pick-up').disabled = false;
    return;
  }

  smbPickAt = data.path || '';
  here.textContent = smbPickAt || t.smbPickRoots;
  document.getElementById('smb-pick-up').disabled = smbPickAt === '';

  const dirs = data.dirs || [];
  // The name, not the whole path. The path is already on the line above, and
  // eight rows of /home/admin/... is a column of identical prefixes.
  const label = d => smbPickAt === '' ? d : d.slice(smbPickAt.length).replace(/^\//, '');
  list.innerHTML = dirs.length
    ? dirs.map(d =>
        '<li><button type="button" data-pick="' + esc(d) + '" title="' + esc(d) + '">' +
        esc(label(d)) + '</button></li>').join('')
    : '<li class="note picker-empty">' + esc(t.smbPickEmpty) + '</li>';
}

document.getElementById('smb-pick-list').addEventListener('click', e => {
  const b = e.target.closest('[data-pick]');
  if (!b) return;
  const dir = b.dataset.pick;
  // Trailing slash, because every share already in the file has one and a
  // config that is consistent is a config that diffs cleanly.
  document.getElementById('smb-path').value = dir.replace(/\/?$/, '/');
  smbPreview();
  smbPick(dir);
});

document.getElementById('smb-pick-up').addEventListener('click', () => {
  const up = smbPickAt.replace(/\/[^/]+\/?$/, '');
  // One press above /home/admin is /home, which the lister refuses. That
  // is not a dead end, it is the top: go back to the roots rather than showing
  // an error nobody can act on.
  smbPick(up && smbInsideRoot(up) ? up : '');
});

if (SMB_READABLE) { renderSmb(); }
