// -----------------------------------------------------------------------------
// The drawer: the same form for editing a row and for adding one.
// -----------------------------------------------------------------------------
// dotnet8, dotnet10 and dotnet are all .NET: the number only decides what a NEW
// project is created against, and the unit runs `dotnet <app>.dll` either way.
// Three places compared the field to the exact word 'dotnet', so a row on
// dotnet8 got a plain Path box with no project picker, the generic label, and
// no .dll check at all. Measured 2026-09-09 on example_net.
// uno is .NET too: Uno with Server runs its Server dll like any Blazor app.
// Beside the Application type: how long the chosen .NET is supported.
function runtimeSupportPill(rt, t) {
  const m = String(rt || '').match(/^dotnet(\d+)$/);
  if (!m) return '';
  const life = supportOf('dotnet', m[1]);
  if (!life.known) return '';
  const sup = supportText(life, t);
  return `<span class="pill lv-${life.level}" title="${esc(sup.tip)}">${esc(sup.tip)}</span>`;
}
document.addEventListener('change', ev => {
  const sel = ev.target.closest && ev.target.closest('select[data-runtime]');
  const slot = sel && sel.parentElement.querySelector('[data-runtime-support]');
  if (slot) slot.innerHTML = runtimeSupportPill(sel.value, T[lang]);
});

function isDotnet(rt) { return /^(dotnet|uno)/.test(String(rt || 'dotnet').toLowerCase()); }
// docker, docker_node and docker_python all take a Dockerfile path (item 141).
function isDocker(rt) { return /^docker/.test(String(rt || '').toLowerCase()); }
// A path this page put there, rather than one somebody typed. Only these are
// ever rewritten when the type changes. Mirrors seededShape in the dll picker,
// which cannot be reused: that one lives inside the .NET-only block.
function seededPath(v) {
  const s = String(v || '').trim();
  if (s === '' || s === '-' || s === 'Dockerfile') return true;
  const m = s.match(/^([A-Za-z0-9_]+)[/]([A-Za-z0-9_]+)(?:[.]Server)?[.]dll$/);
  return !!m && m[1] === m[2];
}
function pathKind(rt) { return isDotnet(rt) ? 'dotnet' : isDocker(rt) ? 'docker' : 'node'; }

const drawer = document.getElementById('drawer');
const scrim  = document.getElementById('scrim');
let editing  = null;
// What a suggested row name starts with, per row type. A proxy and a mailbox
// get nothing: neither can be the other half of a pair.
//
// www_ rather than web_, because a web app is a website too and web_ said
// nothing. www_ is what Apache serves off disk; app_ is what listens on a port.
const SUGGEST_PREFIX = { website: 'www_', app: 'app_' };

// The name this code last suggested. A box still holding it may be moved on
// when the address changes; anything else the operator typed is theirs.
let autoName = '';
// The drawer's fields as they were when it opened, so closing can tell a typed
// drawer from an untouched one. Empty means "do not ask": set on every open.
let drawerOpenedWith = '';
let draft    = null;

// One drawer element, two kinds of thing in it. A machine page is three fields
// and a row is thirteen, so they do not share a field renderer.
let drawerMode   = 'row';   // 'row' | 'panel'
let editingPanel = undefined;

// The DNS account's domains, asked for when the mailbox drawer opens rather
// than on page load: nothing else on this page needs them, and it is one API
// call per open instead of one per visit.
//
// null = never asked, [] = asked and got nothing back.
let accountDomains = null;
let domainsAsking  = false;
let domainsError   = '';

// Repository names the App can see, per owner, asked for when a row is set to
// create one. A row's name becomes its repository name, and a clash is
// otherwise only discovered when provision_repo.sh refuses partway through an
// apply.
//
// A name is refused on EITHER owner. GitHub allows the same name twice; this
// does not, because a transfer leaves a redirect behind and creating the name
// it moved away from silently breaks the old links.
// See .claude/docs/github-org-decisions.md, decision 6.
//
// null = never asked. It is advisory: the machine refuses a real clash whatever
// this holds, so a failed lookup must never block a save.
let repoIndex  = null;
let repoAsking = false;

async function askRepoNames() {
  if (repoAsking || repoIndex !== null) return;
  repoAsking = true;
  try {
    const r = await fetch('?repos=1', { headers: { 'Accept': 'application/json' } });
    repoIndex = await r.json();
  } catch (e) {
    repoIndex = { create_owner: '', owners: {} };
  }
  repoAsking = false;
  checkDrawer();
  // The tab is built from the same answer, so it is filled here rather than
  // waiting on its own fetch: whichever of the two asked first, both get it.
  renderRepos();
}

// -----------------------------------------------------------------------------
// The Repositories tab
//
// The same ?repos answer the clash check consults one name at a time, shown as
// a table instead. Read only: this page's authority over a repository is the
// row that owns it, and acting here would be a second place to answer the
// question the row drawer already asks.
//
// WHAT IT IS FOR: a repository no row claims. It is invisible everywhere else
// on this page, which is how one survived a row deletion that had asked for it
// to be deleted, with nothing anywhere saying so.
// -----------------------------------------------------------------------------
let reposOwner = '';
// Space separated, ANDed, matched anywhere on the row: the name, the owner,
// the row that claims it and the clone URL. Two words beat one long one when
// half the names share a prefix.
let reposQuery = '';

// The row that names this repository, or '' for none. Deleted rows do not
// count: the point of the tab is what will be left standing.
function repoClaimedBy(slug) {
  const want = slug.toLowerCase();
  const hit = rows.find(r => !r.deleted && repoSlugOf(r.f[8]).toLowerCase() === want);
  return hit ? ((hit.f[1] || '').trim() || '?') : '';
}

function renderRepos() {
  const body = document.getElementById('repos-body');
  if (!body) return;
  const t = T[lang];
  const owners = (repoIndex && repoIndex.owners) || {};
  const names  = Object.keys(owners).sort();

  const sel = document.getElementById('repos-owner');
  if (sel.options.length !== names.length + 1 || sel.dataset.built !== names.join(',')) {
    sel.dataset.built = names.join(',');
    sel.innerHTML = `<option value="">${esc(t.reposAll)}</option>`
      + names.map(o => `<option value="${esc(o)}">${esc(o)}`
          + (o === repoCreateOwner() ? ' (' + esc(t.reposCreateHere) + ')' : '')
          + '</option>').join('');
    sel.value = reposOwner;
  }

  const terms = reposQuery.toLowerCase().split(/s+/).filter(Boolean);
  const hit = hay => terms.every(w => hay.indexOf(w) !== -1);

  const list = [];
  names.forEach(o => {
    if (reposOwner && o !== reposOwner) return;
    (owners[o] || []).forEach(n => {
      // The claiming row and the URL are searchable too: "claimed" is a
      // question people ask of this table, and so is "which row is that".
      const hay = (o + '/' + n + ' ' + (repoClaimedBy(o + '/' + n) || '')).toLowerCase();
      if (!hit(hay)) return;
      list.push({ owner: o, name: n });
    });
  });
  list.sort((a, b) => a.name.localeCompare(b.name) || a.owner.localeCompare(b.owner));

  body.innerHTML = list.map(r => {
    const slug = r.owner + '/' + r.name;
    const row  = repoClaimedBy(slug);
    // The URL the row drawer's Repository field wants, one press away. Typing
    // it means getting owner, name and the .git suffix right by hand, and a
    // wrong one is only found at the first deploy.
    const url = 'https://github.com/' + slug + '.git';
    // The same GitHub mark the row tables use in their repo column, so the way
    // to open a repository looks the same wherever it is seen. The name stays a
    // link too: the icon is the thing the eye finds, the name is the wide
    // target. The owner, 2026-09-10.
    return `<tr>
      <td><a class="icon-btn" href="https://github.com/${esc(slug)}"
             target="_blank" rel="noopener"
             title="${esc(slug + '\n' + t.aOpenRepo)}"
             aria-label="${esc(t.aOpenRepo)}">${I.github}</a>
        <a href="https://github.com/${esc(slug)}" target="_blank" rel="noopener">${esc(r.name)}</a></td>
      <td>${esc(r.owner)}</td>
      <td>${row ? esc(row) : '<span class="note">' + esc(t.reposNone) + '</span>'}</td>
      <td class="url-col"><code class="clone-url">${esc(url)}</code></td>
      <td class="copy-col"><button type="button" class="icon-btn" data-copy="${esc(url)}"
          title="${esc(t.aCopyUrl)}" aria-label="${esc(t.aCopyUrl)}">${I.clipboard}</button></td>
    </tr>`;
  }).join('');

  // The line under the table describes what is ON the table. It used to report
  // the total whatever the filter said, so picking one owner left "22
  // repositories, 2 owners" above a single row.
  const total = names.reduce((n, o) => n + (owners[o] || []).length, 0);
  // The owner is named when it is the only filter, because that sentence says
  // more than a count does. A typed query cannot be quoted back usefully, so
  // that case reports the numbers alone.
  document.getElementById('repos-count').textContent =
    total === 0       ? t.reposEmpty
    : terms.length    ? t.reposShowing(list.length, total)
    : reposOwner      ? t.reposFiltered(list.length, total, reposOwner)
    :                   t.reposCount(total, names.length);
  const count = document.getElementById('count-repos');
  if (count) count.textContent = total === 0 ? '' : String(total);
}

document.getElementById('repos-owner').addEventListener('change', e => {
  reposOwner = e.target.value;
  renderRepos();
});

// On input, not on Enter: the list is already in the browser, so filtering it
// costs nothing and waiting for a key nobody thinks to press is worse.
document.getElementById('repos-search').addEventListener('input', e => {
  reposQuery = e.target.value;
  renderRepos();
});

// The owner a new repository would be made under, which is the org when there
// is one.
function repoCreateOwner() {
  return (repoIndex && repoIndex.create_owner) || '';
}

// '' when the name is free or nothing is known yet, otherwise the owner that
// already holds it.
function repoNameTakenBy(name) {
  if (!repoIndex || !repoIndex.owners) return '';
  const want = String(name || '').trim().toLowerCase();
  if (want === '') return '';
  for (const own of Object.keys(repoIndex.owners)) {
    const list = repoIndex.owners[own] || [];
    if (list.some(n => String(n).toLowerCase() === want)) return own;
  }
  return '';
}

// Which domain a row's Subdomain field claims the whole of, or '' for none.
// Mirrors the grammar the address field parses, so the two cannot drift: `@`
// and `@name` are both the base domain in live, `=x` is the whole of x only
// when x is a domain rather than a name in front of one.
function apexOf(v) {
  const s = String(v == null ? '' : v).trim();
  if (s === '' || s === '-') return '';
  if (s.startsWith('@')) return BASE;
  if (!s.startsWith('=')) return '';
  const whole = s.slice(1);
  const DOMAINS = [BASE, ...MAILDOMAINS.filter(d => d !== BASE)];
  const dom = DOMAINS.find(d => whole === d || whole.endsWith('.' + d)) || whole;
  return whole === dom ? dom : '';
}

// The first row to claim a domain owns it. Two rows answering on one hostname
// is two vhosts for it, and which one Apache serves is decided by filename
// order rather than by anybody. Returns the row already holding it, or ''.
// Who holds this apex, counting ENABLED rows only.
//
// A switched-off row holds nothing, 2026-09-10: the whole point of the pair is
// that a customer has a www_ row and an app_ row on one domain, one of them
// live, and the other waiting. Counting the waiting one as a claim made the
// second row of the pair impossible to create, which is how the owner found this.
//
// An enabled row is still a claim, but no longer a refusal: saving over it
// switches it off, so the drawer says what will happen instead of stopping.
function apexClaimedBy(domain) {
  const want = String(domain || '').trim().toLowerCase();
  if (want === '') return '';
  const hit = rows.find((r, i) =>
    i !== editing && !r.deleted && r.f[0] !== 'mailbox'
    && String(r.f[14] || '').trim().toLowerCase() !== 'no'
    && apexOf(r.f[4]).toLowerCase() === want);
  return hit ? (hit.f[1] || '').trim() : '';
}

// Domains chosen out of the account group. They are not in DNS_DOMAINS yet, so
// serialise() adds them to that line: a mailbox on a domain the config has
// never heard of would otherwise be an address nothing routes to.
let extraDomains = [];

function domainStatus(t) {
  if (domainsAsking)          return t.domainsAsking;
  if (domainsError)           return t.domainsFailed;
  if (accountDomains === null) return '';
  return t.domainsFrom.replace('%d', accountDomains.length);
}

async function askDomains() {
  // A limited admin's domains are the ones they own, already on the page, and
  // the account-wide list is refused for them.
  if (typeof MYROLE !== 'undefined' && MYROLE !== 'full') return;
  if (domainsAsking) return;
  domainsAsking = true;
  domainsError  = '';
  paintDomainStatus();

  try {
    const r = await fetch('?ask=domains', { headers: { 'Accept': 'application/json' } });
    const j = await r.json();
    // A failed fetch still carries the previous list, so the dropdown gains
    // what it can and says the refresh did not happen.
    accountDomains = j.domains || [];
    domainsError   = j.ok ? '' : (j.error || 'failed');
  } catch (e) {
    domainsError = String(e);
  }

  domainsAsking = false;
  paintDomainStatus();
  paintDomainOptions();
}

function paintDomainStatus() {
  const el = document.getElementById('domain-status');
  if (el) el.textContent = domainStatus(T[lang]);
}

// Only the dropdown, never the whole drawer. A full re-render arriving while
// someone is typing a mailbox name throws that name away, and the fetch lands
// about a second after the drawer opens: exactly when they are typing.
function paintDomainOptions() {
  const sel = document.querySelector('#drawer-fields [data-domain]');
  if (!sel) return;

  const t     = T[lang];
  const cur   = sel.value;
  const known = [...new Set([...MAILDOMAINS, ...extraDomains])];
  const extra = (accountDomains || []).filter(d => !known.includes(d));

  const opt = d => `<option value="${d === BASE ? '-' : esc(d)}">
      ${esc(d)}${d === BASE ? ' (' + esc(t.baseDomain) + ')' : ''}
    </option>`;

  sel.innerHTML = `<optgroup label="${esc(t.domainsKnown)}">${known.map(opt).join('')}</optgroup>`
    + (extra.length ? `<optgroup label="${esc(t.domainsNew)}">${extra.map(opt).join('')}</optgroup>` : '');
  sel.value = cur;
}

// What each service type actually uses, in the order it makes sense to fill in.
// A mailbox has no port, no path and no vhost; showing it those fields invites
// someone to fill one in, and the file then says something that is not true.
//
// Login and who may enter sit next to each other because they are one decision.
// RepoMode sits straight after Repository: it describes that repository, and
// the two are one decision.
const SHAPE = {
  // Runtime sits straight after the name: it decides what Path has to point at,
  // so it is answered before Path rather than after it.
  // Branch is back, after 2026-09-04. The comment here used to say the
  // environment already decides which branch a row deploys, and that is true
  // only while every repository has a branch per environment. A row pointed
  // at an existing repository whose branches are dev and main had no way to
  // say so, and the startup-project dropdown then failed to clone as well.
  // The repository moved up on 2026-09-07, above Path and Port. It decides
  // two of the fields under it now: Branch is hidden while the repository is
  // being created, and the dll is prefilled from the row name instead of
  // picked out of a clone. A question that changes the ones below it belongs
  // above them.
  // Domain first here too, 2026-09-10, for the reason the website row has had
  // it first all along: it is the question that answers the name, and through
  // the name the repository. An app row asked it eighth, so the name was typed
  // before anything could suggest one.
  app: [4, 1, 13, 8, 12, 9, 3, 2, 5, 6, 7, 11, 10],
  // Domain first on a website: it is the question that answers the next two,
  // suggesting the row name and through it the folder.
  //
  // 13 is here for a different reason than on an app row. It is the same field,
  // and on a website it says what a NEW repository is seeded with. Without it
  // the only way to make a Vue or Angular site was to edit hostings.conf, which
  // has been a read-only tab since 2026-09-01: item 85 built the seeders and
  // left no way to reach them. It sits straight after Repository, because it
  // only means anything for a repository being created.
  // 9, the Source branch, added 2026-09-09. A website was the one row type that
  // could not say where its code comes from, so one pointed at a main-only
  // repository had no way to say so: exactly the case the field exists for.
  website: [4, 1, 3, 7, 11, 8, 13, 12, 9, 10],
  proxy:   [1, 2, 4, 7, 11, 10],
  // No environments: maintain_services.sh skips mailbox rows before the
  // environment loop, so a test copy of an address does not exist and cannot be
  // made. Offering the checkboxes invited a choice that nothing acts on.
  // Domain first, then the local part, because the domain narrows what the
  // name has to be unique against. RFC 5322 calls them the domain part and the
  // local part; the labels say mailbox name, which is what people call it.
  mailbox: [4, 1]
};


// Who a mailbox belongs to: whoever owns its DOMAIN, never its own field 15.
// The same rule as ownership()/rowOwner() in index.php, which has read it that
// way since 2026-09-16. DOMAINOWNERS is that map; a limited admin only ever
// gets their own domains in it.
function mailboxOwner(domainField) {
  const d = String(domainField == null ? '' : domainField).replace(/^=/, '').trim();
  // A domain nobody owns falls back to the admin, as ownership() and
  // person_entry.sh both do since 2026-09-20.
  return DOMAINOWNERS[(d === '' || d === '-') ? BASE : d]
      || (typeof ADMIN === 'undefined' ? '' : ADMIN);
}
// Owner is the last question on every kind of row, and only a full access admin
// is ever asked it. Kept out of SHAPE itself rather than hidden after
// rendering: a field that is not in the list is not read back on save either,
// so a limited admin cannot post an Owner the page never showed them.
function shapeFor(kind) {
  const base = SHAPE[kind] || SHAPE.app;
  if (typeof MYROLE !== 'undefined' && MYROLE !== 'full') {
    // A REQUESTER NEVER SEES A PORT. The owner, 2026-09-10, and it was still in
    // the drawer on 2026-09-11: the port is assigned at APPROVAL from the rows
    // that exist by then, so a box asking for one invites an answer that is
    // thrown away, and two requesters would pick the same number.
    //
    // The request already could not carry one: manage_requests.sh drops `port`
    // on the way in. This is the half that stops it being asked.
    return base.filter(i => i !== 2);
  }
  // A MAILBOX IS NEVER ASKED. It belongs to whoever owns its domain, and the
  // drawer says so rather than offering a box. The owner, 2026-09-20: "domain user
  // must be the same as the mailbox user if it is attached to the domain".
  // ownership() in index.php has read it that way since 2026-09-16, so the box
  // was collecting an answer nothing acted on.
  if (kind === 'mailbox') return base;
  return [...base, 15];
}

function openDrawer(index, kind) {
  editing = index;
  autoName = '';
  const isNew = index === null;
  draft = isNew ? FIELDS.map(() => '-') : rows[index].f.slice();
  // Before the fields render: they paint the preview, and it must already hold
  // this row's value rather than the last one's.
  previewDraft = isNew ? {} : { ...(PREVIEWS[String(draft[1] || '').trim()] || {}) };
  appMemDraft  = isNew ? '' : (APPMEM[String(draft[1] || '').trim()] || '');
  if (isNew) {
    draft[0] = kind;
    draft[10] = ENVS[0] || 'live';
    // A website has no port and a mailbox has no port; suggesting one would
    // invite it to be filled in.
    if (kind === 'app' || kind === 'proxy') draft[2] = nextPort('row', kind);
    // Every application on this machine is .NET today, so the common answer is
    // filled in rather than left as a dash the drawer would show as blank.
    if (kind === 'app') draft[13] = 'dotnet';
  }

  // "Add a site: mailbox" named the wrong thing twice. The add buttons already
  // carry a proper name per kind, so the title reuses those.
  document.getElementById('drawer-title').textContent = isNew
    ? (T[lang].add[draft[0]] || T[lang].drawerAdd)
    : T[lang].drawerEdit + ' ' + rows[index].f[1];

  renderDrawerFields();
  checkDrawer();
  drawer.classList.add('open');
  scrim.classList.add('open');

  // Asked every time the drawer opens, so a domain bought a minute ago is in
  // the list without pressing anything else. The field renders from what is
  // already known first: a dropdown that waits on a network call is a dropdown
  // that looks broken.
  if (draft[0] === 'mailbox') askDomains();
  paintMail();
  paintMailPw();

  // What the drawer held the moment it finished rendering. Closing compares
  // against this, so an untouched drawer shuts with no dialog and a typed one
  // asks first. Through drawerState() rather than readDrawer(), because that is
  // what the close will compare and the two must not disagree.
  drawerOpenedWith = drawerState();
}

// The mail section, shown for an application that already exists.
//
// Not for a new row: the file is named after the row, and the row does not
// exist until it has been published. Offering the fields before that would
// write a file for a name that may still change.
// A preview needs a port to derive from and a row that can serve one. A proxy
// row is refused by add_preview_vhosts.sh, so it is not offered here either.
let previewDraft = {};

// The preview port this row has in this environment, or null. Used by the
// tables, so the name itself opens the thing it names.
function previewPortFor(name, env, rowPort) {
  const spec = (PREVIEWS[String(name).trim()] || {})[env];
  if (spec === undefined) return null;
  if (spec !== 'auto') return parseInt(spec, 10) || null;
  const base = parseInt(rowPort, 10);
  if (isNaN(base)) return null;
  return PREVBASE + base + (parseInt(OFFSET[env], 10) || 0);
}

// The controls, not the draft: Port and Envs are being typed into right now,
// and reading the draft showed the number the drawer opened with.
function previewFields() {
  if (drawerMode === 'panel' || !document.querySelector('#drawer-fields [data-i]')) return draft;
  try { return readDrawer(); } catch (e) { return draft; }
}

// A row with no port of its own has nothing to derive a preview port from, and
// a website row is not even asked for one: Apache serves it off disk and
// nothing listens. Such a row is still offered a preview, and names its port
// itself. The owner's call, 2026-09-02.
function rowHasPort(f) {
  f = f || previewFields();
  return String(f[2] || '').replace('-', '').trim() !== '';
}

function canPreview(f) {
  f = f || previewFields();
  return ['app', 'website', 'php', 'docroot'].includes(f[0]);
}

// The number to suggest for a row that has no port. Free of every row port and
// every machine page, and inside the preview band so it reads like one.
function suggestPreviewPort(env) {
  const used = new Set();
  rows.forEach(r => {
    const n = Number(r.f[2]);
    if (n) { used.add(n); ENVS.forEach(e => used.add(PREVBASE + n + (parseInt(OFFSET[e], 10) || 0))); }
  });
  try { panelEntries().forEach(e => { if (e.port) used.add(e.port); }); } catch (e) {}
  Object.keys(PREVIEWS || {}).forEach(name => {
    Object.values(PREVIEWS[name] || {}).forEach(v => {
      const n = parseInt(v, 10);
      if (n) used.add(n);
    });
  });
  let n = PREVBASE + 900 + (parseInt(OFFSET[env], 10) || 0);
  if (n < 1024) n = PREVBASE + 900;
  while (used.has(n) && n < 65535) n++;
  return n;
}

function previewPort(env, spec, f) {
  if (spec && spec !== 'auto') return parseInt(spec, 10);
  f = f || previewFields();
  if (!rowHasPort(f)) return suggestPreviewPort(env);
  return PREVBASE + parseInt(f[2], 10) + (parseInt(OFFSET[env], 10) || 0);
}

// The controls moved onto the environment lines, where the question belongs.
// This section stays in the markup and stays hidden rather than being deleted
// here: the same fields are rendered by renderDrawerFields now.
function paintPreview() {
  const box = document.getElementById('drawer-preview');
  if (box) box.hidden = true;
  paintAppMem();
}

// An app's own memory ceiling. Admins only: a limited save drops every
// settings line, so the choice would be thrown away.
let appMemDraft = '';
function paintAppMem() {
  const box = document.getElementById('drawer-appmem');
  if (!box) return;
  const f = previewFields();
  box.hidden = !(f[0] === 'app' && MYROLE === 'full');
  if (box.hidden) return;
  const t = T[lang];
  const opts = [{ v: '', l: t.appMemEnvDefault }, ...memOptions()];
  if (appMemDraft && !opts.some(o => o.v === appMemDraft)) opts.push({ v: appMemDraft, l: appMemDraft });
  document.getElementById('appmem-select').innerHTML = opts.map(o =>
    `<option value="${esc(o.v)}"${o.v === appMemDraft ? ' selected' : ''}>${esc(o.l)}</option>`).join('');
}
document.getElementById('appmem-select').addEventListener('change', e => {
  appMemDraft = e.target.value;
  checkDrawer();
});

function commitAppMem(fields) {
  const f = fields || draft;
  const name = String(f[1] || '').trim();
  if (f[0] !== 'app' || !name || name === '-') return;
  if (appMemDraft) APPMEM[name] = appMemDraft; else delete APPMEM[name];
}

// Edited into a copy, like the row's own fields, so Cancel really cancels.
// commitPreview() is what puts it back into PREVIEWS, on Save.
function readPreview(el) {
  const wrap    = el.closest('[data-penv]');
  const env     = wrap.dataset.penv;
  const on      = wrap.querySelector('[data-pon]').checked;
  const noPort  = !rowHasPort();
  const portBox = wrap.querySelector('[data-pport]');

  wrap.querySelector('[data-pdetail]').hidden = !on;

  // ONE BOX, NO TICK, since 2026-09-07. It used to be a checkbox saying whether
  // the port was derived or typed, and that is a question about the port scheme
  // rather than about this row. The owner: "I do not want to think about the
  // ports."
  //
  // The number shown is the derived one, and it is editable. Leaving it alone
  // stores 'auto', so the port keeps following the row's own port. Typing
  // something else stores that number. Typing the derived number back returns
  // to 'auto', which is the way out that dropping the tick would otherwise
  // have taken away.
  //
  // A row with NO port of its own is different and always stores a number:
  // there is nothing on the machine to derive one from, and 'auto' would be a
  // preview on port NaN.
  const derived = noPort ? suggestPreviewPort(env) : previewPort(env, 'auto');
  if (String(portBox.value || '').trim() === '') { portBox.value = derived; }

  const typed = String(portBox.value || '').trim();

  if (!on) { delete previewDraft[env]; }
  else if (noPort) { previewDraft[env] = typed; }
  else { previewDraft[env] = (Number(typed) === Number(derived)) ? 'auto' : typed; }

  wrap.querySelector('[data-purl]').textContent =
    'http://' + location.hostname + ':' + previewPort(env, previewDraft[env]) + '/';
  checkDrawer();
}

// -----------------------------------------------------------------------------
// Mailboxes, edited from the row that owns the domain
//
// A mailbox row is almost empty: a local part and a domain. Everything else in
// the line is a dash. So the question "does this domain have mail" belongs
// beside the domain, not in a tab you have to remember to visit afterwards.
//
// The section is the TRUTH about those rows, not a copy of it: it is built from
// `rows` every time it renders, and pressing Keep this change writes `rows`.
// Unticking removes the line and leaves the mail on disk, the same as removing
// a share leaves the folder. The owner's call, 2026-08-26.
// -----------------------------------------------------------------------------

// OFFERED for a domain that has none yet. Three, because a customer who gets
// one address always asks for these two next.
const MBX_DEFAULTS = ['info', 'contact', 'admin'];

// TICKED, which is a shorter list than the one offered, and since 2026-09-06 it
// has to be. A newly ticked address must be given a password or the row refuses
// to save, so pre-ticking all three meant a website on a fresh domain could not
// be saved until three passwords had been typed, with the reason shown as
// "info@ is new and needs a password" on a drawer nobody had touched. contact@
// alone, because that one cannot be unticked anyway; the other two are listed
// and one click away. Measured 2026-09-09 against apex-claim.spec.js.
const MBX_TICKED = ['contact'];

// What a mailbox row calls this row's domain. BASE is a dash there, exactly as
// it is in the file: a mailbox line carries the domain plainly, with no '='.
function mbxDomainOf(fields) {
  const sub = (fields[4] || '').trim();
  if (sub === '' || sub === '-') return null;          // publishes nothing
  if (sub.startsWith('=')) {
    const full = sub.slice(1);
    const dot = full.indexOf('.');
    // =webmail.example.org is mail for example.org, not for
    // webmail.example.org: the mail domain is the registrable one.
    return DNSDOMAINS.find(d => full === d || full.endsWith('.' + d)) || full;
  }
  return '-';                                          // @ and plain names: BASE
}

// Every mailbox row for one domain, as { local, i }.
//
// Compared on the RESOLVED domain, because a mailbox line may write the base
// domain either way: '-' means BASE and the name itself is equally valid. A raw
// string compare made 'example.com' and '-' different domains, so an existing
// contact@ was invisible to a website row on the base domain and the defaults
// were offered again. On 2026-09-03 that published a second contact row beside
// the first, plus info@ and admin@ nobody had asked for.
function mbxRowsFor(domain) {
  const want = domain === '-' ? BASE : domain;
  return rows
    .map((r, i) => ({ r, i }))
    .filter(({ r }) => r.f[0] === 'mailbox' && !r.deleted
                       && mbxRowDomain(r) === want)
    .map(({ r, i }) => ({ local: (r.f[1] || '').trim(), i }));
}

// Addresses shown in the section: what exists, plus the defaults when the
// domain has none at all, plus anything typed this session.
let mbxDraft = null;   // { domain, chosen: Set, extra: [] } while a drawer is open

function mbxRender() {
  const box = document.getElementById('drawer-mailboxes');
  // The controls, not the draft. A new row opens with a dash for a domain and
  // `draft` is never rewritten while typing, so reading it here meant the
  // section could never appear on a row being created.
  const f = previewFields();
  const kind = f ? f[0] : null;
  const domain = (kind === 'website' || kind === 'app') ? mbxDomainOf(f) : null;

  if (domain === null) {
    box.hidden = true;
    mbxDraft = null;
    return;
  }
  box.hidden = false;

  const shownDomain = domain === '-' ? BASE : domain;
  const existing = mbxRowsFor(domain).map(m => m.local);

  if (!mbxDraft || mbxDraft.domain !== domain) {
    mbxDraft = {
      domain: domain,
      // NOTHING pre-ticked for a limited admin. A mailbox costs one of their
      // allowance, and their Add is a REQUEST that creates nothing yet, so a
      // password could not be asked for anything real. Ticking contact@ for
      // them made every request refuse to save until a password was typed for
      // an address nobody had asked for.
      chosen: new Set(existing.length ? existing : MBX_TICKED),
      extra: []
    };
  }

  const names = [...new Set([...MBX_DEFAULTS, ...existing, ...mbxDraft.extra])].sort();
  document.getElementById('mbx-note').textContent = T[lang].mbxNote(shownDomain);
  // A NEWLY TICKED ADDRESS GETS A PASSWORD BOX, exactly as the mailbox drawer
  // does. Without one this list was the only way to make a mailbox that skips
  // that guard: on 2026-09-06 three addresses ticked here became config rows
  // with no Dovecot account, and the apply reported SUCCESS over it.
  //
  // Only NEW ones. An address that already has a row has a password already,
  // and asking again would mean retyping it to change anything else on the
  // page. Its own drawer is where it is changed.
  //
  // The value is read back out of the DOM rather than kept in mbxDraft on every
  // keystroke: this list is re-rendered on every input event in the drawer, and
  // a re-render that dropped what was typed would be worse than no box at all.
  // contact@ cannot be unticked, and the tick used to say it could. Every other
  // part of the console treats it as mandatory: it is the forced forward target
  // when a mailbox is deleted, and mailDelete() refuses to remove it while
  // anything still forwards there. Offering it as optional at CREATE time is
  // what produced the refusal the owner hit on 2026-09-07 at 15:46,
  // "contact@example.com: no maildir, so forwarding to it would bounce",
  // on a delete that assumed an address the create had never guaranteed.
  mbxDraft.chosen.add('contact');

  document.getElementById('mbx-list').innerHTML = names.map(n => {
    const forced = n === 'contact';
    const isNew = !existing.includes(n) && mbxDraft.chosen.has(n);
    const held = mbxDraft.pw && mbxDraft.pw[n] ? mbxDraft.pw[n] : '';
    return '<label' + (forced ? ' title="' + esc(T[lang].mbxContactForced) + '"' : '') +
      '><input type="checkbox" data-mbx="' + esc(n) + '"' +
      (mbxDraft.chosen.has(n) ? ' checked' : '') +
      (forced ? ' disabled' : '') + '> ' +
      esc(n) + '@' + esc(shownDomain) +
      (forced ? ' <span class="note">' + esc(T[lang].mbxContactNote) + '</span>' : '') +
      '</label>' +
      // EVERY TICKED ADDRESS, not only a new one. An existing address had to be
      // changed from its own row on another tab, which is two navigations away
      // from the domain you are already looking at. The owner, 2026-09-07.
      //
      // The difference is the placeholder, and it is the whole contract: a new
      // address MUST have one, an existing one keeps what it has when the box
      // is left empty. stageMailPw() sends only boxes that were typed into.
      (mbxDraft.chosen.has(n)
        ? '<input type="password" class="mbx-pw" data-mbxpw="' + esc(n) +
          '" value="' + esc(held) + '" placeholder="' +
          esc(isNew ? T[lang].mbxPwPlaceholder : T[lang].mbxPwKeep) + '">'
        : '');
  }).join('');
}

// What has been typed for each new address, kept across the re-renders that
// every keystroke in the drawer causes.
function mbxReadPw() {
  if (!mbxDraft) return;
  mbxDraft.pw = mbxDraft.pw || {};
  document.querySelectorAll('#mbx-list [data-mbxpw]').forEach(b => {
    mbxDraft.pw[b.dataset.mbxpw] = b.value;
  });
}

// The addresses this drawer is about to CREATE, which is the set that needs a
// password. Read from the draft rather than from the DOM so rowProblems() can
// ask the question before anything is rendered.
function mbxNewLocals(fields) {
  const domain = (fields[0] === 'website' || fields[0] === 'app') ? mbxDomainOf(fields) : null;
  if (domain === null || !mbxDraft || mbxDraft.domain !== domain) return [];
  const have = new Set(mbxRowsFor(domain).map(m => m.local));
  return [...mbxDraft.chosen].filter(l => !have.has(l));
}

document.getElementById('mbx-list').addEventListener('change', e => {
  const cb = e.target.closest('[data-mbx]');
  if (!cb || !mbxDraft) return;
  // Belt as well as braces: the box is disabled, and a disabled box cannot be
  // unticked by a person. It can be by a script, and this list has been driven
  // by one in the tests.
  if (cb.dataset.mbx === 'contact') { cb.checked = true; return; }
  mbxReadPw();
  if (cb.checked) { mbxDraft.chosen.add(cb.dataset.mbx); }
  else {
    mbxDraft.chosen.delete(cb.dataset.mbx);
    // Untick and the password goes with it, so re-ticking asks again rather
    // than silently reusing something typed and then abandoned.
    if (mbxDraft.pw) delete mbxDraft.pw[cb.dataset.mbx];
  }
  mbxRender();
  checkDrawer();
});

document.getElementById('mbx-list').addEventListener('input', e => {
  if (!e.target.matches('[data-mbxpw]')) return;
  mbxReadPw();
  checkDrawer();
});

document.getElementById('mbx-add').addEventListener('click', () => {
  const box = document.getElementById('mbx-new');
  const problem = document.getElementById('mbx-problem');
  // The local part only. Typing the whole address is the obvious mistake, so
  // the @ and everything after it is taken off rather than refused.
  const raw = box.value.trim().split('@')[0].toLowerCase();

  if (!raw) { return; }
  if (!/^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$/.test(raw)) {
    problem.hidden = false;
    problem.textContent = T[lang].mbxBadName;
    return;
  }
  problem.hidden = true;
  if (mbxDraft) {
    mbxDraft.extra.push(raw);
    mbxDraft.chosen.add(raw);
  }
  box.value = '';
  mbxRender();
});

// Called from the drawer's save, before the row itself is written, so the
// mailbox lines land in the same edit and go out with the same publish.
function mbxCommit(fields) {
  const kind = fields[0];
  const domain = (kind === 'website' || kind === 'app') ? mbxDomainOf(fields) : null;
  if (domain === null || !mbxDraft || mbxDraft.domain !== domain) return;

  const existing = mbxRowsFor(domain);
  const have = new Set(existing.map(m => m.local));

  // Gone: mark the row removed. The MAILBOX is not removed, only the line, and
  // the messages stay where they are.
  existing.forEach(m => {
    if (!mbxDraft.chosen.has(m.local)) { rows[m.i].deleted = true; rows[m.i].fastOnly = false; }
  });

  // New: a row that is a local part and a domain, and dashes everywhere else.
  mbxDraft.chosen.forEach(local => {
    if (have.has(local)) return;
    const f = FIELDS.map(() => '-');
    f[0] = 'mailbox';
    f[1] = local;
    f[4] = domain;
    f[10] = 'live';
    rows.push({ line: null, f: f, dirty: true });
  });
}

// =============================================================================
// The progress instance. A tick that writes a ROW, not a field.
// =============================================================================
//
// Agreed 2026-09-11, .claude/docs/progress-instance-decisions.md. The owner:
// "the optional progress tick spins up a new instance of the progress
// application", which is what ruled out a seventeenth column: an instance
// needs a unit, a port, a vhost, a certificate, a DNS record and Jenkins jobs,
// and every one of those already exists for an ordinary app row.
//
// So the tick creates `progress_<name>` on `=progress.<domain>` and nothing
// downstream learns a new concept.
//
// The owner's three answers, and each is visible in the row written below:
//   one SHARED repository, so a fix reaches every customer
//   LIVE ONLY. The owner, 2026-09-11, correcting his own earlier answer of live
//     and test: "the customer will not get a test environment". A customer
//     instance is production, and testing happens on your own progress-app rows.
//   unticking DISABLES and keeps, so a mis-click destroys nothing
// PROGRESS_REPO and PROGRESS_DLL come from the config, via index.php.
const PROGRESS_ENVS = 'live';

// NEVER TWO LEVELS DEEP. The owner, 2026-09-11, and the reason is the person
// typing it, not the certificate: "all the *****.*****.example.com way too
// much room for errors and too much to remember".
//
// So the shape of the address follows the shape of the website's:
//
//   website  customer2.example.com   ->  customer2-progress.example.com
//   website  =example.net    ->  =progress.example.net
//   website  @  (the base domain)      ->  progress.example.com
//
// A customer on a subdomain of ours gets a FLAT name, which is also how this
// machine already names customer things: shop.example.com.
// A customer with their own domain gets progress. in front of it, because
// there is no crowding there.
//
// The first version of this reused mbxDomainOf(), which climbs to the
// registrable domain because mail for webmail.x.nl belongs to x.nl. Every
// customer on a subdomain of example.com therefore mapped to the SAME
// progress.example.com, and the second one's tick would have shown as
// already on. Found by creating a second customer and reading the line the
// tick prints, not by reading the code.
//
// Returns the Subdomain FIELD value for the instance row, or null when the
// website publishes nothing and so has nowhere to host one.
function progSubOf(fields) {
  const sub = String(fields[4] || '').trim();
  if (sub === '' || sub === '-') return null;
  if (sub === '@') return 'progress';
  if (sub.startsWith('=')) return '=progress.' + sub.slice(1);
  // A plain name is a subdomain of BASE_DOMAIN, so stay on that one level.
  return sub + '-progress';
}

// What that field actually resolves to, for the line under the tick. The rule
// is the config's own: a plain name hangs off BASE_DOMAIN, an = is absolute.
function progHostOf(fields) {
  const s = progSubOf(fields);
  if (s === null) return null;
  return s.startsWith('=') ? s.slice(1) : s + '.' + BASE;
}

// From the Subdomain FIELD, not the resolved host: the host repeats the base
// domain, which gave progress_customer2_progress_example_com. The name
// becomes a unit name and a vhost filename, so it is kept to what distinguishes
// the row.
//
//   customer2-progress        ->  customer2_progress
//   =progress.example.net    ->  progress_example_net
function progName(fields) {
  const s = progSubOf(fields);
  return String(s || '').replace(/^=/, '').replace(/[^A-Za-z0-9]+/g, '_');
}

// The instance row, as an index into rows, or -1. Matched on the Subdomain
// field rather than the name, because the address is what actually makes two
// instances the same thing.
function progIndexFor(fields) {
  const want = progSubOf(fields);
  if (want === null) return -1;
  return rows.findIndex(r => !r.deleted
    && (r.f[0] || '').trim() === 'app'
    && (r.f[4] || '').trim() === want);
}

function progRender() {
  const box = document.getElementById('drawer-progress');
  if (!box) return;
  const f = previewFields();
  const kind = f ? f[0] : null;
  // Offered on a website row only. An app row on progress.<domain> IS the
  // instance, so offering it there invites a row that hosts itself.
  const host = kind === 'website' ? progHostOf(f) : null;

  if (host === null || !PROGRESS_REPO || !PROGRESS_DLL) { box.hidden = true; return; }
  box.hidden = false;

  const at = progIndexFor(f);
  const on = at >= 0 && (rows[at].f[14] || '').trim() !== 'no';
  const tick = document.getElementById('prog-on');
  tick.checked = on;

  const t = T[lang];
  document.getElementById('prog-note').textContent =
    (t.progNote || 'Serves the progress application at') + ' ' + host;
  document.getElementById('prog-detail').textContent = at < 0
    ? (t.progNew || 'Ticking this creates an application row, live only, on a port chosen when you save.')
    : (on ? (t.progOn || 'Running. Unticking switches it off and keeps everything it owns.')
          : (t.progOff || 'Switched off. Ticking it starts it again with its data intact.'));
}

// Called from the drawer's save, beside mbxCommit, so the instance row lands in
// the same edit and goes out with the same publish.
//
// It never deletes. Unticking sets Enabled to no, which stops the unit and
// takes the vhost away while the row, its folder, its certificate and its data
// stay. Removing an instance for real is the ordinary row delete.
function progCommit(fields) {
  const box = document.getElementById('drawer-progress');
  if (!box || box.hidden) return;
  if ((fields[0] || '').trim() !== 'website') return;
  const sub = progSubOf(fields);
  if (sub === null) return;

  const want = document.getElementById('prog-on').checked;
  const at = progIndexFor(fields);

  if (at >= 0) {
    const now = (rows[at].f[14] || '').trim() !== 'no';
    if (now === want) return;
    rows[at].f[14] = want ? 'yes' : 'no';
    rows[at].dirty = true;
    // Not a fast edit: switching a row off has to reach the unit and the
    // vhost, and the fast path writes neither.
    rows[at].fastOnly = false;
    return;
  }
  if (!want) return;

  const f = FIELDS.map(() => '-');
  f[0]  = 'app';
  f[1]  = progName(fields);
  // The same assignment the approval flow uses, so two instances made minutes
  // apart cannot be handed the same number.
  f[2]  = String(nextPort('row', 'app'));
  // A folder per instance: one shared folder meant one shared settings file,
  // and every instance but the last ran with another's settings (2026-10-04).
  f[3]  = f[1] + '/' + PROGRESS_DLL.split('/').pop();
  f[4]  = sub;
  // Behind a login. The owner, 2026-09-11: a customer's own progress application
  // is not a public page.
  f[7]  = 'live:yes';
  f[8]  = PROGRESS_REPO;
  f[9]  = 'main';
  f[10] = PROGRESS_ENVS;
  f[12] = 'portfolio';
  f[13] = 'dotnet';
  f[14] = 'yes';
  // The website row's owner, so a limited admin sees their own instance and
  // nobody else's. Item 105 decides visibility by this field.
  f[15] = (fields[15] || '-').trim() || '-';
  // And the same account may ENTER it. A login with nobody named means the
  // admin alone, which would lock the customer out of their own instance: the
  // two halves of "behind a login" are the door and who holds a key, and
  // setting only the first is the shape that fails closed on the wrong person.
  if (f[15] !== '-') { f[11] = f[15]; }
  rows.push({ line: null, f: f, dirty: true, fastOnly: false });
}

// Fed the values just read, not the draft: for a NEW row the draft is still
// the blank template of dashes, so a preview ticked while creating a row was
// stored under the name `-` and never reached the row it belonged to.
function commitPreview(fields) {
  const f = fields || draft;
  if (!canPreview(f)) return;
  const name = String(f[1] || '').trim();
  if (!name || name === '-') return;
  if (Object.keys(previewDraft).length) { PREVIEWS[name] = { ...previewDraft }; }
  else { delete PREVIEWS[name]; }
}

// On #drawer-fields, because that is where the controls live: they moved onto
// the environment lines and these two listeners stayed on the old section,
// which is hidden and empty, so ticking Preview did nothing at all.
// The Owner picker and the tick beside it. Item 105.
//
// Changing the owner repaints the tick, because it describes a different
// person the moment the name changes, and a checked box under a new name
// would say something untrue.
//
// THE ROLE ACTS AT ONCE, like everything on the Users tab and unlike every row
// field: it writes a role onto an account, which is not part of this row and is
// not published with it. Keeping it until Save would mean a control that looks
// like the fields around it and behaves differently.

// Repaint ONLY the User role control, in place. Item 105.
//
// It exists because renderDrawerFields() cannot be used for this: it rebuilds
// every field from the draft, and the address picker, the document root and
// the repository choice live in helper controls that reach the draft only on
// save. Repainting them mid-edit throws away what somebody just typed.
function paintOwnerRole() {
  const sel = document.querySelector('#drawer-fields [data-adminrole]');
  if (!sel) return;
  const t = T[lang];
  const who = String(draft[15] || '').trim();
  const u = (typeof USERS !== 'undefined' && who) ? USERS.find(x => x.name === who) : null;
  const role = u ? (u.role || 'none') : 'none';
  sel.disabled = (who === '' || who === '-');
  sel.value = role;
  // The option that says "this is what it was", so a refused change can be put
  // back without asking the server what it used to be.
  [...sel.options].forEach(o => { o.defaultSelected = (o.value === role); });
  const note = document.querySelector("#drawer-fields [data-ownernote]");
  if (note) note.hidden = !sel.disabled;
}
document.getElementById('drawer-fields').addEventListener('change', async e => {
  if (e.target.matches('[data-owner]')) {
    draft[15] = e.target.value;
    // ONLY the role control, never renderDrawerFields(). Repainting every field
    // rebuilds the address picker, the document root and the repository choice
    // from the draft, and those three live in helper controls that are read
    // into the draft only on save: choosing an owner threw away the name and
    // folder somebody had just typed. Caught by filling the drawer in and
    // watching the values disappear.
    paintOwnerRole();
    return;
  }
  if (e.target.matches('[data-adminrole]')) {
    const who = String(draft[15] || '').trim();
    if (!who || who === '-') return;
    const sel = e.target;
    const was = [...sel.options].find(o => o.defaultSelected);
    sel.disabled = true;
    const u = (typeof USERS !== 'undefined') ? USERS.find(x => x.name === who) : null;
    const d = await userMeta(who, sel.value, (u && u.email) || '');
    sel.disabled = false;
    if (!d.ok) {
      if (was) sel.value = was.value;
      alert(userSay(d, T[lang].uFailed));
      return;
    }
    // USERS is what this is drawn from, so it is re-read or the control goes
    // back to its old value the next time the fields are painted. Only this
    // control is repainted: see paintOwnerRole().
    if (typeof loadUsers === "function") await loadUsers();
    paintOwnerRole();
  }
});

document.getElementById('drawer-fields').addEventListener('change', e => {
  if (e.target.matches('[data-pon], [data-pport]')) readPreview(e.target);
});

// The progress tick lives outside #drawer-fields, so it needs its own listener:
// without one the box changed on screen and nothing re-ran the dirty check, so
// Keep this change stayed disabled. It repaints its own wording too, because
// the line under it describes what the tick is about to do.
document.getElementById('prog-on').addEventListener('change', () => {
  const t = T[lang];
  const on = document.getElementById('prog-on').checked;
  const f = previewFields();
  const at = f ? progIndexFor(f) : -1;
  document.getElementById('prog-detail').textContent = at < 0
    ? (on ? (t.progWill || 'Will be created when you save, live only, behind a login.')
          : (t.progNew || 'Ticking this creates an application row, live only, on a port chosen when you save.'))
    : (on ? (t.progOn || 'Running. Unticking switches it off and keeps everything it owns.')
          : (t.progOff || 'Switched off. Ticking it starts it again with its data intact.'));
  checkDrawer();
});
document.getElementById('drawer-fields').addEventListener('input', e => {
  if (e.target.matches('[data-pport]')) readPreview(e.target);
});

function paintMail() {
  const box = document.getElementById('drawer-mail');
  const t = T[lang];
  const isSavedApp = draft[0] === 'app' && editing !== null;

  box.hidden = !isSavedApp;
  if (!isSavedApp) return;

  document.getElementById('mail-title').textContent = t.mailTitle;
  document.getElementById('mail-note').textContent = t.mailNote;
  document.getElementById('mail-from-label').textContent = t.mailFrom;
  document.getElementById('mail-to-label').textContent = t.mailTo;
  document.getElementById('mail-save').textContent = t.mailSave;
  document.getElementById('mail-outcome').textContent = t.mailLoading;
  document.getElementById('mail-from').value = '';
  document.getElementById('mail-to').value = '';

  const row = rows[editing].f[1];
  fetch('?ask=mail&row=' + encodeURIComponent(row), { cache: 'no-store' })
    .then(r => r.json())
    .then(d => {
      // The drawer may have closed, or moved to another row, while the fetch
      // was in the air. Answering into it then fills the wrong row's boxes.
      if (!rows[editing] || rows[editing].f[1] !== row) return;
      if (!d.ok) { document.getElementById('mail-outcome').textContent = d.error || t.mailUnknown; return; }
      document.getElementById('mail-from').value = d.mail.from || '';
      document.getElementById('mail-to').value = d.mail.to || '';
      // Where the shown value came from matters: one is a setting somebody
      // made, the other is whatever the deployed app happens to be running on.
      document.getElementById('mail-outcome').textContent =
        d.mail.owned ? t.mailFromFile : (d.mail.configured ? t.mailFromApp : t.mailUnset);
    })
    .catch(() => { document.getElementById('mail-outcome').textContent = t.mailUnknown; });
}

// The password section. Shown for every mailbox, in one of two modes.
//
// SAVED: the address is already in the published config, so the password can be
// set here and now by its own button.
//
// PENDING: the address is new or renamed, so it exists only in this browser and
// there is nothing yet to give a password to. The password is REQUIRED and
// rides with Keep this change, which sets it after the publish lands. Without
// this the row was created, the maildir was made by the apply, and the account
// was never made at all: on 2026-09-01 five of seven mailboxes could not log in.
// True while the open drawer is a mailbox whose address is not in the published
// config yet, so its password has to travel with the save rather than be set on
// its own.
let mailPwPending = false;

// What the account check found, kept so the line under the box can be redrawn
// on every keystroke without asking the machine again.
let mailPwBox = null;

// One line, and it says what pressing the button will DO, not what is true.
//
// It used to read "admin@example.com: This mailbox has a password. It is set
// when you press Keep this change." Three facts stapled together, none of them
// an instruction, and it did not answer the only question the box raises:
// what happens if I leave this alone. The owner, 2026-09-07.
function paintMailPwOutcome() {
  const t = T[lang];
  const out = document.getElementById('mailpw-outcome');
  const boxEl = document.getElementById('mailpw-value');
  if (!out) return;
  const typed = boxEl && boxEl.value.length > 0;

  // A mailbox that does not exist yet: the password rides with the save, and
  // rowProblems() already refuses to save without one.
  if (mailPwPending) { out.textContent = t.pwWillSet; return; }
  if (!mailPwBox)    { out.textContent = t.pwLoading; return; }

  if (typed)              { out.textContent = t.pwWillChange.replace('%s', mailPwBox.addr); return; }
  if (!mailPwBox.maildir) { out.textContent = t.pwNoBox; return; }
  // No account yet is the one state worth a warning: nobody can get in at all.
  out.textContent = mailPwBox.account
    ? t.pwLeaveBlank
    : t.pwNoLogin.replace('%s', mailPwBox.addr);
}

function paintMailPw() {
  const box = document.getElementById('drawer-mailpw');
  const t = T[lang];
  const isMailbox = draft[0] === 'mailbox';
  const saved = (isMailbox && editing !== null && editing !== undefined
                 && rows[editing] && !rows[editing].deleted
                 && draft[1] === rows[editing].f[1] && draft[4] === rows[editing].f[4]);

  box.hidden = !isMailbox;
  // Still the flag that decides whether a password is REQUIRED: a mailbox that
  // does not exist yet must be given one, or it is created with no Dovecot
  // account. It no longer decides which button sets it, because there is one.
  mailPwPending = isMailbox && !saved;
  document.getElementById('mailpw-save').hidden = true;
  if (!isMailbox) { return; }

  // The "Default password" label is gone. The owner, 2026-09-07: the same box also
  // CHANGES an existing password, so "default" described a first-issue workflow
  // that this field stopped being about, and nothing ever forced a change.
  document.getElementById('mailpw-label').hidden = true;

  if (mailPwPending) {
    const dom = blank(draft[4]) ? BASE : draft[4].replace(/^=/, '');
    document.getElementById('mailpw-title').textContent = t.pwTitle;
    document.getElementById('mailpw-note').hidden = false;
    document.getElementById('mailpw-note').textContent =
      t.pwNewNote.replace('%s', (draft[1] || '?') + '@' + dom);
    paintMailPwOutcome();
    return;
  }

  const local  = draft[1];
  const domain = blank(draft[4]) ? BASE : draft[4].replace(/^=/, '');

  // On an EXISTING mailbox the note is gone too: it told you to hand out a
  // default and let the owner replace it, which is not what this box does when
  // it is changing a password that already works. The address still appears,
  // in the outcome line below.
  document.getElementById('mailpw-title').textContent = t.pwTitle;
  document.getElementById('mailpw-note').hidden = true;
  document.getElementById('mailpw-value').value = '';
  mailPwBox = null;
  paintMailPwOutcome();

  fetch('?ask=mailpw&local=' + encodeURIComponent(local)
        + '&domain=' + encodeURIComponent(domain), { cache: 'no-store' })
    .then(r => r.json())
    .then(d => {
      // The drawer may have closed, or moved to another mailbox, while the
      // fetch was in the air.
      if (!rows[editing] || rows[editing].f[1] !== local) return;
      const out = document.getElementById('mailpw-outcome');
      if (!d.ok) { out.textContent = d.error || t.pwUnknown; return; }
      // The account's state, then which button acts on the box. The second half
      // used to be missing on an existing mailbox, which is how a typed
      // password could look accepted while nothing was going to set it.
      mailPwBox = { addr: local + '@' + domain,
                    maildir: !!d.box.maildir, account: !!d.box.account };
      paintMailPwOutcome();
    })
    .catch(() => { document.getElementById('mailpw-outcome').textContent = t.pwUnknown; });
}

function renderDrawerFields() {
  const t = T[lang];
  const f = draft;
  const shown = shapeFor(f[0]);

  document.getElementById('drawer-fields').innerHTML = shown.map(i => {
    const [key, label, hint, fieldType] = FIELDS[i];
    let v = f[i] === '-' ? '' : f[i];
    const L = t.f[key] || { label, hint };
    let input;

    // The Subdomain field is three different questions wearing one name. On a
    // mailbox it is a whole mail domain. Everywhere else it is a small grammar
    // (@, @name, =other.tld) that has to be known before the field can be
    // filled in, so it is chosen rather than typed.
    // Path is two questions too: an executable for an app, a folder under
    // WEB_ROOT for anything Apache serves from disk.
    const type = (key === 'Subdomain')
      ? (f[0] === 'mailbox' ? 'domain' : 'address')
      : (key === 'Path' && ['website', 'php', 'docroot'].includes(f[0]))
      ? 'docroot-path'
      // An application's Path names the dll, and the BUILD derives the project
      // from it: the dll name is what `find src -name "<name>.csproj"` looks
      // for. Typed by hand, a typo gives either a build that stops with
      // "No <name>.csproj in the repository" or a unit that starts, finds no
      // dll and crash-loops. The repository knows the answer, so it is asked.
      : (key === 'Path' && f[0] === 'app' && isDotnet(f[13]))
      ? 'app-path'
      : fieldType;

    // A CONTAINER ROW'S PATH IS ITS DOCKERFILE, and it is the same word every
    // time. The dll picker above prefills the .NET shapes, but it only renders
    // for a .NET row, so a Docker row had no prefill at all and the word had
    // to be typed. What runs inside the container is named in the Dockerfile,
    // which is why no dll belongs here. The box stays editable: a repository
    // with more than one Dockerfile has no other way to say which.
    if (key === 'Path' && f[0] === 'app' && isDocker(f[13]) && seededPath(v)) {
      v = 'Dockerfile';
    }

    switch (type) {
      case 'kind':
        // The value stays the word hostings.conf uses. Only the label is plain,
        // so the page and the file do not end up with two vocabularies.
        input = `<select data-i="${i}">${[
            ['app', 'Application: we run it'],
            ['website', 'Website: files only'],
            ['proxy',   'Forwarded: points elsewhere'],
            ['mailbox', 'Mailbox: email only']
          ].map(([k, label]) => `<option value="${k}" ${k === v ? 'selected' : ''}>${label}</option>`)
           .join('')}</select>`;
        break;

      // A list, so it is checkboxes rather than a select: a row can be in more
      // than one environment and usually is.
      case 'envs': {
        // One line per environment: whether it exists, whether it needs a
        // login, and who may enter. AuthProtected and AuthUsers are still the
        // stored fields; these controls compose both.
        const auth = f[7];
        const who  = f[11];
        // An empty Envs means EVERY environment, per hostings.conf. Rendering
        // that as four empty boxes said the opposite of what the file said, and
        // every row on this machine stores it, so every row looked as though it
        // ran nowhere. Reading it back turns all-ticked into `-` again, so the
        // file is not rewritten just for having been looked at.
        const all = blank(v);
        // The preview lives on the environment's own line, because "does this
        // environment exist, does it need a login, can I look at it" is one
        // question asked three ways. It used to be a separate section further
        // down, which meant scrolling to answer the third.
        const canPrev = canPreview(f);
        const lines = ENVS.map(e => {
          const on     = all || v.split(',').map(s => s.trim()).includes(e);
          const locked = protectedFor(auth, e);
          const spec   = previewDraft[e];
          const prevOn = spec !== undefined;
          const pport  = canPrev ? previewPort(e, spec, f) : 0;
          const prev = !canPrev ? '' : `
            <label class="env-prev" style="font-weight:400"><input type="checkbox"
                   data-pon ${prevOn ? 'checked' : ''} ${on ? '' : 'disabled'}
                   style="width:auto"> ${esc(t.envPreview)}</label>
            <span data-pdetail ${prevOn ? '' : 'hidden'}>
              <input type="number" data-pport min="1024" max="65535" value="${pport}"
                     style="max-width:7rem">
              <span class="note" data-purl>http://${esc(location.hostname)}:${pport}/</span>
            </span>`;
          return `<div class="env-row" data-penv="${esc(e)}">
            <label style="font-weight:400"><input type="checkbox" data-env value="${esc(e)}"
                   ${on ? 'checked' : ''} style="width:auto"> ${esc(e)}</label>
            <label class="env-lock" style="font-weight:400"><input type="checkbox"
                   data-lock="${esc(e)}" ${locked ? 'checked' : ''}
                   ${on ? '' : 'disabled'} style="width:auto"> ${esc(t.envLock)}</label>${prev}
          </div>`;
        }).join('');

        // One row per account, one column per environment. A column is shown
        // only where a login stands in front, so the grid narrows to the
        // environments the question actually applies to.
        // The admin is ticked and fixed rather than absent: a name missing
        // from a list reads as a mistake.
        const cell = (a, e, isAdmin) =>
          `<td data-whocol="${esc(e)}"><input type="checkbox"
             data-who-name="${esc(a)}" data-who-env="${esc(e)}"
             ${isAdmin || usersFor(who, e).includes(a) ? 'checked' : ''}
             ${isAdmin ? `disabled title="${esc(t.envWhoAdmin)}"` : ''}></td>`;
        const grid = `<table class="who-grid" data-whogrid hidden>
          <tr><th>${esc(t.envWho)}</th>${ENVS.map(e =>
            `<th data-whocol="${esc(e)}">${esc(e)}</th>`).join('')}</tr>
          ${[ADMIN, ...ACCOUNTS.filter(a => a !== ADMIN)].map(a => {
            const isAdmin = a === ADMIN;
            return `<tr><td${isAdmin ? ` title="${esc(t.envWhoAdmin)}"` : ''}>${esc(a)}</td>`
                 + ENVS.map(e => cell(a, e, isAdmin)).join('') + `</tr>`;
          }).join('')}
        </table>`;


        input = `<div data-multi="${i}" data-envrows>${lines}${grid}</div>`;
        break;
      }

      // Composed by the per-environment pickers above, never edited here: one
      // list for the whole row cannot say "these people in skunk only".
      case 'users':
        input = `<input data-i="${i}" value="${esc(v)}">`;
        break;

      case 'auth':
        input = `<select data-i="${i}" data-auth>
            <option value=""    ${v === ''    ? 'selected' : ''}>${esc(t.authNo)}</option>
            <option value="yes" ${v === 'yes' ? 'selected' : ''}>${esc(t.authYes)}</option>
            ${ENVS.map(e => {
              const per = ENVS.map(x => x + ':' + (x === e ? 'yes' : 'no')).join(', ');
              return `<option value="${esc(per)}" ${v === per ? 'selected' : ''}>${esc(t.authOnly)} ${esc(e)}</option>`;
            }).join('')}
            ${(v && v !== 'yes' && !ENVS.some(e => v === ENVS.map(x => x + ':' + (x === e ? 'yes' : 'no')).join(', ')))
              ? `<option value="${esc(v)}" selected>${esc(v)}</option>` : ''}
          </select>`;
        break;

      // Key and value as two controls, with the keys already used in the file
      // offered: nobody should be typing
      // ApplicationOptions__CurrentMainProjectGoal by hand.
      case 'options': {
        const pairs = v ? v.split(';').map(s => s.trim()).filter(Boolean) : [];
        const row = (p, n) => {
          const k = p ? p.split('=')[0] : '';
          const val = p ? p.slice(p.indexOf('=') + 1) : '';
          return `<div class="row-actions opt-pair" style="margin-bottom:.3rem">
            <input list="optkey-list" class="opt-k" value="${esc(k)}" placeholder="${esc(t.optKey)}" style="flex:2">
            <input class="opt-v" value="${esc(p ? val : '')}" placeholder="${esc(t.optVal)}" style="flex:1">
          </div>`;
        };
        input = `<div data-opts="${i}">${[...pairs, ''].map(row).join('')}</div>
                 <p class="note" id="opt-source" style="margin:.2rem 0 0"></p>
                 <button type="button" id="opt-add" class="add-btn panel"
                         style="margin-top:.2rem"><span>${esc(t.optAdd)}</span></button>`;
        break;
      }

      // What the application is written in, which is what the unit ends up
      // executing. Each option carries its own explanation, so picking one does
      // not need a document open.
      case 'runtime': {
        // Field 13 answers two different questions. On an application it is the
        // runtime the unit executes; on a website it is what an empty
        // repository gets seeded with, and nothing runs it afterwards.
        if (draft[0] === 'website') {
          const cur = (v === '' ? '-' : v).toLowerCase();
          const known = SITE_PLATFORMS.some(([p]) => p === cur);
          input = `<select data-i="${i}">${SITE_PLATFORMS.map(([p, label, seeded, why]) => `
              <option value="${p}" ${p === cur ? 'selected' : ''} ${seeded ? '' : 'disabled'}
                      title="${esc(why)}">${esc(label)}${seeded ? '' : ' — ' + esc(t.siteNoSeeder || 'no seeder yet')}</option>`).join('')}
            ${known ? '' : `<option value="${esc(v)}" selected>${esc(v)}</option>`}
            </select>
            <p class="hint">${esc(t.sitePlatformHint || '')}</p>`;
          break;
        }
        const cur = (v === '' ? 'dotnet' : v).toLowerCase();
        const known = RUNTIMES.some(([r]) => r === cur);
        // An out-of-support .NET is never offered, only kept on a row already using it.
        const offered = RUNTIMES.filter(([r]) => {
          const m = r.match(/^dotnet(\d+)$/);
          return r === cur || !m || supportOf('dotnet', m[1]).level !== 'bad';
        });
        input = `<select data-i="${i}" data-runtime>${offered.map(([r, label, why]) => `
            <option value="${r}" ${r === cur ? 'selected' : ''}
                    title="${esc((t.runtimes && t.runtimes[r]) || why)}">${esc(label)}</option>`).join('')}
          ${known ? '' : `<option value="${esc(v)}" selected>${esc(v)}</option>`}
          </select>
          <span data-runtime-support>${runtimeSupportPill(cur, t)}</span>`;
        break;
      }

      // Three modes, each with its meaning on the option itself and all three
      // together behind the ⓘ, so the choice does not need a document open.
      // Who this row belongs to. Only a full access admin ever sees it: the
      // field is dropped from SHAPE for everybody else, so this never renders
      // for the person it would decide about.
      //
      // The accounts come from the password file, through the same ?ask=users
      // the Users tab reads, so a name here is a name that can actually sign
      // in. A dash is first and is the default: an unowned row belongs to
      // nobody, which is what a new row is until somebody says otherwise.
      case 'owner': {
        // Empty is nobody, not '-'. Every other field in this drawer shows a
        // stored '-' as blank, and a post-render pass sets each control from
        // the normalised draft, so an option whose value is '-' can never be
        // the selected one: it silently rendered with nothing chosen.
        const cur = v;
        const names = (typeof USERS !== 'undefined' && USERS.length)
          ? USERS.filter(u => !u.admin).map(u => u.name)
          : (cur ? [cur] : []);
        const sel = `<select data-i="${i}" data-owner>
          <option value="" ${cur === '' ? 'selected' : ''}>${esc(t.ownerNobody)}</option>
          ${names.map(n => `<option value="${esc(n)}" ${n === cur ? 'selected' : ''}>${esc(n)}</option>`).join('')}
        </select>`;

        // USER ROLE, beside the owner because it is about the same person, and
        // a dropdown rather than a tick so all three answers are one click.
        // The owner, 2026-09-10.
        //
        // It is NOT a row field and is not published with the row: it writes a
        // role onto that ACCOUNT, which is what the console door and every
        // admin.<domain> check. Its own call, made the moment it changes,
        // exactly as the Users tab does it.
        //
        // Every domain already has an admin.<domain>; this decides whether this
        // person gets through its login at all.
        const u = (typeof USERS !== 'undefined') ? USERS.find(x => x.name === cur) : null;
        const role = u ? (u.role || 'none') : 'none';
        const off = (cur === '');
        const opt = (val, label) =>
          `<option value="${val}" ${role === val ? 'selected' : ''}>${esc(label)}</option>`;
        const rolePick = `<label class="note" style="display:block;margin:.45rem 0 .2rem"
            >${esc(t.userRole)}</label>
          <select data-adminrole ${off ? 'disabled' : ''}>
            ${opt('none',  t.uRoleNone)}
            ${opt('admin', t.uRoleAdmin)}
            ${opt('full',  t.uRoleFull)}
          </select>
          <p class="note" data-ownernote style="margin:.2rem 0 0" ${off ? "" : "hidden"}>${esc(t.adminPageNoOwner)}</p>`;

        input = sel + rolePick;
        break;
      }

      case 'repomode': {
        const cur = v === '' ? 'private' : v.toLowerCase();
        input = `<select data-i="${i}">${REPOMODES.map(([mode, why]) => `
          <option value="${mode === 'private' ? '-' : mode}" ${mode === cur ? 'selected' : ''}
                  title="${esc((t.modes && t.modes[mode]) || why)}">${mode}</option>`).join('')}</select>`;
        break;
      }

      // The base domain is stored as '-', which is what add_mail_store.sh
      // expects and what keeps the row unchanged when nothing was chosen.
      //
      // Two groups. The first is what this config already knows about; the
      // second is what the DNS account holds and this config has never heard
      // of, which is the case that used to mean editing the file by hand.
      // Choosing one of those adds it to DNS_DOMAINS when the config is saved.
      case 'domain': {
        // A limited admin never owns the base domain, so a new mailbox starts on
        // the first domain they do own rather than as a request for BASE.
        const limitedBlank = typeof MYROLE !== 'undefined' && MYROLE !== 'full'
                             && (v === '' || v === '-') && MAILDOMAINS.length > 0;
        const cur   = limitedBlank ? MAILDOMAINS[0] : (v === '' ? BASE : v.replace(/^=/, ''));
        const known = [...new Set([...MAILDOMAINS, ...extraDomains])];
        const extra = (accountDomains || []).filter(d => !known.includes(d));

        const opt = d => `<option value="${d === BASE ? '-' : esc(d)}" ${d === cur ? 'selected' : ''}>
            ${esc(d)}${d === BASE ? ' (' + esc(t.baseDomain) + ')' : ''}
          </option>`;

        // THE SAME DOMAIN REQUEST AS THE OTHER TWO DRAWERS. The owner, 2026-09-11:
        // all three. A mailbox stores its domain plainly rather than with the
        // `=` grammar, so the wanted name goes into the select as an option of
        // its own and everything downstream reads one control, as before.
        const mNew = cur !== '' && !known.includes(cur) && !extra.includes(cur);
        input = `${domainAskBlock(mNew, cur)}
          <div id="addr-domwrap"${mNew ? ' hidden' : ''}>
          <select data-i="${i}" data-domain>
            <optgroup label="${esc(t.domainsKnown)}">${known.map(opt).join('')}</optgroup>
            ${extra.length ? `<optgroup label="${esc(t.domainsNew)}">${extra.map(opt).join('')}</optgroup>` : ''}
            ${mNew ? `<option value="${esc(cur)}" selected>${esc(cur)}</option>` : ''}
          </select>
          <p class="hint" id="domain-status">${esc(domainStatus(t))}</p>
          </div>`;
        break;
      }

      // Sharing another service's data is the exception, so the question is
      // asked as a tick first. Only applications are offered: apply_app_settings
      // resolves the folder from the source row's dll path, so a website or a
      // mailbox would resolve to nothing.
      case 'datasource': {
        const names = rows.map(r => r.f)
          .filter(r => r[0] === 'app' && !blank(r[1]) && r[1] !== draft[1])
          .map(r => r[1]);
        const on = v !== '';

        // A value the config no longer lists, and the `=path` escape hatch, both
        // have to survive being opened rather than being silently reassigned.
        const known = names.includes(v);

        // GREYED, not just unclickable. The box disabled itself with the reason
        // in a tooltip only, so a control that could not be ticked looked
        // identical to one that could. The owner, 2026-09-07.
        input = `<label id="ds-label" class="${names.length ? '' : 'is-off'}"
                 style="font-weight:400"><input type="checkbox" id="ds-box"
                 ${on ? 'checked' : ''} style="width:auto"> ${esc(t.dsShare)}</label>
          <select id="ds-name" style="margin-top:.4rem"${on ? '' : ' hidden'}>
            ${names.map(n => `<option value="${esc(n)}" ${n === v ? 'selected' : ''}>${esc(n)}</option>`).join('')}
            ${(on && !known) ? `<option value="${esc(v)}" selected>${esc(v)}</option>` : ''}
          </select>
          <input type="hidden" data-i="${i}" id="ds-value" value="${esc(v)}">
          <p class="hint" id="ds-note"${on ? '' : ' hidden'}>${esc(t.dsNote)}</p>`;
        break;
      }

      // What the row answers on, as a question instead of a punctuation rule.
      // `=` for a whole other domain and a bare `@` for the apex are things you
      // have to already know, and the file's legend is not open at the time.
      //
      // The composed value goes into a hidden field, so saving still reads one
      // control and the file still stores the same grammar.
      case 'address': {
        // Which domain, then what goes in front of it. One list of five modes
        // mixed those two questions, and could not say shop.example.org
        // at all.
        // A limited admin is offered only the domains their own rows use, and
        // the server has already cut MAILDOMAINS to those. The owner, 2026-09-16.
        const baseOffered = (typeof MYROLE === 'undefined' || MYROLE === 'full') || MAILDOMAINS.includes(BASE);
        const DOMAINS = [...(baseOffered ? [BASE] : []), ...MAILDOMAINS.filter(d => d !== BASE)];
        let dom = BASE, text = '', live = false;
        if (v === '')               { dom = ''; }
        else if (v === '@')         { dom = BASE; }
        else if (v.startsWith('=')) {
          const whole = v.slice(1);
          dom  = DOMAINS.find(d => whole === d || whole.endsWith('.' + d)) || whole;
          text = whole === dom ? '' : whole.slice(0, -(dom.length + 1));
        }
        else if (v.startsWith('@')) { dom = BASE; text = v.slice(1); live = true; }
        else                        { dom = BASE; text = v; }

        // A domain the config no longer lists still has to survive being
        // opened, so it is offered back rather than silently reassigned.
        const known = dom === '' || DOMAINS.includes(dom);

        // A DOMAIN NOBODY OWNS YET. The owner, 2026-09-11: a customer should be
        // able to ask for the URL, so the order can be placed at TransIP and
        // the row written against it afterwards.
        //
        // It is stored as `=thedomain.nl` like any other whole domain, so
        // nothing downstream learns a new grammar: the difference is only that
        // it does not resolve yet.
        //
        // THE TICK IS A CLAIM, NOT A CHECK, and that is deliberate. I argued
        // for calling TransIP's availability endpoint at file time and again at
        // approval, because a domain free on Tuesday is gone on Thursday;
        // The owner chose the tick and the link. It is recorded with who ticked it
        // and when, so the claim is at least dated.
        const isNewDom = v.startsWith('=') && !known;
        input = `${domainAskBlock(isNewDom, dom)}
          <div id="addr-domwrap"${isNewDom ? ' hidden' : ''}>
          <select id="addr-dom">${
            DOMAINS.map(d => `<option value="${esc(d)}" ${d === dom ? 'selected' : ''}>${esc(d)}</option>`).join('')
          }${known ? '' : `<option value="${esc(dom)}" selected>${esc(dom)}</option>`
          }<option value="" ${dom === '' ? 'selected' : ''}>${esc(t.addrNone)}</option></select>
          </div>
          <div id="addr-live" style="margin-top:.6rem">
            <label style="display:block;margin-bottom:.25rem">${esc(t.addrLiveLinks)}</label>
            <select id="addr-apex">
              <option value="apex" ${live || text === '' ? 'selected' : ''}>${esc(t.addrWholeDomain)}</option>
              <option value="sub"  ${!live && text !== '' ? 'selected' : ''}>${esc(t.addrSubdomain)}</option>
            </select>
            <!-- Whose domain this takes, right under the control that takes it.
                 the owner, 2026-09-10: the answer belongs beside the question, not
                 only in the summary above the button. -->
            <p class="hint warn" id="addr-takeover" hidden></p>
          </div>
          <div id="addr-otherwrap" style="margin-top:.6rem">
            <label style="display:block;margin-bottom:.25rem">${esc(t.addrOtherEnvs)}</label>
            <select id="addr-other">
              <option value="named" ${live && text !== '' ? 'selected' : ''}></option>
              <option value="plain" ${live && text !== '' ? '' : 'selected'}></option>
            </select>
          </div>
          <div id="addr-namewrap">
            <label id="addr-namelabel" style="display:block;margin:.6rem 0 .25rem">${esc(t.addrNameLabel)}</label>
            <input id="addr-text" value="${esc(text)}"
                   placeholder="${esc(t.addrSubHint)}">
            <p class="hint" id="addr-namehint"></p>
          </div>
          <input type="hidden" data-i="${i}" id="addr-value" value="${esc(v)}">`;
        break;
      }

      // A document root is stored relative to WEB_ROOT, so the fixed half is
      // shown rather than asked for, the folders already in that root are
      // offered, and the field says whether this one exists yet. Free text
      // still wins: a folder that does not exist is created by the apply.
      // A repository is asked for two ways, and the file stores both in one
      // field: the word `new` means provision_repo.sh creates it on the next
      // apply, and anything else is a clone URL it uses as it stands. The
      // choice is a picker rather than a word to remember, and the URL box is
      // only there when it applies.
      //
      // HTTPS, not SSH: the deploy job clones with the `github-token`
      // credential, which is the GitHub App. A git@ URL needs a key Jenkins
      // does not have.
      case 'repo': {
        // A row being added defaults to Create new repo: it is the answer in
        // almost every case, and the word 'new' was never discoverable. An
        // existing row with an empty field keeps Use existing, so opening one
        // and saving it cannot create a repository nobody asked for.
        const isNewRow = !ROWWAS[editing];
        const wantsNew = v.toLowerCase() === 'new' || (v === '' && isNewRow);
        input = `<select id="repo-choice">
            <option value="new"      ${wantsNew ? 'selected' : ''}>${esc(t.repoNew)}</option>
            <option value="existing" ${wantsNew ? '' : 'selected'}>${esc(t.repoExisting)}</option>
          </select>
          <div id="repo-urlwrap" style="margin-top:.6rem" ${wantsNew ? 'hidden' : ''}>
            <label style="display:block;margin-bottom:.25rem">${esc(t.repoUrlLabel)}</label>
            <input id="repo-url" spellcheck="false" autocomplete="off"
                   placeholder="https://github.com/you/thing.git"
                   value="${esc(wantsNew ? '' : v)}">
          </div>
          <p class="hint" id="repo-hint"></p>
          <input type="hidden" data-i="${i}" id="repo-value" value="${esc(v)}">`;
        break;
      }

      // THE SOURCE BRANCH.
      //
      // Free text until 2026-09-09, so a name was typed and found wrong at the
      // first deploy. The list arrives from the machine once a clone URL is
      // filled in; until then this holds what the row already says.
      //
      // The hidden input is the value: the select only writes into it, the same
      // shape the repository picker uses, so an unreadable repository leaves the
      // saved value exactly as it was rather than blanking it.
      case 'branch': {
        input = `<select id="branch-select" disabled>
            <option value="">${esc(t.branchAuto)}</option>
          </select>
          <p class="hint" id="branch-hint"></p>
          <p class="hint" id="branch-missing"></p>
          <input type="hidden" data-i="${i}" id="branch-value" value="${esc(v)}">`;
        break;
      }

      case 'docroot-path': {
        const root = WEBROOTS[ENVS[0]] || WEBROOTS.live || '';
        input = `<div class="pathrow">
            <span class="pathfix">${esc(root)}/</span>
            <input data-i="${i}" id="docroot-path" list="docroot-folders"
                   spellcheck="false" autocomplete="off" value="${esc(v)}"
                   placeholder="${esc(draft[1] || '')}">
          </div>
          <datalist id="docroot-folders">${
            (WEBFOLDERS[root] || []).map(f => `<option value="${esc(f)}">`).join('')
          }</datalist>
          <p class="hint" id="docroot-hint"></p>`;
        break;
      }

      case 'app-path': {
        // Two controls over one hidden truth, the same shape the repository
        // picker uses: the dropdown changes only the FILENAME, and the box
        // keeps the folder, because two rows of the same repository differ by
        // their folder and share a dll name. That is how the three
        // progress-repo rows work today.
        //
        // The list arrives from the machine after the drawer is open, so this
        // renders with the current value and one placeholder option. A
        // repository that cannot be read leaves the box exactly as it was.
        input = `<div class="pathrow">
            <select id="app-project" data-appproject>
              <option value="">${esc(t.appProjLoading || 'reading the repository...')}</option>
            </select>
          </div>
          <input data-i="${i}" id="app-path" value="${esc(v)}" spellcheck="false"
                 autocomplete="off">
          <p class="hint" id="app-project-hint"></p>`;
        break;
      }

      default:
        input = `<input data-i="${i}" value="${esc(v)}">`;
    }

    // Who may enter only exists if a login does. Hidden rather than disabled:
    // a list of accounts under "no login" reads as though it still applies.
    // AuthProtected is still the stored field, but the ticks beside each
    // environment are what edit it now, so its own control never shows.
    const hide = (key === 'AuthUsers' || key === 'AuthProtected')
      ? ' style="display:none"' : '';

    // Thirteen fields with a paragraph each is thirteen paragraphs to read past
    // every time one value is changed. The explanation goes behind the ⓘ, with
    // the file's own key for the field, and only opens when it is wanted.
    const tip = (key === 'RepoMode')
      ? REPOMODES.map(([m, why]) => m + ': ' + ((t.modes && t.modes[m]) || why)).join('\n\n')
      : L.hint;

    // Path means two different things. For an app it is the dll that gets
    // executed, for a website the folder that gets served, and one label
    // covering both told you neither.
    // On an application it narrows again by runtime: "Path to the DLL" is wrong
    // the moment the type is Node.
    const fieldLabel = (key === 'ApplicationName' && t.rowName && t.rowName[draft[0]])
        ? t.rowName[draft[0]]
      // Field 13 again: "Runs on" is an application's runtime, and on a website
      // the same field names what the new repository is seeded with.
      : (key === 'Runtime' && draft[0] === 'website' && t.sitePlatform)
        ? t.sitePlatform
      : (key === 'Path' && draft[0] === 'app' && t.pathRuntime
                        && t.pathRuntime[pathKind(draft[13])])
        ? t.pathRuntime[pathKind(draft[13])]
      : (key === 'Path' && t.path && t.path[draft[0]]) ? t.path[draft[0]]
      : (draft[0] === 'mailbox' && t.mail && t.mail[key]) ? t.mail[key]
      : L.label;

    // Its own control rather than a column: AuthUsers already holds the answer,
    // and a second field would hold it twice. It sits above the environments
    // because it is answered first: pick the person, then every environment
    // ticked afterwards is ticked for them.
    // NOT FOR A LIMITED ADMIN. shapeFor() already withholds field 15, and this
    // control writes the same value by another route, so a customer was still
    // shown a picker naming every other account. Item 106: they could hand a
    // row away or take one, and other users are not shown in the picker at all.
    // Found 2026-09-11 by opening the Add drawer signed in as a customer.
    const others = (typeof MYROLE !== 'undefined' && MYROLE !== 'full')
      ? [] : ACCOUNTS.filter(a => a !== ADMIN);
    const owner = (key === 'Envs' && others.length)
      ? `<div data-field="OwnerPick">
          <label>${esc(t.envOwner)}
            <span class="info" title="${esc(t.envOwnerHint)}">&#9432;</span></label>
          <div class="owner-row" data-ownerpick>
            <select data-owner>
              <option value="">${esc(t.envOwnerNone)}</option>
              ${others.map(a => `<option value="${esc(a)}">${esc(a)}</option>`).join('')}
            </select>
          </div>
        </div>`
      : '';

    // SAID, NOT ASKED. shapeFor() withholds field 15 on a mailbox, so without
    // this line the question would simply vanish from the drawer. Item 153.
    const belongs = (key === 'Subdomain' && f[0] === 'mailbox')
      ? `<div class="belongs-note" data-field="BelongsTo">${esc(t.belongsTo)}
           <strong>${esc(mailboxOwner(v) || t.belongsNobody)}</strong></div>`
      : '';

    return owner + `<div data-field="${esc(key)}"${hide}>
              <label>${esc(fieldLabel)}
                <span class="info" title="${esc(key + '\n\n' + tip)}">&#9432;</span></label>
              ${input}
            </div>` + belongs;
  }).join('');

  // BRANCH AND THE DLL PATH BOTH DEPEND ON WHETHER THE REPOSITORY EXISTS YET,
  // and the repository picker is rendered before either of them. Assigned by
  // the app-path block below, called by syncRepo above it.
  let syncRepoDeps = () => {};

  // The repository picker. The hidden field is what the file stores, so the two
  // controls above it never disagree with what gets written.
  const repoChoice = document.getElementById('repo-choice');
  if (repoChoice) {
    const urlWrap = document.getElementById('repo-urlwrap');
    const urlBox  = document.getElementById('repo-url');
    const hidden  = document.getElementById('repo-value');
    const rhint   = document.getElementById('repo-hint');
    // The Branch field names the branch the environment branches are cut FROM,
    // and it is shown for a new repository as well as an existing one:
    // syncRepo() below carries the 2026-09-09 reasoning.
    //
    // This comment used to say it was hidden and cleared for a new repository.
    // That stopped being true the same day, and the contradiction sat here,
    // 140 lines above the code doing the opposite, until 2026-09-10.
    const branchRow = document.querySelector('#drawer-fields [data-field="Branch"]');
    const branchBox = branchRow ? branchRow.querySelector('[data-i]') : null;

    // WHAT BRANCHES THE REPOSITORY ACTUALLY HAS, and which of the ticked
    // environments have none.
    //
    // Asked once per URL and remembered, because this is fired on every
    // keystroke in the URL box and a round trip per character would be absurd.
    const branchSel  = document.getElementById('branch-select');
    const branchVal  = document.getElementById('branch-value');
    const branchHint = document.getElementById('branch-hint');
    const branchMiss = document.getElementById('branch-missing');
    let branchesFor  = '';
    let branchList   = null;
    let branchTimer  = null;

    // The branch each ticked environment deploys, from ENVBRANCH, which is what
    // the config's <ENV>_BRANCH lines say. skunk deploys skunkworks, which is
    // the one name that is not its environment's.
    const wantedBranches = () => {
      // [data-env] is the tick that says the row exists in that environment.
      // The other two boxes on the same line are the preview and the login.
      const on = [...document.querySelectorAll('#drawer-fields [data-env]:checked')]
        .map(c => c.value);
      const list = on.length ? on : ENVS;
      return list.map(e => (ENVBRANCH && ENVBRANCH[e]) || e);
    };

    const paintBranches = () => {
      if (!branchSel || !branchVal) return;
      const cur = branchVal.value.trim();
      if (!branchList) {
        branchSel.disabled = true;
        branchSel.innerHTML = `<option value="">${esc(t.branchAuto)}</option>`;
        if (branchHint) branchHint.textContent = '';
        if (branchMiss) branchMiss.textContent = '';
        return;
      }
      branchSel.disabled = false;
      // WHAT IT OPENS ON, in order: what the row already says, then the branch
      // the LIVE environment deploys, then the repository's default, then
      // whatever is first. Live's branch before the default because that is the
      // branch this row's code actually comes from where the repository is laid
      // out per environment; the default is the answer for a repository that is
      // not. The owner, 2026-09-09.
      const liveEnv = ENVS[0] || 'live';
      const liveBranch = (ENVBRANCH && ENVBRANCH[liveEnv]) || liveEnv;
      const pick = branchList.includes(cur) ? cur
                 : branchList.includes(liveBranch) ? liveBranch
                 : branchList.includes(branchList.def) ? branchList.def
                 : branchList[0];
      // AN EMPTY OPTION, FIRST. Without one there was no way back to blank once
      // the list had loaded, so opening a saved row whose field is `-` and
      // saving it wrote a branch into a field that had none. Rarely wanted,
      // The owner's words, and the row that wants it has no way to say so
      // otherwise.
      // EMPTY MEANS TWO DIFFERENT THINGS, and only the row knows which. On a
      // SAVED row it is an answer: this row deliberately has no source branch,
      // and picking one for it would write a value nobody asked for. On a NEW
      // row it is just an unanswered question, so it takes the live branch or
      // the default. Getting this wrong made every new row open on `none`.
      const isNewRow = !ROWWAS[editing];
      const chosen = branchList.includes(cur) ? cur
                   : (cur === '' && !isNewRow) ? ''
                   : pick;
      branchSel.innerHTML =
        `<option value=""${chosen === '' ? ' selected' : ''}>${esc(t.branchNone2)}</option>`
        + branchList.map(b =>
          `<option value="${esc(b)}"${b === chosen ? ' selected' : ''}>${esc(b)}${
            b === branchList.def ? ' (' + esc(t.branchDefault) + ')' : ''}</option>`).join('');
      branchVal.value = chosen;

      // What the row will actually deploy, said before it is saved rather than
      // discovered at the first build.
      const want = wantedBranches();
      const missing = want.filter(b => !branchList.includes(b));
      // ONE SENTENCE, NOT TWO. They were two lines and read as a
      // contradiction: "every environment deploys main" above "live is
      // created from the branch above". Both were true and neither said WHEN,
      // which is the whole difference between them. The owner, 2026-09-09.
      //
      // So the missing case carries the sequence itself, and the generic line
      // is only shown when there is nothing missing to say.
      const line = !missing.length      ? t.branchPerEnv
                 : chosen === ''        ? t.branchNoneChosen
                 : missing.length === want.length
                                        ? t.branchMakeAll(missing.join(', '), chosen)
                                        : t.branchMakeSome(missing.join(', '), chosen);
      if (branchHint) {
        branchHint.textContent = line;
        branchHint.className = 'hint' + (missing.length ? ' warn' : '');
      }
      if (branchMiss) { branchMiss.textContent = ''; branchMiss.className = 'hint'; }
    };

    const loadBranches = url => {
      if (url === branchesFor) { paintBranches(); return; }
      branchesFor = url;
      branchList = null;
      paintBranches();
      if (!url) return;
      if (branchSel) {
        branchSel.innerHTML = `<option value="">${esc(t.branchReading)}</option>`;
      }
      fetch('?branches=' + encodeURIComponent(url), { cache: 'no-store' })
        .then(r => r.json())
        .then(d => {
          // Still the URL that was asked about: the box may have moved on.
          if (branchesFor !== url) return;
          if (!d || !d.ok || !Array.isArray(d.branches) || !d.branches.length) {
            branchList = null;
            paintBranches();
            if (branchHint) {
              branchHint.textContent = (d && d.error) ? d.error : t.branchNone;
              branchHint.className = 'hint bad';
            }
            return;
          }
          branchList = d.branches.slice();
          branchList.def = d.default || '';
          paintBranches();
        })
        .catch(() => { branchList = null; paintBranches(); });
    };

    if (branchSel) {
      branchSel.addEventListener('change', () => {
        branchVal.value = branchSel.value;
        paintBranches();
        checkDrawer();
      });
    }

    const syncRepo = () => {
      const isNew = repoChoice.value === 'new';
      urlWrap.hidden = isNew;
      hidden.value = isNew ? 'new' : urlBox.value.trim();
      // SHOWN FOR A NEW REPOSITORY TOO, since 2026-09-09. It used to be hidden,
      // because the field only ever OVERRODE a branch and a repository that does
      // not exist has nothing to override. It now names the branch the
      // environment branches are cut FROM, which a new repository has as much as
      // an existing one.
      if (branchRow) { branchRow.hidden = false; }
      clearTimeout(branchTimer);
      branchTimer = setTimeout(() => loadBranches(isNew ? '' : urlBox.value.trim()), 350);
      syncRepoDeps();
      if (!rhint) return;
      const url = urlBox.value.trim();
      if (isNew) {
        // Asked for here, not on page load: it is a sudo call and three GitHub
        // round trips, and most visits never open a row that creates one.
        askRepoNames();
        const rowName = (document.querySelector(
          '#drawer-fields [data-field="ApplicationName"] input') || {}).value || '';
        const held = repoNameTakenBy(rowName);
        const owner = repoCreateOwner();
        rhint.textContent = held ? t.repoNameTaken(rowName.trim(), held)
          : owner ? t.repoNewIn(owner)
          : t.repoNewHint;
        rhint.className = held ? 'hint bad' : 'hint';
        return;
      }
      rhint.textContent = url === '' ? t.repoNeedUrl
        : /^git@/.test(url) ? t.repoSshWrong
        : t.repoUrlOk;
      rhint.className = (url === '' || /^git@/.test(url)) ? 'hint bad' : 'hint';
    };
    repoChoice.addEventListener('change', syncRepo);
    urlBox.addEventListener('input', syncRepo);
    // The row's name IS the repository name, so the hint has to follow it.
    const repoNameBox = document.querySelector(
      '#drawer-fields [data-field="ApplicationName"] input');
    if (repoNameBox) repoNameBox.addEventListener('input', syncRepo);
    syncRepo();
  }

  // The startup-project dropdown. Asked for the row's repository once, when
  // the drawer opens, because it clones a branch.
  //
  // WHAT IT CHANGES IS ONLY THE FILENAME. The folder is the operator's: two
  // rows of the same repository differ by their folder and share a dll name,
  // which is how the three progress-repo rows are told apart.
  //
  // A LIBRARY IS LISTED AND DISABLED rather than hidden. A reader whose
  // project is simply absent has no idea why; one who sees it greyed with
  // "not runnable" beside it knows immediately.
  const appPath = document.getElementById('app-path');
  const appProj = document.getElementById('app-project');
  // `editing != null` used to guard this whole block, so a row being ADDED got
  // no dropdown, no hint and a placeholder option that read "reading the
  // repository..." for ever. Only the CLONE needs a saved row: ?projects= looks
  // the row up in the config to find its repository. The prefill does not, so
  // the guard moved down to the fetch.
  if (appPath && appProj) {
    const hint = document.getElementById('app-project-hint');
    const rowName = ((editing != null && rows[editing] && rows[editing].f[1]) || '').trim();

    const dllOf = p => (p.split('/').pop() || '');
    const setProject = name => {
      const parts = appPath.value.split('/');
      parts[parts.length - 1] = name + '.dll';
      appPath.value = parts.join('/');
      appPath.dispatchEvent(new Event('input', { bubbles: true }));
    };

    // A REPOSITORY THAT DOES NOT EXIST YET CANNOT BE READ, so the dropdown had
    // nothing to offer and said "could not read the repository" on every new
    // row. The answer is derivable instead of pickable: seed_app_project.sh
    // runs `dotnet new blazor --name <row name, letters digits and _ only>`
    // at the repository root, so the dll is that name.
    //
    // Kept in step with seed_app_project.sh:203. If the template or the naming
    // there changes, this line is wrong and the row deploys a dll that is not
    // built.
    const seedProject = () => {
      const box = document.querySelector('#drawer-fields [data-field="ApplicationName"] input');
      let n = ((box ? box.value : rowName) || '').replace(/[^A-Za-z0-9_]/g, '');
      if (n === '') n = 'App';
      if (/^[0-9]/.test(n)) n = 'App' + n;
      return n;
    };

    // Only while the box still holds what WE put there. Something typed by hand
    // is never rewritten, which is the same rule the document-root field
    // follows for the row name.
    // A shape test, not a remembered string: renderDrawerFields() runs on
    // every keystroke, so a per-render `lastSeeded` was '' by the second call
    // and the box kept the empty-name fallback App/App.dll for ever. Measured
    // 2026-09-09 on example_net, whose deploy then hunted for
    // App.csproj in a repository seeded with example_net.csproj and
    // failed every build in every environment.
    // 'Dockerfile' counts as ours too (item 141), so switching the type back to
    // .NET replaces it instead of leaving a Dockerfile path on a dotnet row.
    const seededShape = v => {
      if (v === 'Dockerfile') return true;
      const m = v.match(/^([A-Za-z0-9_]+)[/]([A-Za-z0-9_]+)(?:[.]Server)?[.]dll$/);
      return !!m && m[1] === m[2];
    };
    const paintSeeded = () => {
      const want = seedProject();
      const cur  = appPath.value.trim();
      // A FOLDER OF ITS OWN, not the root of APP_ROOT. deploy_app.sh publishes
      // to APP_ROOT/<Path> and rsyncs with --delete, and every row in an
      // environment shares that APP_ROOT. A bare "<name>.dll" therefore puts
      // two rows in one directory and the second deploy wipes the first.
      // Measured 2026-09-07: tesw6 and test4 landed in the same folder, and
      // accept and skunk were left running a dll from the other row.
      // A CONTAINER ROW NAMES ITS DOCKERFILE, NOT A DLL (item 141). What runs
      // inside is the image's own ENTRYPOINT, so the dll, if there is one, is
      // named in the Dockerfile where only that image's layout decides it.
      // The box stays, because a repository with more than one Dockerfile has
      // no other way to say which.
      const isDockerRow = isDocker(draft[13]);
      if (cur === '' || seededShape(cur)) {
        // Uno with Server is seeded as <name> and <name>.Server; the server runs.
        const isUno = /^uno/.test(String(draft[13] || '').toLowerCase());
        appPath.value = isDockerRow
          ? 'Dockerfile'
          : want + '/' + want + (isUno ? '.Server' : '') + '.dll';
        appPath.dispatchEvent(new Event('input', { bubbles: true }));
      }
      appProj.parentElement.hidden = true;
      if (hint) {
        hint.textContent = isDockerRow
          ? (t.appProjSeededDocker || 'The new repository is seeded with a working sample and this Dockerfile, which is what gets built.')
          : (t.appProjSeeded || 'The new repository is seeded with a starter app called %s, so this is its dll.').replace('%s', want);
        hint.className = 'hint';
      }
    };

    const repoIsNew = () => {
      const h = document.getElementById('repo-value');
      return !!h && h.value.trim().toLowerCase() === 'new';
    };

    const loadProjects = () => {
    // A clone takes 3 to 6 seconds on a real repository, measured 2026-09-04,
    // and until 2026-09-04 the dropdown sat empty and enabled for all of it:
    // indistinguishable from a repository with no projects in it. It says so
    // now, and cannot be picked from while it is still reading.
    appProj.innerHTML = `<option value="">${esc(t.appProjReading || "reading the repository...")}</option>`;
    appProj.disabled = true;
    appProj.classList.add('loading');
    if (hint) hint.textContent = t.appProjReadingHint || '';

    const stopLoading = () => appProj.classList.remove('loading');

    fetch('?projects=' + encodeURIComponent(rowName), { cache: 'no-store' })
      .then(r => r.json())
      .then(d => {
        stopLoading();
        if (!d || d.error || !Array.isArray(d.projects) || !d.projects.length) {
          appProj.innerHTML =
            `<option value="">${esc(t.appProjNone || 'could not read the repository')}</option>`;
          appProj.disabled = true;
          if (hint) hint.textContent = (d && d.error) ? d.error : '';
          return;
        }
        const current = dllOf(appPath.value).replace(/\.dll$/i, '');
        appProj.innerHTML = d.projects.map(p =>
          `<option value="${esc(p.name)}"${p.runnable ? '' : ' disabled'}${
            p.name === current ? ' selected' : ''}>${esc(p.name)}${
            p.runnable ? '' : ' — ' + esc(t.appProjNotRunnable || 'not runnable')}</option>`
        ).join('');
        appProj.disabled = false;

        // Nothing typed yet, so take the first runnable one. A row being
        // EDITED keeps whatever it already names, even if that name is not in
        // the list: saying so is more useful than silently repointing it.
        if (!current) {
          const first = d.projects.find(p => p.runnable);
          if (first) { appProj.value = first.name; setProject(first.name); }
        } else if (!d.projects.some(p => p.name === current)) {
          appProj.value = '';
          if (hint) hint.textContent = (t.appProjMissing || 'this row names %s, which is not in the repository').replace('%s', current);
        }
      })
      .catch(() => {
        stopLoading();
        appProj.innerHTML =
          `<option value="">${esc(t.appProjNone || 'could not read the repository')}</option>`;
        appProj.disabled = true;
      });
    };

    // Called by the repository picker, and once here for the row as it opens.
    // A row switched back to an existing repository gets its dropdown and its
    // clone; one switched to new never pays for a clone it cannot use.
    let loaded = false;
    syncRepoDeps = () => {
      if (repoIsNew()) { paintSeeded(); return; }
      appProj.parentElement.hidden = false;
      // An unsaved row pointed at an existing repository cannot be read yet:
      // ?projects= finds the repository BY LOOKING THE ROW UP in the config,
      // and the row is not in it. Say so, rather than spinning on a clone that
      // can only fail.
      if (editing == null) {
        appProj.innerHTML = '<option value="">' +
          esc(t.appProjAfterSave || 'available once the row is saved') + '</option>';
        appProj.disabled = true;
        if (hint) { hint.textContent = t.appProjTypeIt || ''; hint.className = 'hint'; }
        return;
      }
      if (!loaded) { loaded = true; loadProjects(); }
    };
    const nameBoxForDll = document.querySelector('#drawer-fields [data-field="ApplicationName"] input');
    if (nameBoxForDll) {
      nameBoxForDll.addEventListener('input', () => { if (repoIsNew()) paintSeeded(); });
    }
    // THE TYPE DECIDES THE PATH, so changing it has to repaint it. Only the
    // name box did, which is why switching to Docker left a dll path and the
    // word Dockerfile had to be typed. Measured 2026-09-17: draft[13] was
    // already 'docker' while the box still read <name>/<name>.Server.dll from
    // the type before it. Uno looked right only because the name had been
    // typed after it was picked.
    const rtBox = document.querySelector('#drawer-fields [data-field="Runtime"] select');
    if (rtBox) {
      rtBox.addEventListener('change', () => { if (repoIsNew()) paintSeeded(); });
    }
    syncRepoDeps();

    appProj.addEventListener('change', () => {
      if (appProj.value) { setProject(appProj.value); if (hint) hint.textContent = ''; }
    });
  }

  // The document root field: say whether the folder is there, and offer the
  // row's own name when nothing has been typed. Taking the name over is a
  // default, not a rule: it fills only while the field is untouched, so an
  // existing row's folder is never renamed behind the operator's back.
  const drPath = document.getElementById('docroot-path');
  if (drPath) {
    const root  = WEBROOTS[ENVS[0]] || WEBROOTS.live || '';
    const known = WEBFOLDERS[root] || [];
    const hint  = document.getElementById('docroot-hint');
    const paint = () => {
      const val = drPath.value.trim();
      if (!hint) return;
      if (val === '') { hint.textContent = t.docrootEmpty; hint.className = 'hint'; return; }
      hint.textContent = known.includes(val)
        ? t.docrootExists(root + '/' + val)
        : t.docrootNew(root + '/' + val);
      hint.className = known.includes(val) ? 'hint good' : 'hint';
    };
    drPath.addEventListener('input', () => { drPath.dataset.touched = '1'; paint(); });
    const nameBox = document.querySelector('#drawer-fields [data-field="ApplicationName"] input');
    if (nameBox) {
      nameBox.addEventListener('input', () => {
        if (drPath.value === '' || (!drPath.dataset.touched && !ROWWAS[editing])) {
          drPath.value = nameBox.value.trim();
          paint();
        }
      });
    }
    paint();
  }

  const addrDom = document.getElementById('addr-dom');
  if (addrDom) {
    // Picking the domain answers the name too, on a row that has not been named
    // yet: example.net suggests example-net, which then fills
    // the folder through the field below. Only while both are untouched, so
    // choosing a domain on an existing row never renames it.
    // What the row would be called, given where it answers. A subdomain names
    // the row; only a row on the bare domain is named after the domain.
    const suggestName = () => {
      const apexSel = document.getElementById('addr-apex');
      const textBox = document.getElementById('addr-text');
      const src = (apexSel && apexSel.value !== 'apex' && textBox)
        ? textBox.value : addrDom.value;
      const slug = (src || '').toLowerCase()
        .replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
      if (!slug) return '';
      // One customer, two rows: www_ serves files, app_ runs a service, and
      // only one of them is enabled at a time. The prefix goes at the FRONT
      // because that is where the eye lands, which is the owner's reason for
      // wanting it, 2026-09-10: three characters read before the name rather
      // than a suffix you reach by reading the whole thing.
      //
      // The name becomes the repository name for a row asking for a new one,
      // so this is what makes the pair two repositories rather than one.
      return (SUGGEST_PREFIX[draft[0]] || '') + slug;
    };

    // Re-suggested while the box still holds what this code last put there, not
    // only while it is empty: picking the domain fills it, and choosing a
    // subdomain afterwards has to move it on. A name the operator typed is
    // theirs and is never overwritten, and neither is an existing row's.
    const applySuggestion = () => {
      const nb = document.querySelector('#drawer-fields [data-field="ApplicationName"] input');
      if (!nb || ROWWAS[editing]) return;
      const cur = nb.value.trim();
      if (cur !== '' && cur !== autoName) return;
      const label = suggestName();
      if (!label || label === cur) return;
      nb.value = label;
      autoName = label;
      nb.dispatchEvent(new Event('input', { bubbles: true }));
    };

    addrDom.addEventListener('change', applySuggestion);
    addrDom.addEventListener('change', syncAddress);
    const addrText = document.getElementById('addr-text');
    addrText.addEventListener('input', applySuggestion);
    addrText.addEventListener('input', syncAddress);
    const apex = document.getElementById('addr-apex');
    if (apex) {
      apex.addEventListener('change', applySuggestion);
      apex.addEventListener('change', syncAddress);
    }
    const other = document.getElementById('addr-other');
    if (other) other.addEventListener('change', syncAddress);

    syncAddress();
  }

  // ASKING FOR A DOMAIN NOBODY OWNS YET. Item 106, 2026-09-11, and it is wired
  // OUTSIDE the address block on purpose: a mailbox drawer has no #addr-dom, so
  // wiring it in there gave the tick to two drawers of the three.
  //
  // The two drawers store the answer differently and that is the only branch
  // here: a website or an application uses the `=x.nl` grammar through
  // syncAddress, a mailbox stores the domain plainly, so the typed name becomes
  // an option on its own select.
  const newAsk = document.getElementById('addr-newask');
  if (newAsk) {
    const newDom  = document.getElementById('addr-newdom');
    const newWrap = document.getElementById('addr-newwrap');
    const domWrap = document.getElementById('addr-domwrap');
    const mailSel = document.querySelector('#drawer-fields [data-domain]');

    const applyNew = () => {
      const on = newAsk.checked;
      if (newWrap) newWrap.hidden = !on;
      if (domWrap) domWrap.hidden = on;
      const reg = document.getElementById('addr-newregister');
      if (reg) reg.href = domainRegisterUrl(String(newDom ? newDom.value : '').trim());
      if (mailSel) {
        // The mailbox drawer, where the select IS the stored value.
        const want = String(newDom ? newDom.value : '').trim();
        let opt = mailSel.querySelector('option[data-wanted]');
        if (on && want) {
          if (!opt) {
            opt = document.createElement('option');
            opt.setAttribute('data-wanted', '');
            mailSel.appendChild(opt);
          }
          opt.value = want;
          opt.textContent = want;
          mailSel.value = want;
        } else if (opt) {
          opt.remove();
        }
      }
      if (typeof syncAddress === 'function' && document.getElementById('addr-dom')) {
        syncAddress();
      }
      checkDrawer();
    };

    newAsk.addEventListener('change', applyNew);
    if (newDom) {
      newDom.addEventListener('input', () => {
        // A previous answer is about a previous domain, so it goes the moment
        // the name changes. An "available" line standing beside a different
        // name is worse than no line at all.
        domFreeState(null);
        applyNew();
      });
    }
    const newBtn = document.getElementById('addr-newcheckbtn');
    if (newBtn) newBtn.addEventListener('click', askDomainFree);
  }

  // Changing the application type changes what Path must point at, so the
  // fields are rebuilt rather than left describing the previous choice.
  const rtSel = document.querySelector('#drawer-fields [data-field="Runtime"] select');
  if (rtSel) {
    rtSel.addEventListener('change', () => {
      // Switching a row from one web builder to another moves its site on the
      // next apply (upstream_transfer.sh). Said before it happens; cancel
      // puts it back. Before the rebuild below, which replaces this select.
      const from = String(draft[13] || ''), to = rtSel.value;
      if (from.startsWith('upstream:') && to.startsWith('upstream:') && from !== to
          && !confirm(T[lang].builderSwitch.replaceAll('{from}', from.slice(9)).replaceAll('{to}', to.slice(9)))) {
        rtSel.value = from;
        return;
      }
      draft = readDrawer();
      draft[13] = rtSel.value;
      renderDrawerFields();
      checkDrawer();
    });
  }

  const dsBox = document.getElementById('ds-box');
  if (dsBox) {
    const sel  = document.getElementById('ds-name');
    const hid  = document.getElementById('ds-value');
    const note = document.getElementById('ds-note');

    // Unticking clears the stored value rather than remembering it: a name left
    // behind in a hidden field is a fact the file would still be asserting.
    const syncDataSource = () => {
      // Nothing to point at means the question cannot be answered, so it is not
      // asked. A tick that reveals an empty list reads as a broken control.
      const none = sel.options.length === 0;
      dsBox.disabled = none;
      dsBox.title = none ? T[lang].dsAlone : '';
      if (none) dsBox.checked = false;

      // The reason ON THE PAGE, not only in a tooltip: a tooltip is not read by
      // somebody wondering why a click does nothing.
      const lbl = document.getElementById('ds-label');
      if (lbl) lbl.classList.toggle('is-off', none);
      if (note && none) { note.hidden = false; note.textContent = T[lang].dsAlone; }

      const on = dsBox.checked;
      sel.hidden = !on;
      if (note && !none) { note.hidden = !on; note.textContent = T[lang].dsNote; }
      hid.value = on ? sel.value : '';
    };

    dsBox.addEventListener('change', syncDataSource);
    sel.addEventListener('change', syncDataSource);
    syncDataSource();
  }

  const authSel = document.querySelector('#drawer-fields [data-auth]');
  const envBox  = document.querySelector('#drawer-fields [data-envrows]');
  if (authSel && envBox) {
    // One tick pair per environment composes `live:no, test:yes`. An
    // environment the row does not run in is left out entirely, so turning it
    // back on does not silently reinstate a login nobody asked for.
    const syncAuth = () => {
      const parts = [];
      const whoParts = [];
      const grid = envBox.querySelector('[data-whogrid]');
      let anyLogin = false;
      envBox.querySelectorAll('.env-row').forEach(rowEl => {
        const envBoxEl  = rowEl.querySelector('input[data-env]');
        const lockBoxEl = rowEl.querySelector('input[data-lock]');
        // A row without both is not an environment. Reaching through it threw,
        // and a throw here takes the whole drawer with it: nothing opened at
        // all, with no sign of which line was at fault.
        if (!envBoxEl || !lockBoxEl) return;
        lockBoxEl.disabled = !envBoxEl.checked;

        // The preview follows the environment: unticking the environment
        // leaves no copy to look at, so the offer goes with it.
        const prevBoxEl = rowEl.querySelector('input[data-pon]');
        if (prevBoxEl) {
          prevBoxEl.disabled = !envBoxEl.checked;
          if (!envBoxEl.checked && prevBoxEl.checked) {
            prevBoxEl.checked = false;
            readPreview(prevBoxEl);
          }
        }

        // A column of people only means anything where a login stands in front.
        const env  = envBoxEl.value;
        const show = envBoxEl.checked && lockBoxEl.checked;
        if (grid) grid.querySelectorAll(`[data-whocol="${env}"]`)
                      .forEach(c => { c.hidden = !show; });
        if (show) anyLogin = true;

        if (!envBoxEl.checked) return;
        parts.push(env + ':' + (lockBoxEl.checked ? 'yes' : 'no'));

        // The admin is added by the vhost script, so naming them here would
        // store the same fact twice.
        if (show && grid) {
          const picked = [...grid.querySelectorAll(
            `input[data-who-env="${env}"]:checked:not(:disabled)`)]
            .map(el => el.dataset.whoName);
          if (picked.length) whoParts.push(env + ': ' + picked.join(', '));
        }
      });
      if (grid) grid.hidden = !anyLogin;
      const composed = parts.join(', ');

      // AuthUsers, in the same per-environment shape the vhost script reads.
      const usersEl = document.querySelector('#drawer-fields [data-field="AuthUsers"] [data-i]');
      if (usersEl) usersEl.value = whoParts.join('; ');
      let opt = authSel.querySelector('option[data-composed]');
      if (!opt) {
        opt = document.createElement('option');
        opt.setAttribute('data-composed', '');
        authSel.appendChild(opt);
      }
      opt.value = composed;
      opt.textContent = composed;
      authSel.value = composed;

    };

    const grid = envBox.querySelector('[data-whogrid]');
    // Outside the environment block now, so it is reached from the drawer
    // rather than from envBox.
    const sel = document.querySelector('#drawer-fields [data-ownerpick] select');

    // Ticking someone back off has to stick, so access is only ever given at
    // the moment an environment is turned on or the pick is changed. Never
    // re-applied on every render, which would argue with whoever is using it.
    const giveAccess = env => {
      if (!grid || !sel || !sel.value) return;
      const cell = grid.querySelector(
        `input[data-who-name="${CSS.escape(sel.value)}"][data-who-env="${CSS.escape(env)}"]`);
      if (cell && !cell.disabled) cell.checked = true;
    };

    envBox.addEventListener('change', ev => {
      const box = ev.target.closest('input[data-env]');
      if (!box || !box.checked) return;
      // An environment with a hostname prefix is a rehearsal address, and one
      // open to the internet is the mistake this default prevents. Live is
      // served at the bare hostname and is left alone.
      if (PREFIX[box.value] || '') {
        const lock = box.closest('.env-row')?.querySelector('input[data-lock]');
        if (lock) lock.checked = true;
      }
      giveAccess(box.value);
    });

    if (sel) {
      sel.addEventListener('change', () => {
        // The previous pick loses what this control gave it, so changing your
        // mind does not leave two people behind.
        const prev = sel.dataset.prev || '';
        if (prev && grid) grid.querySelectorAll(`input[data-who-name="${CSS.escape(prev)}"]`)
                              .forEach(c => { if (!c.disabled) c.checked = false; });
        sel.dataset.prev = sel.value;
        envBox.querySelectorAll('.env-row').forEach(rowEl => {
          const on = rowEl.querySelector('input[data-env]');
          if (on && on.checked) giveAccess(on.value);
        });
        syncAuth();
      });
    }

    envBox.addEventListener('change', syncAuth);
    syncAuth();
  }

  // THE KEYS THE APPLICATION ACTUALLY READS, from appsettings.json in its own
  // repository. Item 99, agreed 2026-09-09: until now the list held only keys
  // some row already used, so the first row to need a setting had nothing to
  // pick from and a name typed wrong was an error nowhere.
  //
  // Fetched when the drawer opens, never blocking it: the answer arrives into
  // the datalist a moment later, and a drawer that waited on a clone would be a
  // drawer that hangs on a repository nobody can reach.
  if (document.querySelector('[data-opts]') && draft[0] === 'app'
      && !blank(draft[8]) && String(draft[8]).trim().toLowerCase() !== 'new') {
    const forRow = String(draft[1] || '').trim();
    fetch('?ask=appsettings&row=' + encodeURIComponent(forRow),
          { headers: { 'Accept': 'application/json' } })
      .then(r => r.json())
      .then(j => {
        if (!j || !Array.isArray(j.keys) || !j.keys.length) return;
        // The drawer may have moved on while the clone ran.
        if (String(draft[1] || '').trim() !== forRow) return;
        const list = document.getElementById('optkey-list');
        if (!list) return;
        const have = new Set([...list.querySelectorAll('option')].map(o => o.value));
        j.keys.forEach(k => {
          if (have.has(k.key)) return;
          const o = document.createElement('option');
          o.value = k.key;
          // The repository's own value as the hint, except where the key looks
          // like a credential: the reader blanks those and says so, and the
          // page must not put one on screen either.
          if (!k.secret && k.value !== '') o.label = k.value;
          list.appendChild(o);
          OPTKEYS.push(k.key);
        });
        const note = document.getElementById('opt-source');
        if (note && j.files && j.files.length) {
          note.textContent = T[lang].optFrom
            .replace('%f', j.files[0]).replace('%b', j.branch || '');
        }
      })
      .catch(() => { /* no list is the state it was already in */ });
  }

  const optAdd = document.getElementById('opt-add');
  if (optAdd) {
    const box = document.querySelector('[data-opts]');

    // A second empty row helps nobody, and neither does one when every key the
    // file knows is already on this row. The title says which of the two it is.
    const syncOptAdd = () => {
      const ks = [...box.querySelectorAll('.opt-k')].map(el => el.value.trim());
      const blankRow = ks.some(k => k === '');
      const allUsed  = OPTKEYS.length > 0 && OPTKEYS.every(k => ks.includes(k));
      optAdd.disabled = blankRow || allUsed;
      optAdd.title = blankRow ? T[lang].optFillFirst : (allUsed ? T[lang].optAllUsed : T[lang].optAdd);
    };

    optAdd.addEventListener('click', () => {
      const first = box.querySelector('.opt-pair');
      const copy = first.cloneNode(true);
      copy.querySelectorAll('input').forEach(el => el.value = '');
      box.appendChild(copy);
      syncOptAdd();
    });
    box.addEventListener('input', syncOptAdd);
    syncOptAdd();
  }

  // The fields decide the preview: its environments come from Envs and its
  // ports from Port, both of which this render may just have changed.
  paintPreview();
  // Opened with the domain the row already has, so the ticks describe reality.
  mbxDraft = null;
  mbxRender();
  // The instance tick describes a row that EXISTS, so it is painted from the
  // rows rather than from the draft, exactly like the mailbox ticks above.
  progRender();

  drawer.classList.add('open');
  scrim.classList.add('open');
}

// Composes the field the file stores, and shows the address each environment
// would actually answer on. The preview is the point: the grammar is easy to
// get wrong and impossible to check by reading it back.
// What the machine last said about the wanted domain, and when. Kept beside the
// drawer rather than inside it, because the drawer is re-rendered on almost
// every keystroke elsewhere and this is an answer, not a control.
let DOMFREE = null;

function domFreeState(v) {
  DOMFREE = v;
  const el = document.getElementById('addr-newstate');
  if (!el) return;
  const t = T[lang];
  if (!v) { el.textContent = ''; el.className = ''; return; }

  // A DOMAIN ALREADY IN THIS ACCOUNT IS NOT BAD NEWS. TransIP answers `taken`
  // with the detail `inyouraccount`, which would otherwise paint a red pill on
  // a domain there is nothing to order for. The owner's wording change on
  // 2026-09-11 is what exposed it.
  const mine = v.state === 'taken' && v.detail === 'inyouraccount';
  el.textContent = mine ? t.domMine
    : ({ free: t.domFree, taken: t.domTaken, unknown: t.domUnknown }[v.state] || v.state);
  // Grey for unknown, deliberately: an answer that did not arrive must not look
  // like an answer that said no.
  el.className = 'chip ' + ((v.state === 'free' || mine) ? 'up'
                            : (v.state === 'taken' ? 'down' : 'off'));
  // The answer decides whether the row may be saved at all, so the validation
  // is re-run here. Without it the drawer kept saying "press Check it first"
  // after the check had come back, which is a worse lie than no message.
  if (typeof checkDrawer === 'function') checkDrawer();
}

// TransIP, through the server. Advisory: a failure says unknown and nothing is
// refused because of it. The owner raised the dependency risk himself, 2026-09-11,
// and this is the shape that answers it.
async function askDomainFree() {
  const t = T[lang];
  const box = document.getElementById('addr-newdom');
  const want = String(box ? box.value : '').trim();
  if (!want) return;
  domFreeState({ state: 'asking' });
  const el = document.getElementById('addr-newstate');
  if (el) { el.textContent = t.domAsking; el.className = 'note'; }
  try {
    const r = await fetch('?ask=domainfree&domain=' + encodeURIComponent(want),
                          { headers: { 'Accept': 'application/json' } });
    const j = await r.json();
    domFreeState({ state: j.state || 'unknown', checked: j.checked || 0,
                   domain: j.domain || want, detail: j.detail || '' });
  } catch (e) {
    domFreeState({ state: 'unknown', checked: 0, domain: want, detail: String(e) });
  }
}

function syncAddress() {
  const t    = T[lang];
  const dom  = document.getElementById('addr-dom');
  const text = document.getElementById('addr-text');
  const hid  = document.getElementById('addr-value');
  if (!dom || !text || !hid) return;

  // A DOMAIN NOBODY OWNS YET reads as an ordinary whole domain from here on,
  // so nothing below this line learns a new case: it is the typed name, and the
  // grammar it produces is `=thedomain.nl`. The owner, 2026-09-11.
  const ask     = document.getElementById('addr-newask');
  const wantNew = !!(ask && ask.checked);
  const newWrap = document.getElementById('addr-newwrap');
  const domWrap = document.getElementById('addr-domwrap');
  const newDom  = document.getElementById('addr-newdom');
  const newLink = document.getElementById('addr-newcheck');
  if (newWrap) newWrap.hidden = !wantNew;
  // The picker of domains we already hold is not a second answer to the same
  // question, so it goes away while a new one is being asked for.
  if (domWrap) domWrap.hidden = wantNew;
  if (wantNew && newLink) {
    // The checker, pre-filled with what they typed. One click, not a name to
    // retype into somebody else's search box.
    // %s is where the name goes, and a URL without one is opened as it stands:
    // TransIP's checker cannot be prefilled, and appending to it gives a 404.
    const base = (typeof DOMAIN_CHECK_URL === 'undefined' || !DOMAIN_CHECK_URL)
      ? 'https://domainr.com/%s' : DOMAIN_CHECK_URL;
    const q = encodeURIComponent((newDom && newDom.value.trim()) || '');
    newLink.href = base.indexOf('%s') >= 0 ? base.replace('%s', q) : base;
    const reg = document.getElementById('addr-newregister');
    if (reg) reg.href = domainRegisterUrl((newDom && newDom.value.trim()) || '');
  }

  const wantedDomain = wantNew ? String(newDom ? newDom.value : '').trim() : '';
  const none = wantNew ? wantedDomain === '' : dom.value === '';
  const name = text.value.trim();
  const apex = document.getElementById('addr-apex');
  const lab  = document.getElementById('addr-live');
  const wrap = document.getElementById('addr-namewrap');
  const nameHint = document.getElementById('addr-namehint');

  // Which domain first, then what stands in front of it. Three answers, not
  // two, because `@name` is a real third state and one row already uses it:
  // the bare domain in live, and a named subdomain in every other environment.
  // Offering only Domain and Subdomain would rewrite that row on save.
  //
  // The name box exists only for the two answers that use one, so an empty box
  // is never sitting there asking to be filled in by a row that wants none.
  // Two questions, each with two answers, instead of one question with three.
  // "Live links to" only ever answers what LIVE gets. What the other
  // environments get is a different question and now has its own control, which
  // is why every one-dropdown label read badly: it was two questions in one.
  const other = document.getElementById('addr-other');
  const otherWrap = document.getElementById('addr-otherwrap');

  // A domain another row already answers on is not offered at all. Disabling
  // the option rather than warning about it afterwards is the difference
  // between a choice you cannot make and one you have to undo.
  // Offered, not refused, since 2026-09-10: taking the apex from the row that
  // has it is the switch, and saving does it. The line under the control says
  // whose domain is being taken.
  const apexHeldBy = none ? '' : apexClaimedBy(dom.value);
  if (apex) apex.options[0].disabled = false;
  const mode = apex ? apex.value : (name !== '' ? 'sub' : 'apex');
  const keepName = other ? other.value === 'named' : false;

  // Only while the whole domain is the answer: picking Subdomain takes nothing
  // from anybody, so the warning has to go with the choice rather than with the
  // domain. Same wording as the summary above the button, deliberately: it is
  // one piece of news, said where the choice is made and again where it is
  // confirmed.
  const takeover = document.getElementById('addr-takeover');
  if (takeover) {
    const taking = apexHeldBy !== '' && mode === 'apex';
    takeover.textContent = taking ? `${t.dupClaim} ${apexHeldBy}` : '';
    takeover.hidden = !taking;
  }

  // Only the base domain has two possible answers for the other environments.
  // On another domain the `=` grammar has one form, so there is nothing to ask.
  const askOther = !none && mode === 'apex' && dom.value === BASE;
  // The name is needed by a subdomain, and by a domain that keeps its name
  // outside live.
  const needName = !none && (mode === 'sub' || (askOther && keepName));

  if (lab)       lab.style.display       = none ? 'none' : '';
  if (otherWrap) otherWrap.style.display = askOther ? '' : 'none';
  if (wrap)      wrap.style.display      = needName ? '' : 'none';

  // The options carry the hostnames they produce, not a description of a rule.
  // "Domain, subdomain in the other environments" told you the shape of the
  // answer without telling you the answer. A second environment is named on the
  // middle one because it is the only thing that distinguishes it from the
  // first, and the summary at the bottom lists them all anyway.
  // The second dropdown's options are the hostnames themselves. Produced by
  // running addresses() over each candidate rather than rebuilt here: a
  // hand-built label once printed test-shop.example.org where the vhost
  // script builds test.shop.example.org.
  if (other && askOther) {
    const lbl = name || '…';
    const sample = ENVS.find(e => (PREFIX[e] ?? '') !== '');
    const shownFor = v => Object.fromEntries(addresses(v, ENVS))[sample] || '';
    other.options[0].textContent = shownFor('@' + lbl);
    other.options[1].textContent = shownFor('@');
  }

  let val = '-';
  if (!none && wantNew) {
    // A domain we do not hold yet is stored exactly like one we do: `=x.nl`.
    // Nothing downstream learns a new case, and if the order is never placed
    // the row simply does not resolve, which is visible rather than silent.
    val = '=' + (mode === 'sub' && name ? name + '.' + wantedDomain : wantedDomain);
  } else if (!none) {
    if (dom.value === BASE) {
      if (mode === 'sub')        val = name ? name : '@';
      else if (keepName && name) val = '@' + name;
      else                       val = '@';
    } else {
      val = '=' + (mode === 'sub' && name ? name + '.' + dom.value : dom.value);
    }
  }
  hid.value = val;

  // The end result, not advice about it. This line used to read "Empty answers
  // on example.com itself", which described a rule; it is the hostname live
  // will actually answer on.
  if (nameHint) {
    const shown = Object.fromEntries(addresses(val === '-' ? '' : val, ENVS));
    // The hostname, always. The takeover is said once, under "Live links to",
    // which is the control that causes it: saying it here as well gave two
    // sentences of the same news one under the other. The owner, 2026-09-10.
    nameHint.textContent = shown[ENVS[0]] || '';
    nameHint.classList.remove('warn', 'bad');
  }
  // Every address now lives in one place, at the bottom, under what this row
  // will create. The field itself only asks the question.
  checkDrawer();
}

// The addresses this row would answer on, in environment order.
//
// The environments come from the ticks as they are RIGHT NOW, not from
// draft[10]: that is only rewritten on save, so a list built from it would
// still show an environment you had just turned off.
function addressList() {
  const hid = document.getElementById('addr-value');
  if (!hid) return [];
  const box = document.querySelector('#drawer-fields [data-envrows]');
  let envs;
  if (box) {
    envs = [...box.querySelectorAll('input[data-env]:checked')].map(c => c.value);
  } else {
    envs = blank(draft[10]) ? ENVS : draft[10].split(',').map(s => s.trim());
  }
  if (!envs.length) envs = ENVS;
  return addresses(hid.value === '-' ? '' : hid.value, envs);
}


// Closing by Cancel, the x or the scrim. Keep this change does NOT come through
// here: it saves first and closes afterwards, so saving never asks.
//
// The owner's decision 2026-09-05: warn, then discard. Typed values were dropped
// silently by all three, and clicking the background by accident is the easy
// one to do. An untouched drawer still shuts straight away, because a dialog on
// every close is a dialog nobody reads.
function closeDrawerAsked() {
  if (drawerDirty() && !confirm(T[lang].drawerDiscard)) return;
  closeDrawer();
}

// The drawer's whole answer, as one comparable string.
//
// previewDraft is in here because a preview tick is NOT one of the fifteen
// fields: it is held separately and written to PREVIEW_ROWS, so readDrawer()
// never sees it and ticking one was the one edit that closed silently.
//
// Its keys are sorted, because object key order is insertion order and ticking
// test then live would otherwise differ from live then test with nothing
// actually changed.
//
// Deliberately NOT in here: the mailbox ticks, the mail settings boxes and the
// password box. Each has its own Save and does not go through Keep this change,
// so closing the drawer was never what lost them.
function drawerState() {
  const p = {};
  Object.keys(previewDraft).sort().forEach(k => { p[k] = previewDraft[k]; });

  // The password counts as a change, or Keep this change stays disabled while
  // the one thing you came to do sits typed in the box. Its LENGTH, never its
  // value: this string is kept in a variable for as long as the drawer is open
  // and compared on every keystroke, and a secret does not belong in either.
  // The box is always empty when the drawer opens, so any length is a change.
  const box = document.getElementById('mailpw-value');
  const pwLen = box ? box.value.length : 0;

  // The addresses ticked on a website or application row carry passwords too.
  // Names and lengths, sorted, for the same reason.
  const mbx = {};
  if (mbxDraft && mbxDraft.pw) {
    Object.keys(mbxDraft.pw).sort().forEach(k => { mbx[k] = String(mbxDraft.pw[k] || '').length; });
  }

  // The progress tick is a change too, and for the same reason the preview tick
  // had to be added here on 2026-09-06: it is not one of the sixteen fields, so
  // readDrawer() cannot see it and Keep this change stayed DISABLED while the
  // one thing you came to do sat ticked on screen. Found by clicking it.
  //
  // Its own state, not the box: a tick that matches the row as it already is is
  // not a change, so re-opening a drawer on a running instance and leaving it
  // alone does not arm the button.
  const prog = document.getElementById('drawer-progress');
  const progOn = (prog && !prog.hidden && document.getElementById('prog-on'))
    ? (document.getElementById('prog-on').checked ? 1 : 0) : null;

  return JSON.stringify({ f: readDrawer(), p: p, pw: pwLen, mbx: mbx, prog: progOn, mem: appMemDraft });
}

// A machine page renders through the same element but is not built from `draft`,
// so readDrawer() does not describe it. Rather than compare the wrong thing and
// ask on every close, that drawer keeps the old silent behaviour.
function drawerDirty() {
  if (drawerMode !== 'row' || !draft) return false;
  if (!drawerOpenedWith) return false;
  try { return drawerState() !== drawerOpenedWith; }
  catch (e) { return false; }
}

function closeDrawer() {
  drawerOpenedWith = '';
  drawer.classList.remove('open');
  scrim.classList.remove('open');
  // null, not undefined. Every test in this file reads `editing === null`, so
  // undefined took the "a saved row is open" branch on a drawer that was shut,
  // and `rows[undefined].f` threw. drawer.js:628 already carried a local
  // workaround for it; this is the cause rather than one more site.
  editing = null;
  drawerMode = 'row';
  editingPanel = null;
  // The machine-pages drawer is this same element and never repaints this
  // section, so a left-over mail box would appear under a page's three fields.
  document.getElementById('drawer-mail').hidden = true;
  // Same reason, and one more: a typed password must not survive the drawer it
  // was typed into.
  document.getElementById('drawer-mailpw').hidden = true;
  document.getElementById('mailpw-value').value = '';
}

// -----------------------------------------------------------------------------
// The machine-pages drawer. Same drawer element, different contents, because a
// page is three fields and a row is thirteen.
//
// The id is shown and never editable. That is the whole reason PANEL lines
// replaced the old *_PORT settings on 2026-08-16: a script looks a page up by
// id, so renaming what the console shows must not touch what the script finds.
// -----------------------------------------------------------------------------

function slugify(s) {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

// Where the machine-page picker is looking, and the roots it may not climb
// above. null means it has not been opened yet, which is not the same as being
// at the roots: the first open has to fetch them.
let panelPickAt = null;
let panelRoots = [];

// The same walk the shared-folder picker does, against the same endpoint, with
// the root set that machine pages may use. Separate function rather than a
// shared one: the two drawers hold different elements and the shared version
// would take both as arguments, which is a worse read than two short walks.
async function panelPick(where) {
  const list = document.getElementById('panel-pick-list');
  const here = document.getElementById('panel-pick-here');
  const t = T[lang];
  if (!list) return;

  list.innerHTML = '<li class="note picker-empty">' + esc(t.smbPickLoading) + '</li>';
  let data;
  try {
    const r = await fetch('?for=pages&folders=' + encodeURIComponent(where),
                          { headers: { 'Accept': 'application/json' } });
    data = await r.json();
  } catch (_) {
    data = { error: t.smbPickFailed };
  }

  if (Array.isArray(data.roots)) { panelRoots = data.roots; }

  if (data.error) {
    here.textContent = where || '/';
    list.innerHTML = '<li class="note picker-empty">' + esc(data.error) + '</li>';
    document.getElementById('panel-pick-up').disabled = false;
    return;
  }

  panelPickAt = data.path || '';
  here.textContent = panelPickAt || t.panelPickRoots;
  document.getElementById('panel-pick-up').disabled = panelPickAt === '';

  const dirs = data.dirs || [];
  const label = d => panelPickAt === '' ? d : d.slice(panelPickAt.length).replace(/^\//, '');
  list.innerHTML = dirs.length
    ? dirs.map(d =>
        '<li><button type="button" data-panelpick="' + esc(d) + '" title="' + esc(d) + '">' +
        esc(label(d)) + '</button></li>').join('')
    : '<li class="note picker-empty">' + esc(t.smbPickEmpty) + '</li>';
}

function panelInsideRoot(p) {
  return panelRoots.some(r => p === r || p.startsWith(r + '/'));
}

function openPanelDrawer(id) {
  drawerMode = 'panel';
  editingPanel = id;
  const t = T[lang];
  const p = id === null ? null : PANELS.find(x => x.id === id);
  const s = p ? panelState(p)
              : { port: nextPort('panel'), label: '', serves: 'folder', target: '', login: 'yes', users: '' };

  document.getElementById('drawer-title').textContent =
    p ? t.drawerEdit + ' ' + s.label : t.add.panel;

  // The id line reads differently in the two cases: for an existing page it is a
  // fact, for a new one it is being decided as the name is typed.
  const idBlock = p
    ? `<div data-field="PanelId">
         <label>${esc(t.panelIdLabel)}
           <span class="info" title="${esc(p.held ? t.panelIdHeld.replace('%s', p.held) : t.panelIdFree)}">&#9432;</span>
         </label>
         <p class="hint" style="margin:0"><code>${esc(p.id)}</code> &mdash;
            ${esc(p.held ? t.panelIdHeld.replace('%s', p.held) : t.panelIdFree)}</p>
       </div>`
    : `<div data-field="PanelId">
         <label>${esc(t.panelIdLabel)}</label>
         <p class="hint" style="margin:0"><code id="panel-idpreview"></code>
            &mdash; ${esc(t.panelIdNew)}</p>
       </div>`;

  document.getElementById('drawer-fields').innerHTML = `
    <div data-field="PanelName">
      <label>${esc(t.panelNameLabel)}
        <span class="info" title="${esc(t.panelNameHint)}">&#9432;</span></label>
      <input id="panel-name" value="${esc(s.label)}">
    </div>
    ${idBlock}
    <div data-field="PanelPort">
      <label>${esc(t.panelPortLabel)}
        <span class="info" title="${esc(t.panelPortHint)}">&#9432;</span></label>
      <input id="panel-port" type="number" min="1024" max="65535"
             value="${s.port === null ? '' : esc(s.port)}">
      <p class="hint">${esc(t.panelOffHint)}</p>
    </div>
    <div data-field="PanelServes">
      <label>${esc(t.panelServesLabel)}
        <span class="info" title="${esc(t.panelServesHint)}">&#9432;</span></label>
      <select id="panel-serves">
        <option value="folder"  ${s.serves === 'folder'  ? 'selected' : ''}>${esc(t.servesLong.folder)}</option>
        <option value="service" ${s.serves === 'service' ? 'selected' : ''}>${esc(t.servesLong.service)}</option>
        <option value="itself"  ${s.serves === 'itself'  ? 'selected' : ''}>${esc(t.servesLong.itself)}</option>
      </select>
    </div>
    <div data-field="PanelTarget" id="panel-target-field">
      <label><span id="panel-target-label">${esc(t.panelTargetFolder)}</span>
        <span class="info" id="panel-target-info" title="">&#9432;</span></label>
      <input id="panel-target" spellcheck="false" autocomplete="off"
             list="panel-ports" value="${esc(s.target)}">

      <!-- Browsing beats knowing. The question "is this a folder or a service"
           cannot be answered from the name of the thing, so the drawer shows
           what is actually there instead of asking the operator to assert it. -->
      <div class="picker" id="panel-picker">
        <div class="picker-bar">
          <button type="button" class="icon-btn" id="panel-pick-up"
                  data-i18n-title="smbPickUp" title="${esc(t.smbPickUp)}">&uarr;</button>
          <span class="picker-here" id="panel-pick-here"></span>
        </div>
        <ul class="picker-list" id="panel-pick-list"></ul>
      </div>

      <!-- Everything listening on this machine, so a port is chosen from what
           is there rather than typed from memory. -->
      <datalist id="panel-ports">${LISTENERS.map(l =>
        `<option value="127.0.0.1:${esc(l.port)}">${esc(l.name || '?')}</option>`).join('')}</datalist>
      <p class="hint" id="panel-listeners" hidden></p>
    </div>
    <div data-field="PanelLogin">
      <label class="check">
        <input type="checkbox" id="panel-login" ${s.login === 'no' ? '' : 'checked'}>
        ${esc(t.panelLoginLabel)}</label>
      <p class="hint">${esc(t.panelLoginHint)}</p>

      <!-- The admin is ticked and fixed rather than absent: a name missing from
           the list reads as a mistake, and the master account is admitted to
           everything this repo generates. -->
      <div id="panel-who" ${s.login === 'no' ? 'hidden' : ''}>
        <span class="label">${esc(t.panelWho)}</span>
        <div class="acl">
          ${[ADMIN, ...ACCOUNTS.filter(a => a !== ADMIN)].map(a => {
            const isAdmin = a === ADMIN;
            const on = isAdmin || s.users.split(',').map(x => x.trim()).includes(a);
            return `<label class="check"><input type="checkbox" data-panel-who="${esc(a)}"
                      ${on ? 'checked' : ''} ${isAdmin ? `disabled title="${esc(t.envWhoAdmin)}"` : ''}>
                    ${esc(a)}</label>`;
          }).join('')}
        </div>
      </div>
    </div>
    ${p ? `<div data-field="PanelDelete" style="margin-top:1.6rem">
        <button type="button" class="icon-btn danger" id="panel-delete"
                ${p.held ? 'disabled' : ''} style="width:auto;padding:.4rem .7rem">
          ${I.trash} ${esc(t.panelDelete)}</button>
        <p class="hint" style="margin:.3rem 0 0">${esc(p.held
          ? t.panelDeleteHeld.replace('%s', p.held)
          : t.panelDeleteHint)}</p>
      </div>` : ''}`;

  // Delete removes the PANEL line; switching the port off keeps it. They are
  // not the same act: a script that looks a page up by id errors on a line that
  // is gone, and only stands down for one that says `-`.
  const delBtn = document.getElementById('panel-delete');
  if (delBtn) {
    delBtn.addEventListener('click', () => {
      if (!confirm(t.panelDeleteConfirm.replace('%s', panelState(p).label))) return;
      panelGone.add(p.id);
      delete panelEdits[p.id];
      closeDrawer();
      render();
    });
  }

  // The target means a different thing per kind, and means nothing at all for a
  // page its own installer serves, so the field says which and hides itself.
  const servesEl = document.getElementById('panel-serves');
  const paintTarget = () => {
    const kind = servesEl.value;
    const field = document.getElementById('panel-target-field');
    field.hidden = kind === 'itself';
    if (kind === 'itself') { checkDrawer(); return; }
    const folder = kind === 'folder';
    document.getElementById('panel-target-label').textContent =
      folder ? t.panelTargetFolder : t.panelTargetService;
    document.getElementById('panel-target-info').title =
      folder ? t.panelTargetFolderHint : t.panelTargetServiceHint;
    document.getElementById('panel-target').placeholder =
      folder ? '/var/lib/something/public_html' : '127.0.0.1:8080';

    // The picker is for folders, the port list is for services. Exactly one of
    // them is ever the right help, so only one is on screen.
    document.getElementById('panel-picker').hidden = !folder;
    const hint = document.getElementById('panel-listeners');
    hint.hidden = folder;
    if (!folder) {
      hint.textContent = LISTENERS.length
        ? t.panelListeners.replace('%d', LISTENERS.length)
        : t.panelNoListeners;
    }
    if (folder && panelPickAt === null) { panelPick(''); }
    checkDrawer();
  };
  servesEl.addEventListener('change', paintTarget);
  document.getElementById('panel-target').addEventListener('input', checkDrawer);
  // Who may enter is meaningless without a login in front of the page, so the
  // list follows the checkbox rather than sitting there greyed.
  document.getElementById('panel-login').addEventListener('change', e => {
    document.getElementById('panel-who').hidden = !e.target.checked;
    checkDrawer();
  });

  // Clicking a folder fills the box; the box still takes a typed path, which is
  // the faster route for anyone who already knows where the thing is.
  document.getElementById('panel-pick-list').addEventListener('click', e => {
    const b = e.target.closest('[data-panelpick]');
    if (!b) return;
    document.getElementById('panel-target').value = b.dataset.panelpick;
    checkDrawer();
    panelPick(b.dataset.panelpick);
  });

  document.getElementById('panel-pick-up').addEventListener('click', () => {
    // Up from a root goes to the root list, never to its parent: /var is not a
    // place a machine page may be served from, and landing there empties the
    // list with no way back except closing the drawer.
    const up = (panelPickAt || '').replace(/\/[^/]*$/, '');
    panelPick(up && panelInsideRoot(up) ? up : '');
  });

  // The picker is opened fresh each time rather than kept, so it never shows
  // the folder somebody was browsing in a different page's drawer.
  panelPickAt = null;
  paintTarget();

  const nameEl = document.getElementById('panel-name');
  const idPrev = document.getElementById('panel-idpreview');
  if (idPrev) {
    const syncId = () => { idPrev.textContent = slugify(nameEl.value) || '?'; };
    nameEl.addEventListener('input', syncId);
    syncId();
  }

  checkDrawer();
  drawer.classList.add('open');
  scrim.classList.add('open');
  nameEl.focus();
}

// The same shape as rowProblems: a list of sentences, empty when it can be kept.
function panelProblems() {
  const t = T[lang], out = [];
  const name = document.getElementById('panel-name').value.trim();
  const raw  = document.getElementById('panel-port').value.trim();

  if (name === '') { out.push(t.panelNeedName); }

  if (raw !== '') {
    const n = Number(raw);
    if (!Number.isInteger(n) || n < 1024 || n > 65535) { out.push(t.badPort); }
    else {
      // A port already answering for something else is the fault this tab exists
      // to make visible, so it is caught here rather than at apply time.
      const clash = panelEntries().find(e => e.port === n && !e.deleted && e.panel.id !== editingPanel)
                 || rows.find(r => !r.deleted && Number(r.f[2]) === n);
      if (clash) out.push(t.portTaken.replace('%s', n));

      // Against what is actually listening, not only against what this file
      // says. A port held by something with no row here looked free, and Apache
      // refuses to start with two listeners on one: on 2026-08-28 that was
      // 10003, the GitHub webhook door, and it broke every later reload too.
      // The page's own port is skipped, or editing anything else about a live
      // page would report it clashing with itself.
      const mine = editingPanel === null ? null
                 : panelEntries().find(e => e.panel.id === editingPanel);
      const heard = LISTENERS.find(l => Number(l.port) === n);
      if (!clash && heard && !(mine && mine.port === n)) {
        out.push(t.portListening.replace('%s', n).replace('%p', heard.name || '?'));
      }
    }
  }

  // The same rules add_panel_vhosts.sh checks before it writes anything, said
  // here so a missing folder is a sentence in the drawer rather than a refused
  // apply. The script is the authority and still runs.
  const serves = document.getElementById('panel-serves').value;
  const target = document.getElementById('panel-target').value.trim();
  if (serves !== 'itself') {
    if (raw === '') { out.push(t.panelNeedPort); }
    if (target === '') {
      out.push(serves === 'folder' ? t.panelNeedFolder : t.panelNeedService);
    } else if (serves === 'folder' && !target.startsWith('/')) {
      out.push(t.panelFolderAbsolute);
    } else if (serves === 'service' && !/^[^\s:]+:\d+$/.test(target)) {
      out.push(t.panelServiceShape);
    }
  }

  if (editingPanel === null && slugify(name) === '') { out.push(t.panelNeedName); }
  if (editingPanel === null && PANELS.some(p => p.id === slugify(name))) {
    out.push(t.panelExists);
  }
  return out;
}

// What the page will BE, in the words of the thing it serves, so the effect is
// visible before it is kept rather than after it is applied.
function panelOutcome(t) {
  const name = document.getElementById('panel-name').value.trim();
  const raw  = document.getElementById('panel-port').value.trim();
  return raw === ''
    ? t.panelWillOff.replace('%s', name)
    : name + ', ' + t.onPort + ' ' + raw;
}

function savePanelDrawer() {
  const t = T[lang];
  const name = document.getElementById('panel-name').value.trim();
  const raw  = document.getElementById('panel-port').value.trim();
  const port = raw === '' ? null : Number(raw);

  // Switching off the page you are reading this on. Not blocked: it is a real
  // thing to want. Confirmed, because the way back is SSH and a text editor.
  if (port === null && editingPanel === 'console'
      && !confirm(t.panelOffConsole)) { return; }

  const serves = document.getElementById('panel-serves').value;
  const login  = document.getElementById('panel-login').checked ? 'yes' : 'no';
  // A page its own installer serves has nothing to point at, so a target left
  // over from a previous choice is dropped rather than written out.
  const target = serves === 'itself'
    ? '' : document.getElementById('panel-target').value.trim();
  // The admin is admitted by the generator itself, so storing it here would put
  // a name in the file that means nothing and would read as removable.
  const users = login === 'no' ? '' :
    [...document.querySelectorAll('[data-panel-who]:checked')]
      .map(b => b.dataset.panelWho).filter(a => a !== ADMIN).join(', ');
  const edit = { port, label: name, serves, target, login, users };

  if (editingPanel === null) {
    PANELS.push({ id: slugify(name), label: name, held: null, line: null, value: null,
                  serves: 'itself', target: '', login: 'yes', isNew: true });
    panelEdits[slugify(name)] = edit;
  } else {
    panelEdits[editingPanel] = edit;
  }
  closeDrawer();
  render();
}

// The same rules maintain_services.sh applies, checked here so a missing field
// is a sentence in the drawer rather than a save, a push, a validation run and
// a refusal. Deliberately a copy: the checker is the authority and still runs,
// but a round trip to be told a website has no folder is a poor way to learn it.
//
// Kept in step by hand. If these ever disagree, the checker wins and this is
// the one that is wrong.
// Another row already called this. check_config.sh catches it - "duplicate
// ApplicationName. Unit and vhost names would collide" - but only when the
// publish runs, so the operator filled a whole drawer first. The repository
// name clash beside it has been caught while typing since 2026-09-02; this is
// the same question about the machine's own rows.
//
// A mailbox is excluded on purpose: its name is a local part, so admin@ on two
// domains is two rows legitimately sharing one name, and only the pair is
// unique. Editing a row does not clash with itself.
function rowNameTakenBy(name, selfIndex) {
  const want = String(name || '').trim().toLowerCase();
  if (want === '' || want === '-') return '';
  for (let i = 0; i < rows.length; i++) {
    if (i === selfIndex) continue;
    const r = rows[i];
    if (!r || r.deleted) continue;
    if (r.f[0] === 'mailbox') continue;
    if (String(r.f[1] || '').trim().toLowerCase() === want) return r.f[0];
  }
  return '';
}

// RELATIVE IS NOT THE SAME AS INSIDE. The check above refuses a leading slash
// and stops there, so `../../etc` passed it, passed check_config.sh too, and
// would have given Apache a DocumentRoot outside WEB_ROOT: the row would
// publish whatever it landed on over HTTPS.
//
// Found 2026-09-06 by typing it in. The absolute form was refused by both
// halves, which is exactly what made the gap easy to miss.
//
// Split on both separators: a Windows-style backslash reaches the config
// through a paste, and the machine reads the line either way.
function climbsOut(p) {
  return String(p).split(/[\/\\]/).some(seg => seg === '..');
}

// Switch off every OTHER enabled row that answers on one of this row's
// hostnames, and say which. Returns the names it switched off.
//
// A mailbox has no vhost and a deleted row publishes nothing, so neither can
// hold a hostname. A row being saved switched OFF takes nothing from anybody.
// Which enabled rows this one would take a hostname from. Asked before the
// save as well as during it, so the drawer can say what pressing the button is
// about to do rather than only doing it.
function rivalsFor(f, target) {
  const out = [];
  if (f[0] === 'mailbox') return out;
  if (String(f[14] || '').trim().toLowerCase() === 'no') return out;

  const mine = new Set(
    addresses(f[4], rowEnvs({ f })).map(([, host]) => host));
  if (!mine.size) return out;

  rows.forEach((r, i) => {
    if (i === target || r.deleted || r.f[0] === 'mailbox') return;
    if (String(r.f[14] || '').trim().toLowerCase() === 'no') return;
    if (addresses(r.f[4], rowEnvs(r)).some(([, host]) => mine.has(host))) out.push(i);
  });
  return out;
}

function standDownRivals(f, target) {
  const done = [];
  rivalsFor(f, target).forEach(i => {
    const r = rows[i];
    r.f[14] = 'no';
    r.dirty = true;
    // Enabled is not one of FAST_FIELDS: switching a row off has to reach the
    // vhosts, so this edit can never take the fast path.
    r.fastOnly = false;
    done.push(r.f[1]);
  });
  return done;
}

function rowProblems(f) {
  const t = T[lang], out = [];
  const kind = f[0], name = f[1], port = f[2], path = f[3];

  // A DOMAIN SOMEBODY ELSE HOLDS CANNOT BE ASKED FOR. The owner, 2026-09-11: "if
  // the domain is not available the request should not be made". It is refused
  // here rather than declined later, which also removes the requester's own
  // tick: the machine's answer is the only one that decides.
  //
  // Only a REGISTERED answer blocks. `unknown` means TransIP could not be
  // reached, and blocking on that would let an outage stop every request, which
  // is the dependency risk the owner raised when this was designed.
  const ask = document.getElementById('addr-newask');
  if (ask && ask.checked) {
    const want = String((document.getElementById('addr-newdom') || {}).value || '').trim();
    if (!want) out.push(t.domNeedName);
    else if (!DOMFREE || DOMFREE.domain !== want || DOMFREE.state === 'asking') {
      out.push(t.domNeedCheck);
    } else if (DOMFREE.state === 'taken' && DOMFREE.detail !== 'inyouraccount') {
      out.push(t.domIsTaken.replace('%s', want));
    }
  }

  if (blank(name)) out.push(t.needName);
  else if (kind !== 'mailbox') {
    const held = rowNameTakenBy(name, editing === null ? -1 : editing);
    if (held) out.push(t.rowNameTaken(name, held));
  }

  // The name becomes a unit name and a vhost filename, so this is a refusal
  // rather than the hint it has been since the field existed. `test 11` gave
  // the unit `app-test 11.service`, which systemd cannot have, and the apply
  // then stopped on a row list that had silently closed the gap to `test11`.
  // Item 96, 2026-09-08. check_config.sh refuses the same set, so a row that
  // arrives any other way is caught too.
  if (!blank(name) && /[^A-Za-z0-9._-]/.test(String(name))) out.push(t.badName);

  // A row asking for a new repository takes its name from this field, so the
  // clash is caught while it is typed rather than by a refusal halfway through
  // an apply. Silent while the list has not arrived: an advisory check that
  // blocks on its own failure is worse than no check.
  if (String(f[8] || '').trim().toLowerCase() === 'new' && !blank(name)) {
    const held = repoNameTakenBy(name);
    if (held) out.push(t.repoNameTaken(name, held));
  }

  // A mailbox that does not exist yet has to be given its password here, or it
  // is created with no Dovecot account and nobody can ever open it. Refusing is
  // Decided 2026-09-01: whatever creating an address needs, the
  // console asks for, or it does not create one.
  if (kind === 'mailbox' && mailPwPending) {
    const pw = (document.getElementById('mailpw-value') || {}).value || '';
    if (pw.length === 0)     out.push(t.needPw);
    else if (pw.length < 8)  out.push(t.needPwLong);
  }

  // The same rule for the addresses ticked on a website or application row.
  // They create mailbox rows too, and until 2026-09-06 they were the one way
  // to make one without ever being asked for a password.
  // NOT for a limited admin. Their save is a REQUEST and creates nothing, so
  // there is no address for a password to protect yet, and a password typed
  // here would have to be STORED IN THE REQUEST FILE to survive until somebody
  // approved it. A secret sitting on disk waiting for an admin to get round to
  // it is worse than asking for it at the moment the mailbox is made.
  //
  // Their request carries no mailbox rows either: see mbxCommit(). contact@ is
  // mandatory on a row an ADMIN writes, and an approved row is written by the
  // admin approving it.
  if (typeof MYROLE === 'undefined' || MYROLE === 'full') {
    mbxNewLocals(f).forEach(local => {
      const pw = (mbxDraft.pw && mbxDraft.pw[local]) || '';
      if (pw.length === 0)     out.push(t.needPwFor(local));
      else if (pw.length < 8)  out.push(t.needPwLongFor(local));
    });
  }

  // Unticking every environment stores `-`, which the file reads as ALL of
  // them. Silently meaning the opposite of what the boxes show is the one
  // outcome this control must not have, so it is refused instead.
  const envBox = document.querySelector('#drawer-fields [data-envrows]');
  if (envBox && kind !== 'mailbox'
      && envBox.querySelectorAll('input[data-env]:checked').length === 0) {
    out.push(t.needEnv);
  }

  if (kind === 'app') {
    if (blank(port)) out.push(t.needPort);
    if (blank(path)) out.push(t.needDll);
    else if (path.startsWith('/')) out.push(t.pathRelative);
    else if (climbsOut(path)) out.push(t.pathEscapes);
    // The runtime decides what a valid path looks like, and add_app_services.sh
    // refuses a row it cannot build an ExecStart for. Caught here so that is a
    // sentence in the drawer rather than a failed run on the machine.
    else if ((f[13] || 'dotnet').toLowerCase() === 'node' && !/\.js$/i.test(path)) {
      out.push(t.needEntry);
    }
    else if (isDotnet(f[13]) && !/\.dll$/i.test(path)) {
      out.push(t.needDll);
    }
    else if (isDocker(f[13]) && !/(^|\/)Dockerfile$/.test(path)) {
      out.push(t.needDockerfile || 'A Docker application needs the path to its Dockerfile in the repository, for example Dockerfile.');
    }
  }

  if (kind === 'website') {
    if (blank(path)) out.push(t.needDocRoot);
    else if (path.startsWith('/')) out.push(t.pathRelative);
    else if (climbsOut(path)) out.push(t.pathEscapes);
  }

  if (kind === 'proxy' && blank(port)) out.push(t.needPort);

  if (kind === 'mailbox' && !blank(name)
      && !/^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$/.test(name)) {
    out.push(t.badMailName);
  }

  // The same address twice is one mailbox with two config lines: the publisher
  // refuses it, so it is caught here first. Keyed by local part AND domain, so
  // info@one and info@two are fine and info@one twice is not.
  if (kind === 'mailbox' && !blank(name)) {
    const dom = (f[4] || '-').trim() || '-';
    const clash = rows.some((r, i) =>
      i !== editing && r.f[0] === 'mailbox' && !r.deleted
      && (r.f[1] || '').trim().toLowerCase() === name.trim().toLowerCase()
      && ((r.f[4] || '-').trim() || '-') === dom);
    if (clash) out.push(t.dupMail(name + '@' + (dom === '-' ? BASE : dom)));
  }

  // The dropdown already refuses to offer a claimed domain. This is the same
  // rule where the dropdown cannot reach: an empty name under Subdomain
  // composes back to `@`, which is the apex again.
  // Nothing to refuse here any more: an apex another ENABLED row serves is
  // taken over on save, and the hint beside the field says by whom. It was a
  // refusal until 2026-09-10, which made the second row of a pair impossible.

  return out;
}

// Reads what is on screen right now. Save used to do this inline; the live
// check needs the same values, and two readers would drift apart.
function readDrawer() {
  const shown = shapeFor(draft[0]);

  const vals = FIELDS.map((def, i) => {
    // A field this type does not use keeps whatever it had, which for a new row
    // is a dash. Reading it off a control that was never rendered would blank it.
    if (!shown.includes(i) && i !== 0) return draft[i] || '-';

    const opts = document.querySelector(`[data-opts="${i}"]`);
    if (opts) {
      const pairs = [...opts.querySelectorAll('.opt-pair')]
        .map(p => [p.querySelector('.opt-k').value.trim(), p.querySelector('.opt-v').value.trim()])
        .filter(([k]) => k !== '')
        .map(([k, v]) => k + '=' + v);
      return pairs.length ? pairs.join('; ') : '-';
    }

    const multi = document.querySelector(`[data-multi="${i}"]`);
    if (multi) {
      // Only the environment ticks. The login ticks and the account grid live
      // in the same block and carry no value of their own.
      const on = [...multi.querySelectorAll('input[data-env]:checked')].map(c => c.value);
      // All of them is what `-` already means, so it is written back as `-`
      // rather than as a list that would have to be edited again for every new
      // environment. None is refused by rowProblems, so it never reaches here.
      return (on.length === 0 || on.length === ENVS.length) ? '-' : on.join(', ');
    }

    const el = document.querySelector(`#drawer-fields [data-i="${i}"]`);
    const v = el ? el.value.trim() : '';
    return v === '' ? '-' : v;
  });

  vals[0] = draft[0];
  return vals;
}

// What the row will BE, in the words of the thing it creates. Checked while
// typing rather than after saving, because a value you cannot see the effect
// of is a value you check by deploying it.
// What the row will BE, as the fields that actually apply to it. A one line
// summary could only ever name two of them, and the addresses were the part
// worth reading.
function drawerSummary(v, t) {
  const rows = [];
  const add = (label, value) => { if (!blank(value)) rows.push([label, value]); };

  if (v[0] === 'mailbox') {
    const d = (v[4] || '').replace(/^=/, '');
    add(t.sumAddress, (blank(v[1]) || blank(d)) ? '' : v[1] + '@' + d);
    return rows;
  }

  add(t.sumName, v[1]);
  if (v[0] === 'app' || v[0] === 'proxy') add(t.sumPort, v[2]);
  if (v[0] === 'app') {
    const rt = (v[13] || 'dotnet').toLowerCase();
    const known = RUNTIMES.find(([r]) => r === rt);
    add(t.sumRuntime, known ? known[1] : v[13]);
  }
  if (v[0] === 'website') add(t.sumPath, v[3]);
  if (!blank(v[8])) add(t.sumRepoMode, blank(v[12]) ? 'private' : v[12]);

  // One line per environment, so which ones exist and what each answers on are
  // the same fact rather than two lists to compare.
  addressList().forEach(([e, a]) => rows.push([e, a]));
  return rows;
}

function checkDrawer() {
  const t = T[lang], out = document.getElementById('drawer-outcome');
  const save = document.getElementById('drawer-save');
  if (!out || !save) return;

  // The drawer is always in the DOM, at opacity 0, so its elements existing
  // says nothing about whether one is open. askRepoNames() calls this when the
  // repository list arrives, which happens on the Repositories tab with no
  // drawer at all: readDrawer() then reads draft[0] and throws on null.
  // `draft` was the proxy for "a drawer is open", and it is a bad one:
  // closeDrawer() never clears it, so a fetch landing after the drawer was shut
  // walked straight past this. Measured 2026-09-04: opening the Add drawer
  // starts the cold repo fetch, cancelling it leaves draft set, and when the
  // fetch resolved checkDrawer() threw, so askRepoNames()'s renderRepos() on
  // the NEXT LINE never ran and the Repositories tab stayed empty. Ask the
  // drawer whether it is open, which is the actual precondition.
  if (!drawer.classList.contains('open')) return;
  if (drawerMode !== 'panel' && !draft) return;

  if (drawerMode === 'panel') {
    const bad = panelProblems();
    // A machine page is not built from `draft`, so drawerDirty() cannot judge
    // it and deliberately says no. Gating on it here would disable the button
    // permanently, so this pane keeps the validity-only rule until its own
    // state snapshot exists.
    save.disabled = bad.length > 0;
    out.classList.toggle('bad', bad.length > 0);
    out.innerHTML = bad.length
      ? `<span class="lead">${esc(t.cannotSave)}</span>${esc(bad[0])}`
      : `<span class="lead">${esc(editingPanel === null ? t.willMake : t.willChange)}</span>${esc(panelOutcome(t))}`;
    return;
  }

  const v = readDrawer();
  const bad = rowProblems(v);

  // Enabled only when something actually changed, as well as being valid.
  // The owner, 2026-09-07: a button that is always pressable says a press will do
  // something, and on an unchanged drawer it does nothing at all. drawerDirty()
  // is the same comparison the close dialog uses, so the two cannot disagree
  // about whether there is work to keep.
  const unchanged = !drawerDirty();
  save.disabled = bad.length > 0 || unchanged;
  out.classList.toggle('bad', bad.length > 0);
  if (bad.length === 0 && unchanged) {
    out.classList.remove('bad');
    out.innerHTML = `<span class="lead">${esc(t.nothingChanged)}</span>`;
    return;
  }

  // Say which of the two this press is going to be, because they differ by
  // about eight times in how long you wait.
  const key = fastSafeEdit(editing === null ? null : rows[editing].f, v)
    ? 'keep' : 'keepApply';
  save.setAttribute('data-i18n', key);
  save.textContent = t[key];

  if (bad.length) {
    out.innerHTML = `<span class="lead">${esc(t.cannotSave)}</span>${esc(bad[0])}`;
    return;
  }

  // Amber, above the summary: this save is about to switch another row off, and
  // that is a consequence somebody has to see BEFORE pressing rather than
  // discover in the table afterwards. The owner, 2026-09-10. Not a refusal: taking
  // the hostname over is the intended way to move a customer between their www_
  // row and their app_ row.
  const rivals = rivalsFor(v, editing === null ? -1 : editing)
    .map(i => rows[i].f[1]).filter(Boolean);
  const warn = rivals.length
    ? `<span class="lead warn">${esc(t.dupClaim)}</span>${esc(rivals.join(', '))}`
    : '';
  out.classList.toggle('warn', rivals.length > 0);

  const summary = drawerSummary(v, t);
  out.innerHTML = warn + (summary.length
    ? `<span class="lead">${esc(editing === null ? t.willMake : t.willChange)}</span>`
      + summary.map(([label, value]) =>
          `<span style="display:block"><span style="display:inline-block;min-width:6.5rem;opacity:.65">${esc(label)}</span>${esc(value)}</span>`
        ).join('')
    : '');
}

document.getElementById('drawer-save').addEventListener('click', () => {
  if (drawerMode === 'panel') { savePanelDrawer(); return; }

  const vals = readDrawer();

  const bad = rowProblems(vals);
  if (bad.length) { alert(bad.join('\n\n')); return; }

  // A mailbox on a domain DNS_DOMAINS has never heard of is an address nothing
  // routes to, so choosing one out of the account group adds it to that line.
  if (vals[0] === 'mailbox') {
    const d = vals[4].replace(/^=/, '');
    if (!blank(d) && d !== BASE && !DNSDOMAINS.includes(d) && !extraDomains.includes(d)) {
      extraDomains.push(d);
    }
  }

  // Captured before closeDrawer(), which clears editing.
  const target = editing === null ? rows.length : editing;
  const before = editing === null ? null : rows[editing].f.slice();
  commitPreview(vals);
  commitAppMem(vals);

  // Beside mbxCommit, and for the same reason: the instance row has to land in
  // THIS edit so it goes out with this publish rather than a later one.
  progCommit(vals);

  // BEFORE mbxCommit, and the order is load bearing. stageMailPw asks which
  // addresses are NEW by comparing the ticked set against the mailbox rows that
  // exist; mbxCommit is what adds those rows. Run the other way round it found
  // every address already present, staged nothing, and the create wrote three
  // mailbox rows with no password while the drawer had refused to save without
  // them. Measured 2026-09-06: /etc/dovecot/users stayed empty.
  //
  // Fed the values just read, not the draft: for a NEW row the draft is
  // still the blank template of dashes, so a first mailbox was staged as
  // -@domain and its password refused.
  stageMailPw(vals);

  // Then the rows themselves, so a new website and its mailboxes land in one
  // edit and go out with one publish.
  mbxCommit(vals);

  // One hostname, one enabled row. Saving this row switched ON takes the
  // hostname off whoever else was serving it, which is the switch the owner asked
  // for on 2026-09-10: a www_ row and an app_ row for one customer, live one at
  // a time, and moving between them is a tick rather than a migration.
  //
  // Done here rather than refused in rowProblems(): being told "the other row
  // has it" leaves you to go and find that row, which is the work the tick was
  // supposed to remove. check_config.sh still refuses the pair, for a config
  // that arrives any other way.
  // The rows it switches off become dirty, so render() below paints them as
  // edited and disabled: the switch is visible in the table before the apply
  // starts, rather than only in the job's output.
  standDownRivals(vals, target);


  // A LIMITED ADMIN DOES NOT WRITE ROWS. Item 106.
  //
  // Adding is always a request. Editing is split, which is the owner's call of
  // 2026-09-10: the fields that cost nothing save and apply at once, and the
  // ones that cost a port, a certificate or a repository become a request. So
  // the row is briefly half what they asked for, and the drawer says so.
  //
  // The check is repeated in index.php, which refuses every write action a
  // limited admin sends. This fork is what makes the page behave sensibly; the
  // refusal there is what makes it safe.
  if (typeof MYROLE !== 'undefined' && MYROLE !== 'full') {
    const asked = requestFromDrawer(before, vals, editing === null, target);
    if (asked === 'request-only') {
      closeDrawer();
      render();
      return;
    }
    // Otherwise the free half was written into vals and falls through to the
    // ordinary save below, with the restricted half already filed.
  }
  const fast = fastSafeEdit(before, vals);

  if (editing === null) {
    rows.push({ line: null, f: vals, dirty: true, fastOnly: fast });
  } else {
    rows[editing].f = vals;
    rows[editing].dirty = true;
    rows[editing].fastOnly = (rows[editing].fastOnly !== false) && fast;
  }
  closeDrawer();
  render();

  // Keep this change means keep it, so it goes to the machine now: publish,
  // then an apply. The row sweeps and the page locks while it runs, the same
  // as pressing Stop on a row does.
  document.querySelectorAll(`tr[data-row="${target}"]`).forEach(tr => {
    tr.classList.add('working');
    tr.querySelectorAll('button').forEach(b => { b.disabled = true; });
  });
  document.body.classList.add('locked');
  startSaveFromDrawer();
});

// The fast apply runs add_app_vhosts.sh and add_preview_vhosts.sh and nothing
// else, so an edit may only take it when it changed nothing a vhost does not
// describe. Everything else leaves the machine behind the saved config, which
// is what the drift banner then reports.
const FAST_FIELDS = [7, 11];   // Login, Who may enter

function fastSafeEdit(before, vals) {
  if (vals[0] === 'mailbox') {
    // ALMOST always, and the exception is Enabled. A mailbox writes no vhost
    // and no unit, so everything it needs is done by manage_mail.sh in the same
    // save - EXCEPT disabling, which is field 15 and is read only by
    // add_postfix.sh when it rewrites sender_login_map.
    //
    // Measured 2026-09-06: ticking Disable and pressing Apply changes reported
    // done, and racea@ was still in sender_login_map and could still send. It
    // took a full apply to lose the right. Reporting a security control as
    // applied while it is not is the failure being prevented here.
    return before !== null && String(before[14] || '') === String(vals[14] || '');
  }
  if (before === null) return false;              // a new row needs its root
  return vals.every((v, i) => v === before[i] || FAST_FIELDS.includes(i));
}

// Every pending change, not just the one that was typed last: a vhost-only
// edit made after a repository edit still has to carry the repository.
function pendingIsFastOnly() {
  if (typeof STAGED !== 'undefined' && STAGED) return false;
  const raw = document.getElementById('raw');
  if (raw && raw.value !== raw.defaultValue) return false;
  if (panelEntries().some(e => e.dirty || e.deleted)) return false;
  // Switching a machine page off takes its vhost down and closes its port,
  // which the fast apply does not do.
  if (panelEntries().some(e => (e.enabled === 'no') !== (e.panel.enabled === 'no'))) return false;
  if (typeof ENVGONE !== 'undefined' && ENVGONE.size) return false;
  if (ENVS.some(e =>
       (ENVBRANCH[e] || '') !== (ENVWAS.b[e] || '')
    || (PREFIX[e]    || '') !== (ENVWAS.p[e] || '')
    || (OFFSET[e]    ?? 0)  !== (ENVWAS.o[e] ?? 0))) return false;
  if (envLimDirty()) return false;
  // The mailbox exemption is not absolute, and treating it as one is what let a
  // bulk Disable report success without taking the send right away. bulk.js
  // sets fastOnly=false on exactly the mailbox changes the fast apply cannot
  // make, and that has to win over the row type.
  // A DELETION is never fast, whatever the row type. The fast apply writes
  // vhosts and preview ports and prunes nothing, so removing a row leaves its
  // vhost, its certificate, its document root and, for the last mailbox on a
  // domain, the mail.<domain> lineage that Dovecot and Postfix still name.
  //
  // This was the mailbox exemption reading `r.fastOnly !== false` on a row where
  // fastOnly was never set at all: undefined !== false is true, so every one of
  // the five delete paths that forgot to set it was classified fast-safe.
  // Measured 2026-09-07: deleting contact@example.com left three orphans, an
  // orphaned certificate and two mail configs still naming it.
  //
  // Said here rather than only at the five call sites, so a sixth delete path
  // cannot reintroduce it by forgetting one line.
  if (rows.some(r => r.deleted)) return false;

  return rows.every(r =>
    !r.dirty
    || (r.f[0] === 'mailbox' && r.fastOnly !== false)
    || r.fastOnly === true);
}

// Fast where the whole pending edit is vhost-shaped, the full job otherwise.
// Both save and push first; they differ only in what they then write.
// The pending password travels in the form, once, and is set server side after
// the publish lands. It is never stored: not in the row, not in the candidate,
// not in sessionStorage. The console is HTTP on the LAN, which is the same path
// the existing password box already uses.
// The field has always been a LIST, so the addresses ticked on a website row go
// out in the same one rather than needing a second channel. A website drawer
// can stage several at once; a mailbox drawer still stages exactly its own.
function stageMailPw(vals) {
  const field = document.getElementById('mailpw-field');
  if (!field) return;
  const box = document.getElementById('mailpw-value');
  const out = [];

  // NOT gated on mailPwPending any more. It used to be, so a password typed on
  // an EXISTING mailbox was silently dropped by Keep this change and only the
  // separate button could set it. Two buttons for one field, and the field did
  // nothing under the one people press. There is one button now.
  const pw = box ? box.value : '';
  if (pw) {
    const dom = blank(vals[4]) ? BASE : String(vals[4]).replace(/^=/, '');
    out.push({ local: String(vals[1]).trim(), domain: dom, pw });
  }

  const mbxDom = (vals[0] === 'website' || vals[0] === 'app') ? mbxDomainOf(vals) : null;
  if (mbxDom !== null && mbxDraft && mbxDraft.domain === mbxDom) {
    const dom = mbxDom === '-' ? BASE : String(mbxDom).replace(/^=/, '');
    // Every box that was typed into, new address or existing one. An empty box
    // is not a change and never reaches the machine, which is what lets an
    // existing address keep the password it has.
    Object.keys((mbxDraft && mbxDraft.pw) || {}).forEach(local => {
      const p = String(mbxDraft.pw[local] || '');
      if (p) out.push({ local: local, domain: dom, pw: p });
    });
  }

  field.value = out.length ? JSON.stringify(out) : '';
  if (box) box.value = '';
  if (mbxDraft) mbxDraft.pw = {};
}


// WHICH FIELDS A CUSTOMER MAY CHANGE THEMSELVES. Item 106, the owner field by
// field, 2026-09-10. The index is the position in FIELDS.
//
// Free means: costs no port, no certificate, no repository, and reaches
// nothing outside their own row.

// THE MAILBOX ALLOWANCE. Item 106, the owner 2026-09-10: a number per person, and
// it is the point at which a REQUEST is filed rather than the point at which a
// refusal happens. Raising their number is what makes the request unnecessary,
// so a customer never hits a dead end.
//
// Only the TYPED addresses count. info@, contact@ and admin@ are free, and
// contact@ is mandatory on a new domain anyway, so counting it would have spent
// an allowance on the one address nobody chooses.
const MBX_FREE_LOCALS = ['info', 'contact', 'admin'];

// How many extra addresses this drawer is asking for beyond what already
// exists. MYBOXES_USED covers the rows on the machine; this covers the ones
// about to be added.
function mbxExtrasWanted(f) {
  if (f[0] === 'mailbox') {
    const local = String(f[1] || '').trim();
    const dom = String(f[4] || '').replace(/^=/, '').trim() || '-';
    const exists = mbxRowsFor(dom).some(m => m.local === local);
    return (exists || MBX_FREE_LOCALS.includes(local)) ? [] : [local];
  }
  return mbxNewLocals(f).filter(n => !MBX_FREE_LOCALS.includes(n));
}

// Empty when the allowance is not reached, otherwise the reason. Not an error:
// the caller turns it into a request.
function mbxOverAllowance(f) {
  if (typeof MYBOXES === 'undefined' || MYBOXES === null) return '';
  const wanted = mbxExtrasWanted(f).length;
  if (wanted === 0) return '';
  const total = (typeof MYBOXES_USED === 'number' ? MYBOXES_USED : 0) + wanted;
  if (total <= MYBOXES) return '';
  return T[lang].qOverBoxes
    .replace('%d', String(MYBOXES))
    .replace('%u', String(MYBOXES_USED))
    .replace('%w', String(wanted));
}
const FREE_FIELDS = [
  3,   // Path
  6,   // App settings
  7,   // Login, the per-environment checkbox
  9,   // Source branch
  10,  // Environments
  12,  // Repository mode
  13,  // Runtime
  14,  // Enabled
];
// Not free, and NOT requestable either: these two are refused outright.
// Owner would let somebody hand a row away or take one; DataSource points at
// another row's data folder, which is not a cost but a way to read somebody
// else's files.
const NEVER_FIELDS = [5, 15];

// The subdomain LABEL is theirs, the domain is not. Field 4 holds both: `=x.nl`
// names a whole domain, anything else is a label under BASE. So the test is on
// the shape of the value rather than on the field number.
function domainChanged(before, after) {
  const b = String(before[4] || '').trim();
  const a = String(after[4] || '').trim();
  if (b === a) return false;
  const dom = v => (v.startsWith('=') ? v.slice(1) : BASE);
  return dom(b) !== dom(a);
}

// Build a request out of what the drawer holds, and put the free half back so
// it can be saved. Returns 'request-only' when nothing may be saved directly.
function requestFromDrawer(before, vals, isNew, target) {
  const t = T[lang];
  // An add is a request, whole, except a mailbox on a domain they own while
  // they are under their allowance. The owner, 2026-09-16.
  if (isNew) {
    const over = mbxOverAllowance(vals);
    const dom = String(vals[4] || '').replace(/^=/, '').trim();
    if (vals[0] === 'mailbox' && !over && MAILDOMAINS.includes(dom)) return 'save';
    fileRequest({ ...rowToObject(vals), isNew: true },
                (over ? over + ' ' : '') + t.qCommentAdd);
    return 'request-only';
  }

  // Over their mailbox allowance? Then the whole edit is a request, whatever
  // else it changed: the addresses and the row go together, and approving half
  // of it would create a row whose mailboxes were never agreed.
  const overBoxes = mbxOverAllowance(vals);
  if (overBoxes) {
    fileRequest(rowToObject(vals), overBoxes + ' ' + t.qCommentChange);
    return 'request-only';
  }

  const changed = [];
  for (let i = 0; i < vals.length; i++) {
    if (String(before[i] ?? '') !== String(vals[i] ?? '')) changed.push(i);
  }
  if (!changed.length) return 'nothing';

  const refused = changed.filter(i => NEVER_FIELDS.includes(i));
  if (refused.length) {
    alert(t.qRefusedFields);
    return 'request-only';
  }

  const restricted = changed.filter(i => !FREE_FIELDS.includes(i) && i !== 4);
  if (domainChanged(before, vals)) restricted.push(4);

  if (!restricted.length) return 'save';        // all free: save as normal

  // The restricted half goes as a request holding the WHOLE row as they want
  // it, not a diff: replaying a diff against a row that has moved on is how a
  // request comes back wrong.
  fileRequest(rowToObject(vals), t.qCommentChange);

  // And the free half is put back onto the values that are about to be saved,
  // so their allowed change takes effect now. The owner chose the split over
  // holding everything, 2026-09-10.
  restricted.forEach(i => { vals[i] = before[i]; });
  const stillFree = changed.some(i => FREE_FIELDS.includes(i));
  return stillFree ? 'save' : 'request-only';
}

// The row as an object, so a request reads as something a person can check
// rather than as sixteen positional strings.

// A request's row object back into the sixteen positional fields. The inverse
// of rowToObject(), and it is what lets APPROVING publish through the ordinary
// save: the approved row joins `rows` and goes out with the next apply like any
// other edit, so check_config.sh sees it exactly as it sees everything else.
//
// A field the request does not carry keeps what the existing row has, or a dash
// for a new one. That matters for the PORT: a request never carries one, and
// approving an add must let nextPort() choose it now rather than honour a
// number chosen when the request was filed.
function objectToRow(o, existing) {
  const base = existing ? existing.slice() : FIELDS.map(() => '-');
  FIELDS.forEach(([key], i) => {
    const k = key.charAt(0).toLowerCase() + key.slice(1);
    if (Object.prototype.hasOwnProperty.call(o, k) && o[k] !== undefined && o[k] !== null) {
      base[i] = String(o[k]);
    }
  });
  if (o.type) base[0] = String(o.type);
  if (o.name) base[1] = String(o.name);
  // A MAILBOX STORES ITS DOMAIN PLAINLY, with no `=`. That grammar belongs to a
  // website or an application, where field 5 has to say "a whole other domain"
  // rather than "a label under the base"; a mailbox row's field 5 IS the domain
  // and nothing else.
  //
  // Approving a request that carried the `=` wrote `=example.com` into a
  // mailbox row on 2026-09-11, and the drift report then asked for an account
  // called `facturen@=example.com`. Caught by approving one and reading what
  // the machine said it would do.
  if (base[0] === 'mailbox' && String(base[4] || '').startsWith('=')) {
    base[4] = String(base[4]).slice(1);
  }
  return base;
}
function rowToObject(vals) {
  const o = {};
  FIELDS.forEach(([key], i) => { o[key.charAt(0).toLowerCase() + key.slice(1)] = vals[i]; });
  o.type = vals[0];
  o.name = vals[1];
  return o;
}

// A DOMAIN REQUEST IS HOW A CUSTOMER ASKS. The owner, 2026-09-18: a full admin
// registers the domain themselves, so the same tick reads "New domain" and
// carries the provider's register link instead of saying an admin will order.
function isFullAdmin() {
  return typeof MYROLE === 'undefined' || MYROLE === 'full';
}

function domainRegisterUrl(domain) {
  const order = typeof DOMAIN_REGISTER_URL === 'undefined' ? '' : DOMAIN_REGISTER_URL;
  return order.indexOf('%s') >= 0 ? order.replace('%s', encodeURIComponent(domain)) : order;
}

function domainAskBlock(isNew, value) {
  const t = T[lang];
  const full = isFullAdmin();
  const register = full && domainRegisterUrl('')
    ? `<p class="hint"><a id="addr-newregister" href="${esc(domainRegisterUrl(isNew ? value : ''))}"
               target="_blank" rel="noopener noreferrer">${esc(t.qDomainOrderLink)}</a></p>`
    : '';
  return `<label style="font-weight:400;display:block;margin-bottom:.5rem">
            <input type="checkbox" id="addr-newask" style="width:auto"
                   ${isNew ? 'checked' : ''}> ${esc(full ? t.addrNewDomainFull : t.addrNewDomain)}</label>
          <div id="addr-newwrap" style="margin:0 0 .8rem" ${isNew ? '' : 'hidden'}>
            <label style="display:block;margin-bottom:.25rem"
                   for="addr-newdom">${esc(t.addrNewDomainLabel)}</label>
            <input id="addr-newdom" spellcheck="false" autocomplete="off"
                   placeholder="brochure.nl" value="${esc(isNew ? value : '')}">
            <p class="hint" style="margin:.4rem 0">
              <button type="button" id="addr-newcheckbtn">${esc(t.addrNewDomainAsk)}</button>
              <span id="addr-newstate" style="margin-left:.5rem"></span>
            </p>
            <p class="hint"><a id="addr-newcheck" href="#" target="_blank"
               rel="noopener noreferrer">${esc(t.addrNewDomainCheck)}</a></p>
            ${register}
            <p class="hint">${esc(full ? t.addrNewDomainHintFull : t.addrNewDomainHint)}</p>
          </div>`;
}

// A REQUEST FOR A DOMAIN NOBODY OWNS YET travels with the request, never in a
// row field: the row already says `=x.nl`, and these three say how that answer
// was arrived at. Item 106, 2026-09-11.
//
// ONE ANSWER, THE MACHINE'S. This used to carry the requester's own tick beside
// it, so an admin could see whether the two agreed. The owner removed the question
// on 2026-09-11 by removing the case for it: a request naming a domain somebody
// else holds is refused before it is filed, so there is nothing left for a
// human claim to add and one fewer box to tick.
function domainAskFields(row) {
  const ask = document.getElementById('addr-newask');
  if (!ask || !ask.checked) return row;
  const box = document.getElementById('addr-newdom');
  row.domainRequest = String(box ? box.value : '').trim();
  if (DOMFREE && DOMFREE.domain === row.domainRequest && DOMFREE.state !== 'asking') {
    row.domainChecked = DOMFREE.state;
    row.domainCheckedAt = DOMFREE.checked || 0;
  }
  return row;
}

async function fileRequest(row, promptText) {
  row = domainAskFields(row);
  const t = T[lang];
  // Why they want it, which is the half that makes an answer possible. Asked
  // rather than optional: "add a skunk environment" and "add a skunk
  // environment because the customer wants to test the new form" are different
  // questions to answer.
  const why = prompt(promptText) ?? '';
  row.comment = why;
  const body = new URLSearchParams({ action: 'request', row: JSON.stringify(row) });
  try {
    const r = await fetch(location.pathname, { method: 'POST', body: body,
      headers: { 'Accept': 'application/json' } });
    const d = await r.json();
    if (!d.ok) { alert(d.out || t.qFailed); return; }
    alert(t.qFiled);
    if (typeof loadRequests === 'function') await loadRequests();
  } catch (e) {
    alert(t.qFailed);
  }
}
function startSaveFromDrawer() {
  if (pendingIsFastOnly()) {
    document.getElementById('btn-save-fast').click();
    return;
  }
  applyWatch();
  document.getElementById('btn-save-apply').click();
}

// One listener on the drawer rather than one per control: the fields are
// rebuilt whenever the type changes, and per-control listeners would be lost.
['input', 'change'].forEach(ev =>
  document.getElementById('drawer-fields').addEventListener(ev, () => {
    checkDrawer();
    // A machine page has no preview port and no mailboxes, and `draft` is null
    // while its drawer is open, so both painters below threw on every
    // keystroke in it. Nothing showed it: the drawer kept working, and the
    // errors only ever reached the browser console.
    if (drawerMode === 'panel') return;
    // The preview ports are worked out from Port and Envs, so they follow
    // whatever is being typed rather than what the drawer opened with.
    paintPreview();
    // The mail section belongs to the domain, so it follows the domain field
    // rather than only the drawer opening.
    mbxRender();
    // Same reason: progress.<domain> follows the domain being typed.
    progRender();
    // AGAIN, AFTER mbxRender, and the order is the whole point. Picking a
    // domain is the event that CREATES mbxDraft, so the checkDrawer above ran
    // while it was still null and saw no mailboxes to demand a password for:
    // three password boxes rendered and Keep this change stayed enabled.
    // Caught by clicking it, not by reading it.
    checkDrawer();
  }));

// The password box sits outside #drawer-fields, so the one listener on that
// container never saw it and Keep this change stayed refused however good the
// password was.
document.getElementById('mailpw-value').addEventListener('input', () => { paintMailPwOutcome(); checkDrawer(); });

document.getElementById('drawer-cancel').addEventListener('click', closeDrawerAsked);

// Saved on its own, not with the row. The row goes to git through Publish;
// this goes straight to a file on the machine, and mixing them behind one
// button would make Publish do something it says nothing about.
document.getElementById('mail-save').addEventListener('click', () => {
  const t = T[lang];
  const from = document.getElementById('mail-from').value.trim();
  const to = document.getElementById('mail-to').value.trim();
  const out = document.getElementById('mail-outcome');

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(from) || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) {
    out.textContent = t.mailBad;
    return;
  }
  // Submitting reloads, so an unsaved row edit would go with it. Same warning
  // the certificate buttons give, for the same reason.
  if (rows.some(r => r.dirty || r.deleted) && !confirm(t.certLeaveEdits)) return;

  const f = document.getElementById('mail-form');
  f.querySelector('[name=row]').value = rows[editing].f[1];
  f.querySelector('[name=mail_from]').value = from;
  f.querySelector('[name=mail_to]').value = to;
  f.submit();
});

document.getElementById('mailpw-save').addEventListener('click', () => {
  const t = T[lang];
  const pw = document.getElementById('mailpw-value').value;
  const out = document.getElementById('mailpw-outcome');

  // The same floor the script enforces, said here so it is said before the
  // password leaves the browser.
  if (pw.length < 8) { out.textContent = t.pwShort; return; }
  // Submitting reloads, so an unsaved row edit would go with it.
  if (rows.some(r => r.dirty || r.deleted) && !confirm(t.certLeaveEdits)) return;

  const local  = rows[editing].f[1];
  const domain = blank(rows[editing].f[4]) ? BASE : rows[editing].f[4].replace(/^=/, '');
  const f = document.getElementById('mailpw-form');
  f.querySelector('[name=mail_local]').value  = local;
  f.querySelector('[name=mail_domain]').value = domain;
  f.querySelector('[name=mail_pw]').value     = pw;
  f.submit();
  // The page is on its way out, but a submit the browser then blocks would
  // leave the password sitting in two fields.
  f.querySelector('[name=mail_pw]').value = '';
  document.getElementById('mailpw-value').value = '';
});
document.getElementById('drawer-close').addEventListener('click', closeDrawerAsked);
scrim.addEventListener('click', closeDrawerAsked);
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeDrawer(); });
// One button per service type rather than one "add" that then asks what it is:
// the type decides which fields exist, so it is the first thing to know.
// Only the ones whose kind is a row type. A page and an environment are
// settings, and each has its own handler below. So is a shared folder: it is
// not a row in hostings.conf at all.
// The exception list grew by one on 2026-09-10 and cost a bug: the Users tab's
// Add button carries .add-btn for its hue, so this opened the ROW drawer
// underneath the user drawer, where it silently swallowed every click on the
// table behind it. data-kind is the real test, so it is the one used.
document.querySelectorAll('.add-btn[data-kind]:not(#add-panel):not(#add-env):not(#add-smb)').forEach(b =>
  b.addEventListener('click', () => { leaveEditModeForAdd(); openDrawer(null, b.dataset.kind); }));

// Every table body that holds rows, INCLUDING the two Pipeline views added on
// 2026-09-10. They were left out when the tabs were split, so nothing in that
// view answered a click: Edit, the trashcan, the certificate buttons and the
// service controls all did nothing. The owner found it as "the website edit drawer
// is not opening".
//
// getElementById is guarded, because one missing id throws here and takes every
// listener defined after it in this file with it.
['apps-body', 'apps-pipeline-body',
 'websites-body', 'websites-pipeline-body',
 'proxies-body', 'mail-body'].forEach(id => {
  const el = document.getElementById(id);
  if (el) el.addEventListener('click', rowClick);
});

// A page has a name as well as a port now, so it gets the drawer every other
// tab uses rather than one editable cell.
document.getElementById('machine-body').addEventListener('click', e => {
  const keep = e.target.closest('[data-panel-keep]');
  if (keep) { panelGone.delete(keep.dataset.panelKeep); render(); return; }

  // The same act as the drawer's button, and deliberately the same confirm: a
  // page is deleted from wherever the operator happens to be looking, and the
  // sentence that says what it costs does not depend on which one they used.
  const del = e.target.closest('[data-panel-del]');
  if (del) {
    const id = del.dataset.panelDel;
    const p = PANELS.find(x => x.id === id);
    if (!p || p.held) return;
    if (!confirm(T[lang].panelDeleteConfirm.replace('%s', panelState(p).label))) return;
    panelGone.add(id);
    delete panelEdits[id];
    render();
    return;
  }

  const btn = e.target.closest('[data-panel]');
  if (btn) openPanelDrawer(btn.dataset.panel);
});

// The environment name is fixed once it exists. Renaming it would rewrite every
// row's Envs, AuthProtected and AuthUsers, and then every unit, vhost and
// certificate carrying the old prefix. Remove and add instead: this project
// rebuilds rather than migrates. The other three are ordinary editable values.
// The band the rows themselves sit in, rounded down to the thousand. It is the
// zero the offsets are measured from, and the file never states it: LIVE_PORT_
// OFFSET is 0 because a row's Port IS its live port.
//
// Derived rather than configured, so it cannot disagree with the rows.
function liveBand() {
  const ports = rows
    .filter(r => !r.deleted && (r.f[0] === 'app'))
    .map(r => Number(r.f[2]))
    .filter(n => n > 0);
  if (!ports.length) return null;
  return Math.floor(Math.min(...ports) / 1000) * 1000;
}

// The defaults add_app_services.sh uses when a limit is not in the file.
function limitDefault(key) {
  if (key === 'NONLIVE_CPU')    return '2';
  if (key === 'NONLIVE_MEMORY') return '3G';
  if (key.endsWith('_APP_MEMORY')) return '768M';
  return key.endsWith('_CPU') ? '1' : '1G';
}
const limitOf  = key => ENVLIM[key]   ?? limitDefault(key);
const limitWas = key => ENVWAS.l[key] ?? limitDefault(key);
const limitChanged = key => limitOf(key) !== limitWas(key);

// Sorted, so removing and re-adding the same entry is not a change.
const appMemText = () => Object.keys(APPMEM).sort().map(n => n + ':' + APPMEM[n]).join(', ');
const APPMEMWAS  = appMemText();

function envLimDirty() {
  return Object.keys(ENVLIM).some(limitChanged) || appMemText() !== APPMEMWAS;
}

// Never more than the machine has; live always keeps a core and a gigabyte.
function coreOptions() {
  const out = [];
  for (let c = 0.5; c <= Math.max(0.5, MACHINE.cores - 1); c += 0.5) out.push({ v: String(c), l: String(c) });
  return out;
}
function memOptions() {
  const cap = Math.max(256, MACHINE.memMB - 1024);
  return [256, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768]
    .filter(mb => mb <= cap)
    .map(mb => ({ v: mb % 1024 ? mb + 'M' : (mb / 1024) + 'G', l: mb < 1024 ? mb + ' MB' : (mb / 1024) + ' GB' }));
}

function limitSelect(key, opts, disabled) {
  const cur = limitOf(key);
  // A value typed into the file by hand is kept and shown, not replaced.
  const list = opts.some(o => o.v === cur) ? opts : [{ v: cur, l: cur }, ...opts];
  return `<td class="env-cell"><select data-env-lim="${esc(key)}" ${disabled ? 'disabled' : ''}>${
    list.map(o => `<option value="${esc(o.v)}"${o.v === cur ? ' selected' : ''}>${esc(o.l)}</option>`).join('')
  }</select></td>`;
}

function renderEnvs() {
  const t = T[lang];
  const band = liveBand();
  const cores = coreOptions(), mem = memOptions();
  document.getElementById('count-environments').textContent = ENVS.length;
  document.getElementById('envs-body').innerHTML = ENVS.map(e => {
    const gone = ENVGONE.has(e);
    const up = e.toUpperCase();
    const box  = (k, v, ph) => `<td class="env-cell"><input data-env-set="${k}"
        data-env="${esc(e)}" value="${esc(v)}" placeholder="${esc(ph)}"
        ${gone ? 'disabled' : ''}></td>`;

    // Shown as the band it lands in, not as the offset. "-2000" said nothing
    // about what it was subtracted from; "6000" is the number you go looking
    // for in ss or in a browser. The offset is what the file still stores.
    //
    // With no rows to measure against there is no band, so the offset itself is
    // shown rather than a number derived from nothing.
    const portCell = band === null
      ? box('PORT_OFFSET', String(OFFSET[e] ?? 0), '0')
      : `<td class="env-cell"><input data-env-set="PORT_BAND"
           data-env="${esc(e)}" type="number" step="1000"
           value="${band + (OFFSET[e] ?? 0)}" ${gone ? 'disabled' : ''}></td>`;

    // A checkbox, not a trash can. A trash can on this table read as "delete
    // this entry" where what it does is "this environment stops existing".
    // Unticking is still undoable until the page is saved.
    return `<tr class="${gone ? 'gone' : ''}">
      <td><input type="checkbox" data-env-on="${esc(e)}" ${gone ? '' : 'checked'}
            title="${esc(t.sEnvOn)}" aria-label="${esc(t.sEnvOn)}"></td>
      <td>${esc(e)}</td>
      ${box('BRANCH', ENVBRANCH[e] || '', e)}
      ${portCell}
      ${box('HOST_PREFIX', PREFIX[e] || '', t.envPrefixHint)}
      ${e === 'live'
        ? `<td class="env-cell" title="${esc(t.sEnvLiveFirst)}">${esc(t.envLiveFirst)}</td><td class="env-cell">-</td>`
        : limitSelect(up + '_CPU', cores, gone) + limitSelect(up + '_MEMORY', mem, gone)}
      ${limitSelect(up + '_APP_MEMORY', mem, gone)}
    </tr>`;
  }).join('');

  const shared = ENVS.some(e => e !== 'live' && !ENVGONE.has(e));
  document.getElementById('envs-foot').innerHTML = shared
    ? `<tr><td></td><td colspan="4">${esc(t.envNonliveTogether)}</td>
         ${limitSelect('NONLIVE_CPU', cores, false)}${limitSelect('NONLIVE_MEMORY', mem, false)}<td></td></tr>`
    : '';
}

// One listener for both: the per-environment rows and the shared row below.
['envs-body', 'envs-foot'].forEach(id => document.getElementById(id).addEventListener('change', e => {
  const sel = e.target.closest('[data-env-lim]');
  if (!sel) return;
  ENVLIM[sel.dataset.envLim] = sel.value;
  serialise();
  paintDiscard();
}));

document.getElementById('envs-body').addEventListener('input', e => {
  const box = e.target.closest('[data-env-set]');
  if (!box) return;
  const env = box.dataset.env, v = box.value.trim();
  if (box.dataset.envSet === 'BRANCH')           ENVBRANCH[env] = v;
  else if (box.dataset.envSet === 'HOST_PREFIX') PREFIX[env] = v;
  // Typed as a band, stored as the offset the scripts read. The conversion
  // happens here so nothing downstream has to know the band exists.
  else if (box.dataset.envSet === 'PORT_BAND') {
    const band = liveBand();
    if (band !== null && v !== '') OFFSET[env] = parseInt(v, 10) - band;
  }
  else                                           OFFSET[env] = parseInt(v, 10) || 0;

  // serialise() runs at the end of render(), and nothing here renders: the
  // tables have not changed and rebuilding them mid-keystroke would take the
  // focus out of the box being typed in. Without this the hidden config field
  // keeps whatever the last render wrote, so Make it live posts the config
  // WITHOUT the edit, and the page discards it while reporting success.
  serialise();
  paintDiscard();
});

document.getElementById('envs-body').addEventListener('change', e => {
  const box = e.target.closest('[data-env-on]');
  if (!box) return;
  const env = box.dataset.envOn;
  if (box.checked) { ENVGONE.delete(env); render(); return; }

  // Say how much this costs before it is agreed to, not after: every row that
  // runs here loses a unit, a vhost and a certificate.
  // Two numbers, because they cost differently: a row that also runs elsewhere
  // loses one instance, a row that runs only here stops existing.
  const here = rows.filter(r => !r.deleted && !rowDropped(r) && rowEnvs(r).includes(env));
  const hit  = here.length;
  const only = here.filter(r =>
    rowEnvs(r).filter(e => !ENVGONE.has(e)).join() === env).length;
  // Redrawn on a refusal too: the box is already visually unticked, and leaving
  // it that way would say the environment is gone when it is not.
  if (!confirm(T[lang].envDelConfirm(env, hit, only))) { render(); return; }
  ENVGONE.add(env);
  render();
});

document.getElementById('add-env').addEventListener('click', () => {
  leaveEditModeForAdd();
  const t = T[lang];
  const name = (prompt(t.envName) || '').trim().toLowerCase();
  if (!name) return;
  if (!/^[a-z][a-z0-9]*$/.test(name)) { alert(t.envBadName); return; }
  if (name === 'nonlive') { alert(t.envNameTaken); return; }
  if (ENVS.includes(name)) {
    // A name that is only marked for removal is brought back rather than added
    // twice, which would write the settings block out two times.
    if (ENVGONE.has(name)) { ENVGONE.delete(name); render(); return; }
    alert(t.envExists);
    return;
  }
  ENVS.push(name);
  ENVBRANCH[name] = name;
  PREFIX[name] = name + '-';
  OFFSET[name] = 0;
  render();
});

document.getElementById('add-panel').addEventListener('click',
  () => { leaveEditModeForAdd(); openPanelDrawer(null); });

// The tick and the promotion are POSTs to this page, not edits to the config:
// they change the machine's certificates, never the file under review. So they
// go through a form of their own rather than the unsaved-changes buffer.
function certPost(action, host) {
  // Submitting reloads the page, so anything typed and not yet saved is lost.
  if (rows.some(r => r.dirty || r.deleted) && !confirm(T[lang].certLeaveEdits)) return;
  const f = document.getElementById('cert-form');
  f.querySelector('[name=action]').value = action;
  f.querySelector('[name=host]').value = host;
  f.submit();
}

// THE SERVICE DIALOG. One line per unit, ticked as each answers, with the
// machine's own graphs beside it: the [data-cpu-panel] inside it is painted by
// drawCpu on the page's existing ticker, so it needs nothing of its own.
//
// Sequential on purpose. Starting four units at once tells you only that
// something is happening; one at a time says which, and a stop that hangs is
// then attributable to the unit it is on.
const svcDialog = document.getElementById('svc-dialog');
const svcScrim  = document.getElementById('svc-scrim');
const svcClose  = document.getElementById('svc-dialog-close');

function closeSvcDialog() {
  svcDialog.classList.remove('open');
  svcScrim.classList.remove('open');
  document.body.classList.remove('locked');
  // The units moved, so the page is showing what was true before. The status
  // poll would catch up within five seconds; a reload is what makes the state,
  // the certificate and the Runs on column agree at once.
  location.replace(location.pathname);
}
if (svcClose) svcClose.addEventListener('click', closeSvcDialog);

async function runSvcPairs(pairs, verb) {
  const t = T[lang];
  const list = pairs.split(',').map(x => x.trim()).filter(Boolean);
  if (!list.length) return;

  document.getElementById('svc-dialog-title').textContent = t.svcDlgTitle[verb];
  document.getElementById('svc-dialog-what').textContent  = t.svcDlgWhat(list.length);
  const msg = document.getElementById('svc-dialog-msg');
  msg.hidden = true;
  msg.className = 'msg';
  svcClose.disabled = true;
  svcClose.textContent = t.bClose;

  const ul = document.getElementById('svc-dialog-list');
  ul.innerHTML = list.map((pair, i) => {
    const bits = pair.split(':');
    return '<li id="svcline-' + i + '" class="waiting">' +
      '<span class="svc-mark"></span>' +
      '<span class="svc-name">' + esc(bits[0]) + '</span>' +
      '<span class="env-pill">' + esc(bits[1]) + '</span>' +
      '<span class="svc-said"></span></li>';
  }).join('');

  svcDialog.classList.add('open');
  svcScrim.classList.add('open');
  document.body.classList.add('locked');

  let done = 0;
  const bad = [];
  for (let i = 0; i < list.length; i++) {
    const bits = list[i].split(':');
    const row = bits[0], env = bits[1];
    const li  = document.getElementById('svcline-' + i);
    li.className = 'working';
    li.querySelector('.svc-mark').innerHTML = '<span class="spin"></span>';
    li.querySelector('.svc-said').textContent = t.svcDlgDoing[verb];

    let d = null;
    try {
      const body = new URLSearchParams({ action: 'svcone', row: row, env: env, verb: verb });
      const r = await fetch(location.pathname, { method: 'POST', body: body,
        headers: { 'Accept': 'application/json' } });
      d = await r.json();
    } catch (e) {
      // A dropped request says nothing about the unit, so it is reported as
      // unknown rather than as a failure.
      d = null;
    }

    if (d && d.ok) {
      done++;
      li.className = 'ok';
      li.querySelector('.svc-mark').textContent = '\u2713';
      li.querySelector('.svc-said').textContent = t.svcDlgDone[verb];
    } else {
      bad.push(row + ' ' + env);
      li.className = 'bad';
      li.querySelector('.svc-mark').textContent = '\u2717';
      const said = (d && d.out)
        ? d.out.split('\n').filter(Boolean).slice(-1)[0]
        : '';
      li.querySelector('.svc-said').textContent = said || t.svcDlgUnknown;
    }
  }

  msg.hidden = false;
  msg.className = 'msg ' + (bad.length ? 'bad' : 'good');
  msg.textContent = bad.length ? t.svcDlgSome(done, bad.join(', ')) : t.svcDlgAll(done);
  svcClose.disabled = false;
  svcClose.focus();
}

// Every application on the machine. Read off the table rather than out of the
// config, so it is exactly what the operator can see.
document.querySelectorAll('[data-svcpane]').forEach(b => {
  b.addEventListener('click', () => {
    const pairs = entries('app')
      .filter(x => b.dataset.svcpane === 'start' ? unitStartable(x) : (!x.dirty && !x.deleted))
      .map(x => `${x.name}:${x.env}`);
    if (!pairs.length) return;
    if (b.dataset.svcpane === 'stop'
        && !confirm(T[lang].svcStopAllConfirm(pairs.length))) return;
    if (rows.some(r => r.dirty || r.deleted) && !confirm(T[lang].certLeaveEdits)) return;
    runSvcPairs(pairs.join(','), b.dataset.svcpane);
  });
});

function rowClick(e) {
  const pr = e.target.closest('[data-promote]');
  if (pr) {
    if (!confirm(T[lang].goLiveConfirm(pr.dataset.promote))) return;
    certPost('promote', pr.dataset.promote);
    return;
  }
  // No confirm: a staging certificate costs nothing and is undone by asking
  // again. The one that spends an issuance is the promote above.
  const tc = e.target.closest('[data-testcert]');
  if (tc) {
    certPost('testcert', tc.dataset.testcert);
    return;
  }
  const lg = e.target.closest('[data-svclog]');
  if (lg) { openSvcLog(lg.dataset.svcRow, lg.dataset.svcEnv); return; }

  const mc = e.target.closest('[data-mailcfg]');
  if (mc) { openMailCfg(mc.dataset.mailcfg, mc.dataset.mailcfgRow); return; }

  const ms = e.target.closest('[data-mailshare]');
  if (ms) { shareMailbox(ms); return; }

  // Every environment of one row, in one press. The pairs were composed when
  // the button was drawn, from the lines actually on screen.
  const sa = e.target.closest('[data-svcpairs]');
  if (sa) {
    const pairs = sa.dataset.svcpairs;
    const n = pairs.split(',').length;
    if (sa.dataset.svcverb === 'stop'
        && !confirm(T[lang].svcStopRowConfirm(sa.dataset.svcname, n))) return;
    if (rows.some(r => r.dirty || r.deleted) && !confirm(T[lang].certLeaveEdits)) return;
    runSvcPairs(pairs, sa.dataset.svcverb);
    return;
  }
    const sv = e.target.closest('[data-svc]');
  if (sv) {
    const verb = sv.dataset.svc;
    const row  = sv.dataset.svcRow;
    const env  = sv.dataset.svcEnv;
    // Only the stop asks. Starting and restarting cost a moment; stopping
    // takes an application off the air until somebody starts it again.
    if (verb === 'stop' && !confirm(T[lang].stopConfirm(row, env))) return;
    if (rows.some(r => r.dirty || r.deleted) && !confirm(T[lang].certLeaveEdits)) return;
    // The same dialog as the bulk pair, with one line in it. A single unit used
    // to be a form post: the page went away and came back with one sentence,
    // and what the machine did in between was never shown.
    runSvcPairs(row + ':' + env, verb);
    return;
  }
  const ed = e.target.closest('[data-edit]');
  const dl = e.target.closest('[data-del]');
  if (ed) openDrawer(Number(ed.dataset.edit), null);
  if (dl) {
    const i = Number(dl.dataset.del);

    // Undo: un-deleting a row also drops any pending mail op, which has not run
    // yet (ops run on Keep this change), so there is nothing to reverse.
    if (rows[i].deleted) {
      rows[i].deleted = false;
      delete rows[i].mailOp;
      render();
      return;
    }

    // A mailbox is deleted two ways, so it gets the dialog rather than a confirm.
    // Everything else keeps the plain confirm: removing it takes the vhost and
    // unit but never the files.
    if (rows[i].f[0] === 'mailbox') {
      // A duplicate line: another identical mailbox row is still here, so this
      // one is only a stray config line. Drop it with no mail op and no dialog,
      // which also lets a doubled contact@ be cleaned up despite the guard.
      const local = (rows[i].f[1] || '').trim();
      const dom = mbxRowDomain(rows[i]);
      const twin = rows.some((o, j) => j !== i && o.f[0] === 'mailbox' && !o.deleted
        && (o.f[1] || '').trim() === local && mbxRowDomain(o) === dom);
      if (twin) { mbxDelRow = i; mbxMarkDeleted(null); return; }
      openMbxDelete(i);
      return;
    }

    // A row with a repository leaves more behind than files: the GitHub
    // repository and the Jenkins jobs are never deleted by an apply, and
    // saying so at the moment of deleting is the only place it is visible.
    const _repo = (rows[i].f[8] || "").trim();
    const _hasRepo = _repo && _repo !== "-" && _repo.toLowerCase() !== "new";
    if (_hasRepo || mailRowsOfDomain(i).length) {
      openRowDelete(i, _hasRepo ? _repo : "");
      return;
    }
    if (!confirm(T[lang].delConfirm(rows[i].f[1]))) return;
    rows[i].deleted = true;
    rows[i].fastOnly = false;
    render();
  }
}

// -----------------------------------------------------------------------------
// Deleting a row that owns a repository
//
// Three answers, and only the first is reversible, so it is the default. The
// choice is recorded on the row as repoOp and carried out on the next Keep this
// change, beside the config line leaving: the same shape the mailbox delete
// uses, for the same reason.
// -----------------------------------------------------------------------------
let repoDelRow = null;
let repoDelOp  = 'keep';

// Set when the dialog is being driven by the bulk path rather than a trashcan.
//
// A single row answers and the save starts, because answering IS the press. A
// batch cannot do that: it has more rows to ask about, and starting a save
// after the first one would publish half the batch. So the caller supplies
// what happens next, and the auto-save is the default rather than the rule.
//
// The owner's decision 2026-09-03: ask for EVERY row, keep / archive / delete,
// not once for the batch. bulk.js:347 used to set r.deleted and never set
// repoOp at all, so Delete all checked ALWAYS left every repository on GitHub
// without saying so.
let repoDelThen = null;

// owner/name out of either URL shape, which is what GitHub's API wants.
function repoSlugOf(url) {
  return String(url || '')
    .replace(/^git@[^:]+:/, '')
    .replace(/^https?:\/\/[^/]+\//, '')
    .replace(/\.git$/, '')
    .trim();
}

// Every mailbox row on this row's domain, except contact@.
//
// contact@ stays, deliberately: it is the address every other mailbox forwards
// to when it is removed, so offering to delete it here would let one press
// take the forward target away from the forwards being created in the same
// press. Removing it is a manual act from the Mail tab, where manage_mail.sh
// already refuses while anything still forwards to it. The owner's call,
// 2026-09-02.
function mailRowsOfDomain(i) {
  const dom = mbxDomainOf(rows[i].f);
  if (!dom) return [];
  const want = dom === '-' ? BASE : dom;
  return rows.map((r, j) => [r, j])
    .filter(([r]) => r.f[0] === 'mailbox' && !r.deleted)
    .filter(([r]) => mbxRowDomain(r) === want)
    .filter(([r]) => (r.f[1] || '').trim().toLowerCase() !== 'contact')
    .map(([r, j]) => j);
}

function openRowDelete(i, repo, then) {
  const t = T[lang];
  repoDelRow = i;
  repoDelOp  = 'keep';
  repoDelThen = then || null;

  const hasRepo = repo !== '';
  document.getElementById('repodel-slug').textContent = hasRepo ? repoSlugOf(repo) : '';
  document.querySelectorAll('#repodel-dialog [data-repoop]').forEach(b => {
    b.hidden = !hasRepo;
    b.setAttribute('aria-checked', b.dataset.repoop === 'keep' ? 'true' : 'false');
  });

  // One block per mailbox, with the same two answers the mailbox trashcan
  // gives, plus leaving it alone as the default.
  const boxes = mailRowsOfDomain(i);
  const list  = document.getElementById('repodel-mail-list');
  document.getElementById('repodel-mail').hidden = boxes.length === 0;
  list.innerHTML = boxes.map(j => {
    const addr = (rows[j].f[1] || '').trim() + '@' + mbxRowDomain(rows[j]);
    return `<div data-mbxrow="${j}" style="margin-bottom:.5rem">
      <p style="margin:0 0 .2rem;font-family:var(--mono,monospace)">${esc(addr)}</p>
      <label style="font-weight:400;display:block"><input type="radio" name="mbx${j}"
             value="" checked style="width:auto"> ${esc(t.repoDelMailLeave)}</label>
      <label style="font-weight:400;display:block"><input type="radio" name="mbx${j}"
             value="forward" style="width:auto"> ${esc(t.repoDelMailForward)}</label>
      <label style="font-weight:400;display:block"><input type="radio" name="mbx${j}"
             value="purge" style="width:auto"> ${esc(t.repoDelMailPurge)}</label>
    </div>`;
  }).join('');

  // The progress instance, when this row has one. Asked rather than assumed:
  // it is a separate row, so deleting the website left it running on its own
  // port with nothing on screen connecting it to the customer who had just
  // been removed.
  const progAt = progIndexFor(rows[i].f);
  const progBox = document.getElementById('repodel-prog');
  progBox.hidden = progAt < 0;
  if (progAt >= 0) {
    document.getElementById('repodel-prog-name').textContent =
      (rows[progAt].f[1] || '').trim() + '  ' + progHostOf(rows[i].f);
    // Back to the safe default every time the dialog opens, so an answer given
    // for one row is never inherited by the next.
    const off = progBox.querySelector('input[name="progdel"][value="disable"]');
    if (off) off.checked = true;
  }

  document.getElementById('repodel-dialog').classList.add('open');
  document.getElementById('repodel-scrim').classList.add('open');
}

function closeRepoDelete() {
  document.getElementById('repodel-dialog').classList.remove('open');
  document.getElementById('repodel-scrim').classList.remove('open');
  repoDelRow = null;
  // Cleared too, or Cancel on one row would leave the batch's callback armed
  // and the next single-row delete would run it.
  repoDelThen = null;
}

// Ask about each row in turn, then call done(). Cancel on any of them stops
// the whole run: the rows already answered keep their answers and nothing is
// published, which is the same recoverable state a Cancel leaves anywhere else.
function askRowDeletes(queue, done) {
  const next = () => {
    if (!queue.length) { done(); return; }
    const i = queue.shift();
    const repo = (rows[i].f[8] || '').trim();
    const hasRepo = repo && repo !== '-' && repo.toLowerCase() !== 'new';
    openRowDelete(i, hasRepo ? repo : '', next);
  };
  next();
}

document.querySelectorAll('#repodel-dialog [data-repoop]').forEach(b => {
  b.addEventListener('click', () => {
    repoDelOp = b.dataset.repoop;
    document.querySelectorAll('#repodel-dialog [data-repoop]').forEach(o =>
      o.setAttribute('aria-checked', o === b ? 'true' : 'false'));
  });
});

document.getElementById('repodel-cancel').addEventListener('click', closeRepoDelete);
document.getElementById('repodel-scrim').addEventListener('click', closeRepoDelete);
document.getElementById('repodel-go').addEventListener('click', () => {
  if (repoDelRow === null) return;
  // Captured before closeRepoDelete(), which clears repoDelRow. Reading it
  // afterwards made the sweep selector tr[data-row="undefined"] once already.
  const repoDelTarget = repoDelRow;
  const r = rows[repoDelRow];
  r.deleted = true;
  r.fastOnly = false;
  // Recorded, not done: nothing reaches GitHub until Keep this change runs.
  r.repoOp = repoDelOp === 'keep' ? null : repoDelOp;

  // Each mailbox that was answered goes with the row, carrying the same
  // mailOp the mailbox trashcan would have set.
  document.querySelectorAll('#repodel-mail-list [data-mbxrow]').forEach(block => {
    const j = parseInt(block.dataset.mbxrow, 10);
    const picked = block.querySelector('input[type=radio]:checked');
    const op = picked ? picked.value : '';
    if (!op || !rows[j]) return;
    rows[j].deleted = true;
    rows[j].fastOnly = false;
    rows[j].mailOp = op;
  });

  // The progress instance, per the answer given. Read from the row being
  // deleted rather than from a stored index, for the same reason the sweep
  // selector once read tr[data-row="undefined"]: closeRepoDelete() is below.
  const progBox = document.getElementById('repodel-prog');
  if (!progBox.hidden) {
    const pick = progBox.querySelector('input[name="progdel"]:checked');
    const op = pick ? pick.value : 'disable';
    const pAt = progIndexFor(r.f);
    if (pAt >= 0 && op !== 'keep') {
      if (op === 'delete') {
        rows[pAt].deleted = true;
      } else {
        rows[pAt].f[14] = 'no';
        rows[pAt].dirty = true;
      }
      // Never the fast path: a unit and a vhost are involved either way.
      rows[pAt].fastOnly = false;
    }
  }

  const then = repoDelThen;
  closeRepoDelete();
  render();

  // Driven by the bulk path: it has more rows to ask about, so it decides what
  // happens next. Starting a save here would publish half a batch.
  if (then) { then(); return; }

  // Answered means done, the same as Keep this change in the drawer. It used to
  // stop here, which left the operator to find a top-level button, and a
  // deletion is never fast-safe so the only one showing was Make it live. One
  // press, and startSaveFromDrawer() picks the fast path or the full job.
  document.querySelectorAll(`tr[data-row="${repoDelTarget}"]`).forEach(tr => {
    tr.classList.add('working');
    tr.querySelectorAll('button').forEach(b => { b.disabled = true; });
  });
  document.body.classList.add('locked');
  startSaveFromDrawer();
});

// -----------------------------------------------------------------------------
// Deleting a mailbox: forward and keep, or purge for good
//
// The choice is recorded on the row as mailOp and carried out on the next Keep
// this change, so the config line leaving and the mail moving are one act.
// -----------------------------------------------------------------------------
let mbxDelRow = null;
let mbxDelOp = null;

// A mailbox row carries its domain plainly in f[4], where '-' means the base
// domain. That is not the Subdomain field mbxDomainOf reads, so it is taken
// straight from the row here.
function mbxRowDomain(r) {
  const d = (r.f[4] || '-').trim() || '-';
  return d === '-' ? BASE : d;
}

function openMbxDelete(i) {
  const r = rows[i];
  const local  = (r.f[1] || '').trim();
  const shown  = mbxRowDomain(r);

  // contact@ is the forward target for the other mailboxes on its domain, so it
  // may only go once it is the last one left. The machine decides that for real
  // (manage_mail.sh reads the maildirs and the app secrets); this is the same
  // rule applied to the rows on screen, so the refusal arrives before a save.
  //
  // A duplicate never reaches here: the trashcan handles it as a plain line
  // removal before opening this dialog.
  if (local === 'contact') {
    const siblings = rows.filter((o, j) =>
      j !== i && o.f[0] === 'mailbox' && !o.deleted && !rowDropped(o)
      && mbxRowDomain(o) === shown && (o.f[1] || '').trim() !== 'contact');
    if (siblings.length) { alert(T[lang].mbxContactLocked(shown)); return; }
    // It cannot forward, because it IS the forward target. That is a reason to
    // hide the forward option, and it was taken as a reason to offer deleting
    // everything or nothing at all. Keeping the files is still a real answer:
    // retire writes no alias and leaves the maildir exactly as it is.
    mbxDelRow = i;
    mbxDelOp = 'retire';
    document.getElementById('mbxdel-addr').textContent = local + '@' + shown;
    document.getElementById('mbxdel-forward').hidden = true;
    document.getElementById('mbxdel-retire').hidden = false;
    document.querySelectorAll('.mbxdel-opt').forEach(b => {
      const on = b.dataset.op === 'retire';
      b.classList.toggle('sel', on);
      b.setAttribute('aria-checked', on ? 'true' : 'false');
    });
    document.getElementById('mbxdel-go').disabled = false;
    document.getElementById('mbxdel-scrim').classList.add('open');
    document.getElementById('mbxdel-dialog').classList.add('open');
    return;
  }
  document.getElementById('mbxdel-forward').hidden = false;
  document.getElementById('mbxdel-retire').hidden = true;

  mbxDelRow = i;
  // Keep-the-files is the safe outcome, so it is selected on open and Proceed is
  // ready. Choosing purge is then a deliberate switch, never the default.
  mbxDelOp = 'forward';
  document.getElementById('mbxdel-addr').textContent = local + '@' + shown;
  document.querySelectorAll('.mbxdel-opt').forEach(b => {
    const on = b.dataset.op === 'forward';
    b.classList.toggle('sel', on);
    b.setAttribute('aria-checked', on ? 'true' : 'false');
  });
  document.getElementById('mbxdel-go').disabled = false;
  document.getElementById('mbxdel-scrim').classList.add('open');
  document.getElementById('mbxdel-dialog').classList.add('open');
}

function closeMbxDelete() {
  mbxDelRow = null;
  document.getElementById('mbxdel-scrim').classList.remove('open');
  document.getElementById('mbxdel-dialog').classList.remove('open');
}

// Mark the row deleted, record the mail op, and save it the SAME light way
// adding a mailbox does: publish plus manage_mail, here and now. A mailbox
// writes no vhost and needs no unit or certificate, so it never goes through
// "Make it live" and its Jenkins job. Consistent with the domain drawer, where
// ticking an address already fast-saves.
function mbxMarkDeleted(op) {
  if (mbxDelRow === null) return;
  const target = mbxDelRow;
  rows[target].deleted = true;
  rows[target].fastOnly = false;
  rows[target].mailOp = op;
  closeMbxDelete();
  render();

  document.querySelectorAll(`tr[data-row="${target}"]`).forEach(tr => {
    tr.classList.add('working');
    tr.querySelectorAll('button').forEach(b => { b.disabled = true; });
  });
  document.body.classList.add('locked');
  // One decision point, not two. This hardcoded the fast path; a mailbox row is
  // fast-safe so the outcome is the same, but the choice belongs in one place.
  startSaveFromDrawer();
}

document.getElementById('mbxdel-cancel').addEventListener('click', closeMbxDelete);
document.getElementById('mbxdel-scrim').addEventListener('click', closeMbxDelete);

// Picking an option selects it and enables Proceed, rather than acting. The
// destructive choice is then one deliberate press on Proceed, with no nested
// confirmation to click through.
document.querySelectorAll('.mbxdel-opt').forEach(btn => {
  btn.addEventListener('click', () => {
    mbxDelOp = btn.dataset.op;
    document.querySelectorAll('.mbxdel-opt').forEach(b => {
      const on = b === btn;
      b.classList.toggle('sel', on);
      b.setAttribute('aria-checked', on ? 'true' : 'false');
    });
    document.getElementById('mbxdel-go').disabled = false;
  });
});

document.getElementById('mbxdel-go').addEventListener('click', () => {
  if (mbxDelOp) { mbxMarkDeleted(mbxDelOp); }
});

// Every mail op the rows carry, for the save to hand to manage_mail.sh. A row
// that names its own branch has answered the question; a mailbox names its local
// part and domain the same way the drawer does.
// Repository ops, the same shape and for the same reason: recorded on the row
// when the dialog was answered, handed over when the save actually posts. Only
// a row being deleted can carry one.
// Every op is carried, usable or not. Dropping the unusable ones here is what
// let a row be deleted with "Delete it" answered and the repository still on
// GitHub, with nothing anywhere saying so: a row whose Repository field still
// says `new` has no owner/name to act on. The submit refuses instead.
function collectRepoOps() {
  const ops = [];
  rows.forEach(r => {
    if (!r.deleted || !r.repoOp) return;
    const slug = repoSlugOf(r.f[8]);
    ops.push({
      verb: r.repoOp,
      slug: slug,
      row: (r.f[1] || '').trim(),
      usable: /^[^/]+\/[^/]+$/.test(slug)
    });
  });
  return ops;
}

function collectMailOps() {
  const ops = [];
  rows.forEach(r => {
    if (r.f[0] !== 'mailbox' || !r.mailOp) return;
    ops.push({
      verb: r.mailOp,
      local: (r.f[1] || '').trim(),
      domain: mbxRowDomain(r)
    });
  });
  return ops;
}


// -----------------------------------------------------------------------------
// One service's journal, read only
//
// The row and the environment go to the machine as they are: the unit name is
// BUILT by app_service_control.sh from the published config, so nothing here
// can name a unit, and the verb it runs is journalctl and nothing else.
// -----------------------------------------------------------------------------
let svcLogFor = null;

function openSvcLog(row, env) {
  svcLogFor = { row, env };
  const dlg = document.getElementById('svclog-dialog');
  if (!dlg) return;
  document.getElementById('svclog-unit').textContent = row + ' \u2192 ' + env;
  document.getElementById('svclog-out').textContent = T[lang].applyWorking || '...';
  dlg.classList.add('open');
  document.getElementById('svclog-scrim').classList.add('open');
  document.body.classList.add('locked');
  loadSvcLog();
}

// AN EMPTY JOURNAL IS USUALLY A UNIT THAT HAS NOT RUN YET, not a fault. On
// 2026-09-07 two environments showed "-- No entries --" while their deploy was
// still inside dotnet publish, and the dialog said nothing about waiting. It
// keeps looking now, every five seconds, until there is something to read or
// the dialog is closed.
let svcLogTimer = null;

function loadSvcLog() {
  clearTimeout(svcLogTimer);
  if (!svcLogFor) return;
  const out = document.getElementById('svclog-out');
  fetch('?ask=unitlog&row=' + encodeURIComponent(svcLogFor.row)
        + '&env=' + encodeURIComponent(svcLogFor.env),
        { cache: 'no-store', headers: { 'Accept': 'application/json' } })
    .then(r => r.json())
    .then(d => {
      const raw = (d && d.log) ? d.log.trim() : '';
      const empty = raw === '' || /^-- No entries --$/m.test(raw);
      if (!empty) {
        out.textContent = raw;
        // The tail is what says why a unit will not start, so open at the bottom.
        out.scrollTop = out.scrollHeight;
        return;
      }
      out.textContent = (d && d.error) ? d.error : T[lang].logWaiting;
      svcLogTimer = setTimeout(loadSvcLog, 5000);
    })
    .catch(() => {
      out.textContent = T[lang].logNone;
      svcLogTimer = setTimeout(loadSvcLog, 5000);
    });
}

function closeSvcLog() {
  clearTimeout(svcLogTimer);
  svcLogFor = null;
  const dlg = document.getElementById('svclog-dialog');
  if (dlg) dlg.classList.remove('open');
  document.getElementById('svclog-scrim').classList.remove('open');
  document.body.classList.remove('locked');
}

document.getElementById('svclog-close')?.addEventListener('click', closeSvcLog);
document.getElementById('svclog-refresh')?.addEventListener('click', loadSvcLog);

// =============================================================================
// What to type into a mail app
//
// Every value is read off Dovecot and Postfix by mail_client_settings.sh, so a
// port on screen is a port that is listening. The card deliberately does NOT
// show a password: nothing can read one back, and inventing a placeholder is
// how somebody ends up typing the word "password".
// =============================================================================
let mailCfgFor = null;

// Every value gets its own copy button, the same data-copy the clone URL uses.
// That delegate is in boot.js and carries the textarea fallback, which is the
// half that matters here: this page is plain http on the LAN, so
// navigator.clipboard is absent and a hand-rolled copy silently does nothing.
//
// Somebody setting up a phone types these one box at a time, so copying one
// value is the actual gesture. Copy-all is kept for pasting the lot to a
// customer.
// copyAs is what the button puts on the clipboard when it differs from what is
// shown: "Also works" reads "465  SSL/TLS", and pasting that into a port box
// is not what anybody wanted.
// The copy icon is its own column, right-aligned, so all of them line up down
// the edge of the card instead of stepping in and out with the length of each
// value. The table is width:100% for the same reason: the column has to be at
// the end of the FIELD, not trailing the text.
function mcRow(label, value, mono, copyAs) {
  const t = T[lang];
  const cp = copyAs === undefined ? value : copyAs;
  return `<tr><th style="text-align:left;font-weight:500;padding:.25rem .8rem .25rem 0;white-space:nowrap;vertical-align:top">${esc(label)}</th>`
       + `<td style="padding:.25rem 0;width:100%${mono ? ';font-family:var(--mono,monospace)' : ''}">${esc(value)}</td>`
       + `<td style="padding:.25rem 0 .25rem .8rem;text-align:right;vertical-align:top">`
       + `<button type="button" class="icon-btn" data-copy="${esc(cp)}"`
       + ` title="${esc(t.aCopyValue)}" aria-label="${esc(t.aCopyValue)}">${I.clipboard}</button></td></tr>`;
}

function mcBlock(title, part, t) {
  if (part.port === null || part.port === undefined || part.port === '') {
    return `<h4 style="margin:1rem 0 .3rem">${esc(title)}</h4>`
         + `<p class="note" style="margin:0">${esc(t.mcNoPort)}</p>`;
  }
  let rows = mcRow(t.mcServer, part.host, true)
           + mcRow(t.mcPort, String(part.port), true)
           + mcRow(t.mcSecurity, part.security, false);
  if (part.alt_port) {
    rows += mcRow(t.mcAlso, part.alt_port + '  ' + part.alt_security, true,
                  String(part.alt_port));
  }
  return `<h4 style="margin:1rem 0 .3rem">${esc(title)}</h4><table style="width:100%">${rows}</table>`;
}

function paintMailCfg(s) {
  const t = T[lang];
  const warn = document.getElementById('mailcfg-warn');
  // The mismatch is the worse of the two and is named first: an untrusted
  // certificate warns and can be accepted, a wrong name is simply refused.
  let msg = '';
  if (s.host_matches === false) msg = t.mcMismatch;
  else if (s.trusted === false) msg = t.mcUntrusted;
  warn.textContent = msg;
  warn.hidden = msg === '';

  // Account type and authentication method are up here with the username
  // because a wizard asks them once, before it asks about either server.
  let head = mcRow(t.mcAccountType, s.account_type || 'IMAP', false)
           + mcRow(t.mcUser, s.username, true)
           + mcRow(t.mcAuthMethod, s.auth_method || '', false);

  let tail = '';
  // Said explicitly rather than left out. Somebody who picks POP3 because the
  // wizard offered it gets a failure that names the password.
  if (s.pop3 === false) tail += `<p class="note" style="margin:.6rem 0 0">${esc(t.mcNoPop)}</p>`;
  if (s.smtp_auth) tail += `<p class="note" style="margin:.2rem 0 0">${esc(t.mcSmtpAuth)}</p>`;

  document.getElementById('mailcfg-body').innerHTML =
      `<table style="width:100%">${head}</table>`
    + `<p class="note" style="margin:.4rem 0 0">${esc(t.mcPassNote)}</p>`
    + mcBlock(t.mcIncoming, s.imap || {}, t)
    + mcBlock(t.mcOutgoing, s.smtp || {}, t)
    + `<p class="note" style="margin:.8rem 0 0">${esc(t.mcAuth)}</p>`
    + tail
    + (s.webmail
        ? `<h4 style="margin:1rem 0 .3rem">${esc(t.mcWebmail)}</h4>`
          + `<p class="note" style="margin:0 0 .3rem">${esc(t.mcWebmailNote)}</p>`
          + `<table style="width:100%">${mcRow(t.mcAddress, s.webmail, true)}</table>`
        : '');

  document.getElementById('mailcfg-copy').dataset.copy = mailCfgCopyText();
}

// Asks who gets the mailbox, prefilled with the owner's address when the Users
// list has it, then shares that one item. login-store-decisions.md 2026-09-26.
async function shareMailbox(btn) {
  const t = T[lang];
  const addr = btn.dataset.mailshare;
  // The Users tab fills USERS; a click straight from Mailboxes found it empty.
  if (typeof USERS !== 'undefined' && !USERS.length && typeof loadUsers === 'function') {
    try { await loadUsers(); } catch (e) { /* no prefill then */ }
  }
  const owner = (typeof USERS !== 'undefined' ? USERS : []).find(u => u.name === btn.dataset.mailshareOwner);
  const to = (prompt(t.mShareAsk.replace('%s', addr), (owner && owner.email) || '') || '').trim();
  if (!to) return;
  btn.disabled = true;
  let d;
  try {
    const r = await fetch(location.pathname, { method: 'POST',
      body: new URLSearchParams({ action: 'mailshare', address: addr, to }),
      headers: { 'Accept': 'application/json' } });
    d = await r.json();
  } catch (e) {
    d = { ok: false, error: '' };
  }
  btn.disabled = false;
  alert(d.ok ? t.uShared.replace('%s', d.to) : t.uShareFailed.replace('%s', d.error || '?'));
}

function openMailCfg(address, row) {
  const t = T[lang];
  mailCfgFor = address;
  document.getElementById('mailcfg-addr').textContent = address;
  document.getElementById('mailcfg-warn').hidden = true;
  document.getElementById('mailcfg-body').textContent = t.mcLoading;
  document.getElementById('mailcfg-dialog').classList.add('open');
  document.getElementById('mailcfg-scrim').classList.add('open');
  document.body.classList.add('locked');

  fetch('?ask=mailclient&address=' + encodeURIComponent(address)
        + '&row=' + encodeURIComponent(row ?? ''), { cache: 'no-store' })
    .then(r => r.json())
    .then(d => {
      // The dialog may have been closed, or opened on another address, while
      // the fetch was in the air.
      if (mailCfgFor !== address) return;
      if (!d.ok) {
        document.getElementById('mailcfg-body').textContent = d.error || t.mcLoading;
        return;
      }
      paintMailCfg(d.settings);
    })
    .catch(() => {
      if (mailCfgFor === address) {
        document.getElementById('mailcfg-body').textContent = t.mcLoading;
      }
    });
}

function closeMailCfg() {
  mailCfgFor = null;
  document.getElementById('mailcfg-dialog')?.classList.remove('open');
  document.getElementById('mailcfg-scrim')?.classList.remove('open');
  document.body.classList.remove('locked');
}

document.getElementById('mailcfg-close')?.addEventListener('click', closeMailCfg);

// Copy-all, as plain text: what gets pasted to whoever is holding the phone.
//
// It sets data-copy and lets boot.js's delegate do the work, rather than
// calling navigator.clipboard here. That call needs a secure context and this
// page is plain http on the LAN, so a hand-rolled copy fails silently on every
// press. The delegate carries the textarea fallback that actually runs.
//
// Composed when the card is painted, not on the press, because the press is
// the delegate's and it reads the attribute rather than calling anything.
function mailCfgCopyText() {
  const lines = [document.getElementById('mailcfg-addr').textContent, ''];
  document.querySelectorAll('#mailcfg-body tr, #mailcfg-body h4').forEach(el => {
    if (el.tagName === 'H4') { lines.push('', el.textContent); return; }
    const th = el.querySelector('th'), td = el.querySelector('td');
    // The per-value copy button sits inside the cell, so its label would be
    // pasted with the value if the whole cell were read.
    if (th && td) {
      const v = td.cloneNode(true);
      v.querySelectorAll('button').forEach(b => b.remove());
      lines.push('  ' + th.textContent + ': ' + v.textContent.trim());
    }
  });
  return lines.join('\n');
}
