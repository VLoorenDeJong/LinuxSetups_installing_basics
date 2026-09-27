// -----------------------------------------------------------------------------
// The people who may sign in.
//
// One htpasswd file guards the console, every machine page with a login, every
// LAN preview and every row whose AuthProtected names an environment, so this
// is one list for all of them. It is NOT a config row: nothing here is staged,
// published or applied, and every press takes effect on the machine at once.
// That is why each one asks first where it cannot be undone.
//
// Switching off comes before deleting everywhere it is offered. A deleted user
// cannot be told apart from one who never existed, so a row that named them
// loses its access with nothing saying why.
// -----------------------------------------------------------------------------
let USERS = [];
// How many mailboxes somebody may have when their line says nothing. Sent by
// --list so the number lives in ONE place: the script, the page and the
// comment cannot disagree about it.
let MAILBOX_DEFAULT = 5;
// One op per user, name -> 'delete' | 'enable' | 'disable'. The same shape the
// other tabs use, and for the same reason: three verb buttons here and tick
// columns everywhere else meant the same job was done two ways. The owner,
// 2026-09-10.
//
// NOT bulk.js. That stages edits to config rows and publishes them; a user
// change is applied the moment Apply is pressed, so the two only look alike.
const userOps = new Map();

// The three columns, in the order they are shown.
const USER_COLS = ['delete', 'enable', 'disable'];

// The table is data only until Edit is pressed, exactly as every other tab is
// since 2026-08-31. Written down in .claude/docs/disable-and-bulk-decisions.md,
// whose trigger is touching the tick columns, and which I did not read before
// building these: the owner had to point out that Users showed them always.
function usersEditing() { return typeof EDITMODE !== 'undefined' && EDITMODE; }

function usersRefreshBar() {
  const apply = document.getElementById('users-apply');
  if (!apply) return;
  const n = userOps.size;
  apply.hidden = !usersEditing();
  apply.disabled = n === 0;
  apply.textContent = T[lang].bBulkApply + (n ? ' (' + n + ')' : '');
  document.querySelectorAll('table[data-table="users"] th.ubulk-col')
    .forEach(th => { th.hidden = !usersEditing(); });
  const edit = document.getElementById('users-edit');
  if (edit) {
    edit.classList.toggle('active', usersEditing());
    edit.innerHTML = I.edit + '<span>' + esc(usersEditing() ? T[lang].bEditDone : T[lang].bEdit) + '</span>';
  }
}

// Would this tick change anything? A user already enabled cannot be enabled,
// one already disabled cannot be disabled, and a user on their way out is not
// also being switched. The owner asked for exactly this, 2026-09-10.
function userBoxDisabled(u, col) {
  const op = userOps.get(u.name) || '';
  if (op === 'delete' && col !== 'delete') return true;
  if (col === 'enable'  && u.enabled) return true;
  if (col === 'disable' && !u.enabled) return true;
  return false;
}

function renderUsers() {
  const body = document.getElementById('users-body');
  if (!body) return;
  const t = T[lang];

  const count = document.getElementById('count-users');
  if (count) count.textContent = USERS.length ? USERS.length : '';

  if (!USERS.length) {
    body.innerHTML = `<tr><td colspan="10" class="note">${esc(t.uNone)}</td></tr>`;
    usersRefreshBar();
    return;
  }

  body.innerHTML = USERS.map(u => {
    // The admin account gets empty cells rather than boxes that refuse when
    // pressed: a control that can only say no is worse than one visibly not
    // for now.
    const ticks = !usersEditing() ? '' : USER_COLS.map(col => {
      if (u.admin) return '<td class="ubulk-col"></td>';
      const op = userOps.get(u.name) || '';
      return `<td class="ubulk-col"><input type="checkbox"
        data-user-op="${esc(col)}" data-user-name="${esc(u.name)}"
        ${op === col ? 'checked' : ''}
        ${userBoxDisabled(u, col) ? 'disabled' : ''}></td>`;
    }).join('');
    // The role is what a person MAY do; the address is where they are told.
    // Both come from the side file, and a name with no line reads as Admin,
    // which is the smaller set.
    // In Edit mode the role is the same dropdown the row drawer and the user
    // drawer use, so changing somebody's role is one click wherever you happen
    // to be. The owner, 2026-09-10. Outside Edit mode it is a chip, because the
    // table is data only until Edit is pressed, like every other tab.
    //
    // The admin account gets a chip either way: the script refuses to make it
    // anything but full, and a control that can only say no is worse than one
    // visibly not for now.
    const roleChip = u.role === 'full'
      ? `<span class="chip go">${esc(t.uRoleFull)}</span>`
      : u.role === 'admin'
        ? `<span class="chip">${esc(t.uRoleAdmin)}</span>`
        // No role is not a lesser role, it is no access to this page at all,
        // so it is greyed rather than coloured like the two that work.
        : `<span class="chip off">${esc(t.uRoleNone)}</span>`;
    const roleOpt = (val, label) =>
      `<option value="${val}" ${(u.role || 'none') === val ? 'selected' : ''}>${esc(label)}</option>`;
    const role = (!usersEditing() || u.admin) ? roleChip
      : `<select data-user-role="${esc(u.name)}">
           ${roleOpt('none',  t.uRoleNone)}
           ${roleOpt('admin', t.uRoleAdmin)}
           ${roleOpt('full',  t.uRoleFull)}
         </select>`;
    // How many mailboxes this person may make for themselves, 0 to 30, and the
    // same shape as the Role column beside it: a chip until Edit is pressed,
    // a dropdown after. The owner, 2026-09-10.
    //
    // Empty is not zero. A blank line means "use the default", which --list
    // sends as mailbox_default, so raising the default later moves everybody
    // who never had a number set. Writing the number onto every line would
    // freeze each of them on today's figure.
    const boxNum = (u.mailboxes === null || u.mailboxes === undefined)
      ? null : Number(u.mailboxes);
    // Just the number. The default materialises on save now, so a line that
    // still says nothing is simply showing what it would get.
    const boxLabel = boxNum === null ? String(MAILBOX_DEFAULT) : String(boxNum);
    const boxOpt = n =>
      `<option value="${n}" ${boxNum === n ? 'selected' : ''}>${n}</option>`;
    const boxes = (!usersEditing() || u.admin)
      ? `<span class="chip">${boxLabel}</span>`
      : `<select data-user-boxes="${esc(u.name)}">
           <option value="" ${boxNum === null ? 'selected' : ''}
             >${MAILBOX_DEFAULT} (${esc(t.uMailboxesDefault)})</option>
           ${Array.from({ length: 31 }, (_, n) => boxOpt(n)).join('')}
         </select>`;
    const mail = u.email
      ? esc(u.email)
      : `<span class="note">${esc(t.uNoEmail)}</span>`;
    const state = u.enabled
      ? `<span class="chip up">${esc(t.uOn)}</span>`
      : `<span class="chip off">${esc(t.uOff)}</span>`;
    // What names them, which is the thing worth reading before deleting one.
    const used = u.rows && u.rows.length
      ? u.rows.map(r => `<span class="chip">${esc(r)}</span>`).join(' ')
      : `<span class="note">${esc(t.uUsedByNone)}</span>`;
    const btns = [
      `<button class="icon-btn" type="button" data-user-pw="${esc(u.name)}"
         title="${esc(t.uEdit)}" aria-label="${esc(t.uEdit)}">${I.edit}</button>`,
      // Only with an address to share to: the script refuses anything else.
      u.email ? `<button class="icon-btn" type="button" data-user-share="${esc(u.name)}"
         title="${esc(t.uShare)}" aria-label="${esc(t.uShare)}">${I.lock}</button>` : '',
      u.admin ? '' : (u.enabled
        // Not danger. Disabling keeps the password and Enable undoes it; only
        // the trashcan beside it cannot be taken back, and two red buttons in
        // one row said they were equally serious. The owner, 2026-09-10.
        ? `<button class="icon-btn" type="button" data-user-off="${esc(u.name)}"
             title="${esc(t.uDisable)}" aria-label="${esc(t.uDisable)}">${I.stop}</button>`
        : `<button class="icon-btn go" type="button" data-user-on="${esc(u.name)}"
             title="${esc(t.uEnable)}" aria-label="${esc(t.uEnable)}">${I.play}</button>`),
      // The trashcan is the one-row immediate delete and lives behind Edit as
      // well, per the same decision: the table is data only until Edit is
      // pressed.
      (u.admin || !usersEditing()) ? '' : `<button class="icon-btn danger" type="button" data-user-del="${esc(u.name)}"
           title="${esc(t.uDelete)}" aria-label="${esc(t.uDelete)}">${I.trash}</button>`
    ].filter(Boolean).join('');
    return `<tr class="${u.enabled ? '' : 'off'}">
      ${ticks}
      <td class="state-col">${state}</td>
      <td class="name">${esc(u.name)}${u.admin
        ? ` <span class="chip" title="${esc(t.uAdminWhy)}">${esc(t.uAdmin)}</span>` : ''}</td>
      <td>${role}</td>
      <td class="name">${mail}</td>
      <td>${boxes}</td>
      <td>${used}</td>
      <td><span class="row-actions">${btns}</span></td>
    </tr>`;
  }).join('');
  usersRefreshBar();
}

// Only a failure is shown: the save already happened here, and the hourly
// retry catches up, so "ok" needs nobody.
function showStoreState(store) {
  const el = document.getElementById('users-store');
  if (!el) return;
  const m = /^failed (\S+) ?(.*)$/.exec(store || '');
  el.hidden = !m;
  if (m) el.textContent = T[lang].uStoreFailed
    .replace('%s', new Date(m[1]).toLocaleString()).replace('%s', m[2]);
}

async function loadUsers() {
  try {
    const r = await fetch('?ask=users', { headers: { 'Accept': 'application/json' } });
    const j = await r.json();
    USERS = Array.isArray(j.users) ? j.users : [];
    if (typeof j.mailbox_default === 'number') MAILBOX_DEFAULT = j.mailbox_default;
    showStoreState(j.store);
  } catch (e) {
    USERS = [];
  }
  // A name that has gone is not still selected.
  // An op staged against a name that has gone is dropped rather than sent.
  [...userOps.keys()].forEach(n => { if (!USERS.some(u => u.name === n)) userOps.delete(n); });
  renderUsers();
}

// Every change goes through here, so there is one place that reports what the
// script said rather than a generic failure. The script's own last line is the
// message: "already exists" and "not a username" need different answers.
async function userOp(verb, name, pw) {
  const body = new URLSearchParams({ action: 'user', verb: verb, name: name });
  if (pw !== undefined) body.set('pw', pw);
  try {
    const r = await fetch(location.pathname, { method: 'POST', body: body,
      headers: { 'Accept': 'application/json' } });
    return await r.json();
  } catch (e) {
    return { ok: false, out: '' };
  }
}


// Who somebody is and what they may do. Its own call because it carries two
// extra values and no password, and because 105 and 106 will want to set a role
// from somewhere other than this drawer.
async function userMeta(name, role, email, boxes) {
  const body = new URLSearchParams({ action: 'user', verb: 'meta', name: name,
                                     role: role, email: email || '',
                                     boxes: (boxes === undefined || boxes === null) ? '' : String(boxes) });
  try {
    const r = await fetch(location.pathname, { method: 'POST', body: body,
      headers: { 'Accept': 'application/json' } });
    return await r.json();
  } catch (e) {
    return { ok: false, out: '' };
  }
}
function userSay(d, fallback) {
  const line = (d && d.out) ? d.out.split('\n').filter(Boolean).slice(-1)[0] : '';
  return line || fallback;
}


// ALLOWING A TYPED ADDRESS MEANS VALIDATING IT. The owner, 2026-09-10, naming the
// pattern: a combo box with allowCustom needs input validation, or the free
// half is where the bad values come in.
//
// Deliberately loose. It refuses what cannot be an address and what would break
// the file it is written into, and it does NOT try to decide whether a mailbox
// exists somewhere in the world: that is a question only sending to it answers.
//
//   empty        allowed. Nobody has to have an address
//   no @         refused
//   two @        refused
//   nothing either side of the @, or no dot after it   refused
//   a pipe, a hash, or a space                         refused: the side file
//                is `name | e-mail | role`, and a pipe in the middle field
//                would shift the role into somebody else's column
//
// The script refuses the same things again. This one exists so the answer is
// instant and says which rule was broken, not because the script is trusted
// less.
function emailProblem(addr) {
  const t = T[lang];
  if (addr === '') return '';
  if (/[|#\s]/.test(addr)) return t.uEmailBadChar;
  const at = addr.split('@');
  if (at.length !== 2) return t.uEmailNoAt;
  if (!at[0] || !at[1]) return t.uEmailNoAt;
  if (!/^[^.].*\.[A-Za-z]{2,}$/.test(at[1])) return t.uEmailNoDomain;
  return '';
}
// --- the drawer --------------------------------------------------------------
const userDrawer = document.getElementById('user-drawer');
const userScrim  = document.getElementById('user-scrim');
let userEditing  = null;          // null = adding, a name = changing a password


// THE ADDRESSES THIS MACHINE ACTUALLY HOSTS, offered rather than enforced.
// The owner, 2026-09-10.
//
// A list, not a closed dropdown: most customers are reached at an address that
// has nothing to do with this machine, billing@customer.example, and a select
// would make the common case the impossible one. A datalist suggests and still
// takes anything typed, which is the shape the App settings box already uses.
//
// DEFAULT: contact@<domain> of a domain this person owns a row on. That is the
// address a domain's mail is meant to reach, so it is the first guess rather
// than the only one, and it is only filled in when the box is empty.
function mailSuggestionsFor(name) {
  const all = (typeof mailEntries === 'function')
    ? mailEntries().filter(m => !m.deleted).map(m => m.addr) : [];
  // Their own domains first: an address on a domain they hold is the one being
  // looked for, and a long alphabetical list buries it.
  const mine = new Set();
  if (name) {
    rows.forEach(r => {
      if (String(r.f[15] || '').trim() !== name) return;
      const sub = String(r.f[4] || '').trim();
      if (!sub || sub === '-') { mine.add(BASE); return; }
      mine.add(sub.startsWith('=') ? sub.slice(1) : BASE);
    });
  }
  const ours = all.filter(a => mine.has(a.split('@')[1]));
  const rest = all.filter(a => !mine.has(a.split('@')[1]));
  return { list: [...ours, ...rest], preferred: ours.find(a => a.startsWith('contact@')) || ours[0] || '' };
}
function closeUserDrawer() {
  if (!userDrawer) return;
  userDrawer.classList.remove('open');
  userScrim.classList.remove('open');
  document.body.classList.remove('locked');
  userEditing = null;
}

function openUserDrawer(name) {
  if (!userDrawer) return;
  const t = T[lang];
  userEditing = name || null;
  const u = userEditing ? USERS.find(x => x.name === userEditing) : null;
  document.getElementById('user-drawer-title').textContent =
    userEditing ? t.uEditFor.replace('%s', userEditing) : t.uAdd;
  const nameEl = document.getElementById('user-name');
  nameEl.value = userEditing || '';
  nameEl.disabled = !!userEditing;      // a rename is a delete and an add
  document.getElementById('user-pw').value = '';
  // Blank means unchanged on an existing account, so the hint has to say so:
  // an empty box that means two different things is how a password gets
  // cleared by somebody who only came to change a role.
  const pwHint = document.getElementById('user-pw-hint');
  if (pwHint) pwHint.textContent = userEditing ? t.uPwKeep : t.uPwNeeded;
  // The addresses this machine hosts, offered as suggestions. contact@ on a
  // domain they own is filled in when the box is empty, and never over an
  // address somebody already chose.
  const sug = mailSuggestionsFor(userEditing);
  const dl = document.getElementById('user-email-list');
  if (dl) dl.innerHTML = sug.list.map(a => '<option value="' + esc(a) + '">').join('');
  document.getElementById('user-email').value = (u && u.email) ? u.email : sug.preferred;
  // Empty rather than the default number: writing 5 into the box would store 5
  // on that line, and the default could then never be changed for them again.
  // 0 to 30, with the default as the empty first option. A dropdown rather
  // than a number box so the same control appears here and in the table.
  const bsel = document.getElementById('user-boxes');
  bsel.innerHTML = '<option value="">' + MAILBOX_DEFAULT + ' (' + esc(t.uMailboxesDefault) + ')</option>'
    + Array.from({ length: 31 }, (_, n) => '<option value="' + n + '">' + n + '</option>').join('');
  bsel.value = (u && u.mailboxes !== null && u.mailboxes !== undefined) ? String(u.mailboxes) : '';
  const roleEl = document.getElementById('user-role');
  roleEl.value = u ? (u.role || 'none') : 'none';
  // The admin account is always full and the script refuses anything else, so
  // the control says so rather than offering a change that will be refused.
  roleEl.disabled = !!(u && u.admin);
  const msg = document.getElementById('user-msg');
  msg.hidden = true;
  msg.className = 'msg';
  userDrawer.classList.add('open');
  userScrim.classList.add('open');
  document.body.classList.add('locked');
  (userEditing ? document.getElementById('user-pw') : nameEl).focus();
}

const addUserBtn = document.getElementById('add-user');
if (addUserBtn) addUserBtn.addEventListener('click', () => openUserDrawer(null));
const userCancelBtn = document.getElementById('user-cancel');
if (userCancelBtn) userCancelBtn.addEventListener('click', closeUserDrawer);
if (userScrim) userScrim.addEventListener('click', closeUserDrawer);

// Add is a password and then a role; an edit is a role, and a password only if
// one was typed. Two calls rather than one verb doing both, because the script
// keeps the password on stdin and the role in argv, and mixing them would put a
// password where ps can read it.
// A typed address is checked as it is typed, so the answer arrives before Save
// rather than after it. The box goes red and Save refuses; nothing else stops
// somebody carrying on typing.
const userEmailBox = document.getElementById('user-email');
if (userEmailBox) userEmailBox.addEventListener('input', () => {
  const bad = emailProblem(userEmailBox.value.trim());
  userEmailBox.classList.toggle('bad', !!bad);
  const msg = document.getElementById('user-msg');
  if (bad) {
    msg.hidden = false; msg.className = 'msg bad'; msg.textContent = bad;
  } else if (msg.className === 'msg bad') {
    msg.hidden = true;
  }
});

const userForm = document.getElementById('user-form');
if (userForm) userForm.addEventListener('submit', async ev => {
  ev.preventDefault();
  const t = T[lang];
  const msg = document.getElementById('user-msg');
  const name  = document.getElementById('user-name').value.trim();
  const pw    = document.getElementById('user-pw').value;
  const email = document.getElementById('user-email').value.trim();
  const roleEl = document.getElementById('user-role');
  const role  = roleEl.disabled ? 'full' : roleEl.value;
  const show = (ok, text) => {
    msg.hidden = false;
    msg.className = 'msg ' + (ok ? 'good' : 'bad');
    msg.textContent = text;
  };
  if (!name) { show(false, t.uNeedName); return; }
  // Before the password is even sent: a refused address after a changed
  // password would leave half the drawer applied.
  const mailBad = emailProblem(email);
  if (mailBad) { show(false, mailBad); return; }
  // Checked here as well, so the answer is instant rather than a round trip.
  // Only on an add: an empty box on an existing account means "leave it".
  if (!userEditing && !pw) { show(false, t.uNeedPw); return; }

  if (!userEditing) {
    const d = await userOp('add', name, pw);
    if (!d.ok) { show(false, userSay(d, t.uFailed)); return; }
  } else if (pw) {
    const d = await userOp('password', name, pw);
    if (!d.ok) { show(false, userSay(d, t.uFailed)); return; }
  }
  // The account exists by now, so a refused role leaves a real account with the
  // safe role rather than nothing at all. That is why it is said out loud
  // instead of being swallowed.
  const boxes = document.getElementById("user-boxes").value.trim();
  const m = await userMeta(name, role, email, boxes);
  if (!m.ok) { show(false, userSay(m, t.uFailed)); return; }
  closeUserDrawer();
  await loadUsers();
});

// --- the table ---------------------------------------------------------------
const usersBody = document.getElementById('users-body');
if (usersBody) usersBody.addEventListener('click', async ev => {
  const t = T[lang];
  // One op per user: ticking a second column moves it rather than adding to
  // it, which is why the box records the column rather than a boolean.
  const box = ev.target.closest('[data-user-op]');
  if (box) {
    const n = box.dataset.userName;
    if (box.checked) { userOps.set(n, box.dataset.userOp); } else { userOps.delete(n); }
    // Repainted rather than left alone: ticking Delete greys the other two on
    // that row, and unticking it gives them back.
    renderUsers();
    return;
  }
  const pw = ev.target.closest('[data-user-pw]');
  if (pw) { openUserDrawer(pw.dataset.userPw); return; }

  const share = ev.target.closest('[data-user-share]');
  if (share) {
    const n = share.dataset.userShare;
    const u = USERS.find(x => x.name === n) || {};
    if (!confirm(t.uShareAsk.replace('%s', n).replace('%s', u.email || ''))) return;
    share.disabled = true;
    let d;
    try {
      const r = await fetch(location.pathname, { method: 'POST',
        body: new URLSearchParams({ action: 'usershare', name: n }),
        headers: { 'Accept': 'application/json' } });
      d = await r.json();
    } catch (e) {
      d = { ok: false, error: '' };
    }
    share.disabled = false;
    alert(d.ok ? t.uShared.replace('%s', d.to) : t.uShareFailed.replace('%s', d.error || '?'));
    return;
  }

  const off = ev.target.closest('[data-user-off]');
  if (off) {
    if (!confirm(t.uDisableAsk.replace('%s', off.dataset.userOff))) return;
    await userOp('disable', off.dataset.userOff);
    await loadUsers();
    return;
  }
  const on = ev.target.closest('[data-user-on]');
  if (on) { await userOp('enable', on.dataset.userOn); await loadUsers(); return; }

  const del = ev.target.closest('[data-user-del]');
  if (del) {
    // Names the consequence, not just the name: what a deleted account takes
    // with it is the thing somebody needs to weigh.
    if (!confirm(t.uDeleteAsk.replace('%s', del.dataset.userDel))) return;
    await userOp('delete', del.dataset.userDel);
    await loadUsers();
  }
});


// The inline role dropdown. It acts at once, like every other control on this
// tab: nothing here is staged, and Apply is only for the three tick columns.
if (usersBody) usersBody.addEventListener('change', async ev => {
  const sel = ev.target.closest('[data-user-role]');
  if (!sel) return;
  const name = sel.dataset.userRole;
  sel.disabled = true;
  const u = USERS.find(x => x.name === name);
  // The inline role dropdown changes only the role: the allowance it already
  // has is passed back so a role change does not silently reset it to default.
  const keep = (u && u.mailboxes !== null && u.mailboxes !== undefined) ? u.mailboxes : '';
  const d = await userMeta(name, sel.value, (u && u.email) || '', keep);
  sel.disabled = false;
  if (!d.ok) alert(userSay(d, T[lang].uFailed));
  await loadUsers();
});

// The inline mailbox dropdown. Same shape as the role one beside it: it acts at
// once, and it passes the role back so changing one does not reset the other.
if (usersBody) usersBody.addEventListener('change', async ev => {
  const sel = ev.target.closest('[data-user-boxes]');
  if (!sel) return;
  const name = sel.dataset.userBoxes;
  sel.disabled = true;
  const u = USERS.find(x => x.name === name);
  const d = await userMeta(name, (u && u.role) || 'none', (u && u.email) || '', sel.value);
  sel.disabled = false;
  if (!d.ok) alert(userSay(d, T[lang].uFailed));
  await loadUsers();
});
const usersAll = document.querySelectorAll('[data-users-all]');
usersAll.forEach(box => box.addEventListener('change', () => {
  const col = box.dataset.usersAll;
  USERS.forEach(u => {
    if (u.admin) return;
    // Only where the tick would change something, exactly as the per-row rule
    // decides. Ticking a column therefore never selects every user: those
    // already in that state are left alone rather than silently doing nothing.
    if (box.checked) {
      if (!userBoxDisabled(u, col)) userOps.set(u.name, col);
    } else if (userOps.get(u.name) === col) {
      userOps.delete(u.name);
    }
  });
  // The other two select-alls no longer describe what is ticked.
  usersAll.forEach(o => { if (o !== box) o.checked = false; });
  renderUsers();
}));

// --- Apply -------------------------------------------------------------------
// One at a time, like the service dialog, and for the same reason: four at once
// tells you only that something happened.
//
// Enables first, then disables, then deletes. A delete last means a list that
// mixes them leaves the machine in the intended state even if something refuses
// halfway.
const usersApply = document.getElementById('users-apply');
if (usersApply) usersApply.addEventListener('click', async () => {
  const t = T[lang];
  if (!userOps.size) return;
  const by = verb => [...userOps.entries()].filter(([, v]) => v === verb).map(([n]) => n);
  const dels = by('delete');
  const offs = by('disable');
  const ons  = by('enable');

  // Asked once, naming what is about to happen. Deleting is the half that
  // cannot be taken back, so it is what the question leads with.
  const parts = [];
  if (dels.length) parts.push(t.uApplyDel.replace('%d', String(dels.length)));
  if (offs.length) parts.push(t.uApplyOff.replace('%d', String(offs.length)));
  if (ons.length)  parts.push(t.uApplyOn.replace('%d', String(ons.length)));
  if (!confirm(t.uApplyAsk.replace('%s', parts.join('\n')))) return;

  usersApply.disabled = true;
  for (const n of ons)  await userOp('enable', n);
  for (const n of offs) await userOp('disable', n);
  for (const n of dels) await userOp('delete', n);
  userOps.clear();
  usersAll.forEach(b => { b.checked = false; });
  usersApply.disabled = false;
  await loadUsers();
});

const usersEdit = document.getElementById('users-edit');
// The SHARED edit mode, so leaving it in one tab leaves it in all of them, which
// is what the mode means everywhere else on this page. toggleEditMode() calls
// render(), and render() does not repaint this table, so it is repainted here.
if (usersEdit) usersEdit.addEventListener('click', () => {
  if (typeof toggleEditMode === 'function') toggleEditMode();
  if (!usersEditing()) userOps.clear();
  renderUsers();
});

// Only for somebody who has the Users tab. A limited admin does not, and the
// server refuses ?ask=users for them, so calling it anyway painted a 403 in
// the console of a page that is working correctly.
//
// Read once at load. The file changes only when this page changes it, so there
// is nothing to poll for.
if (typeof MYROLE === 'undefined' || MYROLE === 'full') loadUsers();
