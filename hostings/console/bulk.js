// Edit mode: the tick boxes that act on many rows at once.
//
// The tables are data until Edit is pressed. Pressing it adds three columns
// and an Apply changes button, and pressing it again takes them away without
// acting on anything: leaving edit mode is always safe.
//
// The per-row trashcan is untouched and still deletes one row immediately.
// These tick boxes are the other path: they batch, and nothing happens until
// Apply changes.

// Rows in these tables are config rows the page already indexes by data-row.
// Machine pages and shared folders are their own structures and are not here
// yet.
const BULK_TABS = ['apps', 'websites', 'proxies', 'mailboxes', 'machine', 'smb'];

// Machine pages are not config rows: they are PANEL lines keyed by an id, and
// their tick boxes act on that id rather than on an index into `rows`.
const BULK_BY_ID = ['machine'];

// Shared folders are sections of a real smb.conf, keyed by their index in it,
// and they are saved by their own button rather than by the row apply.
const BULK_SMB = 'smb';

// Proxies have no enable and disable: they are for testing, and the one real
// proxy is Jenkins, which stays reachable.
const BULK_NO_STATE = ['proxies'];

// var, not let: cells.js reads this to decide whether to draw a trashcan, and
// it is loaded before this file. A let would be in its temporal dead zone, and
// even `typeof` throws on one of those, which would take the first render with
// it rather than reading as "not in edit mode".
var EDITMODE = false;

// rowIndex -> 'delete' | 'enable' | 'disable'. One op per row: the three tick
// boxes are a choice, not a combination.
const bulkOps = new Map();

// contact@ on any domain. Excluded from bulk delete, and from the select-all
// that fills it: it is the forward target the other mailboxes are given when
// they go, so it cannot leave in the same press as they do.
function isContactRow(r) {
  return !!r && r.f[0] === 'mailbox'
      && (r.f[1] || '').trim().toLowerCase() === 'contact';
}

function rowEnabled(r) {
  return String((r && r.f && r.f[14]) || 'yes').trim().toLowerCase() !== 'no';
}

function bulkCount() { return bulkOps.size; }

// Every pane gets the same two buttons, built here rather than in the page, so
// the seven of them cannot drift apart.
function buildBulkButtons() {
  const t = T[lang];
  document.querySelectorAll('.row-actions[data-pane]').forEach(pane => {
    if (pane.querySelector('.edit-btn')) return;
    if (!BULK_TABS.includes(pane.dataset.pane)) return;

    // Both buttons wear the pane hue, read off the add button that is already
    // there rather than restated, so a new kind cannot give them a colour of
    // its own.
    const hue = [...(pane.querySelector('.add-btn') || { classList: [] }).classList]
                  .filter(c => c !== 'add-btn').join(' ');

    const edit = document.createElement('button');
    edit.type = 'button';
    edit.className = ('edit-btn ' + hue).trim();
    edit.innerHTML = I.edit + '<span>' + esc(t.bEdit) + '</span>';
    edit.addEventListener('click', toggleEditMode);

    const apply = document.createElement('button');
    apply.type = 'button';
    apply.className = ('bulk-apply ' + hue).trim();
    apply.setAttribute('data-i18n', 'bBulkApply');
    apply.textContent = t.bBulkApply;
    apply.disabled = true;
    apply.hidden = true;
    // Wrapped, not passed directly: addEventListener hands the listener the
    // click Event, which as bulkApply's first argument reads as "the
    // repositories have already been answered" and skips the whole per-row
    // question. It did exactly that on the first press, 2026-09-03.
    apply.addEventListener('click', () => bulkApply());

    // Before the add button, which stays the rightmost thing on every pane:
    // its position is how you find it, and a button that moves when a mode is
    // entered is a button you have to look for.
    const addBtn = pane.querySelector('.add-btn');
    if (addBtn) { pane.insertBefore(edit, addBtn); pane.insertBefore(apply, addBtn); }
    else { pane.append(edit, apply); }
  });

  // Discard belongs with them rather than under the tables: it undoes the same
  // edits these buttons make. Every pane gets one, including those with no tick
  // boxes, and it sits before the add button like the other two, so the order
  // reads edit, apply, discard, add on every pane.
  document.querySelectorAll('.row-actions[data-pane]').forEach(pane => {
    if (pane.querySelector('.discard-btn')) return;
    const hue = [...(pane.querySelector('.add-btn') || { classList: [] }).classList]
                  .filter(c => c !== 'add-btn').join(' ');
    const undo = document.createElement('button');
    undo.type = 'button';
    undo.className = ('discard-btn ' + hue).trim();
    undo.hidden = true;
    undo.addEventListener('click', discardChanges);
    const add = pane.querySelector('.add-btn');
    if (add) { pane.insertBefore(undo, add); } else { pane.append(undo); }
  });
}

// Reload rather than undo each edit in turn: the page is built from the
// published config on load, so fetching it again IS the revert, and there is no
// list of changes to walk backwards through and get wrong.
function discardChanges() {
  if (!confirm(T[lang].discardConfirm)) return;
  window.location.href = window.location.pathname;
}

// Tick or clear one column across one table. The boxes already know what they
// may do: a disabled one is a row this column cannot change, so it is skipped
// rather than forced.
function selectColumn(tbl, col, on) {
  const cols = tbl.querySelectorAll('thead .bulk-col').length;
  const at = [...tbl.querySelectorAll('thead .bulk-col')]
    .findIndex(th => th.querySelector('.bulk-head').textContent === T[lang]['c' +
      col.charAt(0).toUpperCase() + col.slice(1)]);
  if (at < 0) return;

  tbl.querySelectorAll('tbody tr').forEach(tr => {
    const boxes = tr.querySelectorAll('.bulk-col input[type="checkbox"]');
    if (boxes.length !== cols) return;      // a spacer row has empty cells
    const box = boxes[at];
    if (!box || box.disabled) return;
    if (box.checked === on) return;
    box.checked = on;
    box.dispatchEvent(new Event('change'));
  });
}

// Each header box reports its own column: all of what it may tick, some of it,
// or none. Indeterminate is the honest third state and the browser draws it.
function paintSelectAll(tbl) {
  const heads = [...tbl.querySelectorAll('thead .bulk-col')];
  heads.forEach((th, at) => {
    const all = th.querySelector('.bulk-all');
    if (!all) return;
    let can = 0, on = 0;
    tbl.querySelectorAll('tbody tr').forEach(tr => {
      const boxes = tr.querySelectorAll('.bulk-col input[type="checkbox"]');
      if (boxes.length !== heads.length) return;
      const box = boxes[at];
      if (!box || box.disabled) return;
      can++;
      if (box.checked) on++;
    });
    all.disabled = can === 0;
    all.checked = can > 0 && on === can;
    all.indeterminate = on > 0 && on < can;
  });
}

// The owner's decision 2026-09-05: leaving Edit mode throws everything away, ticks
// and pending row edits together, after asking.
//
// It CHANGES what happens, and the change is deliberate. Before this, turning
// Edit mode off silently cleared the ticks while leaving edited rows staged
// behind a Discard button, so the mode you left and the state you were in
// disagreed. In or out is the point of a mode.
//
// The revert is a reload, the same one discardChanges() uses: the page is built
// from the published config on load, so fetching it again IS the undo.
function toggleEditMode() {
  const t = T[lang];
  if (EDITMODE) {
    const ticks = bulkCount();
    const edits = rows.filter(r => r.dirty || r.deleted).length;
    if (ticks || edits) {
      if (!confirm(t.editLeaveDiscard(ticks, edits))) return;
      if (edits) { window.location.href = window.location.pathname; return; }
    }
  }
  EDITMODE = !EDITMODE;
  if (!EDITMODE) bulkOps.clear();
  render();
}

// Called at the end of render, so the columns survive every repaint.
function paintEditCols() {
  const t = T[lang];

  document.querySelectorAll('.row-actions[data-pane]').forEach(pane => {
    const apply = pane.querySelector('.bulk-apply');
    const edit  = pane.querySelector('.edit-btn');
    if (!apply || !edit) return;
    apply.hidden   = !EDITMODE;
    apply.disabled = bulkCount() === 0;
    edit.classList.toggle('active', EDITMODE);
    edit.innerHTML = I.edit + '<span>' + esc(EDITMODE ? t.bEditDone : t.bEdit) + '</span>';
  });

  // Hidden, not disabled, when there is nothing to throw away. A button that
  // can never be pressed is one more thing to read past on a clean page.
  document.querySelectorAll('.discard-btn').forEach(b => {
    b.hidden = !isDirty();
    b.innerHTML = I.undo + '<span>' + esc(t.bDiscard) + '</span>';
  });

  document.querySelectorAll('table[data-table]').forEach(tbl => {
    tbl.querySelectorAll('.bulk-col').forEach(el => el.remove());

    const kind = tbl.dataset.table;
    if (!EDITMODE || !BULK_TABS.includes(kind)) return;

    const withState = !BULK_NO_STATE.includes(kind);
    const cols = withState ? ['delete', 'enable', 'disable'] : ['delete'];
    const label = { delete: t.cDelete, enable: t.cEnable, disable: t.cDisable };

    const hrow = tbl.querySelector('thead tr');
    if (hrow) {
      cols.slice().reverse().forEach(c => {
        const th = document.createElement('th');
        th.className = 'bulk-col';

        const cap = document.createElement('span');
        cap.className = 'bulk-head';
        cap.textContent = label[c];

        // Select all, for this column and this table only. It ticks every box
        // the column would allow, which is never all of them: a row already
        // disabled cannot be disabled again, and a row marked for deletion is
        // not also being switched. Those stay untouched rather than silently
        // doing something else.
        const all = document.createElement('input');
        all.type = 'checkbox';
        all.className = 'bulk-all';
        all.title = t.selectAll;
        all.setAttribute('aria-label', t.selectAll + ': ' + label[c]);
        all.addEventListener('change', () => selectColumn(tbl, c, all.checked));

        th.append(cap, all);
        hrow.prepend(th);
      });
    }

    const byId  = BULK_BY_ID.includes(kind);
    const isSmb = kind === BULK_SMB;

    tbl.querySelectorAll('tbody tr').forEach(tr => {
      const idx = byId ? tr.dataset.panelRow
                : isSmb ? tr.dataset.smbRow
                : tr.dataset.row;
      // A row with no index is a spacer or a message, not something to act on.
      if (idx === undefined || idx === '') {
        cols.forEach(() => {
          const td = document.createElement('td');
          td.className = 'bulk-col';
          tr.prepend(td);
        });
        return;
      }
      // The key is an id for a machine page and an index everywhere else, and
      // it is what bulkOps is keyed by either way.
      const i = byId ? idx : Number(idx);
      // A share is keyed by a number like a row, so it needs its own key space
      // or index 3 would mean both the fourth row and the fourth section.
      const key = isSmb ? 'smb:' + i : i;
      const on = byId  ? !panelOff.has(idx)
               : isSmb ? (smbSections[i] || {}).enabled !== 'no'
               : rowEnabled(rows[i]);
      const op = bulkOps.get(key) || '';

      cols.slice().reverse().forEach(c => {
        const td = document.createElement('td');
        td.className = 'bulk-col';
        const box = document.createElement('input');
        box.type = 'checkbox';
        box.checked = op === c;
        // Enable is blocked on a row that is already enabled, and disable on
        // one already disabled: the tick box says what it would change, so a
        // box that would change nothing cannot be ticked.
        box.disabled = (c === 'enable'  && on)
                    || (c === 'disable' && !on)
                    // Delete supersedes: a row on its way out is not also
                    // being turned on or off.
                    || (op === 'delete' && c !== 'delete')
                    // contact@ is never part of a bulk delete. It is the
                    // forward target of every other mailbox on its domain, so
                    // manage_mail.sh refuses it while any forward still points
                    // there, and a select-all could therefore only ever fail on
                    // that one row. Removing it is a deliberate act on its own,
                    // after the others have gone. The owner's call, 2026-09-02.
                    || (c === 'delete' && !byId && !isSmb && isContactRow(rows[i]));
        if (box.disabled && c === 'delete' && !byId && !isSmb && isContactRow(rows[i])) {
          box.title = T[lang].bulkNoContact;
        }
        box.addEventListener('change', () => {
          if (box.checked) { bulkOps.set(key, c); } else { bulkOps.delete(key); }
          render();
        });
        td.append(box);
        tr.prepend(td);
      });
    });

    paintSelectAll(tbl);
  });
}

// The only thing here that writes. Marks the rows, then hands over to the same
// chooser the drawer uses, so a batch of vhost-only changes still takes the
// fast path and anything touching a unit takes the full job.
// The rows a batch is about to touch, so they can be swept while it runs.
// A key is a row index, a machine page id, or 'smb:<n>', and each shape lives
// in a different table, so the selector is chosen per key rather than guessed.
function sweepKeys(keys) {
  const sel = k => (typeof k !== 'string') ? `tr[data-row="${k}"]`
                 : k.startsWith('smb:')    ? `tr[data-smb-row="${k.slice(4)}"]`
                 :                           `tr[data-panel-row="${k}"]`;
  keys.forEach(k => document.querySelectorAll(sel(k)).forEach(tr => {
    tr.classList.add('working');
    tr.querySelectorAll('button').forEach(b => { b.disabled = true; });
  }));
}

// repoAnswered: set only by the recursive call below, once every row that owns
// a repository has been asked about.
function bulkApply(repoAnswered) {
  if (bulkCount() === 0) return;

  const t = T[lang];

  // smb.conf and hostings.conf are published by different buttons, and the
  // share one reloads the page when it finishes. A selection spanning both
  // would therefore save the shares and throw the rest away, so it is refused
  // rather than half-applied.
  const keys = [...bulkOps.keys()];
  const isShare = k => typeof k === 'string' && k.startsWith('smb:');
  if (keys.some(isShare) && keys.some(k => !isShare(k))) {
    alert(t.bulkMixed);
    return;
  }

  // Not asked again on the way back through: the operator has just answered a
  // dialog per repository, and a second "are you sure" after that reads as a
  // fault rather than a safeguard.
  const dels = [...bulkOps.values()].filter(v => v === 'delete').length;
  if (!repoAnswered && dels && !confirm(t.bulkDelConfirm.replace('{n}', dels))) return;

  // ASK ABOUT EVERY REPOSITORY BEING DELETED, one row at a time.
  //
  // This set r.deleted and never set repoOp at all, so Delete all checked
  // ALWAYS left every repository standing on GitHub and said nothing about it.
  // The owner's decision 2026-09-03: ask per row, keep / archive / delete, not
  // once for the batch, because the rows are not interchangeable and one
  // answer for all of them is the kind of default that deletes something you
  // meant to keep.
  //
  // Asked before anything is published. Cancel part way through does NOT undo
  // the rows already answered: they keep their answer and stay marked deleted,
  // and nothing reaches GitHub or the config until a save runs. Say it plainly
  // rather than claim the selection is untouched, because it is not.
  if (!repoAnswered) {
    const repoQueue = [...bulkOps.entries()]
      .filter(([k, op]) => op === 'delete' && typeof k === 'number')
      .map(([k]) => k)
      .filter(i => {
        const repo = ((rows[i] && rows[i].f[8]) || '').trim();
        return repo && repo !== '-' && repo.toLowerCase() !== 'new';
      });

    if (repoQueue.length && typeof askRowDeletes === 'function') {
      // The flag is the argument, not a module variable: a variable reset
      // before the recursive call would ask the same batch again forever.
      askRowDeletes(repoQueue, () => bulkApply(true));
      return;
    }
  }

  // Shared folders are saved by their own button against smb.conf, so they are
  // applied first and separately from anything in hostings.conf.
  let smbTouched = false;
  bulkOps.forEach((op, key) => {
    if (typeof key !== 'string' || !key.startsWith('smb:')) return;
    const i = Number(key.slice(4));
    if (op === 'delete') {
      // Removing a share does not remove the folder, the same as the trashcan.
      if (smbSections[i]) { smbSections[i].removed = true; smbDirty = true; }
    } else {
      smbSetEnabled(i, op === 'enable');
    }
    smbTouched = true;
  });

  bulkOps.forEach((op, i) => {
    if (typeof i === 'string' && i.startsWith('smb:')) return;
    // A machine page: the key is its id, and its state lives in PANELS_OFF
    // rather than on the row.
    if (typeof i === 'string') {
      if (op === 'delete') { panelGone.add(i); panelOff.delete(i); return; }
      if (op === 'disable') { panelOff.add(i); } else { panelOff.delete(i); }
      return;
    }

    const r = rows[i];
    if (!r) return;
    if (op === 'delete') {
      r.deleted = true;
      // A mailbox needs to say what happens to its files. Bulk delete keeps
      // them and forwards, which is the reversible half of the dialog.
      if (r.f[0] === 'mailbox') r.mailOp = 'forward';
      r.fastOnly = false;
      return;
    }
    r.f[14] = (op === 'enable') ? 'yes' : 'no';
    r.dirty = true;
    // Turning a website on or off is a vhost change; everything else reaches a
    // unit, a service or the mail stack.
    //
    // A plain `=` here DISCARDED an earlier false, so a row whose environments
    // had already been edited in the drawer was reclassified fast-safe by a
    // later bulk enable, and the whole pending set took the vhost-only path.
    // Same shape as the mailbox exemption in pendingIsFastOnly: a false has to
    // win, whatever is decided afterwards. drawer.js has always done it this
    // way; this was the one place that did not.
    r.fastOnly = (r.fastOnly !== false) && (r.f[0] === 'website');
  });

  // Captured before the map is cleared: these are the rows to sweep.
  const touched = [...bulkOps.keys()];

  bulkOps.clear();
  EDITMODE = false;
  render();
  if (typeof renderSmb === 'function') renderSmb();

  // The same sweep the drawer's Keep this change runs, on every row in the
  // batch. Without it a bulk apply looked like nothing had happened until the
  // page reloaded, which for a fast apply is half a minute of silence.
  sweepKeys(touched);
  document.body.classList.add('locked');

  if (smbTouched) {
    document.getElementById('btn-smb-save').click();
    return;
  }
  startSaveFromDrawer();
}

// The scripts sit at the end of the body, so the panes exist by now.
buildBulkButtons();

// Adding a row is not a bulk operation, so pressing any Add button drops out of
// Edit mode first. Ticks go, because a selection made against one table means
// nothing once a drawer is open; staged row edits stay, behind Discard, since
// they were typed rather than ticked.
function leaveEditModeForAdd() {
  if (!EDITMODE) return;
  EDITMODE = false;
  bulkOps.clear();
  render();
}
