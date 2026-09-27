// -----------------------------------------------------------------------------
// Make it live: the summary, then the act.
// -----------------------------------------------------------------------------
const applyDialog = document.getElementById('apply-dialog');
const applyScrim  = document.getElementById('apply-scrim');

function driftList(t) {
  const items = [];
  ['ADD', 'UPDATE', 'ORPHAN'].forEach(k => (CHECK.drift[k] || []).forEach(d => {
    items.push(`<li><span class="tag ${k.toLowerCase()}">${esc(t['tag' + k[0] + k.slice(1).toLowerCase()])}</span>
                    <span class="what">${esc(d.what)}</span>
                    <span class="name">${esc(d.name)}</span></li>`);
  }));
  return items;
}

function openApply() {
  const t = T[lang];
  const age  = document.getElementById('apply-age');
  const body = document.getElementById('apply-summary');
  const go   = document.getElementById('apply-go');

  age.textContent = CHECK.ran
    ? `${t.checked} ${CHECK.age}${CHECK.head ? ' — ' + CHECK.head : ''}`.replace(' — ', ' · ')
    : '';

  if (!CHECK.ran) {
    body.innerHTML = `<p class="note">${esc(t.reportEmpty)}</p>`;
  } else if (CHECK.failed) {
    // A failure list is something to paste somewhere else, and it is built by
    // script rather than being a <pre>, so the page-load copy buttons miss it.
    body.innerHTML = `<button type="button" class="icon-btn text-btn" id="apply-copy"
        style="float:right" title="${esc(t.aCopy)}" aria-label="${esc(t.aCopy)}">${esc(t.bCopy)}</button>
      <ul class="drift">${CHECK.problems.map(p =>
      `<li><span class="tag bad">${esc(t.tagError)}</span><span>${esc(p)}</span></li>`).join('')}</ul>
      <p class="note">${esc(t.applyLocked)}</p>`;
    document.getElementById('apply-copy').addEventListener('click', () => {
      copyText(CHECK.problems.join('\n'), document.getElementById('apply-copy'));
    });
  } else {
    const list = driftList(t);
    body.innerHTML = (list.length
        ? `<ul class="drift">${list.join('')}</ul>`
        : `<p class="nothing">${esc(t.reportSame)}</p>`)
      + `<p class="note" style="margin:.5rem 0 0">${CHECK.drift.OK.length} ${esc(t.alreadyThere)}`
      + (CHECK.warnings ? `, ${CHECK.warnings} ${esc(t.warnCount)}` : '')
      + `. ${esc(t.rewriteNote)}</p>`;
  }

  // Locked on a failed check and on no check at all: applying an unvalidated
  // config is the one thing this page exists to make impossible.
  go.disabled = !CHECK.ran || CHECK.failed;

  applyDialog.classList.add('open');
  applyScrim.classList.add('open');
  document.body.classList.add('locked');
}

function closeApply() {
  // A dialog that is watching a job is not dismissed by a stray click on the
  // scrim or an Escape meant for something else. Hide says it deliberately.
  if (applyWatching) return;
  applyDialog.classList.remove('open', 'watching');
  applyScrim.classList.remove('open');
  document.body.classList.remove('locked');

  // The URL is what reopens it, so a refresh after closing brought it straight
  // back with the same report.
  if (location.search) {
    history.replaceState(null, '', location.pathname);
  }
}

// -----------------------------------------------------------------------------
// The dialog while Jenkins works.
//
// The press navigates, so this runs twice: once before the POST leaves, and
// again on the page that comes back with done=applied. Both put the dialog in
// the same state, which is why it looks as though it never went away.
// -----------------------------------------------------------------------------
let applyWatching = false;
// The build number the apply job had BEFORE this one was started, from the
// query string. -1 when it could not be read.
const APPLY_FROM = BOOT.applyFrom;
let applySawBusy = false;
let applyTicks = 0;
// Until Jenkins numbers the new build, lastBuild's log is the PREVIOUS run's,
// ending in its own "Finished:". Set by the job poll in boot.js.
let applyBuildStarted = APPLY_FROM < 0;

// Sampled once a second on its own timer, not on the five-second job poll: a
// graph of the machine working needs to look like the machine working.
// 120 samples is the last two minutes.
const cpuSamples = [];
const coreSamples = [];
const readSamples = [];
const writeSamples = [];
const tempSamples = [];
const memSamples = [];
const CPU_KEEP = 120;
// Fixed, so a hot run and a cool one can be compared by eye. A Pi throttles at 80.
const TEMP_LO = 30;
const TEMP_HI = 90;
let cpuTimer = null;
let cpuPrev = null;
const avail = { disk: false, temp: false, mem: false };

// The graph survives the reload a save or publish causes. Saving a mailbox or a
// share posts the form and the page comes back fresh, which used to throw away
// the two minutes of history. The samples are kept in sessionStorage, this tab
// only, and pushed back on load. Wrapped in try/catch because a private window
// can make even reading it throw.
const CPU_HIST_KEY = 'hm-cpu-history';
try {
  const saved = JSON.parse(sessionStorage.getItem(CPU_HIST_KEY) || 'null');
  if (saved) {
    (saved.c || []).forEach(v => cpuSamples.push(v));
    (saved.cores || []).forEach((arr, i) => { coreSamples[i] = (arr || []).slice(-CPU_KEEP); });
    (saved.r || []).forEach(v => readSamples.push(v));
    (saved.w || []).forEach(v => writeSamples.push(v));
    (saved.t || []).forEach(v => tempSamples.push(v));
    (saved.m || []).forEach(v => memSamples.push(v));
    if (typeof saved.disk === 'boolean') avail.disk = saved.disk;
    if (typeof saved.temp === 'boolean') avail.temp = saved.temp;
    if (typeof saved.mem === 'boolean') avail.mem = saved.mem;
  }
} catch (e) { /* no history to restore */ }

function saveCpuHist() {
  try {
    sessionStorage.setItem(CPU_HIST_KEY, JSON.stringify({
      c: cpuSamples, cores: coreSamples, r: readSamples,
      w: writeSamples, t: tempSamples, m: memSamples,
      disk: avail.disk, temp: avail.temp, mem: avail.mem
    }));
  } catch (e) { /* storage full or blocked: the live graph still runs */ }
}

async function cpuTick() {
  // Runs for the page, not for the dialog: the panel under the table is live
  // whether or not a job is going. A tab nobody is looking at asks for nothing,
  // and drops its previous sample so the gap is never divided into a rate.
  if (document.hidden) {
    cpuPrev = null;
    cpuTimer = setTimeout(cpuTick, 2000);
    return;
  }
  try {
    const r = await fetch('?ask=cpu', { headers: { 'Accept': 'application/json' } });
    const j = await r.json();
    if (j.ok) {
      if (cpuPrev) {
        const dt = j.total - cpuPrev.total;
        const di = j.idle  - cpuPrev.idle;
        // A counter that did not move says nothing, so nothing is plotted.
        if (dt > 0) {
          cpuSamples.push(busyPercent(dt, di));
          while (cpuSamples.length > CPU_KEEP) cpuSamples.shift();
          const cores = j.cores || [];
          const was = cpuPrev.cores || [];
          cores.forEach((c, i) => {
            if (!was[i]) return;
            const ct = c.total - was[i].total;
            if (ct <= 0) return;
            if (!coreSamples[i]) coreSamples[i] = [];
            coreSamples[i].push(busyPercent(ct, c.idle - was[i].idle));
            while (coreSamples[i].length > CPU_KEEP) coreSamples[i].shift();
          });
          // Both counters only ever climb, so a drop means the machine rebooted
          // and the difference would be nonsense.
          if (typeof j.reads === 'number' && typeof cpuPrev.reads === 'number') {
            push(readSamples,  Math.max(0, j.reads  - cpuPrev.reads));
            push(writeSamples, Math.max(0, j.writes - cpuPrev.writes));
          }
          if (typeof j.temp === 'number') push(tempSamples, j.temp);
          if (typeof j.mem === 'number') push(memSamples, j.mem);
          drawCpu();
          saveCpuHist();
        }
      }
      // What this machine can answer at all, as opposed to what it happens to
      // be doing. A metric it cannot supply gets no cell rather than an empty
      // one nobody can explain.
      avail.disk = typeof j.reads === 'number';
      avail.temp = typeof j.temp === 'number';
      avail.mem = typeof j.mem === 'number';
      cpuPrev = j;
    }
  } catch (e) {
    // A missed sample is a missed sample. The graph keeps what it has.
  }
  cpuTimer = setTimeout(cpuTick, 1000);
}


function busyPercent(total, idle) {
  return Math.max(0, Math.min(100, Math.round(100 * (total - idle) / total)));
}

function push(arr, v) {
  arr.push(v);
  while (arr.length > CPU_KEEP) arr.shift();
}

// One SVG per cell, made once. The core count comes from the machine, so it is
// not known until the first sample answers.
function cpuCells(grid, count) {
  if (!grid || grid.childElementCount === count) return grid;
  grid.textContent = '';
  for (let i = 0; i < count; i++) {
    const cell = document.createElement('div');
    cell.className = 'cpu-core';
    cell.innerHTML =
      '<svg viewBox="0 0 120 34" preserveAspectRatio="none">' +
      '<path fill="none" stroke="currentColor" stroke-width=".8" d=""></path></svg>' +
      '<b></b><span></span>';
    grid.appendChild(cell);
  }
  return grid;
}

// Value, name, and the bars. Called for every cell of every panel each second.
function fillCell(cell, samples, lo, hi, value, name) {
  if (!cell) return;
  cell.querySelector('path').setAttribute('d', barPath(samples, lo, hi));
  cell.querySelector('b').textContent = value;
  cell.querySelector('span').textContent = name;
}

// Bars, newest on the right, so a graph that is not full yet grows from the
// right rather than stretching to fit.
function barPath(samples, lo, hi) {
  const step = 120 / CPU_KEEP;
  const span = hi - lo || 1;
  return samples.map((v, i) => {
    const x = (120 - (samples.length - i) * step + step / 2).toFixed(2);
    const f = Math.max(0, Math.min(1, (v - lo) / span));
    return `M${x},33V${(33 - f * 31).toFixed(2)}`;
  }).join('');
}

// Every panel on the page draws the same samples: the dialog's and the one at
// the bottom of the table. The disk scales to its own busiest second, which the
// name carries, because operations per second have no natural ceiling.
function drawCpu() {
  const t = T[lang];
  const last = a => a.length ? a[a.length - 1] : null;
  const readPeak  = Math.max(1, ...readSamples);
  const writePeak = Math.max(1, ...writeSamples);

  document.querySelectorAll('[data-cpu-panel]').forEach(panel => {
    const grid = cpuCells(panel.querySelector('.cpu-core-grid'), coreSamples.length);
    coreSamples.forEach((s, i) => {
      fillCell(grid.children[i], s, 0, 100,
               last(s) === null ? '--' : last(s) + '%', 'Core ' + i);
    });

    const cells = [];
    if (avail.disk) {
      cells.push([readSamples, 0, readPeak,
                  last(readSamples) === null ? '--' : String(last(readSamples)),
                  t.diskRead + ' · ' + t.peakIs + ' ' + readPeak]);
      cells.push([writeSamples, 0, writePeak,
                  last(writeSamples) === null ? '--' : String(last(writeSamples)),
                  t.diskWrite + ' · ' + t.peakIs + ' ' + writePeak]);
    }
    if (avail.mem) {
      cells.push([memSamples, 0, 100,
                  last(memSamples) === null ? '--' : last(memSamples) + '%',
                  t.memUsed]);
    }
    if (avail.temp) {
      cells.push([tempSamples, TEMP_LO, TEMP_HI,
                  last(tempSamples) === null ? '--' : last(tempSamples) + '°C',
                  t.cpuTemp]);
    }
    const extra = cpuCells(panel.querySelector('.cpu-extra'), cells.length);
    cells.forEach((c, i) => fillCell(extra.children[i], c[0], c[1], c[2], c[3], c[4]));
  });
}

function applyWatch() {
  const t = T[lang];
  applyWatching = true;
  applySawBusy = false;
  applyTicks = 0;
  // The samples are the page's, not the dialog's, so the graph the dialog opens
  // on already holds the minutes before the job started.
  document.getElementById('apply-log-box').hidden = true;
  document.getElementById('apply-summary').hidden = true;
  document.getElementById('apply-actions').hidden = true;
  document.getElementById('apply-progress').hidden = false;
  document.getElementById('apply-running-actions').hidden = false;
  document.getElementById('apply-close').hidden = true;
  document.getElementById('apply-progress-text').textContent = t.applyWorking;
  logTick();
  applyDialog.classList.add('open');
  applyDialog.classList.add('watching');
  applyScrim.classList.add('open');
  document.body.classList.add('locked');
}

// Called once, when the job is known to be over. `result` is what the apply job
// last reported, which is null for a job Jenkins has never built.
//
// A green run closes itself: there is nothing to read, and a dialog that has to
// be dismissed after every success trains you to dismiss it without looking,
// which is exactly when it matters. Anything else stays, and fetches the log.
function applyFinished(result) {
  const t = T[lang];
  if (!applyWatching) return;
  applyWatching = false;

  // A GREEN RUN NO LONGER CLOSES ITSELF. It used to reload the page the moment
  // Jenkins said SUCCESS, so the result was a page that had already moved on
  // and nothing said what had just happened. The owner, 2026-09-09, after the
  // service dialog waited for a press and the apply one did not.
  //
  // The re-check still runs, and still before anything reloads: the check that
  // ran with the press happened before the build wrote anything, so a reload
  // without it brings back the drift banner for drift this run has just fixed.
  // It is the Close button that reloads now.
  if (result === 'SUCCESS') {
    fetch('?recheck=1', { headers: { 'Accept': 'application/json' } }).catch(() => {});
  }

  const say = result === 'SUCCESS'  ? t.applyDone
            : result === 'UNSTABLE' ? t.applyUnstable
            : result === 'FAILURE'  ? t.applyFailed
            : t.applyUnknown;
  const p = document.querySelector('#apply-progress .msg');
  if (p) p.className = 'msg ' + (result === 'SUCCESS' ? 'good' : result ? 'bad' : 'note');
  const spin = document.querySelector('#apply-progress .spin');
  if (spin) spin.remove();
  document.getElementById('apply-progress-text').textContent = say;
  document.getElementById('apply-close').hidden = false;
  const watched = document.querySelector('#apply-progress .cpu-box');
  if (watched) watched.hidden = true;
  // Only for a run that actually happened, and not for a green one: there is
  // nothing in a successful log that the summary does not already say. With no
  // result the last build is somebody else's run, and its log would answer a
  // different question.
  if (result && result !== 'SUCCESS') loadJobLog('hosting-apply');
}

function busyText(j) {
  const t = T[lang];
  const ago = ms => {
    const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
    return s < 60 ? s + ' s' : Math.floor(s / 60) + ' min';
  };
  const run = j.running || [], q = j.queued || [];
  const lines = [t.busyWaiting || "Waiting for Jenkins to start the apply job.", ''];
  lines.push((t.busyRunning || 'Running now') + ' (' + run.length + '):');
  if (!run.length) lines.push('  ' + (t.busyNothing || 'nothing'));
  run.forEach(b => lines.push('  ' + b.name + '   ' + ago(b.since)));
  lines.push('', (t.busyQueued || 'Waiting in the queue') + ' (' + q.length + '):');
  if (!q.length) lines.push('  ' + (t.busyNothing || 'nothing'));
  q.forEach(i => lines.push('  ' + i.name + '   ' + ago(i.since) + (i.why ? '   ' + i.why : '')));
  return lines.join('\n');
}

// Fetched rather than rendered with the page: it only exists once the job has
// failed, and it is the one thing here worth pasting somewhere else.
async function loadJobLog(job) {
  const box = document.getElementById('apply-log-box');
  const pre = document.getElementById('apply-log');
  if (!box || !pre) return;
  if (!pre.textContent) pre.textContent = T[lang].jobLogWait;
  box.hidden = false;
  if (job === 'hosting-apply' && applyWatching && !applyBuildStarted) {
    // No build of ours yet, so its log would be the previous run's. Say what
    // Jenkins is doing instead, so a wait in the queue does not look like a hang.
    try {
      const r = await fetch('?ask=jobbusy', { headers: { 'Accept': 'application/json' } });
      const j = await r.json();
      // ok:false is Jenkins not answering, which must not read as a slow job.
      pre.textContent = j.ok ? busyText(j) : T[lang].busyUnreachable;
    } catch (e) { /* keep what is on screen */ }
    return;
  }
  try {
    const r = await fetch('?ask=joblog&job=' + encodeURIComponent(job),
                          { headers: { 'Accept': 'application/json' } });
    const j = await r.json();
    const text = j.log && j.log.trim() ? j.log : (j.error || T[lang].jobLogNone);
    if (text !== pre.textContent) {
      // Only follow the tail while the reader is already at it: scrolling back
      // to read something must not be undone a second later.
      const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
      // Writing textContent puts the scroll back at the top, which is why
      // reading anything but the tail was impossible: every poll yanked it up.
      const was = pre.scrollTop;
      pre.textContent = text;
      pre.scrollTop = atEnd ? pre.scrollHeight : was;
    }
  } catch (e) {
    // Keep whatever is on screen. A missed poll is not an empty log.
  }
}

// Tailed on its own timer while the job runs, slower than the CPU graph: the
// console output of a build that has just started changes every few seconds,
// not every second.
let logTimer = null;
function logTick() {
  clearTimeout(logTimer);
  if (!applyWatching) return;
  loadJobLog('hosting-apply');
  logTimer = setTimeout(logTick, 3000);
}

// Pressing it submits the form with action=recheck: the drift has to be
// computed from what is on this screen before it can be shown. The dialog opens
// by itself when the page comes back.

document.getElementById('btn-apply').addEventListener('click', () => {
  document.getElementById('intent').value = 'apply';
});


// =============================================================================
// Re-run one environment's deploy, with the Jenkins console tailed live.
//
// The owner asked for both halves on 2026-09-10: one button per environment row,
// and the output while it runs rather than after it. The shape is the service
// dialog's, with the console in place of the list.
//
// The tail is the same ?ask=joblog endpoint the apply dialog uses. It reads
// lastBuild/consoleText, so it follows the build that was just started.
// =============================================================================
const redeployDialog = document.getElementById('redeploy-dialog');
const redeployScrim  = document.getElementById('redeploy-scrim');
const redeployClose  = document.getElementById('redeploy-close');
const redeployCancel = document.getElementById('redeploy-cancel');
let redeployTimer = null;
let redeployJob   = null;
// Did this dialog START a build, or is it only watching one? It decides whether
// closing reloads the page: a rerun moved the machine, watching moved nothing.
let redeployWeStarted = false;
// Has the poll already moved the panes for a build it found running?
let redeployPanesCorrected = false;

// The labelled facts under the title. The owner, 2026-09-10: three sentences of
// prose, one of which he could not read at all: "Deployed 0146693, the tip of
// live" never said what it was claiming. Each answer gets a label saying what
// the number IS.
//
// One store and one painter, because three lookups land at three different
// times: a slow one repainting must not wipe what another has already
// answered.
const redeployFacts = {};
function setFact(k, v, cls) {
  if (v === null || v === undefined || v === '') delete redeployFacts[k];
  else redeployFacts[k] = { v: v, cls: cls || '' };
  paintFacts();
}
function clearFacts() {
  Object.keys(redeployFacts).forEach(k => delete redeployFacts[k]);
  paintFacts();
}
function paintFacts() {
  const t = T[lang], el = document.getElementById('redeploy-facts');
  if (!el) return;
  const ranLabel = redeployFacts.ranLabel ? redeployFacts.ranLabel.v : t.fRunning;
  const order = [
    ['started',  t.fStarted],
    ['ran',      ranLabel],
    ['runs',     t.fRuns],
    ['avgWins',  t.fAvgWins],
    ['avgFail',  t.fAvgFail],
    ['avgDone',  t.fAvgAll],
    ['deployed', t.fDeployed],
    ['branch',   t.fBranch]
  ];
  el.innerHTML = order
    .filter(([k]) => redeployFacts[k])
    .map(([k, label]) => '<dt>' + esc(label) + '</dt><dd class="'
       + esc(redeployFacts[k].cls) + '">' + esc(redeployFacts[k].v) + '</dd>')
    .join('');
}

// Jenkins fills duration in only when the build ENDS, so a running build
// reports 0. Elapsed is worked out from the start instead, or it would read as
// having taken no time at all for as long as it runs.
//
// humanMs and clockOf live in cells.js: the table needs them too, and cells.js
// loads first.
function buildTiming(one, t) {
  if (!one || !one.started) { setFact('started', ''); setFact('ran', ''); return ''; }
  // Clamped at zero. The build's start time is the MACHINE's clock and the
  // subtraction uses the BROWSER's, and the two are not the same: measured
  // 2026-09-10, this machine runs 9 seconds ahead of the Windows PC watching
  // it. A build younger than that skew came out negative, humanMs returned
  // nothing for it, and the line read 'Running for ?'.
  const ran = one.running ? Math.max(0, Date.now() - one.started) : one.duration;
  setFact('started', clockOf(one.started));
  // The label changes with the tense: a finished build did not take the time it
  // is taking. Stored as a fact of its own so paintFacts stays a painter.
  setFact('ranLabel', one.running ? t.fRunning : t.fTook);
  // Only the WARNING is carried here. The average has a line of its own below.
  const slow = one.running && redeployAvg && ran > redeployAvg * 1.5;
  setFact('ran', humanMs(ran) || (one.running ? '0s' : ''), slow ? 'warn' : '');
  setFact('slow', slow ? t.redeploySlow.replace('%d', humanMs(redeployAvg)) : '');
  return '';
}

// The last twenty runs of this job, and what they average. Fetched once when
// the dialog opens: the history of finished builds does not change while one
// runs, so polling it would be twenty round trips for the same answer.
//
// The average is what makes the running number mean something: 40s is fast or
// slow only against what this job usually takes.
let redeployAvg = null;
async function loadRedeployHistory(row, env) {
  const t = T[lang];
  const tbl   = document.getElementById('redeploy-history-table');
  redeployAvg = null;
  if (tbl) tbl.innerHTML = '';
  let j = null;
  try {
    const r = await fetch('?ask=jobhistory&row=' + encodeURIComponent(row)
                          + '&env=' + encodeURIComponent(env),
                          { headers: { 'Accept': 'application/json' } });
    j = await r.json();
  } catch (e) {
    return;
  }
  if (!j || !Array.isArray(j.builds) || !j.builds.length) {
    setFact('runs', t.fNoRuns);
    return;
  }
  redeployAvg = j.average || null;
  // Three numbers, three lines: how many runs finished, how long a SUCCESSFUL
  // deploy takes, and how long any finished run takes. The owner asked for both
  // averages, 2026-09-10: they answer different questions and neither is a
  // substitute for the other on a job whose runs are mostly NOT_BUILT.
  setFact('runs', String(j.finished !== undefined ? j.finished : (j.counted || 0)));
  setFact('avgWins', j.avgWins
    ? (humanMs(j.avgWins) || '') + ' ' + t.fOverN.replace('%n', String(j.wins || 0))
    : '');
  setFact('avgFail', j.avgFail
    ? (humanMs(j.avgFail) || '') + ' ' + t.fOverN.replace('%n', String(j.fails || 0))
    : '');
  setFact('avgDone', j.avgDone
    ? (humanMs(j.avgDone) || '') + ' ' + t.fOverN.replace('%n', String(j.finished || 0))
    : '');
  if (!tbl) return;
  // Result, when, how long. In that order because the eye scans the first
  // column for the red one, which is the row anybody opens this to find.
  tbl.innerHTML = '<tr><th>#</th><th>' + esc(t.hResult) + '</th><th>'
    + esc(t.hStarted) + '</th><th>' + esc(t.hTook) + '</th></tr>'
    + j.builds.map(b => {
        const cls = b.result === 'SUCCESS' ? 'up'
                  : ((b.result === null || b.result === 'NOT_BUILT') ? '' : 'down');
        return `<tr><td class="port">${esc(String(b.number))}</td>
          <td><span class="chip ${cls}">${esc(resultWord(b.result, t))}</span></td>
          <td>${esc(new Date(b.started).toLocaleString(lang === 'nl' ? 'nl-NL' : 'en-GB'))}</td>
          <td>${esc(humanMs(b.duration) || '')}</td></tr>`;
      }).join('');
}

// Which stage the build is on, from pipeline-stage-view's wfapi. Polled with
// the log, because unlike the history this DOES change while a build runs: it
// is the answer to "where has it got to", which is the question a raw console
// makes you read a thousand lines to answer.
async function loadRedeployStages(row, env) {
  const t = T[lang];
  const el = document.getElementById('redeploy-stages');
  if (!el) return;
  let j = null;
  try {
    const r = await fetch('?ask=jobhistory&what=stages&row=' + encodeURIComponent(row)
                          + '&env=' + encodeURIComponent(env),
                          { headers: { 'Accept': 'application/json' } });
    j = await r.json();
  } catch (e) {
    return;                       // keep whatever is on screen
  }
  if (!j || !Array.isArray(j.stages) || !j.stages.length) { el.innerHTML = ''; return; }
  el.innerHTML = j.stages.map(s => {
    const st = s.status;
    const cls = st === 'SUCCESS' ? 'ok'
              : st === 'IN_PROGRESS' ? 'run'
              : (st === 'NOT_EXECUTED' || st === 'SKIPPED') ? 'skipped'
              : (st === 'FAILED' || st === 'UNSTABLE' || st === 'ABORTED') ? 'bad' : '';
    return `<li class="${cls}" title="${esc(st || '')}">${esc(s.name)}
      <span class="ms">${esc(humanMs(s.duration) || '')}</span></li>`;
  }).join('');
}

// What is actually deployed, and whether the branch has moved since. Item 104
// feature 5: "Succeeded" says nothing about WHICH commit it succeeded on, which
// is the question somebody asks after pushing.
//
// Polled with the log rather than fetched once: the point of pressing rerun is
// usually that the branch moved, so this is the line that has to change.
async function loadRedeployCommit(row, env) {
  const t = T[lang];
  let j = null;
  try {
    const r = await fetch('?ask=deployed&row=' + encodeURIComponent(row)
                          + '&env=' + encodeURIComponent(env),
                          { headers: { 'Accept': 'application/json' } });
    j = await r.json();
  } catch (e) {
    return;                       // keep whatever is on screen
  }
  if (!j || !j.deployed) {
    setFact('deployed', j && j.head ? t.fNothingDeployed : '');
    setFact('branch', '');
    return;
  }
  const short = v => String(v).slice(0, 7);
  const branch = j.branch || env;
  setFact('deployed', short(j.deployed));
  // behind is null when a lookup failed, and that is NOT the same as up to
  // date: saying so on a failed check is the one answer nobody could catch
  // being wrong.
  if (j.behind === true) {
    setFact('branch', t.fBranchBehind.replace('%b', branch).replace('%h', short(j.head)), 'warn');
  } else if (j.behind === false) {
    setFact('branch', t.fBranchCurrent.replace('%b', branch), 'good');
  } else {
    setFact('branch', t.fBranchUnknown.replace('%b', branch));
  }
}

function closeRedeploy() {
  clearTimeout(redeployTimer);
  redeployTimer = null;
  redeployJob = null;
  const cpuBox = document.getElementById('redeploy-cpu');
  if (cpuBox) cpuBox.hidden = true;
  redeployDialog.classList.remove('open');
  redeployScrim.classList.remove('open');
  document.body.classList.remove('locked');
  // Only when THIS dialog started something. A rerun moved the machine, so the
  // page is showing what was true before it did; watching a build moved
  // nothing, and reloading the page on close threw away the tab, the sub-view
  // and any open work for no reason. The owner, 2026-09-10.
  if (redeployWeStarted) {
    redeployWeStarted = false;
    location.replace(location.pathname);
  }
}
if (redeployClose) redeployClose.addEventListener('click', closeRedeploy);

// The tail, and the thing that decides when to stop tailing. Asked of the job
// status rather than of the log: a log that stops growing has not necessarily
// finished, and a build that fails in its first second has almost no log at all.
async function redeployTick() {
  clearTimeout(redeployTimer);
  if (!redeployJob) return;
  const pre = document.getElementById('redeploy-log');
  try {
    const r = await fetch('?ask=joblog&job=' + encodeURIComponent(redeployJob.job),
                          { headers: { 'Accept': 'application/json' } });
    const j = await r.json();
    const text = j.log && j.log.trim() ? j.log : (j.error || T[lang].jobLogWait);
    if (text !== pre.textContent) {
      // Follow the tail only while the reader is already at it, the same rule
      // the apply dialog's log uses: scrolling back to read must not be undone.
      const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
      const was = pre.scrollTop;
      pre.textContent = text;
      pre.scrollTop = atEnd ? pre.scrollHeight : was;
    }
  } catch (e) {
    // A missed poll is not an empty log. Keep what is on screen.
  }

  let done = false, result = null, mine = null;
  try {
    const s = await fetch('?ask=jobs', { headers: { 'Accept': 'application/json' } });
    const sj = await s.json();
    const one = ((sj.sites || {})[redeployJob.row] || {}).jobs || {};
    mine = one['deploy-' + redeployJob.env];
    if (mine && !mine.running) { done = true; result = mine.result; }
  } catch (e) {
    // Unknown is not finished: keep tailing rather than declaring success.
  }

  // Started at, and how long it has been going. Repainted every poll, so a
  // running build counts up rather than sitting on the value it opened with.
  //
  // Only when the status actually answered. A poll that timed out knows nothing
  // about the build, and blanking the line on it wiped the timing off the
  // finished dialog: seen happening after a cancel, where the abort made the
  // status call slow enough to miss its own window.
  if (mine) buildTiming(mine, T[lang]);
  // SITEJOBS is up to five seconds old, so a build that had just started opened
  // the dialog on its history. The poll knows better: the first time it sees a
  // build going, the console takes over. Once only, so it never fights a pane
  // the operator has folded by hand.
  if (mine && mine.running && !redeployPanesCorrected) {
    redeployPanesCorrected = true;
    redeployPanes(true);
  }
  loadRedeployStages(redeployJob ? redeployJob.row : '', redeployJob ? redeployJob.env : '');
  loadRedeployCommit(redeployJob ? redeployJob.row : '', redeployJob ? redeployJob.env : '');

  if (done) {
    const msg = document.getElementById('redeploy-msg');
    msg.hidden = false;
    // NOT_BUILT is not a failure and must not be red: it is the commonest
    // result here and means the deploy found nothing to do. Only a real
    // conclusion against the build is bad.
    msg.className = 'msg ' + (result === 'SUCCESS' ? 'good'
                            : (result === 'NOT_BUILT' ? '' : 'bad'));
    // The operator's word, not Jenkins': they pressed Cancel, so it says
    // cancelled. resultWord lives in cells.js beside the column that uses it.
    msg.textContent = T[lang].redeployEnded.replace('%r', resultWord(result, T[lang]));
    // A build that succeeded has nothing left to read, so its console folds
    // away and the history takes the space: the new run is the top row of it.
    // Anything else stays open, because the reason is in the log. The owner,
    // 2026-09-10.
    if (result === 'SUCCESS' || result === 'NOT_BUILT') {
      redeployPanes(false);
      // The run that just finished is not in the table yet: it was fetched when
      // the dialog opened, and it is now the row worth reading.
      if (redeployJob) loadRedeployHistory(redeployJob.row, redeployJob.env);
    }
    redeployClose.disabled = false;
    redeployCancel.hidden = true;
    redeployClose.focus();
    redeployJob = null;
    return;
  }
  redeployTimer = setTimeout(redeployTick, 3000);
}

// Open the dialog on a build without starting anything.
//
// The pipeline word in the table opens this, not startRedeploy: it is a status,
// and pressing a status must never make the machine do work. Measured
// 2026-09-10, which is why this exists: startRedeploy's "already building"
// guard reads SITEJOBS, the status poll is up to five seconds old, and a click
// during that gap queued build #94 while #93 was still going.
//
// A finished build is fine to open too: the tail reads the last build's console
// and the poll reports the result it already has.
function watchRedeploy(row, env) {
  const t = T[lang];
  resetRedeployDialog(row, env, t.redeployWatching.replace('%s', row).replace('%e', env));

  const one = (typeof SITEJOBS !== 'undefined' && SITEJOBS)
    ? (((SITEJOBS[row] || {}).jobs || {})['deploy-' + env] || {}) : {};
  redeployWeStarted = false;
  redeployPanes(!!one.running);
  redeployJob = { job: row + '/deploy-' + env, row: row, env: env };
  // Cancel belongs to a build that is actually going. The poll shows it if one
  // turns out to be running after all.
  redeployCancel.hidden = !one.running;
  redeployTick();
}

// Which half of the dialog is open, decided by whether a build is going RIGHT
// NOW rather than by which button opened it. The owner, 2026-09-10: a running
// build opened on its history and folded away the console, which is the one
// thing worth watching while it runs.
//
// Nothing is going: the question is "how has this been going", and the answer
// is the last 20 runs.
function redeployPanes(running) {
  redeployPanesCorrected = running;
  const hist = document.getElementById('redeploy-history');
  const log  = document.getElementById('redeploy-log-box');
  if (hist) hist.open = !running;
  if (log)  log.open  = running;
}

// Everything both entry points do to the dialog before they differ.
function resetRedeployDialog(row, env, whatText) {
  const t = T[lang];
  document.getElementById('redeploy-title').textContent = t.redeployTitle;
  document.getElementById('redeploy-what').textContent = whatText;
  const pre = document.getElementById('redeploy-log');
  pre.textContent = t.jobLogWait;
  const msg = document.getElementById('redeploy-msg');
  msg.hidden = true;
  msg.className = 'msg';
  redeployClose.disabled = true;
  redeployClose.textContent = t.bClose;
  redeployCancel.hidden = true;
  redeployCancel.disabled = false;
  redeployCancel.textContent = t.redeployCancel;
  clearFacts();
  loadRedeployHistory(row, env);
  const strip = document.getElementById('redeploy-stages');
  if (strip) strip.innerHTML = '';
  loadRedeployCommit(row, env);

  redeployDialog.classList.add('open');
  redeployScrim.classList.add('open');
  document.body.classList.add('locked');

  const cpuBox = document.getElementById('redeploy-cpu');
  if (cpuBox) { cpuBox.hidden = false; drawCpu(); }
}

// Start a deploy and stay out of the way.
//
// The owner, 2026-09-10: "we can just rebuild the thing without opening the dialog
// box and then wait for the user to open the dialog". Pressing Re-run is an
// instruction, not a request to watch: the row sweeps, the pipeline word says
// Running, and the log button is there when you want to see it.
//
// The dialog opens on a REFUSAL only, because a refusal has a reason worth
// reading: "already running" and "no such job" need different answers.
async function startRedeploy(row, env) {
  const t = T[lang];

  // Already going, usually because a push started it. Nothing to start, so this
  // is just a look: open the dialog on it.
  const already = (typeof SITEJOBS !== 'undefined' && SITEJOBS)
    ? (((SITEJOBS[row] || {}).jobs || {})['deploy-' + env] || {}).running
    : false;
  if (already) { watchRedeploy(row, env); return; }

  // The row says something is happening straight away: the POST answers as soon
  // as Jenkins accepts the job, but the status poll is up to five seconds behind
  // it, and a button that appears to do nothing gets pressed twice.
  document.querySelectorAll(`[data-redeploy-row="${cssEsc(row)}"][data-redeploy-env="${cssEsc(env)}"]`)
    .forEach(b => { b.disabled = true; });

  let d = null;
  try {
    const body = new URLSearchParams({ action: 'redeploy', row: row, env: env });
    const r = await fetch(location.pathname, { method: 'POST', body: body,
      headers: { 'Accept': 'application/json' } });
    d = await r.json();
  } catch (e) {
    d = null;
  }

  if (!d || !d.ok) {
    // The one case worth interrupting for. resetRedeployDialog puts the dialog
    // in a known state first, so the reason is not shown under a previous
    // build's stages and timings.
    resetRedeployDialog(row, env, t.redeployWhat.replace('%s', row).replace('%e', env));
    redeployWeStarted = false;
    const msg = document.getElementById('redeploy-msg');
    msg.hidden = false;
    msg.className = 'msg bad';
    msg.textContent = (d && d.out) ? d.out.split('\n').filter(Boolean).slice(-1)[0]
                                   : t.redeployNoStart;
    redeployClose.disabled = false;
    document.querySelectorAll(`[data-redeploy-row="${cssEsc(row)}"][data-redeploy-env="${cssEsc(env)}"]`)
      .forEach(b => { b.disabled = false; });
    return;
  }

  // Ask the status now rather than waiting out the poll, so the row shows the
  // build within a second of the press.
  if (typeof refreshJobs === 'function') refreshJobs();
}

// Stop a build from the row it belongs to, without opening anything. Confirmed
// first: a build stopped halfway leaves whatever it had already written on the
// machine, which is not the same as never having run.
async function cancelFromRow(row, env) {
  const t = T[lang];
  if (!confirm(t.redeployCancelAsk.replace('%s', row).replace('%e', env))) return;
  document.querySelectorAll(`[data-cancel-row="${cssEsc(row)}"][data-cancel-env="${cssEsc(env)}"]`)
    .forEach(b => { b.disabled = true; });
  try {
    const body = new URLSearchParams({ action: 'redeploy', row: row, env: env, stop: '1' });
    await fetch(location.pathname, { method: 'POST', body: body,
      headers: { 'Accept': 'application/json' } });
  } catch (e) {
    // The poll below is what says whether it actually stopped, so a dropped
    // request is not reported as a failure to cancel.
  }
  if (typeof refreshJobs === 'function') refreshJobs();
}

// Cancel. Confirmed first: a build stopped halfway leaves whatever it had
// already written on the machine, which is not the same as never having run.
if (redeployCancel) redeployCancel.addEventListener('click', async () => {
  if (!redeployJob) return;
  const t = T[lang];
  if (!confirm(t.redeployCancelAsk.replace('%s', redeployJob.row)
                                  .replace('%e', redeployJob.env))) return;
  redeployCancel.disabled = true;
  redeployCancel.textContent = t.redeployCancelling;
  try {
    const body = new URLSearchParams({ action: 'redeploy', row: redeployJob.row,
                                       env: redeployJob.env, stop: '1' });
    await fetch(location.pathname, { method: 'POST', body: body,
      headers: { 'Accept': 'application/json' } });
  } catch (e) {
    // The poll below is what says whether it actually stopped, so a dropped
    // request is not reported as a failure to cancel.
  }
  // Nothing is declared here. The status poll decides when it is over and what
  // the result was, exactly as it does for a build that ends on its own.
  redeployTick();
});

document.addEventListener('click', ev => {
  // A status opened, never a build started. The pipeline word in the table.
  const w = ev.target.closest('[data-watch-row]');
  if (w) { watchRedeploy(w.dataset.watchRow, w.dataset.watchEnv); return; }

  const c = ev.target.closest('[data-cancel-row]');
  if (c && !c.disabled) { cancelFromRow(c.dataset.cancelRow, c.dataset.cancelEnv); return; }

  const b = ev.target.closest('[data-redeploy-row]');
  if (!b || b.disabled) return;
  startRedeploy(b.dataset.redeployRow, b.dataset.redeployEnv);
});
