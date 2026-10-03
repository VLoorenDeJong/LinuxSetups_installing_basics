// The service tabs take their icon from the same set the rows and the add
// buttons use. Drawn once: an icon does not change with the language, and the
// label beside it is a span applyLang() rewrites without touching this.
document.querySelectorAll('.tab.svc[data-kind]').forEach(b => {
  b.insertAdjacentHTML('afterbegin', I[b.dataset.kind] || '');
});

const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const blank = v => v === '' || v === '-';

// The Subdomain field's own grammar, per the legend in hostings.conf, resolved
// per environment: "@portfolio" is the domain itself when live and
// test-portfolio.example.com when test, and neither is guessable from the
// field. Returns one address per environment the row runs in.
function addresses(sub, envs) {
  if (blank(sub)) return [];

  // Another domain gets an environment copy too, and the page said it did not.
  // Mirrors host_for in add_app_vhosts.sh:420: live answers on the real domain,
  // and every other environment becomes a SUBDOMAIN of it with the prefix's
  // trailing hyphen dropped, so test- gives test.example.org rather
  // than test-example.org, which is a domain nobody owns.
  if (sub.startsWith('=')) {
    const whole = sub.slice(1);
    return envs.map(e => {
      const p = PREFIX[e] ?? '';
      return [e, p ? p.replace(/-$/, '') + '.' + whole : whole];
    });
  }

  return envs.map(e => {
    const p = PREFIX[e] ?? '';
    if (sub === '@')         return [e, p ? p.replace(/-$/, '') + '.' + BASE : BASE];
    if (sub.startsWith('@')) return [e, p ? p + sub.slice(1) + '.' + BASE : BASE];
    return [e, p + sub + '.' + BASE];
  });
}

// A row is protected if AuthProtected is yes anywhere in it. `live:no, test:yes`
// counts, because the login exists somewhere.
const protectedRow = v => /(^|[:,\s])yes\b/.test(v) || v === 'yes';

// Per environment, because `live:no, test:yes` means the login exists in one
// and not the other, and a single padlock for the pair says neither.
function protectedFor(v, env) {
  if (blank(v)) return false;
  if (v === 'yes') return true;
  if (v === 'no')  return false;
  const m = v.match(new RegExp('\\b' + env + '\\s*:\\s*(yes|no)\\b'));
  return m ? m[1] === 'yes' : protectedRow(v);
}

// Who may enter, per environment. Mirrors users_in_env in add_app_vhosts.sh:
// a plain list is everyone everywhere, a list holding a colon is read per
// environment, and an environment the field does not name gets the admin alone.
function usersFor(v, env) {
  if (blank(v)) return [];
  const names = s => s.split(',').map(x => x.trim()).filter(x => x && x !== '-');
  if (!v.includes(':')) return names(v);
  for (const grp of v.split(';')) {
    const at = grp.indexOf(':');
    if (at < 0) continue;
    if (grp.slice(0, at).trim() === env) return names(grp.slice(at + 1));
  }
  return [];
}

// One sort per tab. Sharing one would mean opening Mailboxes sorted by a column
// it does not have.
const SORT = {
  apps:      { col: 2,  asc: true },
  websites:  { col: 1,  asc: true },
  // The Pipeline view of the same rows. Its own sort, because Port is not one
  // of its columns and a shared state would point at a column it does not have.
  'apps-pipeline':     { col: 1, asc: true },
  'websites-pipeline': { col: 1, asc: true },
  proxies:   { col: 2,  asc: true },
  mailboxes: { col: 4,  asc: true },
  machine:   { col: 2,  asc: true },
  smb:       { col: 0,  asc: true }
};

// Machine pages the operator has changed but not yet saved, keyed by the id the
// file stores. Kept apart from `rows` because a PANEL line is not a row, and
// serialise() rewrites a different kind of line for it.
//
// A port of null is a page switched off, which is what `-` means in the file.
// The id is never in here: it is what scripts look up, so it cannot be edited.
const panelEdits = {};   // id -> { port: Number|null, label: String }

// Pages whose PANEL line is to be removed entirely. Kept apart from a port of
// null: that switches a page off and leaves the line, this takes the line out.
const panelGone = new Set();
// Pages switched off in this browser but not yet saved. Seeded from the
// config, so a page that is already off comes back off after a reload.
const panelOff = new Set(PANELS.filter(p => p.enabled === 'no').map(p => p.id));

function panelState(p) {
  const e = panelEdits[p.id] || {};
  return {
    port:   'port'   in e ? e.port   : (p.value === null ? null : Number(p.value)),
    label:  'label'  in e ? e.label  : p.label,
    serves: 'serves' in e ? e.serves : (p.serves || 'itself'),
    target: 'target' in e ? e.target : (p.target || ''),
    login:  'login'  in e ? e.login  : (p.login  || 'yes'),
    users:  'users'  in e ? e.users  : (p.users  || '')
  };
}

// The sort keys are what the table shows, not what the file stores, because the
// table now shows one entry per environment and the file does not.
function entryValue(e, col) {
  switch (col) {
    case 0:  return e.kind;
    case 2:  return e.port;
    case 3:  return e.path ? e.path.toLowerCase() : null;
    // The Name column, so it sorts by the name. It returned the address until
    // 2026-08-16, which put every environment of one site apart from the others.
    case 1:  return e.name.toLowerCase();
    case 4:  return e.domain ? e.domain.toLowerCase() : (e.addr ? e.addr.toLowerCase() : null);
    case 7:  return e.locked ? 0 : 1;
    case 10: return e.env;
    default: return e.name.toLowerCase();
  }
}

function sorted(list, col, asc) {
  return list.sort((a, b) => {
    const x = entryValue(a, col), y = entryValue(b, col);
    if (x === null && y === null) return 0;
    if (x === null) return 1;                 // empties last, both directions
    if (y === null) return -1;
    const d = (typeof x === 'number') ? x - y : String(x).localeCompare(String(y));
    return d * (asc ? 1 : -1);
  });
}

// One entry per environment, not per config row. A row that runs live and test
// IS two things: two units, two ports, two addresses. Showing it once with both
// names in a corner asked the reader to hold the difference in their head.
//
// Editing any entry opens the same row, because the file still has one line.
// A proxy row is one service however many environments exist, which is what
// maintain_services.sh does with it. Listing it four times would invent three
// services that are never created.
function rowEnvs(r) {
  if (r.f[0] === 'proxy') return [ENVS[0]];
  return blank(r.f[10]) ? ENVS
    : r.f[10].split(',').map(e => e.trim()).filter(Boolean);
}

// Unticking an environment removes it everywhere, so a row that runs ONLY there
// stops existing. Derived rather than stored, so re-ticking brings the row back
// without anything having to remember why it went.
function rowDropped(r) {
  if (!ENVGONE.size) return false;
  const envs = rowEnvs(r);
  return envs.length > 0 && envs.every(e => ENVGONE.has(e));
}

// The environments the FILE gives a row, so narrowing it can be shown as a
// removal instead of the entries silently disappearing off the table.
function rowWasEnvs(i) {
  const f = ROWWAS[i];
  if (!f) return [];
  if (f[0] === 'proxy') return [ENVS[0]];
  return blank(f[10]) ? ENVS : f[10].split(',').map(e => e.trim()).filter(Boolean);
}


// WHOSE ROWS SOMEBODY SEES. Item 105.
//
// A full access admin sees every row. A limited admin sees the rows whose
// sixteenth field names them, and nothing else: an unowned row is NOT theirs,
// which is why a dash fails closed rather than reading as "anybody's".
//
// THIS IS NOT A SECURITY CONTROL. It decides what a table lists; every script
// behind every button decides for itself who may run it. A row kept off the
// page is still reachable by anyone who types its name into a request, so the
// refusals live in the scripts, and this lives here.
//
// Deliberately used only by the two table builders. Everything else, the port
// finder, the name-clash check, serialise(), keeps reading every row: a limited
// admin who cannot see a row must still not be handed its port or its name.
function maySeeRow(r) {
  if (typeof MYROLE === 'undefined' || MYROLE === 'full') return true;
  // A mailbox is its domain owner's, and MAILDOMAINS is exactly the domains
  // this account owns. The owner, 2026-09-16.
  if (r && r.f && r.f[0] === 'mailbox') {
    const d = String(r.f[4] || '').replace(/^=/, '').trim();
    return d !== '' && d !== '-' && MAILDOMAINS.includes(d);
  }
  const owner = String((r && r.f && r.f[15]) || '').trim();
  return owner !== '' && owner !== '-' && owner === ME;
}
function entries(kind) {
  const out = [];

  rows.forEach((r, i) => {
    if (r.f[0] !== kind || !maySeeRow(r)) return;
    const inherited = blank(r.f[10]);
    const envs = rowEnvs(r);
    // Still listed where the file had it, so an environment taken off a row
    // reads as struck through and removed until it is saved.
    const was   = rowWasEnvs(i);
    const shown = ENVS.filter(e => envs.includes(e) || was.includes(e));

    const addrs = addresses(r.f[4], shown);

    shown.forEach(env => {
      const base = Number(r.f[2]);
      const port = blank(r.f[2]) || isNaN(base) ? null : base + (OFFSET[env] ?? 0);
      const a = addrs.find(([e]) => e === env);
      out.push({
        kind: r.f[0], name: r.f[1], env, port, inherited,
        preview: previewPortFor(r.f[1], env, r.f[2]),
        path: blank(r.f[3]) ? null : r.f[3],
        addr: a ? a[1] : null,
        locked: protectedFor(r.f[7], env),
        // The repository, so the rerun button knows whether this row has a
        // deploy job at all. A row with no repository is served off disk and
        // Jenkins has nothing to build for it.
        repo: blank(r.f[8]) ? null : String(r.f[8]).trim(),
        row: i, dirty: r.dirty,
        deleted: r.deleted || ENVGONE.has(env) || !envs.includes(env)
      });
    });
  });

  return out;
}

// What hosting-status.service last published, indexed by unit name.
//
// null means nobody could look: either no file, or a collector that failed and
// published null with a sentence in errors. An empty Map means it looked and
// found nothing. Collapsing those two is how a page reports a healthy machine
// while the thing doing the checking is dead.
// What each deployed build targets, keyed by unit name. Read out of the build's
// own runtimeconfig.json by the publisher, never out of this config: the version
// is the build's fact, and a copy of it here could disagree.
// EVERYTHING BELOW IS DERIVED FROM `STATUS`, AND `STATUS` NOW CHANGES.
//
// It used to be baked into the page once, at load, so a row could only ever
// show the machine as it was when you pressed F5. That is why a unit coming up
// never made its row sweep: a Blazor app is "activating" for about a second,
// and the page was reading a snapshot minutes old. readStatus() re-derives all
// of it, and boot.js calls it every few seconds with a fresh file.
let RUNTIME_OF, DOTNET_HAVE, DOTNET_SUPPORT, UNITS, STATUS_AGE, STATUS_FRESH,
    SVC, CFG, FW, VHOSTS, LISTEN, CERTS;

// A published file older than this is not trusted. The writer runs every 5
// seconds, so a minute means it stopped, and the page must say unknown rather
// than show a minute-old answer as current.
const STATUS_MAX_AGE = 60;

// Amber from six months before Microsoft's end date, red after it.
const SUPPORT_WARN_DAYS = 183;
function supportOf(major) {
  const s = DOTNET_SUPPORT && DOTNET_SUPPORT[major];
  if (!s || !/^\d{4}-\d{2}-\d{2}$/.test(String(s.eol || ''))) {
    return { level: s && s.phase === 'eol' ? 'bad' : 'ok', eol: '' };
  }
  const days = (Date.parse(s.eol + 'T00:00:00Z') - Date.now()) / 86400000;
  return { level: days <= 0 ? 'bad' : days <= SUPPORT_WARN_DAYS ? 'warn' : 'ok', eol: s.eol };
}

function readStatus() {
  // What each deployed build targets, keyed by unit name. Read out of the
  // build's own runtimeconfig.json by the publisher, never out of this config:
  // the version is the build's fact, and a copy of it here could disagree.
  RUNTIME_OF = (STATUS && STATUS.runtimes && typeof STATUS.runtimes === 'object')
    ? STATUS.runtimes : {};
  DOTNET_HAVE = (STATUS && Array.isArray(STATUS.dotnetInstalled))
    ? STATUS.dotnetInstalled : null;
  DOTNET_SUPPORT = (STATUS && STATUS.dotnetSupport && typeof STATUS.dotnetSupport === 'object')
    ? STATUS.dotnetSupport : {};

  // null means nobody could look: either no file, or a collector that failed.
  // An empty Map means it looked and found nothing.
  UNITS = (STATUS && Array.isArray(STATUS.units))
    ? new Map(STATUS.units.map(u => [u.unit, u]))
    : null;

  STATUS_AGE = STATUS && STATUS.checked
    ? Math.floor(Date.now() / 1000) - Number(STATUS.checked)
    : null;
  STATUS_FRESH = STATUS_AGE !== null && STATUS_AGE <= STATUS_MAX_AGE;

  SVC    = (STATUS && STATUS.services) || {};
  CFG    = (STATUS && STATUS.configs)  || {};
  FW     = (STATUS && STATUS.firewall) || null;
  VHOSTS = (STATUS && Array.isArray(STATUS.vhosts))
    ? new Set(STATUS.vhosts) : null;
  LISTEN = (STATUS && Array.isArray(STATUS.listening))
    ? new Set(STATUS.listening.map(Number)) : null;
  // The whole record, not just the days: staging and verified decide whether a
  // row may be promoted to a real certificate.
  CERTS  = (STATUS && Array.isArray(STATUS.certificates))
    ? new Map(STATUS.certificates.map(c => [c.name, c])) : null;
}

readStatus();

// Worst wins, and unknown outranks ok: one check nobody could run means the
// row cannot be called healthy, only unproven.
const RANK = { ok: 0, unknown: 1, warn: 2, bad: 3 };
const WORST = list => list.reduce((w, c) => RANK[c.level] > RANK[w] ? c.level : w, 'ok');

// One shared service, checked the same way wherever a row depends on it: is it
// installed, is it running, does its own validator accept its config.
function serviceChecks(t, svc) {
  const out = [];
  const state = SVC[svc];
  if (state === undefined) {
    out.push({ level: 'unknown', text: `${svc}: ${t.ckNotInstalled}` });
  } else if (state === 'active') {
    out.push({ level: 'ok', text: `${svc}: ${t.st_running}` });
  } else {
    out.push({ level: 'bad', text: `${svc}: ${state}` });
  }
  const cfg = CFG[svc];
  if (cfg && cfg.ok === false) {
    out.push({ level: 'bad', text: `${svc} ${t.ckConfigBad}: ${cfg.message || ''}` });
  } else if (cfg && cfg.ok === true) {
    out.push({ level: 'ok', text: `${svc} ${t.ckConfigOk}` });
  }
  return out;
}

function certCheck(t, host) {
  if (!host) return [];
  if (!CERTS) return [{ level: 'unknown', text: t.ckCertUnknown }];
  if (!CERTS.has(host)) return [{ level: 'warn', text: t.ckCertMissing }];
  const rec = CERTS.get(host);
  const days = Number(rec.days);
  const out = [];
  if (days < 7)       out.push({ level: 'bad',  text: t.ckCertDays.replace('%d', days) });
  else if (days < 21) out.push({ level: 'warn', text: t.ckCertDays.replace('%d', days) });
  else                out.push({ level: 'ok',   text: t.ckCertDays.replace('%d', days) });
  // A staging certificate is not a fault: it is the intended state until the
  // row has been checked. It is warn so that it cannot be mistaken for live.
  if (rec.staging === true) {
    out.push({ level: 'warn', text: rec.verified === true ? t.ckCertTestReady : t.ckCertTest });
  }
  return out;
}

// Everything known about one row, as a list of checks. The pill takes the
// worst; the tooltip shows all of them, so a red pill always says why.
function rowChecks(t, e) {
  if (!STATUS || !STATUS_FRESH) return [{ level: 'unknown', text: t.st_unknown }];
  const out = [];

  if (e.kind === 'app') {
    if (!UNITS) {
      out.push({ level: 'unknown', text: t.st_unknown });
    } else {
      const u = UNITS.get(`app-${e.name}${SUFFIX[e.env] ?? ''}.service`);
      if (!u)                          out.push({ level: 'warn', text: t.st_absent });
      else if (u.active === 'active')  out.push({ level: 'ok',   text: t.st_running });
      else if (u.active === 'activating') out.push({ level: 'bad', text: t.st_restarting });
      else                             out.push({ level: 'warn', text: t.st_stopped });
    }
    // A Kestrel port is reached through Apache and must NOT be open to the
    // world. Listening is the check; a firewall hole is the fault.
    if (e.port && FW && Array.isArray(FW.ports) && FW.ports.includes(e.port)) {
      out.push({ level: 'bad', text: t.ckPortExposed.replace('%d', e.port) });
    }
    out.push(...certCheck(t, e.addr));
  }

  if (e.kind === 'website' || e.kind === 'proxy') {
    out.push(...serviceChecks(t, 'apache2'));
    if (!VHOSTS) {
      out.push({ level: 'unknown', text: t.ckVhostUnknown });
    } else if (!VHOSTS.has(`${e.name}-${e.env}`)) {
      out.push({ level: 'warn', text: t.ckVhostOff });
    } else {
      out.push({ level: 'ok', text: t.ckVhostOn });
    }
    out.push(...certCheck(t, e.addr));
  }

  if (e.kind === 'mailbox') {
    out.push(...serviceChecks(t, 'postfix'));
    out.push(...serviceChecks(t, 'dovecot'));
  }

  // The firewall being off is a fact about the machine, so it lands on every
  // row rather than on one of them.
  if (FW && FW.active === false) {
    out.push({ level: 'warn', text: t.ckFirewallOff });
  }

  return out.length ? out : [{ level: 'unknown', text: t.st_unknown }];
}

// A machine page is a port and nothing else: no unit name, no vhost, no
// certificate of its own.
function panelChecks(t, port) {
  if (!STATUS || !STATUS_FRESH || !LISTEN) return [{ level: 'unknown', text: t.st_unknown }];
  if (!port) return [];
  return LISTEN.has(Number(port))
    ? [{ level: 'ok',   text: t.ckListening.replace('%d', port) }]
    : [{ level: 'bad',  text: t.ckNotListening.replace('%d', port) }];
}

// The machine's own panels: settings at the top of the file rather than rows.
// They hold ports, and nothing else on this page would say so, which is how a
// collision between one of them and a row would go unnoticed.
// The legend used to spell out "10000 Webmin, 10001 this page, 10002 Jenkins"
// in both languages, so it could disagree with the file and nothing would say
// so. It is the same data the Machine pages tab shows.
// The next free port, one past the highest already in use in the same half of
// the file. Panels and rows are counted apart: a machine page belongs after
// the other machine pages, not after the highest application.
function nextPort(scope, kind) {
  // EVERY environment of every row, not just the base. A row's port is its LIVE
  // port and each environment subtracts its offset, so 11003 also means 10003,
  // 9003 and 8003. Counting the base alone is how a new row was handed 11003 on
  // 2026-09-07: its accept port landed on 10003, the GitHub webhook door, and
  // the save was refused by check_config.sh after the fact.
  const used = new Set();
  const take = base => {
    if (!base) return;
    used.add(base);
    ENVS.forEach(e => used.add(base + (OFFSET[e] ?? 0)));
  };
  rows.forEach(r => take(Number(r.f[2])));
  panelEntries().forEach(e => { if (e.port) used.add(e.port); });

  const free = n => {
    if (used.has(n)) return false;
    return ENVS.every(e => !used.has(n + (OFFSET[e] ?? 0)));
  };

  // The band, derived from the offsets rather than written down: live is 0 and
  // the highest band, so measuring from the lowest offset puts skunk at 5000
  // and live at 8000. paintPortMap() does the same sum for the port map.
  const offs = ENVS.map(e => OFFSET[e] ?? 0);
  const floor = Math.min(...offs, 0);
  const liveBand = 5000 + (0 - floor);

  // An application belongs in the live band whatever else is on the machine.
  // Taking the highest port of ANY row could only ever count upward, so one
  // proxy row naming a service at 11002 moved every later application out of
  // the scheme for good.
  //
  // A proxy is not in the scheme at all: its port is the port the service it
  // forwards to actually listens on, so it keeps the old highest+1 suggestion.
  if (scope === 'row' && kind === 'app') {
    for (let n = liveBand + 1; n < liveBand + 1000; n++) {
      if (free(n)) return String(n);
    }
    return '';
  }

  const mine = scope === 'panel'
    ? panelEntries().map(e => e.port)
    : rows.map(r => Number(r.f[2]));

  const highest = Math.max(0, ...mine.filter(n => n > 0));
  if (!highest) return '';

  let n = highest + 1;
  while (!free(n) && n < 65535) n++;
  return String(n);
}

// What is actually taken, band by band. Built from the rows rather than kept as
// a list, because a written-down list of reserved ports is wrong the first time
// somebody adds a row without updating it.
//
// One line per config row, one column per environment band. A cell holds the
// port that row has in that band, linked to the address that actually answers
// today: the LAN preview port, because no public hostname resolves here until
// the drive swap.
function paintPortMap() {
  const t = T[lang];
  const el = document.getElementById('port-map');
  if (!el) return;

  // The offsets are relative to live, which is 0 and the HIGHEST band, so they
  // are negative. The band is the offset measured from the lowest one, not the
  // offset itself: reading it directly labelled live as 5000.
  const offs = ENVS.map(e => OFFSET[e] ?? 0);
  const floor = Math.min(...offs, 0);
  const bandOf = env => 5000 + ((OFFSET[env] ?? 0) - floor);
  const bands = ENVS.slice().sort((a, b) => bandOf(a) - bandOf(b));

  // Keyed by row so a row's four environments line up on one line, which is the
  // whole point: the last three digits are the thing to recognise.
  const byRow = new Map();
  ['app', 'website', 'proxy'].forEach(kind =>
    entries(kind).filter(e => e.port && !e.deleted).forEach(e => {
      if (!byRow.has(e.row)) byRow.set(e.row, { name: e.name, kind: e.kind, cells: {} });
      byRow.get(e.row).cells[e.env] = e;
    }));

  if (!byRow.size) { el.innerHTML = `<tr><td class="note">${esc(t.portsNone)}</td></tr>`; return; }

  const cell = e => {
    if (!e) return '<td><span class="dash">&mdash;</span></td>';
    const label = esc(String(e.port)) + (e.addr ? ' ' + esc(e.addr) : '');
    // Only a row with a preview port has somewhere to send a click today.
    if (!e.preview) return `<td class="port">${label}</td>`;
    return `<td class="port"><a href="http://${esc(location.hostname)}:${esc(e.preview)}/"
      target="_blank" rel="noopener">${label}</a></td>`;
  };

  const head = '<tr><th>' + esc(t.bandRange) + '</th>'
             + bands.map(b => `<th>${bandOf(b)}&ndash;${bandOf(b) + 999}</th>`).join('')
             + '</tr>';

  const body = [...byRow.values()]
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(r => `<tr><td class="name">${esc(r.name)}</td>`
            + bands.map(b => cell(r.cells[b])).join('') + '</tr>')
    .join('');

  el.innerHTML = head + body;

  // Preview ports, by ENVIRONMENT rather than by band. A website row carries no
  // port of its own, so it was absent from the map above and its previews, which
  // are named outright in PREVIEW_ROWS, appeared nowhere at all. Those numbers
  // need not sit in the 20000 band either: 17900 is a real one on this machine.
  const prev = document.getElementById('port-map-preview');
  if (prev) {
    const byPrev = new Map();
    ['app', 'website', 'proxy'].forEach(kind =>
      entries(kind).filter(e => !e.deleted && (e.preview || e.port)).forEach(e => {
        if (!byPrev.has(e.row)) byPrev.set(e.row, { name: e.name, cells: {} });
        byPrev.get(e.row).cells[e.env] = e;
      }));

    // Reserved but not served: the number the row would take if its preview were
    // switched on. Only inside the four-digit scheme, so the jenkins proxy on
    // 11002 reserves nothing rather than the meaningless 31002.
    const reserved = e => {
      const base = parseInt(e.port, 10);
      if (isNaN(base) || base >= 10000) return null;
      return PREVBASE + base + (parseInt(OFFSET[e.env], 10) || 0);
    };
    const prevCell = e => {
      if (!e) return '<td><span class="dash">&mdash;</span></td>';
      if (e.preview) {
        return `<td class="port"><a href="http://${esc(location.hostname)}:${esc(e.preview)}/"
          target="_blank" rel="noopener">${esc(String(e.preview))}</a></td>`;
      }
      const n = reserved(e);
      if (n === null) return '<td><span class="dash">&mdash;</span></td>';
      return `<td class="port"><span class="dash"
        title="${esc(t.sPreviewOff)}">${esc(String(n))}</span></td>`;
    };
    prev.innerHTML = '<tr><th></th>'
      + ENVS.map(b => `<th>${esc(b)}</th>`).join('') + '</tr>'
      + [...byPrev.values()].sort((a, b) => a.name.localeCompare(b.name))
          .map(r => `<tr><td class="name">${esc(r.name)}</td>`
                  + ENVS.map(b => prevCell(r.cells[b])).join('') + '</tr>').join('');
  }

  // The bands above 9999 have no environments: one page, one port. They are
  // listed separately rather than squeezed into a column that means nothing.
  const fixed = document.getElementById('port-map-fixed');
  if (!fixed) return;
  const panels = panelEntries().filter(e => e.port !== null && !e.deleted)
                              .sort((a, b) => a.port - b.port);
  fixed.innerHTML = '<tr><th>' + esc(t.bandRange) + '</th><th>' + esc(t.bandMeans) + '</th></tr>'
    + panels.map(e => `<tr>
        <td class="port"><a href="http://${esc(location.hostname)}:${esc(e.port)}/"
          target="_blank" rel="noopener">${esc(String(e.port))}</a></td>
        <td>${esc(e.name)}${e.enabled === 'no' ? ` <span class="chip off">${esc(t.chipOff)}</span>` : ''}</td>
      </tr>`).join('');
}

function paintBandList() {
  const el = document.getElementById('band10-list');
  if (!el) return;
  el.textContent = panelEntries()
    .filter(e => e.port !== null)
    .sort((a, b) => a.port - b.port)
    .map(e => e.port + ' ' + e.name)
    .join(', ');
}

// Every page, including the ones switched off: a page with no port still has to
// be visible, or there is no way to switch it back on.
function panelEntries() {
  return PANELS.map(p => {
    const s = panelState(p);
    const wasPort = p.value === null ? null : Number(p.value);
    const deleted = panelGone.has(p.id);
    return {
      kind: 'panel', name: s.label, env: null,
      // Only a page THIS repo serves can be said to have a login in front of
      // it. A page its own installer serves may well have one, and whether it
      // does is not ours to claim.
      port: s.port, addr: null, locked: s.serves !== 'itself' && s.login !== 'no',
      row: null, panel: p, deleted,
      serves: s.serves, target: s.target, login: s.login,
      // Held in its own map rather than on the panel, because it is written to
      // a settings line and not to the PANEL line.
      enabled: panelOff.has(p.id) ? 'no' : (p.enabled || 'yes'),
      dirty: !deleted && (s.port !== wasPort || s.label !== p.label
                          || s.serves !== p.serves || s.target !== p.target
                          || s.login !== p.login)
    };
  });
}

// A mailbox is an address and a folder. Its domain is the Subdomain field taken
// literally, not as a subdomain: '-' means the base domain, which is what
// hostings.conf says under MAILBOXES.
function mailEntries() {
  return rows.map((r, i) => {
    if (r.f[0] !== 'mailbox' || !maySeeRow(r)) return null;
    const domain = blank(r.f[4]) ? BASE : r.f[4].replace(/^=/, '');
    return {
      kind: 'mailbox', name: r.f[1], domain,
      addr: r.f[1] + '@' + domain,
      store: MAILROOT + '/' + domain + '/' + r.f[1],
      row: i, deleted: r.deleted || rowDropped(r), dirty: r.dirty
    };
  }).filter(Boolean);
}

// The address is the link, so the row does not need a column holding an icon
// that goes to the same place. A panel has no hostname, so its "this machine
// only" is what carries the link to its port.
function addressCell(e, t, url) {
  const label = e.addr ? esc(e.addr) : esc(e.panel ? t.panelLocal : t.notPublished);
  if (!url) return `<span class="dash">${label}</span>`;
  return `<a class="addr" href="${esc(url)}" target="_blank" rel="noopener"
             title="${esc(t.aOpen)}">${e.addr ? label : `<span class="dash">${label}</span>`}</a>`;
}

// Edit and delete look the same in both tables, so they are written once.
// One button per ENVIRONMENT row, not one per row: a deploy is per environment,
// and a picker would make the operator say twice what the line already says.
// The owner, 2026-09-10.
//
// Only where there is something to re-run: a row with no repository is served
// off disk and Jenkins has no deploy job for it, and a row still being edited
// has nothing on the machine yet.
// Elapsed time the way a person says it. Under a minute is seconds, because
// "0m 47s" is not what anybody asks.
function humanMs(ms) {
  if (!ms || ms < 0) return '';
  const s = Math.round(ms / 1000);
  if (s < 60) return s + 's';
  const m = Math.floor(s / 60);
  return m + 'm ' + String(s % 60).padStart(2, '0') + 's';
}

// A clock, not a date: 14:07:31 is what an operator compares against their own
// memory of when they pressed the button.
function clockOf(ts) {
  if (!ts) return '';
  return new Date(ts).toLocaleTimeString(lang === 'nl' ? 'nl-NL' : 'en-GB');
}


// Jenkins' own words, in the operator's. ABORTED in particular: the owner pressed
// Cancel and was told the build was "aborted", which is the same event named
// twice. NOT_BUILT is the commonest result here and says nothing at all on its
// own, so it says what actually happened instead.
function resultWord(r, t) {
  if (!r) return t.pipeRunning;
  return t.pipeWords[r] || r;
}

// The last build of this environment's deploy job, in the row. The owner,
// 2026-09-10: the pipeline's state belongs beside the row it deploys rather
// than only inside a dialog somebody has to open.
//
// A row with no repository has no deploy job, so it gets a dash, not a blank:
// blank reads as "nobody looked".
// The last build of one row's deploy job, or null when the row has no job to
// have built anything.
function lastBuildOf(e) {
  if (e.dirty || e.deleted || !e.env || !e.repo) return null;
  const job = (typeof SITEJOBS !== 'undefined' && SITEJOBS) ? SITEJOBS[e.name] : null;
  return (job && job.jobs) ? job.jobs['deploy-' + e.env] : null;
}

// The last five builds as dots, newest first. A single result cannot tell "it
// failed" from "it has been failing all morning", and that difference is the
// whole reason anybody opens the job.
function recentDots(one, t) {
  return (one.recent || []).slice(0, 5).map(b => {
    const d = b.result === 'SUCCESS' ? 'ok'
            : b.result === null ? 'run'
            : b.result === 'NOT_BUILT' ? 'none'
            : b.result === 'ABORTED' ? 'none' : 'bad';
    const dTip = '#' + b.number + ' ' + resultWord(b.result, t)
               + (b.duration ? ' · ' + humanMs(b.duration) : '')
               + (b.started ? ' · ' + clockOf(b.started) : '');
    return `<i class="bdot ${d}" title="${esc(dTip)}"></i>`;
  }).join('');
}

function cPipeline(e, t, withDots) {
  if (e.dirty || e.deleted || !e.env || !e.repo) {
    return '<td class="pipe-col"><span class="dash">&mdash;</span></td>';
  }
  const one = lastBuildOf(e);
  if (!one || (!one.started && !one.result && !one.running)) {
    return `<td class="pipe-col"><span class="chip" title="${esc(t.pipeNever)}">${esc(t.pipeNone)}</span></td>`;
  }
  const cls = one.running ? 'run'
            : (one.result === 'SUCCESS' ? 'up'
            : (one.result === 'NOT_BUILT' ? '' : 'down'));
  // Clamped: the start time is the machine's clock and Date.now() is the
  // browser's, and a build younger than the skew between them came out
  // negative. Measured 2026-09-10: 9 seconds apart.
  const ran = one.running ? Math.max(0, Date.now() - one.started) : one.duration;
  const tip = [
    one.started ? t.redeployTiming.replace('%t', clockOf(one.started))
                                  .replace('%d', humanMs(ran) || '?') : '',
    one.number ? '#' + one.number : ''
  ].filter(Boolean).join('\n');
  // In the Pipeline view the dots have a column of their own, so the word does
  // not carry them.
  const dots = withDots ? recentDots(one, t) : '';

  // A status, not a control. Reading the console is the log button in the row's
  // actions: the owner, 2026-09-10, "can we not just add the build history button
  // and show the Jenkins console output if it is running".
  return `<td class="pipe-col"><span class="chip ${cls}"
    title="${esc(tip)}">${esc(resultWord(one.result, t))}</span>${
    dots ? `<span class="bdots">${dots}</span>` : ''}</td>`;
}

// The dots alone, for the Pipeline view's own column.
function cRecent(e, t) {
  const one = lastBuildOf(e);
  const dots = one ? recentDots(one, t) : '';
  return `<td class="dots-col">${
    dots ? `<span class="bdots">${dots}</span>` : '<span class="dash">&mdash;</span>'}</td>`;
}

// What is deployed, and whether the branch has moved since. Two columns that
// exist only in the Pipeline view: there was never room for them beside the
// serving state, which is half of why the view was split.
//
// Asked per row on the first paint that shows it, never on page load: each one
// is a sudo call and a git ls-remote, and most visits never open the tab.
const DEPLOYED = {};             // "row env" -> { deployed, head, behind, branch }
const DEPLOYASKED = new Set();

function deployKey(e) { return e.name + '::' + e.env; }

async function askDeployed(e) {
  const key = deployKey(e);
  if (DEPLOYASKED.has(key)) return;
  DEPLOYASKED.add(key);
  try {
    const r = await fetch('?ask=deployed&row=' + encodeURIComponent(e.name)
                          + '&env=' + encodeURIComponent(e.env),
                          { headers: { 'Accept': 'application/json' } });
    DEPLOYED[key] = await r.json();
  } catch (_) {
    DEPLOYASKED.delete(key);     // a failed ask may be worth making again
    return;
  }
  // Paint only the two cells this answers. A full render() would throw away
  // whatever else the operator has open.
  document.querySelectorAll(`[data-deployed="${cssEsc(key)}"]`).forEach(td => {
    td.outerHTML = cDeployed(e, T[lang]);
  });
  document.querySelectorAll(`[data-behind="${cssEsc(key)}"]`).forEach(td => {
    td.outerHTML = cBehind(e, T[lang]);
  });
}

// The key holds a row name and an environment, both of which check_config.sh
// restricts to [A-Za-z0-9._-], so this only has to survive the :: joiner.
function cssEsc(s) {
  return (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/[^\w-]/g, '\\$&');
}

function cDeployed(e, t) {
  if (e.dirty || e.deleted || !e.env || !e.repo) {
    return '<td class="sha-col"><span class="dash">&mdash;</span></td>';
  }
  const key = deployKey(e);
  const j = DEPLOYED[key];
  if (!j) {
    return `<td class="sha-col" data-deployed="${esc(key)}"><span class="dash">…</span></td>`;
  }
  if (!j.deployed) {
    return `<td class="sha-col" data-deployed="${esc(key)}"
      ><span class="dash" title="${esc(t.deployedNone)}">&mdash;</span></td>`;
  }
  return `<td class="sha-col" data-deployed="${esc(key)}"
    ><code title="${esc(j.deployed)}">${esc(String(j.deployed).slice(0, 7))}</code></td>`;
}

function cBehind(e, t) {
  if (e.dirty || e.deleted || !e.env || !e.repo) {
    return '<td class="behind-col"><span class="dash">&mdash;</span></td>';
  }
  const key = deployKey(e);
  const j = DEPLOYED[key];
  if (!j || !j.deployed) {
    return `<td class="behind-col" data-behind="${esc(key)}"></td>`;
  }
  const branch = j.branch || e.env;
  // behind === null is a lookup that failed, and that is NOT "up to date":
  // saying so on a failed check is the one answer nobody could catch being
  // wrong.
  if (j.behind === true) {
    return `<td class="behind-col" data-behind="${esc(key)}"><span class="pill lv-warn"
      title="${esc(t.deployedBehind.replace('%d', String(j.deployed).slice(0, 7))
                                   .replace('%h', String(j.head || '').slice(0, 7))
                                   .replace('%b', branch))}"
      >${esc(t.behindMoved)}</span></td>`;
  }
  if (j.behind === false) {
    return `<td class="behind-col" data-behind="${esc(key)}"><span class="pill lv-ok"
      title="${esc(t.deployedCurrent.replace('%d', String(j.deployed).slice(0, 7))
                                    .replace('%b', branch))}"
      >${esc(t.behindCurrent)}</span></td>`;
  }
  return `<td class="behind-col" data-behind="${esc(key)}"><span class="pill lv-unknown"
    title="${esc(t.deployedUnknown.replace('%d', String(j.deployed).slice(0, 7)))}"
    >${esc(t.behindUnknown)}</span></td>`;
}

function redeployButton(e, t) {
  if (e.dirty || e.deleted || !e.env || !e.repo) return '';
  const job = (typeof SITEJOBS !== "undefined" && SITEJOBS) ? SITEJOBS[e.name] : null;
  const one = job && job.jobs ? job.jobs['deploy-' + e.env] : null;
  const running = !!(one && one.running);
  // When the last build started and how long it took, on the button's own
  // tooltip. The owner asked for both by name: they answer "is this stale" without
  // opening anything, which is the whole point of putting them here.
  //
  // duration is 0 while a build runs, because Jenkins fills it in at the end,
  // so a running one counts from its start instead.
  const timing = (one && one.started)
    ? '\n' + t.redeployTiming
        .replace('%t', new Date(one.started).toLocaleTimeString(lang === 'nl' ? 'nl-NL' : 'en-GB'))
        .replace('%d', humanMs(one.running ? Math.max(0, Date.now() - one.started) : one.duration) || '0s')
    : '';
  // A switched-off row skips every stage, so the job finishes NOT_BUILT and the
  // dialog closes with nothing said. Say why instead of offering a press that
  // cannot do anything.
  const off = rowOff(e);
  const label = off ? t.aRedeployOff
                    : (running ? t.aRedeployBusy : t.aRedeploy.replace('%e', e.env)) + timing;
  // Not disabled while it runs: pressing it then opens the dialog on the
  // running build, which is where Cancel is.
  return `<button class="icon-btn" type="button"${off ? ' disabled' : ''}
      data-redeploy-row="${esc(e.name)}" data-redeploy-env="${esc(e.env)}"
      title="${esc(label)}" aria-label="${esc(label)}">${I.update}</button>`;
}

// The build history and, while one is running, its console as it goes. It never
// starts anything: that is the button beside it. The owner, 2026-09-10, after a
// deploy a GitHub push had started could only be read by pressing the button
// that re-runs it.
function watchButton(e, t) {
  if (e.dirty || e.deleted || !e.env || !e.repo) return '';
  const one = lastBuildOf(e);
  if (!one || (!one.started && !one.result && !one.running)) return '';
  const label = (one.running ? t.aWatchBusy : t.aWatch).replace('%e', e.env);
  return `<button class="icon-btn" type="button"
      data-watch-row="${esc(e.name)}" data-watch-env="${esc(e.env)}"
      title="${esc(label)}" aria-label="${esc(label)}">${I.log}</button>`;
}

// Stop a build from the row it belongs to. The owner, 2026-09-10: pressing Re-run
// no longer opens anything, so the only way to stop what it started must not be
// inside a dialog either.
//
// Only while THIS environment is building: the folder-wide state paints four
// rows for one build, which is the fault item 103 records.
function cancelButton(e, t) {
  if (e.dirty || e.deleted || !e.env || !e.repo) return '';
  const one = lastBuildOf(e);
  if (!one || !one.running) return '';
  const label = t.aCancelBuild.replace('%e', e.env);
  return `<button class="icon-btn danger" type="button"
      data-cancel-row="${esc(e.name)}" data-cancel-env="${esc(e.env)}"
      title="${esc(label)}" aria-label="${esc(label)}">${I.stop}</button>`;
}
// The pipeline controls live in the PIPELINE view only, 2026-09-10: the owner saw
// Re-run in the Websites table and the Applications table beside the serving
// state, where they answer a different question than the rest of the row.
// The cog on a mailbox row: what to type into Outlook or a phone. It carries
// the ADDRESS, because that is what a mail client signs in with, and the row
// name as well, because every row-bound ask is permission-checked by row.
function mailCfgButton(e) {
  const addr = e.name + '@' + e.domain;
  const t = T[lang];
  return `<button class="icon-btn" type="button" data-mailcfg="${esc(addr)}"
            data-mailcfg-row="${e.row}"
            title="${esc(t.aMailCfg)}" aria-label="${esc(t.aMailCfg)}">${I.cog}</button>`;
}

// A mailbox's own 1Password item, to an address typed at the press: the
// person reading info@ need not be the domain's owner. Full access only, as the
// person Share on the Users tab is.
function mailShareButton(e) {
  if (typeof MYROLE !== 'undefined' && MYROLE !== 'full') return '';
  const addr = e.name + '@' + e.domain;
  const t = T[lang];
  return `<button class="icon-btn" type="button" data-mailshare="${esc(addr)}"
            data-mailshare-owner="${esc(DOMAINOWNERS[e.domain] || ADMIN)}"
            title="${esc(t.mShare)}" aria-label="${esc(t.mShare)}">${I.lock}</button>`;
}

function actions(e, t, url, extra, pipeline) {
  return `<td><span class="row-actions">
    ${pipeline ? cancelButton(e, t) : ''}
    ${pipeline ? watchButton(e, t) : ''}
    ${pipeline ? redeployButton(e, t) : ''}
    ${extra ? extra(e) : ''}
    ${url ? `<a class="icon-btn" href="${esc(url)}" target="_blank" rel="noopener"
                title="${esc(t.aOpen)}" aria-label="${esc(t.aOpen)}">${I.open}</a>` : ''}
    ${e.row === null || e.row === undefined ? '' : `
      <button class="icon-btn" type="button" data-edit="${e.row}" title="${esc(t.aEdit)}" aria-label="${esc(t.aEdit)}">${I.edit}</button>
      ${
        // The trashcan lives behind Edit, per disable-and-bulk-decisions.md.
        // Undo is not gated: a row already marked for deletion must be
        // reversible from wherever it is seen, or leaving edit mode strands it.
        (e.deleted || (typeof EDITMODE !== 'undefined' && EDITMODE))
        ? `<button class="icon-btn ${e.deleted ? '' : 'danger'}" type="button" data-del="${e.row}"
              title="${esc(e.deleted ? t.aKeep : t.aDelete)}"
              aria-label="${esc(e.deleted ? t.aKeep : t.aDelete)}">${e.deleted ? I.undo : I.trash}</button>`
        : ''}`}
  </span></td>`;
}

// `off` is not a pending edit like `edited`: it is what the row IS, so it
// survives a reload and is painted even on a row nobody has touched.
const rowOff = e => {
  // A machine page is not a config row: its state is its own `enabled`, and a
  // page with no port cannot be served whatever the field says.
  if (e.panel) return e.enabled === 'no' || e.port === null;
  const r = (e.row === null || e.row === undefined) ? null : rows[e.row];
  return !!r && String((r.f && r.f[14]) || 'yes').trim().toLowerCase() === 'no';
};
// The sweeping gradient was only ever applied to a row somebody had just
// pressed a button on. A unit coming up on its own, which is most of them after
// a deploy, looked exactly like a dead one. Same class, same animation, driven
// by systemd's state instead of by a click.
// Running or not, from systemd's own word. Used by the status column and by
// the enabled state of the row-wide pair, so the two can never disagree.
const unitIsUp = e => {
  if (e.kind !== 'app' || !UNITS) return false;
  const u = UNITS.get(`app-${e.name}${SUFFIX[e.env] ?? ''}.service`);
  return !!u && u.active === 'active';
};

// Something Start could honestly act on. A disabled row is off on purpose, and
// a row with no unit shows a dash in the State column, so neither counts.
const unitStartable = e => {
  if (e.kind !== 'app' || e.dirty || e.deleted || rowOff(e) || !UNITS) return false;
  const u = UNITS.get(`app-${e.name}${SUFFIX[e.env] ?? ''}.service`);
  return !!u && u.active !== 'active';
};

const unitBusy = e => {
  if (e.kind !== 'app' || !UNITS || e.dirty || e.deleted) return false;
  const u = UNITS.get(`app-${e.name}${SUFFIX[e.env] ?? ''}.service`);
  return !!u && (u.active === 'activating' || u.sub === 'auto-restart');
};

// A JENKINS JOB COUNTS AS BUSY TOO, queued as well as building.
//
// The gradient only ever followed systemd, so a row was still until the very
// end: a deploy queues behind the two executors, builds for a minute or more,
// and only in the last second does the unit go `activating`. jenkins_job_status
// folds inQueue and lastBuild.building into one flag, so waiting for an
// executor sweeps as well, which is the half a person is most likely to read
// as nothing happening. The owner asked for it 2026-09-09.
//
// PER ENVIRONMENT WHERE THERE IS A PER-ENVIRONMENT ANSWER, folder-wide only
// where there is not. It was folder-wide for everything until 2026-09-10,
// because the status call had no per-job detail to offer.
//
// That is why a row swept on all four lines at once while one environment
// deployed, and it is half of what item 103 reports as "rows sweeping with
// nothing running": nothing was running ON THAT LINE, which is the only thing
// a line can honestly claim.
//
// The folder-wide flag is kept as the fallback, and it is not a leftover: the
// three set-up jobs belong to the whole row, so a row being provisioned still
// sweeps everywhere, which is correct.
const jobBusy = e => {
  if (e.dirty || e.deleted) return false;
  const j = (typeof SITEJOBS !== 'undefined' && SITEJOBS) ? SITEJOBS[e.name] : null;
  if (!j) return false;
  const mine = e.env && j.jobs ? j.jobs['deploy-' + e.env] : null;
  if (mine) {
    // This line's own deploy decides it, unless something outside the
    // per-environment jobs is running, which only the folder can see.
    const anyDeployRunning = Object.keys(j.jobs)
      .filter(n => n.indexOf('deploy-') === 0)
      .some(n => j.jobs[n].running);
    return mine.running || (!!j.running && !anyDeployRunning);
  }
  return !!j.running;
};

const rowClass = e =>
  (e.deleted ? 'gone' : (e.dirty ? 'edited' : '')) + (rowOff(e) ? ' off' : '')
  + ((unitBusy(e) || jobBusy(e)) ? ' working live-busy' : '');

// Empty until something has been touched, in both tables. What it says is that
// the line differs from the file on disk, which is exactly what Save writes.
// A row on its way out says only that. Otherwise the two facts are independent
// and both are shown: `edited` is a pending change, `Disabled` is what the row
// currently IS, which is the pair you get when a row is switched off in an
// edit that has not been applied yet.
function stateChip(e, t) {
  if (e.deleted) return `<span class="chip removed">${esc(t.chipRemoved)}</span>`;
  const out = [];
  if (e.dirty)  out.push(`<span class="chip edited">${esc(t.chipEdited)}</span>`);
  if (rowOff(e)) out.push(`<span class="chip off">${esc(t.chipOff)}</span>`);

  // STARTING, which the table never said. An application spends a minute or
  // two between "deployed" and "answering", and the row looked identical to a
  // dead one for all of it. Two states, from systemd's own words:
  //   activating          it is coming up, or restarting after a crash
  //   auto-restart        it died and systemd is trying again
  // The owner, 2026-09-07: "there is no UI indication the applications are
  // starting".
  const u = (e.kind === 'app' && UNITS)
    ? UNITS.get(`app-${e.name}${SUFFIX[e.env] ?? ''}.service`) : null;
  if (u && u.active === 'activating') {
    out.push(`<span class="chip busy" title="${esc(t.chipStartingTip)}">${esc(t.chipStarting)}</span>`);
  } else if (u && u.sub === 'auto-restart') {
    out.push(`<span class="chip bad" title="${esc(t.chipRetryTip)}">${esc(t.chipRetry)}</span>`);
  }

  // WHAT JENKINS SAYS ABOUT THIS ROW, which the page never showed. A build
  // that fails deploys nothing, so the row reads exactly like one that was
  // never created and gives no reason. Measured 2026-09-09: every
  // example_net build had failed on a wrong dll path for a day and
  // nothing on this page said so.
  //
  // PER ENVIRONMENT, since 2026-09-10. It used to be one chip per ROW, because
  // jenkins_job_status.sh folds a folder's jobs into the worst result it holds
  // and the folder is the row. That reads as four broken environments when one
  // deploy failed: the owner's accept build failed and live, test and skunk all
  // said 'build failed' beside a Pipeline column reading 'No change'.
  //
  // Same fault as item 103, which fixed the sweep and left this behind. The
  // folder result stays as the fallback for a line with no environment.
  const folder = (typeof SITEJOBS !== 'undefined' && SITEJOBS) ? SITEJOBS[e.name] : null;
  const jb = (e.env && folder && folder.jobs && folder.jobs['deploy-' + e.env])
    ? folder.jobs['deploy-' + e.env]
    : folder;
  if (jb && jb.running) {
    out.push(`<span class="chip busy" title="${esc(t.chipBuildingTip)}">${esc(t.chipBuilding)}</span>`);
  } else if (jb && jb.result === 'FAILURE') {
    // The rerun sits beside the failure too, not only on the Pipeline view.
    // The owner, 2026-09-19.
    out.push(`<span class="chip bad" title="${esc(t.chipBuildBadTip)}">${esc(t.chipBuildBad)}</span>`
      + redeployButton(e, t));
  } else if (jb && jb.result === 'UNSTABLE') {
    out.push(`<span class="chip warn" title="${esc(t.chipBuildWarnTip)}">${esc(t.chipBuildWarn)}</span>`);
  }

  return out.join(' ');
}

// The certificate column: what state the certificate is in, and the one button
// that changes it, side by side. They were split across the row, the chip on
// the left and the button among edit and delete on the right, which read as two
// unrelated things.
// Is there anything to say about this row.s certificate? Only a test one, for
// now: a real certificate is the resting state and needs no column.
function certIssue(e) {
  if (!e.addr || !CERTS || !CERTS.has(e.addr)) return false;
  return CERTS.get(e.addr).staging === true;
}

// No certificate at all, which the cell used to leave blank: the state with the
// most to do about it was the one with no button. A row still being edited is
// excluded, because the address it would ask for is not the published one.
function certMissing(e) {
  return !!e.addr && e.kind !== 'mailbox' && e.row != null
      && !!CERTS && !CERTS.has(e.addr);
}

// Does the machine's answer belong to THIS line? Dirtiness is per row, so
// ticking skunk marked live edited too and blanked a certificate that had not
// moved. What decides it is the address: an environment that was already in the
// file, at the address it still has, is a line the machine can be asked about.
function certLineIsLive(e) {
  if (e.deleted || e.row == null || !e.addr) return false;
  const was = ROWWAS[e.row];
  if (!was) return false;
  const wasEnvs = blank(was[10]) ? ENVS
    : was[10].split(',').map(s => s.trim()).filter(Boolean);
  if (!wasEnvs.includes(e.env)) return false;
  const a = addresses(was[4], [e.env]).find(([en]) => en === e.env);
  return !!a && a[1] === e.addr;
}

// A real certificate was left blank, on the reasoning that it is the resting
// state. That held while blank meant only one thing. It now also means "no
// certificate, and not a row we can ask for one", so the resting state says it.
function certReal(e) {
  if (!e.addr || !CERTS || !CERTS.has(e.addr)) return false;
  return CERTS.get(e.addr).staging !== true;
}

const certActionable = e =>
  certLineIsLive(e) && (certIssue(e) || certMissing(e) || certReal(e));

// The button sits on every environment that has no certificate, because that
// is where a reader looks for it. One press still does the whole row: the job
// behind it requests every hostname the row declares.
const CERTASKED = new Set();

// One row name per paint, so the row-wide start and stop are drawn ONCE and not
// on all four of a row's environment lines. Cleared in paint(), the same way
// CERTASKED is: a Set that outlives a repaint would silently draw nothing on
// the second one.
const SVCALLDONE = new Set();

function certCell(e, t) {
  // A line the machine cannot be asked about says nothing: added in the browser,
  // removed, or at an address the file does not have yet.
  if (!certLineIsLive(e)) return '<td class="cert-col"></td>';
  if (certMissing(e)) {
    return `<td class="cert-col"><span class="row-actions">
      <button class="icon-btn text-btn" type="button" data-testcert="${esc(e.name)}"
              title="${esc(t.aTestCert + '\n' + t.sCertWholeRow.replace('%r', e.name))}"
              aria-label="${esc(t.aTestCert)}">${esc(t.bTestCert)}</button>
    </span></td>`;
  }
  if (certReal(e)) {
    const days = Number(CERTS.get(e.addr).days);
    return `<td class="cert-col"><span class="chip real"
      title="${esc(t.chipRealHint.replace('%d', days))}"
      aria-label="${esc(t.chipReal)}">${I.check}</span></td>`;
  }
  if (!certIssue(e)) return '<td class="cert-col"></td>';
  // One button, decided 2026-08-16. There was a tick in front of it, so a
  // person confirmed the site worked before an issuance could be spent. The
  // confirm dialog is now the only thing between a stray click and a real
  // certificate.
  return `<td class="cert-col"><span class="row-actions">
    <span class="chip removed" title="${esc(t.chipTestHint)}">${esc(t.chipTest)}</span>
    <button class="icon-btn text-btn danger" type="button" data-promote="${esc(e.addr)}"
            title="${esc(t.aGoLive)}" aria-label="${esc(t.aGoLive)}">${esc(t.bRealCert)}</button>
  </span></td>`;
}

// Rebuilt on every render, because adding a mailbox can add a domain. The
// current choice survives it, so the list does not jump back to all.
function fillDomainFilter(list) {
  const sel = document.getElementById('mail-domain-filter');
  const keep = sel.value;
  const domains = [...new Set(list.map(e => e.domain))].sort();
  sel.innerHTML = `<option value="">${esc(T[lang].allDomains)}</option>` +
    domains.map(d => `<option value="${esc(d)}"${d === keep ? ' selected' : ''}>${esc(d)}</option>`).join('');
}
document.getElementById('mail-domain-filter').addEventListener('change', render);

// Is there anything to discard? Asked of the things that track their own edits
// rather than by re-serialising and comparing: serialise() normalises as it
// writes, so an untouched page can come back differing from the file it was
// built from, and the button would then always be live.
function isDirty() {
  if (STAGED) return true;
  const raw = document.getElementById('raw');
  if (raw && raw.value !== raw.defaultValue) return true;
  if (rows.some(r => r.dirty || r.deleted)) return true;
  if (panelEntries().some(e => e.dirty || e.deleted)) return true;
  if (ENVGONE.size) return true;
  return ENVS.some(e =>
       (ENVBRANCH[e] || '') !== (ENVWAS.b[e] || '')
    || (PREFIX[e]    || '') !== (ENVWAS.p[e] || '')
    || (OFFSET[e]    ?? 0)  !== (ENVWAS.o[e] ?? 0));
}

// Like isDirty, but blind to mailbox rows. A mailbox writes no vhost and no
// unit and fast-saves on its own, so a changed mailbox is not a reason to show
// Make it live: showing it, disabled, during the fast-save was pure confusion.
function needsMachineApply() {
  if (STAGED) return true;
  const raw = document.getElementById('raw');
  if (raw && raw.value !== raw.defaultValue) return true;
  if (rows.some(r => (r.dirty || r.deleted) && r.f[0] !== 'mailbox')) return true;
  if (panelEntries().some(e => e.dirty || e.deleted)) return true;
  if (ENVGONE.size) return true;
  return ENVS.some(e =>
       (ENVBRANCH[e] || '') !== (ENVWAS.b[e] || '')
    || (PREFIX[e]    || '') !== (ENVWAS.p[e] || '')
    || (OFFSET[e]    ?? 0)  !== (ENVWAS.o[e] ?? 0));
}

// Called from render, and from the two editors that change state without one:
// the raw textarea and the environment fields.
function paintDiscard() {
  // The discard buttons live on every pane and are painted by paintEditCols,
  // which runs at the end of every render.
  if (typeof paintEditCols === 'function') paintEditCols();

  // Make it live is hidden when the last report said nothing differs, and it
  // comes straight back the moment anything that needs the machine is edited.
  // A mailbox change does not, so it never brings the button back.
  const a = document.getElementById('btn-apply');
  if (a && needsMachineApply()) { a.hidden = false; }
}

// The pane's Start all and Stop all follow the machine, exactly as the row-wide
// pair does: nothing to start means Start all is dead, and nothing running
// means Stop all is. Repainted on every render, so the status poll moves them
// without a reload.
function paintSvcPane() {
  const mine = entries('app').filter(x => !x.dirty && !x.deleted);
  const up   = mine.filter(unitIsUp).length;
  document.querySelectorAll('[data-svcpane]').forEach(b => {
    b.disabled = !mine.length
      || (b.dataset.svcpane === 'start' ? !mine.some(unitStartable) : up === 0);
  });
}

function render() {
  const t = T[lang];

  paintDiscard();

  // The cells every table shares, written once. Which of them a table uses is
  // the whole difference between the tables.
  const cPort  = e => `<td class="port">${e.port === null ? '<span class="dash">&mdash;</span>' : esc(e.port)}</td>`;
  // The name opens the preview when the row has one. Nothing else on the page
  // reaches a row by IP, and a link is where anyone looks first.
  const nameText = e => (e.preview && !e.dirty && !e.deleted)
    ? `<a href="http://${esc(location.hostname)}:${e.preview}/" target="_blank" rel="noopener"
         title="Open the preview on port ${e.preview}">${esc(e.name)}</a>`
    : esc(e.name);
  const cName  = e => `<td class="name">${nameText(e)}</td>`;
  // For tables with no environment pill to colour. A proxy is one service
  // however many environments exist, so it has no pill and would otherwise be
  // the only tab with no answer at all.
  const cNameState = e => {
    if (e.dirty || e.deleted) return cName(e);
    const checks = rowChecks(t, e);
    return `<td class="name"><span class="pill lv-${WORST(checks)}"
      title="${esc(checks.map(c => c.text).join('\n'))}">${nameText(e)}</span></td>`;
  };
  // What the page is made of, in words rather than the config's short token.
  // A page served by its own installer says so: it is the answer to "why is
  // there no folder here", which was otherwise only in the config comments.
  const cPanelServes = e => {
    const label = t.serves[e.serves] || e.serves;
    if (e.serves === 'itself') {
      return `<td><span class="env" title="${esc(t.sServesItself)}">${esc(label)}</span></td>`;
    }
    return `<td><span class="env" title="${esc(e.target)}">${esc(label)}</span></td>`;
  };
  const cLogin = e => `<td>${e.locked
    ? `<span class="lock" title="${esc(t.lockTitle)}">${I.lock}</span>`
    : '<span class="dash">&mdash;</span>'}</td>`;
  const cEnv   = e => {
    if (!e.env) return `<td><span class="env">${esc(t.always)}</span></td>`;
    // A row being added or edited has nothing on the machine yet, so its
    // checks would report faults that are really just unsaved changes.
    const live = !e.dirty && !e.deleted;
    const checks = live ? rowChecks(t, e) : [];
    const cls = ['env', e.inherited ? 'inherited' : esc(e.env)];
    if (live) cls.push('lv-' + WORST(checks));
    const hint = [
      ...checks.map(c => c.text),
      e.inherited ? t.inherited : ''
    ].filter(Boolean).join('\n');
    return `<td><span class="${cls.join(' ')}" title="${esc(hint)}">${esc(e.env)}</span></td>`;
  };
  // A LAN preview, coloured like its environment pill because it is the same
  // copy seen from the inside. Nothing to show is a dash, not a blank cell.
  const cPreview = e => {
    if (!e.preview) return `<td><span class="dash">&mdash;</span></td>`;
    const cls = ['env', e.inherited ? 'inherited' : esc(e.env)].join(' ');
    if (e.dirty || e.deleted) {
      return `<td><span class="${cls}" title="${esc(t.envIs.replace('%e', e.env) + '\n' + t.sPreviewPending)}">${esc(e.preview)}</span></td>`;
    }
    return `<td><a class="${cls}" href="http://${esc(location.hostname)}:${esc(e.preview)}/"
      target="_blank" rel="noopener"
      title="${esc(t.envIs.replace('%e', e.env))}">${esc(e.preview)}</a></td>`;
  };
  // Start, stop and restart, on app rows only: an application is the one kind
  // of row with a unit of its own. A row still being edited has nothing on the
  // machine to act on, so it gets none.
  const svcButtons = e => {
    if (e.dirty || e.deleted) return '';
    const u = UNITS ? UNITS.get(`app-${e.name}${SUFFIX[e.env] ?? ''}.service`) : null;
    const running = u && u.active === 'active';
    const btn = (verb, icon, label, tone) =>
      `<button class="icon-btn${tone}" type="button"
        data-svc="${verb}" data-svc-row="${esc(e.name)}" data-svc-env="${esc(e.env)}"
        title="${esc(label)}" aria-label="${esc(label)}">${icon}</button>`;
    // The journal, read only, whatever the row's state. A unit that will not
    // start is exactly the one whose log is wanted, so this is not hidden when
    // the row is stopped.
    const logBtn = `<button class="icon-btn" type="button"
        data-svclog data-svc-row="${esc(e.name)}" data-svc-env="${esc(e.env)}"
        title="${esc(t.aLog)}" aria-label="${esc(t.aLog)}">${I.log}</button>`;
    // THE ROW-WIDE PAIR FIRST, before Restart. Drawn once per row, so the
    // other lines of the row start straight at their own controls.
    //
    // Enabled by what is actually running: Start all is dead when every
    // environment of the row is already up, Stop all when they are all down.
    // A button that can only report that there was nothing to do is worse
    // than one that is visibly not for now.
    let allBtns = '';
    // ON THE LIVE LINE, always. It used to land on whichever line the sort put
    // first, so re-sorting the table moved a row-wide control onto a different
    // environment: the pair acts on the whole row and has to sit somewhere
    // predictable. The owner, 2026-09-09.
    //
    // A row that does not run in live keeps the old rule and takes its first
    // line, because a control that exists only sometimes is worse than one in
    // an unexpected place.
    const mine = entries('app').filter(x => x.name === e.name && !x.dirty && !x.deleted);
    const liveEnv = ENVS[0] || 'live';
    const homeEnv = mine.some(x => x.env === liveEnv) ? liveEnv
                  : (mine[0] ? mine[0].env : e.env);

    if (e.env === homeEnv && !SVCALLDONE.has(e.name)) {
      SVCALLDONE.add(e.name);
      if (mine.length > 1) {
        const pairs = mine.map(x => `${x.name}:${x.env}`).join(',');
        const up = mine.filter(x => unitIsUp(x)).length;
        const all = (verb, icon, label, tone, dead) =>
          `<button class="icon-btn${tone} svc-row-all" type="button"
            data-svcpairs="${esc(pairs)}" data-svcverb="${verb}"
            data-svcname="${esc(e.name)}"${dead ? ' disabled' : ''}
            title="${esc(label)}" aria-label="${esc(label)}">${icon}</button>`;
        allBtns = all('start', I.play, t.aStartAll.replace('%d', mine.length), ' go',
                      !mine.some(unitStartable))
                + all('stop', I.stop, t.aStopAll.replace('%d', mine.length), ' danger',
                      up === 0);
      }
    }
    return allBtns + (running
      ? btn('restart', I.update, t.aRestart, '') + btn('stop', I.stop, t.aStop, ' danger')
      : (rowOff(e) ? '' : btn('start', I.play, t.aStart, ' go'))) + logBtn;
  };

  const cCert  = e => certCell(e, t);

  const cState = e => `<td class="state-col">${stateChip(e, t)}</td>`;

  // RUNNING OR STOPPED, said in words. The row's colour and its sweep say
  // that something is happening; nothing said in the table what the unit's
  // state actually is, so a stopped row and a row with no unit at all read
  // the same. The owner, 2026-09-09.
  //
  // Empty for a row that is not on the machine yet: a pending row has no unit
  // to be up or down, and calling it stopped would be a claim about something
  // that does not exist.
  const cUnit = e => {
    if (e.dirty || e.deleted || !UNITS) return '<td class="unit-col"></td>';
    const u = UNITS.get(`app-${e.name}${SUFFIX[e.env] ?? ''}.service`);
    if (!u) return `<td class="unit-col"><span class="dash">&mdash;</span></td>`;
    const up = u.active === 'active';
    return `<td class="unit-col"><span class="chip ${up ? 'up' : 'down'}"
      title="${esc(u.active + (u.sub ? ' / ' + u.sub : ''))}">${
      esc(up ? t.chipRunning : t.chipStopped)}</span></td>`;
  };
  // A mailbox has no environment pill either. Mail is one pair of services for
  // the whole machine, so every mailbox carries the same answer, which is
  // honest: if dovecot is down, none of them work.
  const cMailName = e => {
    if (e.dirty || e.deleted) return `<td class="name local">${esc(e.name)}</td>`;
    const checks = rowChecks(t, e);
    return `<td class="name local"><span class="pill lv-${WORST(checks)}"
      title="${esc(checks.map(c => c.text).join('\n'))}">${esc(e.name)}</span></td>`;
  };
  // A machine page has no environment pill, so the name carries the state and
  // is also the link to the page. The port stays plain, like every other tab.
  const cPanelName = e => {
    // Switched off means there is nothing to open, so the name is not a link.
    if (e.port === null) {
      return `<td class="name"><span title="${esc(t.panelOffTitle)}">${esc(e.name)}</span></td>`;
    }
    const link = `<a href="http://${esc(location.hostname)}:${esc(e.port)}/"
      target="_blank" rel="noopener" title="${esc(t.aOpen)}">${esc(e.name)}</a>`;
    if (e.dirty) return `<td class="name">${link}</td>`;
    const checks = panelChecks(t, e.port);
    return `<td class="name"><span class="pill lv-${WORST(checks)}"
      title="${esc(checks.map(c => c.text).join('\n'))}">${link}</span></td>`;
  };
  const cAddr  = e => `<td>${addressCell(e, t, e.addr ? `https://${e.addr}/` : null)}</td>`;

  // The repository, as its own icon rather than a column of URLs: a clone URL
  // is fifty characters and the tables are already wide. The title carries
  // owner/name, which is the half that matters now there are two owners.
  const cRepo = e => {
    const raw = (e.row != null && rows[e.row] ? rows[e.row].f[8] : '') || '';
    const v = String(raw).trim();
    if (v === '' || v === '-') return '<td class="repo-col"></td>';
    // A row that has not been provisioned yet has nowhere to open.
    if (v.toLowerCase() === 'new') {
      return `<td class="repo-col"><span class="dash" title="${esc(t.repoPending)}">&mdash;</span></td>`;
    }
    // Both shapes the field accepts become the same browsable address.
    const slug = v
      .replace(/^git@[^:]+:/, '')
      .replace(/^https?:\/\/[^/]+\//, '')
      .replace(/\.git$/, '');
    if (!/^[^/]+\/[^/]+$/.test(slug)) return '<td class="repo-col"></td>';
    return `<td class="repo-col"><a href="https://github.com/${esc(slug)}"
      target="_blank" rel="noopener"
      title="${esc(slug + '\n' + t.aOpenRepo)}">${I.github}</a></td>`;
  };

  const paint = (id, kind, cells, extra) => {
    const list = sorted(entries(kind), SORT[id].col, SORT[id].asc);
    CERTASKED.clear();
    SVCALLDONE.clear();
    document.getElementById(id + '-body').innerHTML = list.map(e =>
      `<tr class="${rowClass(e)}" data-row="${e.row === null || e.row === undefined ? '' : e.row}">${cells.map(c => c(e)).join('')}${actions(e, t, null, extra, /-pipeline$/.test(id))}</tr>`
    ).join('');
    // A sub-view shares its tab's count, so only the first view of a pair has
    // a counter of its own to write.
    const counter = document.getElementById('count-' + id);
    if (counter) counter.textContent = list.length;
    // The Certificate column only exists while something in this table has a
    // test certificate. Once every row is promoted it is an empty column on
    // every screen, forever, saying nothing.
    const table = document.querySelector(`table[data-table="${id}"]`);
    if (table) table.classList.toggle('no-cert-col', !list.some(certActionable));
  };

  // What the deployed build targets. Empty until something is deployed, which
  // is honest: the answer lives in the build, so before a deploy there is none.
  const cRuntime = e => {
    // `!= null`, not a truthiness test: row 0 is a valid index and the first
    // application would otherwise lose its type.
    const declared = (e.row != null && rows[e.row] ? rows[e.row].f[13] : '') || 'dotnet';
    if (declared.toLowerCase() === 'node') {
      return `<td class="runtime"><span class="dash">Node</span></td>`;
    }
    const ver = RUNTIME_OF[`app-${e.name}${SUFFIX[e.env] ?? ''}.service`];
    if (!ver) return `<td class="runtime"><span class="dash">&mdash;</span></td>`;
    if (ver === 'self-contained') {
      return `<td class="runtime"><span title="${esc(t.rtSelf)}">${esc(t.rtSelfShort)}</span></td>`;
    }
    // ".NET 8" is what anyone would say out loud; the exact 8.0.29 goes in the
    // tooltip along with whether this machine can actually run it.
    const major = String(ver).split('.')[0];
    const ok = !DOTNET_HAVE || DOTNET_HAVE.some(h => String(h).split('.')[0] === major);
    const life = supportOf(major);
    const tip = t.rtNeeds.replace('%v', ver)
      + (DOTNET_HAVE ? '\n' + t.rtHave.replace('%l', DOTNET_HAVE.join(', ')) : '')
      + (life.eol ? '\n' + (life.level === 'bad' ? t.rtEolSince : t.rtEolOn).replace('%d', life.eol) : '');
    const level = !ok ? 'bad' : life.level;
    const note = life.level === 'bad' ? `, ${t.rtEolShort}`
      : life.level === 'warn' ? `, ${t.rtEolSoonShort}` : '';
    return `<td class="runtime"><span class="pill lv-${level}"
      title="${esc(tip)}">.NET ${esc(major)}${esc(note)}</span></td>`;
  };

  // Two views of the same rows. Serving answers "is it up", Pipeline answers
  // "did the last deploy work"; thirteen columns answering both at once is what
  // The owner could not read, 2026-09-10.
  const cPipe = e => cPipeline(e, t, false);
  // The repository icon stays in BOTH views. It is one glyph wide and it is the
  // way to open a row's code from the table; taking it out of Serving cost more
  // than the column was worth. The owner, 2026-09-10.
  paint('apps',     'app', [cCert, cState, cPort, cEnv, cPreview, cName, cRepo, cLogin, cAddr, cUnit],
        svcButtons);
  paint('apps-pipeline', 'app',
    [cState, cEnv, cName, cRepo, cRuntime, cPipe, e => cRecent(e, t),
     e => cDeployed(e, t), e => cBehind(e, t)]);

  paint('websites', 'website', [cCert, cState, cEnv, cPreview, cName,
    e => `<td class="store">${e.path ? esc(e.path) : '<span class="dash">&mdash;</span>'}</td>`,
    cRepo, cLogin, cAddr]);
  paint('websites-pipeline', 'website',
    [cState, cEnv, cName, cRepo, cPipe, e => cRecent(e, t),
     e => cDeployed(e, t), e => cBehind(e, t)]);

  paint('proxies',  'proxy',   [cCert, cState, cPort, cNameState, cLogin, cAddr]);

  // Only once the Pipeline view is actually on screen: each ask is a sudo call
  // and a git ls-remote against GitHub.
  askDeployedForVisible();

  // Says where the colours came from and when. A page that colours pills
  // without saying how old the answer is invites trusting a dead writer.
  const line = document.getElementById('status-line');
  if (!STATUS) {
    line.textContent = t.stNone;
  } else if (!STATUS_FRESH) {
    line.textContent = t.stStale.replace('%s', STATUS.checkedText || '?');
  } else {
    const errs = Array.isArray(STATUS.errors) ? STATUS.errors : [];
    line.textContent = t.stFrom.replace('%s', STATUS.checkedText || '?')
      + (errs.length ? ' · ' + t.stErrors + ' ' + errs.join('; ') : '');
  }

  // The panels. No environment column: a page is one service however many
  // environments exist. A page with no port is shown greyed rather than hidden,
  // so switching it back on is possible from here.
  const panels = sorted(panelEntries(), SORT.machine.col, SORT.machine.asc);
  document.getElementById('machine-body').innerHTML = panels.map(e => `
    <tr data-panel-row="${esc(e.panel.id)}"
        class="${[e.deleted ? 'gone' : (e.dirty ? 'edited' : ''),
                  (e.port === null || e.enabled === 'no') && !e.deleted ? 'off' : ''].filter(Boolean).join(' ')}">
      ${cState(e)}
      ${cPort(e)}
      ${cPanelName(e)}
      ${cPanelServes(e)}
      ${cLogin(e)}
      <td><span class="row-actions">
        ${e.deleted
          ? `<button class="icon-btn" type="button" data-panel-keep="${esc(e.panel.id)}"
                     title="${esc(t.aKeep)}" aria-label="${esc(t.aKeep)}">${I.undo}</button>`
          : `<button class="icon-btn" type="button" data-panel="${esc(e.panel.id)}"
                     title="${esc(t.aEdit)}" aria-label="${esc(t.aEdit)}">${I.edit}</button>
             ${(typeof EDITMODE !== 'undefined' && EDITMODE)
             ? `<button class="icon-btn ${e.panel.held ? '' : 'danger'}" type="button"
                     data-panel-del="${esc(e.panel.id)}" ${e.panel.held ? 'disabled' : ''}
                     title="${esc(e.panel.held
                       ? t.panelDeleteHeld.replace('%s', e.panel.held)
                       : t.panelDeleteRow)}"
                     aria-label="${esc(t.aDelete)}">${I.trash}</button>`
             : ''}`}
      </span></td>
    </tr>`).join('');
  document.getElementById('count-machine').textContent = panels.length;
  renderEnvs();
  paintBandList();
  paintPortMap();

  // The address column holds the local part alone, and the domain has a column
  // of its own. The dropdown above narrows to one domain; the column is what
  // makes "all" readable.
  const all = mailEntries();
  fillDomainFilter(all);
  const pick = document.getElementById('mail-domain-filter').value;
  // Two levels, always: by domain then by address, so a domain's mailboxes sit
  // together and read in order. Clicking the Address header makes address the
  // primary and domain the tie-break; the default is the other way round.
  const primary = SORT.mailboxes.col;
  const dir = SORT.mailboxes.asc ? 1 : -1;
  const mail = all.filter(e => pick === '' || e.domain === pick).sort((a, b) => {
    const byDomain = a.domain.localeCompare(b.domain);
    const byAddr = a.name.localeCompare(b.name);
    return ((primary === 1 ? byAddr : byDomain) * dir) || (primary === 1 ? byDomain : byAddr);
  });

// Whoever owns the domain; nobody means the admin, as ownership() decides.
function cMailOwner(e) {
  const o = DOMAINOWNERS[e.domain];
  if (o) return `<td class="owner">${esc(o)}</td>`;
  return `<td class="owner muted" title="${esc(T[lang].sOwnerFallback)}">${esc(ADMIN)}</td>`;
}
  document.getElementById('mail-body').innerHTML = mail.map(e => `
    <tr class="${rowClass(e)}" data-row="${e.row}">
      ${cState(e)}
      ${cMailName(e)}
      <td class="at-col">@</td>
      <td>${esc(e.domain)}</td>
      ${cMailOwner(e)}
      <td class="store">${esc(e.store)}</td>
      ${actions(e, t, null, x => mailShareButton(x) + mailCfgButton(x))}
    </tr>`).join('');

  document.getElementById('count-mailboxes').textContent = all.length;

  // After every table is painted, because the edit columns are prepended to
  // rows that have just been rebuilt.
  if (typeof paintEditCols === 'function') paintEditCols();
  paintSvcPane();

  serialise();
}

// Switching tab shows a different set of rows of the same file. Nothing is
// filtered out of what gets saved: serialise() always writes every row.
// Applications and Websites each show one of two views of the same rows.
// Chosen 2026-09-10 over hiding columns: the two views answer different
// questions, so neither is a shortened version of the other.
function showSubview(tab, view) {
  document.querySelectorAll(`[data-subview-of="${tab}"]`).forEach(d => {
    d.style.display = (d.dataset.subview === view) ? '' : 'none';
  });
  document.querySelectorAll(`[data-subtabs="${tab}"] button`).forEach(b => {
    b.setAttribute('aria-pressed', b.dataset.subview === view ? 'true' : 'false');
  });
  try { sessionStorage.setItem('subview:' + tab, view); } catch (_) {}
  askDeployedForVisible();
}

// What is deployed is asked for the rows on screen and nowhere else. A cell
// that has not been asked yet carries its key and an ellipsis, so this finds
// exactly the outstanding ones.
function askDeployedForVisible() {
  document.querySelectorAll('[data-deployed]').forEach(td => {
    // checkVisibility, not offsetParent: a <td> in a static table reports a
    // null offsetParent in Chromium whether or not the pane is on screen, so the
    // guard was always true and nothing was ever asked. Measured 2026-09-10.
    if (typeof td.checkVisibility === 'function' ? !td.checkVisibility()
                                                : td.getClientRects().length === 0) return;
    const key = td.dataset.deployed;
    const at = key.lastIndexOf('::');
    if (at < 0) return;
    askDeployed({ name: key.slice(0, at), env: key.slice(at + 2) });
  });
}

document.querySelectorAll('[data-subtabs] button').forEach(b =>
  b.addEventListener('click', () =>
    showSubview(b.closest('[data-subtabs]').dataset.subtabs, b.dataset.subview)));

// Restored per tab, like the tab itself: a save reloads the page, and coming
// back on Serving when you were reading Pipeline is the same annoyance the
// tab memory exists to stop.
function restoreSubviews() {
  document.querySelectorAll('[data-subtabs]').forEach(s => {
    let v = null;
    try { v = sessionStorage.getItem('subview:' + s.dataset.subtabs); } catch (_) {}
    showSubview(s.dataset.subtabs, v === 'pipeline' ? 'pipeline' : 'serving');
  });
}


// WHICH TABS A LIMITED ADMIN HAS. Item 105, the owner's own list: Applications,
// Websites and Mailboxes, and nothing else.
//
// Hiding a tab is a courtesy, not a control: the pane is still in the document
// and anyone can unhide it from a console. What actually protects the machine
// is that every script behind every button checks for itself. Hiding it means
// somebody is not offered work they cannot do.
const ROLE_TABS = ['apps', 'websites', 'mailboxes'];
// TABS_ON (index.php) switches whole tabs off per machine, for every role.
function tabOn(name) {
  return typeof TABS_ON === 'undefined' || TABS_ON[name] !== false;
}
function tabAllowed(name) {
  if (!tabOn(name)) return false;
  if (typeof MYROLE === 'undefined' || MYROLE === 'full') return true;
  return ROLE_TABS.includes(name);
}
// For when the tab asked for is not allowed.
function firstAllowedTab() {
  const b = [...document.querySelectorAll('.tab')].find(t => tabAllowed(t.dataset.tab));
  return b ? b.dataset.tab : 'apps';
}
function applyRoleToTabs() {
  document.querySelectorAll('.tab').forEach(b => {
    if (!tabAllowed(b.dataset.tab)) b.hidden = true;
  });
  if (typeof MYROLE === 'undefined' || MYROLE === 'full') return;
  // Edit mode rewrites config rows wholesale, so it is not a limited admin's
  // to press: their changes go through a request. Item 106.
  ['edit-mode', 'users-edit', 'discard'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.hidden = true;
  });
}
function showTab(name) {
  // A tab a role may not have is not shown even if something asks for it by
  // name: a remembered tab from a fuller account, or a hash in the URL.
  if (!tabAllowed(name)) name = firstAllowedTab();
  document.querySelectorAll('[data-pane]').forEach(p => {
    p.style.display = (p.dataset.pane === name) ? '' : 'none';
  });
  document.querySelectorAll('.tab').forEach(b => {
    b.setAttribute('aria-selected', b.dataset.tab === name ? 'true' : 'false');
  });
  const picked = document.querySelector(`.tab[data-tab="${name}"]`);
  const menuLabel = document.getElementById('tabs-menu-label');
  if (picked && menuLabel) menuLabel.textContent = picked.querySelector('[data-i18n]').textContent;
  const menuBtn = document.getElementById('tabs-menu-btn');
  if (picked && menuBtn) {
    const kind = getComputedStyle(picked);
    for (const v of ['--k-bg', '--k-fg', '--k-line']) menuBtn.style.setProperty(v, kind.getPropertyValue(v));
  }
  setTabsMenu(false);
  // Asked on the first visit to the tab rather than on page load: it costs a
  // sudo call and a GitHub round trip per owner, and most visits never open it.
  // askRepoNames() calls renderRepos() itself when the answer lands.
  if (name === 'repos' && typeof askRepoNames === 'function') { askRepoNames(); renderRepos(); }
  if (name === 'audit' && typeof loadAudit === 'function') loadAudit();
  // A tab switch reveals a Pipeline view that was never asked, because nothing
  // hidden is asked.
  askDeployedForVisible();
}
function setTabsMenu(open) {
  const btn = document.getElementById('tabs-menu-btn');
  if (!btn) return;
  btn.setAttribute('aria-expanded', open ? 'true' : 'false');
  document.getElementById('tabs-list').classList.toggle('open', open);
}
document.getElementById('tabs-menu-btn')?.addEventListener('click', e =>
  setTabsMenu(e.currentTarget.getAttribute('aria-expanded') !== 'true'));
document.querySelectorAll('.tab').forEach(b =>
  b.addEventListener('click', () => { showTab(b.dataset.tab); rememberTab(b.dataset.tab); }));

// Which tab was open, kept across the reload that a certificate action causes.
// Without it, ticking a website sent you back to Applications.
function rememberTab(name) { try { sessionStorage.setItem('tab', name); } catch (_) {} }

// Restored at the very end of the file, not here: a showTab('apps') further down
// ran afterwards and overwrote it, so every save and every apply came back on
// Applications whatever tab you were working in.
function restoreTab() {
  let t = null;
  try { t = sessionStorage.getItem('tab'); } catch (_) {}
  showTab(t && document.querySelector(`.tab[data-tab="${t}"]`) ? t : firstAllowedTab());
}

// A copy button on every block of command output. An error list is something to
// paste somewhere else, and selecting it by hand in a scrolling <pre> is worse
// than the error.
document.querySelectorAll('pre.out').forEach(pre => {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'icon-btn';
  b.style.cssText = 'float:right;margin:-.2rem 0 .2rem .4rem';
  const label = () => T[lang].aCopy;
  b.textContent = '⧉';
  b.title = label();
  b.setAttribute('aria-label', label());
  b.addEventListener('click', () => copyText(pre.textContent, b, pre));
  pre.parentNode.insertBefore(b, pre);
});

// Clipboard access needs a secure context, and this page is plain HTTP by IP,
// so the fallback is not optional: select the text and say to press Ctrl+C.
async function copyText(text, btn, selectNode) {
  const was = btn.textContent;
  try {
    await navigator.clipboard.writeText(text);
  } catch (_) {
    if (selectNode) {
      const r = document.createRange();
      r.selectNodeContents(selectNode);
      const s = getSelection(); s.removeAllRanges(); s.addRange(r);
    }
    btn.title = T[lang].aCopyManual;
    return;
  }
  btn.textContent = '✔';
  setTimeout(() => { btn.textContent = was; }, 1500);
}

// One line per row, padded to the widths already in the file, so a diff shows
// the change rather than a realignment of everything around it.
function lineFor(r) {
  return withoutGone(r.f).map((v, i) => (v === '' ? '-' : v).padEnd(WIDTHS[i] ?? 0)).join(' | ').replace(/\s+$/, '');
}

// Do this row's fields still say what the file says? Compared as values, not as
// text: the file's padding is not part of the answer.
function untouched(r, i) {
  const was = ROWWAS[i];
  if (!was || r.line === null || LINES[r.line] === undefined) return false;
  const now = withoutGone(r.f);
  return was.length === now.length
    && was.every((v, k) => (v === '-' ? '' : v) === (now[k] === '-' ? '' : now[k]));
}

// A row may not name an environment ENVS no longer has: check_config.sh refuses
// the whole save for it, which is why unticking one used to appear to do
// nothing. Rows that name ONLY a removed environment are dropped by rowDropped
// and never reach here.
function withoutGone(f) {
  if (!ENVGONE.size) return f;
  const gone = e => ENVGONE.has(e);
  const out  = f.slice();

  // Blank means the standard set, so it follows ENVS on its own.
  if (!blank(out[10])) {
    out[10] = out[10].split(',').map(s => s.trim())
      .filter(e => e && !gone(e)).join(', ');
  }

  // AuthProtected is per environment only when it holds a colon; one plain
  // answer covers every environment and needs no editing.
  if (!blank(out[7]) && out[7].includes(':')) {
    const keep = out[7].split(',').map(s => s.trim())
      .filter(p => p && !gone(p.split(':')[0].trim()));
    out[7] = keep.length ? keep.join(', ') : '';
  }

  // AuthUsers groups with semicolons, and is per environment on the same rule.
  if (!blank(out[11]) && out[11].includes(':')) {
    const keep = out[11].split(';').map(s => s.trim())
      .filter(p => p && !gone(p.split(':')[0].trim()));
    out[11] = keep.length ? keep.join('; ') : '';
  }

  return out;
}

function serialise() {
  const out = LINES.slice();
  const added = [];
  let lastRowLine = null;

  rows.forEach((r, i) => {
    if (r.line === null) { if (!r.deleted && !rowDropped(r)) added.push(lineFor(r)); return; }
    lastRowLine = (lastRowLine === null) ? r.line : Math.max(lastRowLine, r.line);
    if (r.deleted || rowDropped(r)) { out[r.line] = null; return; }
    // A row that did not change keeps its line byte for byte. Rewriting all of
    // them realigned every column when one field grew, and git then reported
    // sixteen changed rows for a one-row edit, which made --changed apply
    // everything.
    out[r.line] = untouched(r, i) ? LINES[r.line] : lineFor(r);
  });

  // New rows go after the last existing one, so they land among the rows rather
  // than in the middle of the comments. With no rows at all, the end of file is
  // the only place that is certainly not inside a comment block.
  if (added.length) {
    const at = (lastRowLine === null) ? out.length - 1 : lastRowLine;
    out[at] = [out[at], ...added].filter(v => v !== null && v !== undefined).join('\n');
  }

  // The machine pages. A PANEL line is rewritten where it already is, so the
  // comment block explaining it stays above it. The id is written back
  // unchanged: it is what a script looks up, and only the port and the name are
  // the console's to edit.
  //
  // The last three fields are written only when the page is served by this
  // repo's generator. A page its own installer serves keeps the three-field
  // line it has always had, so nothing about the existing pages moves.
  const panelLine = (p, s) => {
    const head = 'PANEL = ' + p.id + ' | ' + (s.port === null ? '-' : s.port) + ' | ' + s.label;
    if (s.serves === 'itself') return head;
    const tail = head + ' | ' + s.serves + ' | ' + (s.target || '-') + ' | ' + s.login;
    // The seventh field is only written when it says something. A trailing `-`
    // on every line is noise, and the admin is admitted whether it is there or
    // not.
    return s.users ? tail + ' | ' + s.users : tail;
  };

  let lastPanelLine = null;
  const newPanels = [];

  PANELS.forEach(p => {
    // Deleted: the line goes, and its comment block above it stays. A comment
    // explaining a setting that is no longer there is better than losing the
    // reasoning, which is not recoverable.
    if (panelGone.has(p.id)) {
      if (p.line !== null && p.line !== undefined) out[p.line] = null;
      return;
    }
    if (panelEdits[p.id] === undefined) {
      if (p.line !== null && p.line !== undefined) lastPanelLine = p.line;
      return;
    }
    const s = panelState(p);
    if (p.line === null || p.line === undefined) { newPanels.push(panelLine(p, s)); return; }
    lastPanelLine = (lastPanelLine === null) ? p.line : Math.max(lastPanelLine, p.line);
    out[p.line] = panelLine(p, s);
  });

  // A page added on this tab has no line yet. It goes under the last PANEL line,
  // so it lands among the pages rather than inside somebody's comment block.
  if (newPanels.length) {
    if (lastPanelLine === null) {
      out.push(...newPanels);
    } else {
      out[lastPanelLine] = [out[lastPanelLine], ...newPanels].join('\n');
    }
  }

  // Environments. Each is four settings: the name inside ENVS, plus a branch,
  // a port offset and a host prefix. A removed one takes its three settings out
  // of the file entirely, so nothing is left behind reading as configuration.
  const envLive = ENVS.filter(e => !ENVGONE.has(e));
  // LIVE_HOST_PREFIX is empty by design, and the file stores it with nothing
  // after the `=`. A trailing space there is what once made the parser read the
  // next key as this value.
  const setEnv = (key, value) => {
    const tail = (value === '' ? ' =' : ' = ' + value);
    for (let i = 0; i < out.length; i++) {
      if (out[i] !== null && new RegExp('^[ \\t]*' + key + '[ \\t]*=').test(out[i])) {
        out[i] = out[i].replace(/[ \t]*=.*$/, tail);
        return;
      }
    }
    // New: put it under the last <ENV>_ setting so it lands with its kind
    // rather than at the end of the file.
    let at = -1;
    for (let i = 0; i < out.length; i++) {
      if (out[i] !== null && /^[ \t]*[A-Z0-9]+_(BRANCH|PORT_OFFSET|HOST_PREFIX)[ \t]*=/.test(out[i])) { at = i; }
    }
    const line = key + tail;
    if (at === -1) { out.push(line); } else { out[at] = out[at] + '\n' + line; }
  };

  envLive.forEach(e => {
    const up = e.toUpperCase();
    const branch = ENVBRANCH[e] || e, prefix = PREFIX[e] || '', offset = OFFSET[e] ?? 0;
    if (ENVWAS.b[e] !== branch) setEnv(up + '_BRANCH',      branch);
    if (ENVWAS.p[e] !== prefix) setEnv(up + '_HOST_PREFIX', prefix);
    if (ENVWAS.o[e] !== offset) setEnv(up + '_PORT_OFFSET', offset);
  });

  // Every setting named after the environment goes, in both spellings the file
  // uses: <ENV>_ for the ones the environment owns, and <THING>_<ENV> for the
  // roots. A leftover APP_ROOT_SKUNK reads as configuration for something that
  // no longer exists.
  ENVGONE.forEach(e => {
    const up = e.toUpperCase();
    for (let i = 0; i < out.length; i++) {
      if (out[i] !== null &&
          (new RegExp('^[ \\t]*' + up + '_(BRANCH|PORT_OFFSET|HOST_PREFIX|UNIT_SUFFIX)[ \\t]*=').test(out[i])
        || new RegExp('^[ \\t]*(APP_ROOT|WEB_ROOT)_' + up + '[ \\t]*=').test(out[i]))) {
        out[i] = null;
      }
    }
  });

  // ENVS, and PUBLISH_ENVS where the file states it: naming a removed
  // environment there fails the check exactly as a row does.
  const dropFromList = key => {
    for (let i = 0; i < out.length; i++) {
      if (out[i] === null || !new RegExp('^[ \\t]*' + key + '[ \\t]*=').test(out[i])) continue;
      const kept = out[i].replace(/^[^=]*=/, '').split(',').map(s => s.trim())
        .filter(v => v && !ENVGONE.has(v));
      out[i] = out[i].replace(/[ \t]*=.*$/, ' = ' + kept.join(', '));
      return;
    }
  };

  for (let i = 0; i < out.length; i++) {
    if (out[i] !== null && /^[ \t]*ENVS[ \t]*=/.test(out[i])) {
      out[i] = out[i].replace(/[ \t]*=.*$/, ' = ' + envLive.join(', '));
      break;
    }
  }
  if (ENVGONE.size) dropFromList('PUBLISH_ENVS');

  // DNS_DOMAINS, when a mailbox was put on a domain this config did not list.
  // Rewritten in place rather than appended, so the comment block above it and
  // everything below stay exactly where they were.
  if (extraDomains.length) {
    const all = [...DNSDOMAINS, ...extraDomains];
    for (let i = 0; i < out.length; i++) {
      if (out[i] !== null && /^[ \t]*DNS_DOMAINS[ \t]*=/.test(out[i])) {
        out[i] = out[i].replace(/[ \t]*=.*$/, ' = ' + all.join(', '));
        break;
      }
    }
  }

  // PREVIEW_ROWS, rewritten in place from what the drawers hold. Written
  // explicitly as row:env or row:env:port, never as a bare name, so what the
  // file says is what the drawer showed.
  //
  // A deleted row takes its previews with it. Leaving the name behind used to
  // stop the whole apply: add_preview_vhosts.sh found a preview for a row that
  // no longer exists, and nothing after it ran, including the prune that would
  // have cleaned up the deletion.
  const alive = new Set(
    rows.filter(r => !r.deleted && !rowDropped(r))
        .map(r => (r.f[1] || '').trim())
        .filter(Boolean));
  const prev = [];
  Object.keys(PREVIEWS).sort().forEach(name => {
    if (!alive.has(name)) return;
    Object.keys(PREVIEWS[name]).sort().forEach(env => {
      const spec = PREVIEWS[name][env];
      prev.push(name + ':' + env + (spec === 'auto' ? '' : ':' + spec));
    });
  });
  for (let i = 0; i < out.length; i++) {
    if (out[i] !== null && /^[ \t]*PREVIEW_ROWS[ \t]*=/.test(out[i])) {
      out[i] = out[i].replace(/[ \t]*=.*$/, ' = ' + prev.join(', '));
      break;
    }
  }

  // PANELS_OFF, rewritten in place from what the tick boxes hold. A page that
  // has been deleted takes its entry with it, so a stale id cannot be left
  // naming a page that no longer exists.
  const offIds = [...panelOff].filter(id =>
    !panelGone.has(id) && PANELS.some(p => p.id === id)).sort();
  let panelOffAt = -1;
  for (let i = 0; i < out.length; i++) {
    if (out[i] !== null && /^[ \t]*PANELS_OFF[ \t]*=/.test(out[i])) { panelOffAt = i; break; }
  }
  if (panelOffAt !== -1) {
    out[panelOffAt] = out[panelOffAt].replace(/[ \t]*=.*$/, ' = ' + offIds.join(', '));
  } else if (offIds.length && lastPanelLine !== null) {
    // Written beside the PANEL lines it talks about, and only once something
    // is actually off: an empty key in every config would be noise.
    out[lastPanelLine] = out[lastPanelLine] + '\nPANELS_OFF = ' + offIds.join(', ');
  }

  document.getElementById('config-field').value =
    out.filter(l => l !== null).join('\n');
}

// The mail ops travel in their own field, filled the instant before the form
// posts, so whichever save button fired carries the same list. Empty for every
// save that touched no mailbox, which is almost all of them.
document.getElementById('rows-form').addEventListener('submit', e => {
  const ops = collectMailOps();
  document.getElementById('mailops-field').value = ops.length ? JSON.stringify(ops) : '';

  // An op with no owner/name cannot be carried out, and going ahead anyway
  // deletes the row and leaves the repository, silently. The save stops here
  // instead, naming the rows, because the answer was Archive or Delete and
  // neither of those is a thing to guess about.
  const rops = collectRepoOps();
  const lost = rops.filter(o => !o.usable);
  if (lost.length) {
    e.preventDefault();
    alert(T[lang].repoOpNoSlug(lost.map(o => o.row || '?').join(', ')));
    return;
  }
  document.getElementById('repoops-field').value = rops.length
    ? JSON.stringify(rops.map(o => ({ verb: o.verb, slug: o.slug })))
    : '';
});

// The file, shown rather than edited. One <pre>, coloured by line shape: a
// comment, a SETTING = value, or a row whose type word carries its own hue.
// Comments are hidden by default because they are most of the file and none of
// them is what you opened this tab to find.
const RAW_KINDS = ['app', 'website', 'proxy', 'mailbox', 'panel', 'php', 'docroot'];

function paintRawView() {
  const src  = document.getElementById('raw');
  const view = document.getElementById('raw-view');
  if (!src || !view) return;
  const box = document.getElementById('raw-comments');
  const withComments = !!(box && box.checked);

  view.innerHTML = src.value.split('\n').map(line => {
    const t = line.trim();
    if (t === '' || t.startsWith('#')) {
      return withComments ? '<span class="c-note">' + esc(line) + '</span>' : null;
    }

    const kv = line.match(/^(\s*)([A-Z_][A-Z0-9_]*)(\s*=\s*)(.*)$/);
    if (kv) {
      return esc(kv[1]) + '<span class="c-key">' + esc(kv[2]) + '</span>'
           + esc(kv[3]) + '<span class="c-val">' + esc(kv[4]) + '</span>';
    }

    const first = t.split('|')[0].trim();
    if (RAW_KINDS.includes(first)) {
      const at = line.indexOf(first);
      return esc(line.slice(0, at))
           + '<span class="c-row ' + esc(first) + '">' + esc(first) + '</span>'
           + esc(line.slice(at + first.length));
    }
    return esc(line);
  }).filter(l => l !== null).join('\n');
}
document.getElementById('raw-comments')?.addEventListener('change', paintRawView);
paintRawView();

