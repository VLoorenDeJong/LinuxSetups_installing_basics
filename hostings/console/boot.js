
document.getElementById('apply-cancel').addEventListener('click', closeApply);
applyScrim.addEventListener('click', closeApply);
// Escape closes whatever is open, not only the apply dialog. The owner,
// 2026-09-10. Each close function decides for itself whether it may run: the
// apply dialog refuses while it is watching a job, the redeploy dialog refuses
// while its Close button is disabled, and the drawer asks before throwing away
// typed work.
//
// Topmost first, so Escape peels one layer at a time rather than shutting the
// drawer underneath a confirmation on top of it.
document.addEventListener('keydown', e => {
  if (e.key !== 'Escape') return;
  const open = id => {
    const el = document.getElementById(id);
    return el && el.classList.contains('open');
  };
  const layers = [
    ['repodel-dialog', () => closeRepoDelete()],
    ['mbxdel-dialog',  () => closeMbxDelete()],
    ['svclog-dialog',  () => closeSvcLog()],
    ['mailcfg-dialog', () => closeMailCfg()],
    ['svc-dialog',     () => closeSvcDialog()],
    // Escape closes it even while a build runs. The Close BUTTON stays disabled
    // then, on purpose: it is the end of the job and pressing it early reads as
    // 'this is finished'. Escape is the other gesture, 'I am done looking', and
    // the build carries on either way. The owner asked for Escape to exit every
    // dialog, 2026-09-10.
    ['redeploy-dialog',() => closeRedeploy()],
    ['apply-dialog',   () => closeApply()],
    ['user-drawer',    () => closeUserDrawer()],
    ['smb-drawer',     () => closeSmbDrawer()],
    ['drawer',         () => closeDrawerAsked()]
  ];
  for (const [id, close] of layers) {
    if (!open(id)) continue;
    try { close(); } catch (err) { /* a dialog this build does not have */ }
    return;
  }
});

// The confirmation. This is the first thing in the whole flow that writes
// anything: it saves, pushes, and then starts the apply job.
document.getElementById('apply-go').addEventListener('click', () => {
  applyWatch();
  document.getElementById('btn-save-apply').click();
});

// Both leave the page as it is: Close reloads so the tables stop showing the
// state from before the job, Hide only puts the dialog away and lets the
// banner carry on.
// COPY, anywhere on the page. Delegated, because the Repositories table is
// rebuilt on every render and a listener bound to a row would go with it.
//
// navigator.clipboard needs a secure context, and this page is plain http on
// the LAN, so it is absent in Firefox and Chrome alike. The textarea fallback
// is what actually runs here; the modern call is tried first for the day this
// page has a certificate.
document.addEventListener('click', async e => {
  const b = e.target.closest('[data-copy]');
  if (!b) return;
  const text = b.dataset.copy;
  let ok = false;
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      ok = true;
    }
  } catch (err) { ok = false; }
  if (!ok) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { ok = document.execCommand('copy'); } catch (err) { ok = false; }
    ta.remove();
  }
  // Said on the button itself rather than in a banner: the answer belongs
  // where the press was.
  if (!b.dataset.was) b.dataset.was = b.innerHTML;
  // Its OWN title, not the clone URL's. This delegate serves every copy button
  // on the page now, and putting back a hardcoded string left a mail server
  // port labelled "Copy the clone URL" after one press.
  if (b.dataset.wasTitle === undefined) b.dataset.wasTitle = b.title;
  b.innerHTML = ok ? I.check : I.undo;
  b.title = ok ? T[lang].aCopied : b.dataset.wasTitle;
  clearTimeout(b._copyTimer);
  b._copyTimer = setTimeout(() => {
    b.innerHTML = b.dataset.was;
    b.title = b.dataset.wasTitle;
  }, 1400);
});

document.getElementById('apply-close').addEventListener('click', () => {
  location.replace(location.pathname);
});
document.getElementById('apply-hide').addEventListener('click', () => {
  applyWatching = false;
  applyDialog.classList.remove('open', 'watching');
  applyScrim.classList.remove('open');
  document.body.classList.remove('locked');
});

document.getElementById('apply-recheck').addEventListener('click', () => {
  closeApply();
  document.getElementById('btn-check').click();
});

// Creating repositories reaches outside this machine, so it asks even though
// the button says what it does.
const provForm = document.getElementById('provision-form');
if (provForm) {
  provForm.addEventListener('submit', e => {
    if (!confirm(T[lang].provConfirm)) e.preventDefault();
  });
}

// -----------------------------------------------------------------------------
// The busy overlay. Every button here shells out to a script that takes
// seconds, and until now the page sat looking idle while it ran.
//
// No progress bar: none of these scripts report a percentage to this page, and
// a bar that moves on a timer is a lie about how far along something is.
// -----------------------------------------------------------------------------
const busy = document.getElementById('busy');

function busyOn(text, note) {
  document.getElementById('busy-text').textContent = text;
  document.getElementById('busy-note').textContent = note || '';
  busy.classList.add('open');
}

// A submit that the browser then blocks (a cancelled confirm) must not leave the
// overlay up for ever, so pageshow clears it on the way back too.
window.addEventListener('pageshow', () => {
  busy.classList.remove('open');
  document.body.classList.remove('working', 'locked');
});

// Capture, so a "no" stops the submit before the busy overlay goes up.
document.getElementById('reboot-form')?.addEventListener('submit', e => {
  if (!confirm(T[lang].rebootConfirm)) {
    e.preventDefault();
    e.stopImmediatePropagation();
  }
}, true);

document.querySelectorAll('form[data-busy]').forEach(f => {
  f.addEventListener('submit', () => {
    const t = T[lang];
    const key = f.dataset.busy;
    busyOn(t.busy[key] || t.busyWorking, t.busyJob);
  });
});

// The rows form has two buttons and they do different things, so the message
// comes from whichever one was pressed.
document.getElementById('rows-form').addEventListener('submit', e => {
  const t = T[lang];
  const what = (e.submitter && e.submitter.value) || 'save';
  // The fast actions show the row sweeping instead: an overlay over the
  // whole page hides the one thing worth watching.
  if (what === 'save_fast' || what === 'savesmb') {
    document.body.classList.add('working');
    return;
  }
  busyOn(t.busy[what] || t.busyWorking, what.startsWith('save') ? t.busyPush : t.busyRead);
});

document.querySelectorAll('th.sortable').forEach(th => {
  th.addEventListener('click', () => {
    const which = th.closest('table').dataset.table;
    const s = SORT[which];
    const col = Number(th.dataset.sort);
    s.asc = (col === s.col) ? !s.asc : true;
    s.col = col;
    th.closest('thead').querySelectorAll('th.sortable').forEach(o =>
      o.setAttribute('aria-sort', o === th ? (s.asc ? 'ascending' : 'descending') : 'none'));
    render();
  });
});

// -----------------------------------------------------------------------------
// Buttons whose job is still running.
//
// Starting a job is a POST that returns the moment Jenkins accepts it, so the
// page comes back, the overlay clears, and the button invites a second press
// while the first run is still going. The trigger scripts refuse a duplicate,
// but a button that looks ready and then says no is a worse answer than one
// that says it is busy.
//
// Polled only while something is running. An idle page asks once on load and
// then leaves Jenkins alone.
// -----------------------------------------------------------------------------
// The worst Jenkins result per site folder, keyed by row name, straight out of
// jenkins_job_status.sh's `sites` object. It has always been in the response
// and nothing read it, so a deploy that failed was invisible on the page:
// measured 2026-09-09, when example_net's every build had failed and
// the row said only that nothing was deployed.
var SITEJOBS = {};
let sitesSeen = '';

let jobTimer = null;
// True when this load followed a press that started a job, so the finish is
// noticed even if the first poll lands before Jenkins has queued it.
let jobsWereBusy = BOOT.startedJob;
let idleTicks = 0;

// A form on its way to the server. Reloading now cancels that navigation in the
// browser: the server still saves, but the page never shows the result.
let formInFlight = false;
window.addEventListener('submit', e => { if (!e.defaultPrevented) formInFlight = true; });
window.addEventListener('pageshow', () => { formInFlight = false; });

// Whether the loop has a reason to keep polling after a failed request. Kept
// here rather than inlined so the retry above and the schedule below cannot
// drift apart.
function anyJobPolling() { return jobsWereBusy; }

async function refreshJobs() {
  let jobs = {}, updates = null;
  try {
    const r = await fetch('?ask=jobs', { headers: { 'Accept': 'application/json' } });
    const j = await r.json();
    jobs    = j.jobs || {};
    updates = j.updates || null;
    // Re-rendered only when it actually differs: this poll runs every five
    // seconds while a job is up, and repainting the tables under an open
    // drawer is how typed values get thrown away.
    // The KEY LEAVES OUT the timing fields. They were added on 2026-09-10 and
    // a running build's duration ticks every poll, so the whole document
    // differed every five seconds and the tables re-rendered every five
    // seconds with it. Caught by smoke.spec.js, whose hand-set class was wiped
    // before it could be read; on screen it would have been a table that
    // rebuilds under the reader's hands.
    //
    // What is compared is what the PAINT depends on: running, result, number.
    // SITEJOBS still holds everything, so the tooltips and the dialog keep the
    // timings they show.
    const paintKey = s => JSON.stringify(Object.entries(s || {}).map(([row, v]) => [
      row, v.running, v.result,
      Object.entries(v.jobs || {}).map(([n, jb]) => [n, jb.running, jb.result, jb.number])
    ]));
    const seen = paintKey(j.sites);
    SITEJOBS = j.sites || {};
    if (seen !== sitesSeen) {
      sitesSeen = seen;
      if (!drawer.classList.contains('open')) render();
    }
  } catch (e) {
    // A status call that failed says nothing about what is running, so every
    // button stays exactly as it is rather than being greyed out on a guess.
    //
    // BUT IT MUST STILL COME BACK. This used to return without rescheduling,
    // and the apply dialog closes ONLY from this loop, so one dropped request
    // left "Saving, pushing, and starting the apply job" on screen for ever
    // while the job finished and the machine went idle. Seen 2026-09-07.
    if (applyWatching || anyJobPolling()) {
      clearTimeout(jobTimer);
      jobTimer = setTimeout(refreshJobs, 5000);
    }
    return;
  }

  // Shown when there is something to install, and also when the count could not
  // be worked out: an unknown count must not hide the only way to start one.
  // While the job runs it stays visible whatever the count says, so the thing
  // you just pressed does not disappear from under you.
  const busyUpdate = !!(jobs['machine-update']
    && (jobs['machine-update'].running || jobs['machine-update'].queued));
  const pending = !updates || !updates.known || updates.count > 0;
  // Once an update needs a reboot, the same slot offers the reboot instead.
  const needsReboot = !!(updates && updates.reboot) && !busyUpdate;

  // A limited admin's page has no update card.
  const updateCard = document.getElementById('update-card');
  if (updateCard) updateCard.style.display = (pending || busyUpdate || needsReboot) ? '' : 'none';
  const updateForm = document.getElementById('btn-update')?.closest('form');
  const rebootForm = document.getElementById('reboot-form');
  if (updateForm && rebootForm) {
    updateForm.style.display = needsReboot ? 'none' : '';
    rebootForm.style.display = needsReboot ? '' : 'none';
  }

  const note = document.getElementById('update-note');
  if (note && needsReboot) {
    note.textContent = T[lang].rebootNote;
  } else if (note && updates && updates.known && updates.count > 0) {
    note.textContent = T[lang].updatesWaiting
      .replace('%d', updates.count)
      .replace('%s', updates.security);
  }

  let anyBusy = false;

  document.querySelectorAll('[data-job]').forEach(b => {
    const s    = jobs[b.dataset.job];
    const busyNow = !!(s && (s.running || s.queued));
    anyBusy = anyBusy || busyNow;

    b.disabled = busyNow;
    if (busyNow) {
      if (!b.dataset.labelHtml) b.dataset.labelHtml = b.innerHTML;
      b.textContent = T[lang].jobRunning;
    } else if (b.dataset.labelHtml) {
      b.innerHTML = b.dataset.labelHtml;
      delete b.dataset.labelHtml;
    }
  });

  const banner = document.getElementById('job-banner');
  if (banner) {
    const busy = anyBusy || jobsWereBusy;
    banner.hidden = !busy;
    if (busy) document.getElementById('job-banner-text').textContent = T[lang].jobBanner;
  }

  // Reload once the work is over, so the page stops showing the state from
  // before the job ran. Two idle answers, not one: Jenkins takes a moment to
  // admit a job exists, and the first poll after a press can land in that gap.
  // The dialog decides for itself, from the build NUMBER rather than from
  // idleness. Idle means two different things: not queued yet, and already
  // over. Two idle answers used to be read as the second, so a Jenkins that
  // took longer than ten seconds to queue was reported as a finished job,
  // carrying the PREVIOUS run's result.
  if (applyWatching) {
    const st = jobs['hosting-apply'] || {};
    const busyNow = !!(st.running || st.queued);
    if (busyNow) applySawBusy = true;
    applyTicks++;

    const newBuild = typeof st.number === 'number' && APPLY_FROM >= 0
                   && st.number > APPLY_FROM;
    if (newBuild) applyBuildStarted = true;

    if (!busyNow && (newBuild || applySawBusy)) {
      jobsWereBusy = false;
      applyFinished(st.result || null);
      return;
    }
    // Two minutes of nothing at all. Said plainly rather than shown as a
    // result: nothing here knows what happened.
    if (!busyNow && !applySawBusy && applyTicks >= 24) {
      jobsWereBusy = false;
      applyFinished(null);
      return;
    }
    clearTimeout(jobTimer);
    jobTimer = setTimeout(refreshJobs, 5000);
    return;
  }

  // A site's own deploy counts as busy for the schedule, so a build started
  // from Jenkins or by a push finishes visibly here rather than at the next F5.
  const siteBusy = Object.keys(SITEJOBS).some(k => SITEJOBS[k] && SITEJOBS[k].running);

  if (anyBusy) { jobsWereBusy = true; idleTicks = 0; }
  else if (jobsWereBusy && ++idleTicks >= 2 && !formInFlight) {
    // Without the query string: the message has been read, and keeping it
    // would make the next load think another job had just started.
    location.replace(location.pathname);
    return;
  }

  clearTimeout(jobTimer);
  // Five seconds while something is up, thirty when nothing is. A deploy
  // started by a push, or by somebody else's browser, has to reach this page:
  // without the slow tick the loop stopped the moment the last job ended and a
  // new one was invisible until F5, which is what the rows sweeping on a
  // Jenkins job is meant to prevent. One tree request every half minute.
  jobTimer = setTimeout(refreshJobs,
    (anyBusy || jobsWereBusy || siteBusy) ? 5000 : 30000);
}

// THE MACHINE'S STATE, WITHOUT A RELOAD.
//
// STATUS used to be a snapshot taken when the page was built, so a row could
// only ever show what was true at F5. A unit is "activating" for about a
// second, so the starting sweep could essentially never be seen. The publisher
// rewrites the file every 5 seconds; this reads it at the same rate and
// re-renders when something actually differs.
//
// A drawer that is open is left alone: re-rendering the table under an edit is
// how typed values get thrown away.
let statusSeen = '';

// A CHANGE SOMEBODY ELSE STARTED. The owner, 2026-09-18: a save in another
// browser ran for a minute with nothing on this page saying so, and the drift
// it caused looked like a fault. Painted even while the page is locked.
function showWork(work) {
  const banner = document.getElementById('work-banner');
  if (!banner) return;
  const t = T[lang];
  const lines = (Array.isArray(work) ? work : []).map(w => {
    if (!w.user) return t.workOther.replace('%s', w.secs);
    const act = t.workAct[w.action] || t.workAct[''];
    return (w.user === ME ? t.workMine : t.workBy.replace('%u', w.user))
      .replace('%a', act)
      .replace('%r', w.row ? t.workOn.replace('%s', w.row) : '')
      .replace('%s', w.secs);
  });
  banner.hidden = lines.length === 0;
  document.getElementById('work-banner-text').textContent = lines.join(' ');
}

// WHO ELSE HAS THE PAGE OPEN, for a full admin, with a Kick each. The
// server answers from the status poll every page makes, so "online" means a
// page asked in the last 90 seconds.
function showOnline(list) {
  const ul = document.getElementById('who-users');
  if (!ul || !Array.isArray(list)) return;
  const t = T[lang];
  const others = list.filter(u => u.user !== ME).length;
  const count = document.getElementById('who-count');
  count.hidden = others === 0;
  count.textContent = '+' + others;
  ul.replaceChildren(...list.sort((a, b) => a.user.localeCompare(b.user)).map(u => {
    const li = document.createElement('li');
    const name = document.createElement('span');
    name.textContent = u.user === ME ? `${u.user} (${t.whoYou})` : u.user;
    li.append(name);
    if (u.user !== ME) {
      const kick = document.createElement('button');
      kick.type = 'button';
      kick.className = 'icon-btn text-btn who-kick';
      kick.dataset.kick = u.user;
      kick.textContent = t.whoKick;
      li.append(kick);
    }
    return li;
  }));
}

const whoBtn = document.getElementById('who-btn');
const whoList = document.getElementById('who-list');
if (whoBtn && whoList) {
  whoBtn.addEventListener('click', () => {
    whoList.hidden = !whoList.hidden;
    whoBtn.setAttribute('aria-expanded', String(!whoList.hidden));
  });
  document.addEventListener('click', e => {
    if (!whoList.hidden && !e.target.closest('#who')) {
      whoList.hidden = true;
      whoBtn.setAttribute('aria-expanded', 'false');
    }
  });
  whoList.addEventListener('click', async e => {
    const b = e.target.closest('[data-kick]');
    if (!b) return;
    const t = T[lang];
    if (!confirm(t.whoKickAsk.replace('%s', b.dataset.kick))) return;
    const body = new URLSearchParams({ action: 'kick', name: b.dataset.kick });
    try {
      const r = await fetch(location.pathname, { method: 'POST', body,
        headers: { 'Accept': 'application/json' } });
      const d = await r.json();
      b.textContent = d.ok ? t.whoKicked : t.qFailed;
      b.disabled = true;
      if (d.ok) setTimeout(() => b.closest('li').remove(), 1200);
    } catch (err) {
      b.textContent = t.qFailed;
    }
  });
}

async function refreshStatus() {
  try {
    const r = await fetch('?ask=status', { cache: 'no-store', headers: { 'Accept': 'application/json' } });
    // Signed out, however it arrives: the kick answer itself, or, when another
    // request used the kick up first, Apache handing the login page to a
    // cookie that is gone.
    if (r.status === 401 || (r.redirected && /login\.html/.test(r.url))) {
      location.replace('/login.html');
      return;
    }
    const d = await r.json();
    showWork(d && d.work);
    showOnline(d && d.online);
    // Not while a save or dialog has the page locked: a redraw rebuilds the
    // rows and drops the sweep. Left unseen, so it redraws once unlocked.
    if (d && d.ok && d.status && !document.body.classList.contains('locked')) {
      const fresh = JSON.stringify(d.status);
      if (fresh !== statusSeen) {
        statusSeen = fresh;
        STATUS = d.status;
        readStatus();
        if (!drawer.classList.contains('open')) { render(); }
      }
    }
  } catch (e) {
    // A missed read says nothing about the machine. Keep what is on screen.
  }
  setTimeout(refreshStatus, 5000);
}
refreshStatus();

// Before restoreTab(): a remembered tab a limited admin may not have must not
// be painted first and taken away afterwards.
applyRoleToTabs();
restoreTab();
restoreSubviews();
applyLang();
refreshJobs();

// WARM THE REPOSITORY LIST, two seconds after the page is up.
//
// ?repos=1 was deliberately never asked on load, because a cold lookup is a
// sudo call and a GitHub round trip per owner: measured 4.153s on this machine
// 2026-09-09. But list_repo_names.sh caches, and a warm answer is 0.091s, so
// what that decision actually bought was paying the 4 seconds while somebody
// waited on the Repositories tab instead of while nobody was looking.
//
// Deliberately after a delay and never awaited: the tables, the graphs and the
// status poll all come first, and if this never answers nothing on the page is
// worse off than it was.
setTimeout(() => {
  if (typeof askRepoNames === 'function') askRepoNames();
}, 2000);
// Paint the history restored from before the reload at once, so the graph is
// already there rather than starting blank and filling over two minutes.
if (cpuSamples.length) drawCpu();
cpuTick();

// The button pressed before this page load was the single Make it live one, so
// the check has just run against the config on screen and the dialog is what
// that press was for.
if (BOOT.autoConfirm) openApply();

// The load that follows Apply now. The dialog goes straight back up in its
// watching state, so from the screen it never left.
if (BOOT.startedApply) applyWatch();

// The refusal dialog. No dismiss button on purpose: the edit is already gone,
// and the only useful next act is to reload onto the current config. Escape and
// the scrim are deliberately not wired to close it.
const refusedReload = document.getElementById('refused-reload');
if (refusedReload) {
  refusedReload.addEventListener('click', () => {
    window.location.href = window.location.pathname;
  });
  refusedReload.focus();
}

// After a reboot press: wait for the machine to stop answering and come back,
// then load the page fresh. Bounded, so a reboot that never happened still ends.
if (BOOT.rebooting) {
  let sawDown = false, tries = 0;
  const probe = async () => {
    tries++;
    try {
      const r = await fetch('?ask=jobs', { cache: 'no-store' });
      if (r.ok && (sawDown || tries > 18)) {
        window.location.href = window.location.pathname;
        return;
      }
      if (!r.ok) sawDown = true;
    } catch (_) {
      sawDown = true;
    }
    if (tries < 60) setTimeout(probe, 5000);
  };
  setTimeout(probe, 5000);
}
