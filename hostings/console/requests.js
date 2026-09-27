// -----------------------------------------------------------------------------
// What has been asked for, and what was said back. Item 106.
//
// A REQUEST IS NOT A ROW. It is somebody asking for a row they may not write
// themselves, stored in its own directory, and it never reaches hostings.conf
// until a full access admin approves it. That is the whole safety property:
// everything on this machine reads that file, and one missed filter on an
// unapproved row would serve it for real.
//
// ONE TABLE PER KIND, not a Requests tab. The owner, 2026-09-10, applying his own
// rule that one table holds one entity: a tab would have mixed websites,
// applications and mailboxes into one list. It is a third view beside Serving
// and Pipeline, so a website request sits with the websites.
//
// BOTH SIDES READ THE SAME TABLE. index.php sends a limited admin only the
// requests they filed, so the difference between what a customer sees and what
// an admin sees is the data, never a second page to keep in step.
// -----------------------------------------------------------------------------
let REQUESTS = [];
let REQ_PENDING = 0;

// Which table a request belongs in. The kind is what was asked FOR, so a
// request to add an application shows under Applications even though no
// application exists yet.
function reqKind(r) {
  const t = String((r.row && r.row.type) || '').toLowerCase();
  if (t === 'app' || t === 'proxy') return 'apps';
  // A mailbox request is its own kind. The owner, 2026-09-11: it used to fall
  // through to the websites table, so the one request a customer files by
  // asking for a mailbox past their allowance arrived where nobody looking
  // after mail would look for it.
  if (t === 'mailbox') return 'mailboxes';
  return 'websites';
}

function reqWhen(sec) {
  if (!sec) return '';
  const d = new Date(sec * 1000);
  // The machine's clock, not the browser's: the 2026-09-10 session found a nine
  // second difference between them, which is enough to render "in the future".
  return d.toLocaleString();
}

// What was asked for, in words. A request to add says what kind and where; a
// request to change an existing row names the row.
function reqWhat(r) {
  const t = T[lang];
  const row = r.row || {};
  const name = String(row.name || '').trim();
  const kind = String(row.type || '').trim();
  if (row.deleted === true || row.delete === true) {
    return t.qDelete.replace('%s', name || '?');
  }
  if (row.isNew === true || !name) {
    // The name goes in the sentence, so the table says which one. A list of
    // four rows all reading "a new website" cannot be told apart without
    // opening every one of them.
    const what = kind === 'mailbox' && name
      ? name + '@' + String(row.subdomain || '').trim().replace(/^=/, '')
      : name;
    return t.qAdd.replace('%s', (kind || '?') + (what ? ' ' + what : ''));
  }
  return t.qChange.replace('%s', name);
}

function reqStateChip(r) {
  const t = T[lang];
  const s = r.state || 'pending';
  const cls = { pending: '', approved: 'go', declined: 'off',
                withdrawn: 'off', superseded: 'off', unreadable: 'off' }[s] ?? '';
  const label = t.qStates[s] || s;
  return `<span class="chip ${cls}">${esc(label)}</span>`;
}

// The count on each bell, and it means a DIFFERENT thing on each side, which is
// the point of counting it here rather than trusting one number for both:
//   an admin  -> requests waiting to be answered
//   a customer -> answers they have not read yet
// index.php already sends the right set; this counts what is in it.
function reqCountFor(kind) {
  const mine = REQUESTS.filter(r => reqKind(r) === kind);
  if (typeof MYROLE !== 'undefined' && MYROLE !== 'full') {
    return mine.filter(r => ['approved', 'declined'].includes(r.state) && !r.seen).length;
  }
  return mine.filter(r => r.state === 'pending').length;
}

// The button itself is hidden until there is something to look at. The owner,
// 2026-09-10, and it goes for both sides: an admin with no requests waiting has
// nothing to press, and a customer who has never asked for anything should not
// be shown a view that is always empty.
//
// The COUNT and the BUTTON are two different tests. The button is there while
// any request exists for that kind, answered ones included, so a customer can
// still read what was said back; the bell counts only what needs attention.
function paintReqBells() {
  document.querySelectorAll('[data-subtabs]').forEach(box => {
    const kind = box.dataset.subtabs;
    const btn  = box.querySelector('button[data-subview="requests"]');
    if (!btn) return;
    const any = REQUESTS.some(r => reqKind(r) === kind);
    btn.hidden = !any;
    // A hidden button cannot be the selected view: leaving it selected would
    // show an empty pane with no way back to Serving.
    if (!any && btn.getAttribute('aria-pressed') === 'true') {
      showSubview(kind, 'serving');
    }
    const span = btn.querySelector('[data-reqcount]');
    if (!span) return;
    const n = reqCountFor(kind);
    // Hidden at zero rather than showing a 0: a red 0 reads as a count of
    // something rather than as nothing to do.
    span.hidden = n === 0;
    span.innerHTML = (I.bell || '') + '<span>' + n + '</span>';
  });

  // THE SAME BELL ON THE MAIN TAB. The owner, 2026-09-11. The sub-tab bell is only
  // visible once you are already inside the tab holding it, so a request filed
  // against Websites while you are reading Applications announced itself to
  // nobody. The count is the same number: what needs attention in that tab.
  document.querySelectorAll('[data-tabreq]').forEach(span => {
    const n = reqCountFor(span.dataset.tabreq);
    span.hidden = n === 0;
    span.innerHTML = (I.bell || '') + '<span>' + n + '</span>';
  });
}

function renderRequests() {
  const t = T[lang];
  document.querySelectorAll('[data-reqbody]').forEach(body => {
    const kind = body.dataset.reqbody;
    const mine = REQUESTS.filter(r => reqKind(r) === kind);
    if (!mine.length) {
      body.innerHTML = `<tr><td colspan="7" class="note">${esc(t.qNone)}</td></tr>`;
      return;
    }
    body.innerHTML = mine.map(r => {
      const pending = r.state === 'pending';
      // ONE BUTTON, AND IT OPENS THE REQUEST. The owner, 2026-09-11: "from the row
      // I am not getting enough info". Approve and Decline used to sit here,
      // which meant answering from four table cells while the request itself
      // carries up to sixteen fields. Every answer is given in the drawer now.
      const btns = `<button class="icon-btn" type="button" data-req-open="${esc(r.id)}"
              title="${esc(t.qOpen)}" aria-label="${esc(t.qOpen)}">${I.edit}</button>`;
      const answer = r.answer
        ? esc(r.answer) + (r.answered_by ? ` <span class="note">${esc(r.answered_by)}</span>` : '')
        : `<span class="dash">&mdash;</span>`;
      return `<tr class="${pending ? '' : 'off'}" data-req-open="${esc(r.id)}"
                  style="cursor:pointer">
        <td class="note">${esc(reqWhen(r.filed))}</td>
        <td class="name">${esc(r.by || '')}</td>
        <td>${esc(reqWhat(r))}</td>
        <td>${r.comment ? esc(r.comment) : '<span class="dash">&mdash;</span>'}</td>
        <td>${reqStateChip(r)}</td>
        <td>${answer}</td>
        <td><span class="row-actions">${btns}</span></td>
      </tr>`;
    }).join('');
  });
  paintReqBells();
}

async function loadRequests() {
  try {
    const r = await fetch('?ask=requests', { headers: { 'Accept': 'application/json' } });
    const j = await r.json();
    REQUESTS = Array.isArray(j.requests) ? j.requests : [];
    REQ_PENDING = Number(j.pending) || 0;
  } catch (e) {
    REQUESTS = [];
    REQ_PENDING = 0;
  }
  renderRequests();
}

// Every answer goes through here, so there is one place that reports what the
// script said rather than a generic failure.
async function reqOp(action, id, reason) {
  // NOTHING OPEN MEANS NOTHING TO ANSWER. The drawer's markup is always in the
  // page, so a press that arrives while REQ_OPEN is null used to send the word
  // "null" to the server and get "No request null" back. Found 2026-09-11 by
  // driving three declines in a row.
  if (!id) return { ok: false, out: '' };
  const body = new URLSearchParams({ action: action, id: id });
  if (reason !== undefined) body.set('reason', reason);
  try {
    const r = await fetch(location.pathname, { method: 'POST', body: body,
      headers: { 'Accept': 'application/json' } });
    return await r.json();
  } catch (e) {
    return { ok: false, out: '' };
  }
}

// -----------------------------------------------------------------------------
// THE REQUEST DRAWER. The owner, 2026-09-11: "from the row I am not getting enough
// info".
//
// A request carries a whole row, up to sixteen fields, and the table shows four
// of them. Answering from the table meant approving something nobody had read.
// So the row opens, every field it asks for is listed beside the value the row
// has today, and Approve and Decline live in here beside the reason box.
//
// THE REASON IS A TEXTAREA, not a prompt(). A decline is the one answer that
// has to be written in sentences, and a browser prompt gives a single unwrapped
// line that cannot be reviewed before it is sent.
// -----------------------------------------------------------------------------
let REQ_OPEN = null;

function reqById(id) { return REQUESTS.find(x => x.id === id) || null; }

// Where a person looks a domain up by hand. `%s` is where the name goes, and a
// URL without one is used as it stands: TransIP's own checker cannot be
// prefilled, measured in a browser on 2026-09-11, and pasting the name onto the
// end of it gives a 404.
function domainCheckUrl(domain) {
  const base = (typeof DOMAIN_CHECK_URL === 'undefined' || !DOMAIN_CHECK_URL)
    ? 'https://domainr.com/%s' : DOMAIN_CHECK_URL;
  return base.indexOf('%s') >= 0
    ? base.replace('%s', encodeURIComponent(domain)) : base;
}

// The config's Subdomain field as an address somebody recognises.
function hostnameOf(sub) {
  const v = String(sub || '').trim();
  if (!v || v === '-') return '';
  if (v.startsWith('=')) return v.slice(1);
  const base = (typeof BASE === 'undefined' ? '' : BASE);
  if (v === '@') return base;
  return base ? v + '.' + base : v;
}

// What the row has NOW, so a change request reads as a change rather than as a
// list of values with no baseline. A request to ADD has no current row, and the
// column is left out rather than filled with dashes.
function reqCurrentRow(r) {
  const name = String((r.row || {}).name || '').trim();
  if (!name || typeof rows === 'undefined') return null;
  const at = rows.findIndex(x => (x.f[1] || '').trim() === name);
  return at >= 0 ? rows[at].f : null;
}

function renderReqDrawer() {
  const t = T[lang];
  const r = REQ_OPEN ? reqById(REQ_OPEN) : null;
  const meta = document.getElementById('req-meta');
  const tbl  = document.getElementById('req-fields');
  const btns = document.getElementById('req-buttons');
  const box  = document.getElementById('req-answer-box');
  if (!r || !meta || !tbl || !btns) return;

  const full = (typeof MYROLE === 'undefined' || MYROLE === 'full');
  const pending = r.state === 'pending';

  meta.innerHTML = `
    <p class="note" style="margin:.2rem 0">
      ${esc(t.qWho)}: <strong>${esc(r.by || '')}</strong> &middot;
      ${esc(t.qWhen)}: ${esc(reqWhen(r.filed))} &middot; ${reqStateChip(r)}
    </p>
    <p style="margin:.4rem 0"><strong>${esc(reqWhat(r))}</strong></p>
    ${r.answered ? `<p class="note" style="margin:.2rem 0">${
      esc(t.qAnswered.replace('%s', reqWhen(r.answered)).replace('%s', r.answered_by || '?'))
    }: ${r.answer ? esc(r.answer) : '<span class="dash">&mdash;</span>'}</p>` : ''}`;

  // Every field the request carries, labelled from FIELDS so the drawer and the
  // table cannot disagree about what a column is called.
  const row = r.row || {};
  const cur = reqCurrentRow(r);

  // THE NAME IS ALWAYS SHOWN, AND FIRST. The owner, 2026-09-11: a mailbox request
  // never showed the address being asked for. A request carries `name` and
  // `type`, which are not the camelCase keys FIELDS matches on, so the one
  // value the whole request is about fell out of the table. For a mailbox that
  // is the local part, and without it the drawer said only which domain.
  const kind = String(row.type || '').toLowerCase();
  const isMail = kind === 'mailbox';
  const pad = cur ? '<td class="note"><span class="dash">&mdash;</span></td>' : '';
  const line = (label, value) => `<tr><td class="note">${esc(label)}</td>${pad}
      <td><strong>${value}</strong></td></tr>`;

  const head = [];
  // TYPE IN WORDS, FIRST. The owner, 2026-09-11. The sentence above already says
  // what kind it is, but a reader scanning the table should not have to read
  // prose to find out, and "E-mail" is what a mailbox is called everywhere a
  // customer sees it.
  if (kind) head.push(line(t.qType, esc((t.qKinds || {})[kind] || kind)));

  // WHY, DIRECTLY UNDER TYPE. The owner, 2026-09-11. It was a line of prose above
  // the block, which put the one thing that explains the request outside the
  // part being scanned.
  if (String(r.comment || '').trim()) {
    head.push(line(t.qWhy, esc(String(r.comment).trim())));
  }

  if (String(row.name || '').trim()) {
    // A mailbox is shown whole: a local part on its own is not an address, and
    // its domain would otherwise sit three rows further down.
    head.push(line(isMail ? (t.cMailAddr || 'Address') : (t.qRepoName || 'Repo name'),
                   esc(isMail
                     ? String(row.name).trim() + '@'
                       + (hostnameOf(row.subdomain) || (typeof BASE === 'undefined' ? '' : BASE))
                     : String(row.name).trim())));
  }

  // A DOMAIN NOBODY OWNS YET, and the two separate answers about it. Item 106,
  // 2026-09-11. The tick is the requester's claim and the check is the
  // machine's; they are shown apart and both dated, because the person placing
  // the order is the one who has to decide whether they agree.
  const wantDom = String(row.domainRequest || '').trim();
  if (wantDom) {
    head.push(line(t.qDomainRequest, esc(wantDom)));
    // ONE LINE, NOT THREE. The owner, 2026-09-11: a domain that is not available
    // cannot be asked for at all now, so "is it free" is answered by the
    // request existing. What is left worth knowing is WHEN it was looked up,
    // because an answer from last month is not an answer.
    const st = String(row.domainChecked || '');
    const when = Number(row.domainCheckedAt || 0);
    // And a way to look it up by hand, which is the whole point when the
    // machine's answer is "could not check". The owner, 2026-09-11.
    const checkUrl = domainCheckUrl(wantDom);
    const lookItUp = ` <a href="${esc(checkUrl)}" target="_blank"
        rel="noopener noreferrer" class="note">${esc(t.addrNewDomainCheck)}</a>`;
    head.push(line(t.qDomainCheckedAt, (when
      ? esc(reqWhen(when))
      : `<span class="chip off">${esc(t.domUnknown)}</span>`) + lookItUp));

    // WHERE IT IS REGISTERED, and only for the person who registers it: a
    // customer does not. The URL comes from the DNS service; none, no line.
    const order = typeof DOMAIN_REGISTER_URL === 'undefined' ? '' : DOMAIN_REGISTER_URL;
    if (full && order) {
      const orderUrl = order.indexOf('%s') >= 0
        ? order.replace('%s', encodeURIComponent(wantDom)) : order;
      head.push(line(t.qDomainOrder, `<a href="${esc(orderUrl)}" target="_blank"
        rel="noopener noreferrer">${esc(t.qDomainOrderLink)}</a>`));
    }
    // The exception, and it is the one case worth a pill: the provider could not be
    // reached, so the request was allowed through unchecked.
    if (st === 'unknown' || (!st && !when)) {
      head.push(line('', `<span class="chip off">${esc(t.domUnknown)}</span>`));
    }
  }

  // A REQUEST NEVER CARRIES A PASSWORD, and saying so is the point: a mailbox
  // cannot be created without one (add_dovecot.sh refuses, item 101), so the
  // admin approving this has to know they will be asked for one.
  if (isMail) {
    head.push(line(t.qPassword, `<span class="dash">${esc(t.qNoPassword)}</span>`));
  }
  const lines = (typeof FIELDS === 'undefined' ? [] : FIELDS).map(([key, label], i) => {
    const k = key.charAt(0).toLowerCase() + key.slice(1);
    if (!Object.prototype.hasOwnProperty.call(row, k)) return '';
    // ALREADY SAID ABOVE. The head rows carry the kind and the name, and the
    // domain request carries the domain, so leaving these in printed Type
    // twice, Name beside Repo name, and Domain beside Domain requested.
    // Seen 2026-09-11 on the first request a customer filed through the drawer.
    if (i === 0 || i === 1) return '';
    if (i === 4 && String(row.domainRequest || '').trim()) return '';
    // The Address row above already carries the domain for a mailbox, so
    // repeating it as "=example.com" says the same thing twice, in the
    // config's spelling rather than the reader's.
    if (isMail && k === 'subdomain') return '';
    let want = String(row[k] === undefined || row[k] === null ? '' : row[k]).trim();
    let now  = cur ? String(cur[i] === undefined ? '' : cur[i]).trim() : '';
    // The address a person recognises, not the config's spelling of it. `=x.nl`
    // is a whole domain, `@` is the base itself, anything else is a label under
    // it, and printing "=example.com" at a reader makes them decode a field.
    if (k === 'subdomain') {
      want = hostnameOf(want);
      now  = hostnameOf(now);
    }
    // A field asking for exactly what is already there is noise in a review.
    if (cur && want === now) return '';
    // And on an ADD, a field nobody filled in is not a request for anything:
    // twelve lines reading "not set" buried the five that were answered.
    if (!cur && (want === '' || want === '-')) return '';
    const shown = (want === '' || want === '-')
      ? `<span class="dash">${esc(t.qFieldEmpty)}</span>` : esc(want);
    return `<tr><td class="note">${esc(label)}</td>
      ${cur ? `<td class="note">${(now === '' || now === '-')
        ? '<span class="dash">&mdash;</span>' : esc(now)}</td>` : ''}
      <td><strong>${shown}</strong></td></tr>`;
  }).filter(Boolean);
  const all = head.concat(lines);
  tbl.innerHTML = all.length
    ? (cur ? '<tr><th></th><th class="note">now</th><th class="note">asked</th></tr>' : '')
      + all.join('')
    : `<tr><td class="note">${esc(t.qNothingAsked)}</td></tr>`;

  // Only a full access admin gets the reason box, and only while the request is
  // still waiting. Everybody else here is a reader.
  if (box) box.hidden = !(full && pending);

  const cancel = `<button type="button" class="icon-btn text-btn" id="req-close">${
    esc(t.bCancel || 'Cancel')}</button>`;
  if (full && pending) {
    btns.innerHTML = `
      <button type="button" class="cta" id="req-approve">${esc(t.qApprove)}</button>
      <button type="button" class="icon-btn text-btn danger" id="req-decline">${esc(t.qDecline)}</button>
      ${cancel}`;
  } else if (!full && pending && r.by === (typeof ME === 'undefined' ? '' : ME)) {
    btns.innerHTML = `
      <button type="button" class="icon-btn text-btn danger" id="req-drop">${esc(t.qWithdraw)}</button>
      ${cancel}`;
  } else if (!full && !r.seen && ['approved', 'declined'].includes(r.state)) {
    btns.innerHTML = `
      <button type="button" class="cta" id="req-seen">${esc(t.qSeen)}</button>
      ${cancel}`;
  } else {
    btns.innerHTML = cancel;
  }
}

function openReqDrawer(id) {
  if (!reqById(id)) return;
  REQ_OPEN = id;
  const msg = document.getElementById('req-msg');
  const why = document.getElementById('req-reason');
  if (msg) { msg.hidden = true; msg.textContent = ''; }
  if (why) why.value = '';
  renderReqDrawer();
  document.getElementById('req-scrim').classList.add('open');
  document.getElementById('req-drawer').classList.add('open');
  if (why) why.focus();
}

function closeReqDrawer() {
  REQ_OPEN = null;
  document.getElementById('req-scrim').classList.remove('open');
  document.getElementById('req-drawer').classList.remove('open');
  // The link that opened it is spent: leaving it in the address bar means a
  // refresh reopens a request that has already been answered.
  if (location.hash.indexOf('#req-') === 0) {
    history.replaceState(null, '', location.pathname + location.search);
  }
}

function reqSay(text) {
  const msg = document.getElementById('req-msg');
  if (!msg) { alert(text); return; }
  msg.textContent = text;
  msg.hidden = false;
}

// APPROVING PUBLISHES THE ROW, through the ordinary save. The request is marked
// approved first: if the publish then fails, the answer stands and the row can
// be written again, which is the better half to be wrong on. The reverse would
// leave a row live that nothing records approving.
async function approveRequest(id, why) {
  const t = T[lang];
  const r = reqById(id);
  if (!r) return;
  const d = await reqOp('reqapprove', id, why);
  if (!d.ok) { reqSay(d.out || t.qFailed); return; }
  const row = d.row || (r.row || null);
  if (row && row.name) {
    const at = rows.findIndex(x => (x.f[1] || '').trim() === String(row.name).trim());
    const vals = objectToRow(row, at >= 0 ? rows[at].f : null);
    // A new application or proxy gets its port NOW, from the rows that exist
    // today. The request never carried one: the requester has no port field, so
    // there was nothing to reserve and nothing to collide.
    if (at < 0 && (vals[0] === 'app' || vals[0] === 'proxy')
        && !String(vals[2] || '').trim().match(/^\d+$/)) {
      vals[2] = nextPort('row', vals[0]);
    }
    if (at >= 0) {
      rows[at].f = vals;
      rows[at].dirty = true;
      rows[at].fastOnly = false;
    } else {
      rows.push({ line: null, f: vals, dirty: true, fastOnly: false });
    }
    closeReqDrawer();
    render();
    await loadRequests();
    // The full apply, never the fast one: an approved row may need a vhost, a
    // unit, a certificate and a repository, and the fast path writes none of
    // those.
    applyWatch();
    document.getElementById('btn-save-apply').click();
    return;
  }
  closeReqDrawer();
  alert(t.qApproved);
  await loadRequests();
}

document.addEventListener('click', async ev => {
  const t = T[lang];

  const open = ev.target.closest('[data-req-open]');
  if (open) {
    openReqDrawer(open.dataset.reqOpen);
    return;
  }

  if (ev.target.closest('#req-close') || ev.target.id === 'req-scrim') {
    closeReqDrawer();
    return;
  }

  if (ev.target.closest('#req-approve')) {
    const id = REQ_OPEN;
    // The reason is optional on an approve: "yes, but rename it first" is worth
    // more to the requester than a bare yes, and a bare yes is still an answer.
    const why = ((document.getElementById('req-reason') || {}).value || '').trim();
    await approveRequest(id, why);
    return;
  }

  if (ev.target.closest('#req-decline')) {
    const id = REQ_OPEN;
    const why = ((document.getElementById('req-reason') || {}).value || '').trim();
    // Refused here as well as in the script. Without a reason the requester
    // learns no, and nothing else.
    if (!why) { reqSay(t.qNeedReason); return; }
    const d = await reqOp('reqdecline', id, why);
    if (!d.ok) { reqSay(d.out || t.qFailed); return; }
    closeReqDrawer();
    await loadRequests();
    return;
  }

  if (ev.target.closest('#req-drop')) {
    if (!confirm(t.qWithdrawAsk)) return;
    const d = await reqOp('reqwithdraw', REQ_OPEN);
    if (!d.ok) { reqSay(d.out || t.qFailed); return; }
    closeReqDrawer();
    await loadRequests();
    return;
  }

  if (ev.target.closest('#req-seen')) {
    await reqOp('reqseen', REQ_OPEN);
    closeReqDrawer();
    await loadRequests();
  }
});

// Escape closes it, like every other drawer on this page.
document.addEventListener('keydown', ev => {
  if (ev.key === 'Escape' && REQ_OPEN) closeReqDrawer();
});

// THE LINK IN THE NOTIFICATION MAIL LANDS HERE. notify_request.sh sends
// <console>/#req-<id>, so the mail opens the request itself rather than the
// page in general, which is what item 106 asked for.
async function openRequestFromHash() {
  const m = /^#req-([A-Za-z0-9._-]+)$/.exec(location.hash || '');
  if (!m) return;
  // A link pasted into a tab that is already open changes the hash WITHOUT
  // reloading, so the request it names may have been filed after this page
  // read the list. Measured on 2026-09-11: the drawer opened on nothing and
  // said nothing. Ask again before deciding the id is unknown.
  let r = reqById(m[1]);
  if (!r) { await loadRequests(); r = reqById(m[1]); }
  if (!r) return;
  const kind = reqKind(r);
  const tab = document.querySelector('.tab[data-tab="' + kind + '"]');
  if (tab) tab.click();
  if (typeof showSubview === 'function') showSubview(kind, 'requests');
  openReqDrawer(r.id);
}

loadRequests().then(openRequestFromHash);
window.addEventListener('hashchange', openRequestFromHash);
