// Live run dashboard (#1444 spike).
//
// Consumes the SSE stream at /api/live/stream. Every frame is self-contained,
// so rendering is idempotent: cards are created once per run and their fields
// updated in place (keeps CSS animations and text selection stable).
//
// Honesty rules mirrored from the runtime side:
//  - Budget meters are true enforced fractions (deadline, evaluations, calls).
//  - Heap is a high-water readout + sparkline, deliberately NOT a gauge:
//    the max_heap check runs only at GC, so kills can occur far below ceiling.

const WORD_BYTES = 8;

export function createLiveController({ onLiveCount } = {}) {
  const runsEl = document.getElementById('live-runs');
  const emptyEl = document.getElementById('live-empty');
  const connEl = document.getElementById('live-connection');
  const launchEl = document.getElementById('live-launch');
  const cards = new Map(); // run_id -> { frame, el, fields }

  let source = null;

  connect();
  initLaunch(launchEl).catch(() => {});

  function connect() {
    source = new EventSource('/api/live/stream');
    source.onopen = () => setConnection('live', 'Streaming');
    source.onerror = () => setConnection('down', 'Reconnecting…');
    source.onmessage = event => {
      let frame;
      try {
        frame = JSON.parse(event.data);
      } catch {
        return;
      }
      if (frame && typeof frame.run_id === 'string') accept(frame);
    };
  }

  function setConnection(state, text) {
    connEl.dataset.state = state;
    connEl.textContent = text;
  }

  function accept(frame) {
    let card = cards.get(frame.run_id);
    if (!card) {
      card = createCard(frame.run_id);
      cards.set(frame.run_id, card);
      runsEl.prepend(card.el);
    }
    if (card.frame && typeof frame.seq === 'number' && frame.seq < card.frame.seq) return;
    card.frame = frame;
    updateCard(card, frame);
    refreshChrome();
  }

  function refreshChrome() {
    const liveCount = [...cards.values()].filter(c => c.frame?.phase === 'running').length;
    emptyEl.hidden = cards.size > 0;
    onLiveCount?.(liveCount);
  }

  function setActive(_active) {
    // The stream stays open regardless of tab visibility: frames are tiny and
    // keeping state current makes tab switches instant.
  }

  return { setActive };
}

/* ---------- launch panel (fixed target, editable input) ---------- */

async function initLaunch(root) {
  const response = await fetch('/api/live/launch');
  if (!response.ok) return;
  const spec = await response.json();
  if (!spec.enabled) return;

  root.hidden = false;
  root.innerHTML = `
    <div class="live-launch-card">
      <div class="live-launch-head">
        <span class="live-section-label">Launch a run</span>
        <span class="live-launch-target" data-role="target"></span>
      </div>
      <label class="live-launch-label">Input object — the only thing the browser controls; passed to <code>mix ptc run --input</code></label>
      <textarea class="live-launch-input" data-role="editor" spellcheck="false" rows="10"></textarea>
      <div class="live-launch-foot">
        <span class="live-launch-validity" data-role="validity"></span>
        <button type="button" class="live-launch-run" data-role="run">▶ Run</button>
      </div>
      <div class="live-launch-status" data-role="status" hidden></div>
    </div>
  `;

  const fields = {};
  for (const node of root.querySelectorAll('[data-role]')) fields[node.dataset.role] = node;
  fields.target.textContent = spec.label ? `${spec.label} · ${spec.manifest}` : spec.manifest;
  fields.editor.value = JSON.stringify(spec.input ?? {}, null, 2);

  const state = { running: spec.launch?.status === 'running', polling: null };

  const validate = () => {
    let parsed = null;
    let error = null;
    try {
      parsed = JSON.parse(fields.editor.value);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        error = 'input must be a JSON object';
        parsed = null;
      }
    } catch (e) {
      error = e.message.split('\n')[0];
    }
    fields.validity.textContent = error || 'valid JSON';
    fields.validity.dataset.state = error ? 'bad' : 'ok';
    fields.run.disabled = Boolean(error) || state.running;
    return parsed;
  };

  const setStatus = (status) => {
    state.running = status?.status === 'running';
    fields.run.disabled = state.running || fields.validity.dataset.state === 'bad';
    fields.run.textContent = state.running ? 'Running…' : '▶ Run';
    if (!status || status.status === 'idle') {
      fields.status.hidden = true;
      return;
    }
    fields.status.hidden = false;
    fields.status.dataset.state = status.status;
    if (status.status === 'running') {
      fields.status.textContent = 'Run launched — its card appears below as frames arrive.';
    } else if (status.status === 'ok') {
      fields.status.textContent = 'Last launch completed (exit 0).';
    } else {
      fields.status.replaceChildren();
      const line = document.createElement('div');
      line.textContent = 'Last launch failed:';
      const pre = document.createElement('pre');
      pre.textContent = status.output_tail || '(no output captured)';
      fields.status.append(line, pre);
    }
  };

  const poll = async () => {
    try {
      const res = await fetch('/api/live/launch');
      if (!res.ok) return;
      const current = await res.json();
      setStatus(current.launch);
      if (current.launch?.status === 'running') {
        state.polling = setTimeout(poll, 1500);
      }
    } catch {
      state.polling = setTimeout(poll, 3000);
    }
  };

  fields.editor.addEventListener('input', validate);
  fields.run.addEventListener('click', async () => {
    const parsed = validate();
    if (!parsed || state.running) return;
    setStatus({ status: 'running' });
    const res = await fetch('/api/live/launch', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ input: parsed }),
    });
    if (res.status !== 202) {
      const body = await res.json().catch(() => ({}));
      setStatus({ status: 'error', output_tail: `launch refused: ${body.error || res.status}` });
      return;
    }
    clearTimeout(state.polling);
    state.polling = setTimeout(poll, 1500);
  });

  validate();
  setStatus(spec.launch);
  if (state.running) state.polling = setTimeout(poll, 1500);
}

/* ---------- card construction ---------- */

function createCard(runId) {
  const el = document.createElement('article');
  el.className = 'live-card';
  el.innerHTML = `
    <header class="live-card-head">
      <div class="live-card-title">
        <span class="live-badge" data-role="badge"><span class="live-badge-dot"></span><span data-role="badge-text">RUNNING</span></span>
        <h2 data-role="label"></h2>
      </div>
      <div class="live-card-meta">
        <span class="live-run-id" data-role="run-id"></span>
        <span class="live-elapsed" data-role="elapsed"></span>
      </div>
    </header>

    <div class="live-kpis">
      <div class="live-kpi"><span class="live-kpi-value" data-role="kpi-calls">–</span><span class="live-kpi-label">tool calls</span></div>
      <div class="live-kpi"><span class="live-kpi-value" data-role="kpi-evals">–</span><span class="live-kpi-label">evaluations</span></div>
      <div class="live-kpi"><span class="live-kpi-value" data-role="kpi-left">–</span><span class="live-kpi-label">time left</span></div>
      <div class="live-kpi live-kpi-workers">
        <span class="live-kpi-value" data-role="kpi-workers">–</span>
        <span class="live-worker-dots" data-role="worker-dots" aria-hidden="true"></span>
        <span class="live-kpi-label">workers</span>
      </div>
    </div>

    <div class="live-meters" data-role="meters"></div>

    <div class="live-heap" data-role="heap-panel" hidden>
      <div class="live-heap-head">
        <span class="live-section-label">Sandbox heap</span>
        <span class="live-heap-stats" data-role="heap-stats"></span>
      </div>
      <svg class="live-spark" data-role="spark" viewBox="0 0 240 36" preserveAspectRatio="none" role="img" aria-label="Observed heap samples"></svg>
      <p class="live-heap-note">observed samples &amp; high-water — not a gauge: the heap limit is checked at GC, kills can occur below the ceiling</p>
    </div>

    <div class="live-activity-wrap">
      <span class="live-section-label">Activity</span>
      <ol class="live-activity" data-role="activity"></ol>
    </div>
  `;

  const fields = {};
  for (const node of el.querySelectorAll('[data-role]')) fields[node.dataset.role] = node;
  fields['run-id'].textContent = runId;
  return { frame: null, el, fields };
}

/* ---------- per-frame update ---------- */

function updateCard(card, frame) {
  const f = card.fields;
  const usage = frame.usage || {};
  const limits = frame.limits || {};

  f.label.textContent = frame.label || frame.run_id;
  f.elapsed.textContent = fmtClock(frame.elapsed_ms);

  updateBadge(card, frame);

  const calls = totalCalls(usage.capability_calls);
  f['kpi-calls'].textContent = String(calls);
  f['kpi-evals'].textContent = usage.subordinate_evaluations ?? '–';
  f['kpi-left'].textContent = frame.remaining_ms == null ? '–' : fmtSeconds(frame.remaining_ms);
  updateWorkers(f, frame.parallel);

  renderMeters(f.meters, frame, usage, limits, calls);
  renderHeap(f, frame.heap);
  renderActivity(f.activity, frame.activity || []);
}

function updateBadge(card, frame) {
  const badge = card.fields.badge;
  const text = card.fields['badge-text'];
  const phase = frame.phase === 'running' ? 'running' : frame.phase === 'ok' ? 'ok' : 'error';
  badge.dataset.phase = phase;
  card.el.dataset.phase = phase;
  text.textContent =
    phase === 'running' ? 'RUNNING' : phase === 'ok' ? '✓ COMPLETED' : '✗ FAILED';
  if (phase === 'error' && frame.outcome_reason) badge.title = frame.outcome_reason;
}

function updateWorkers(fields, parallel) {
  if (!parallel) {
    fields['kpi-workers'].textContent = '–';
    fields['worker-dots'].replaceChildren();
    return;
  }
  fields['kpi-workers'].textContent = `${parallel.held}/${parallel.capacity}`;
  const dots = [];
  for (let i = 0; i < Math.min(parallel.capacity, 16); i++) {
    const dot = document.createElement('span');
    dot.className = i < parallel.held ? 'live-dot held' : 'live-dot';
    dots.push(dot);
  }
  fields['worker-dots'].replaceChildren(...dots);
}

/* ---------- meters (true enforced budgets only) ---------- */

function renderMeters(container, frame, usage, limits, calls) {
  const rows = [];

  if (frame.remaining_ms != null && limits.run_duration_ms) {
    const used = Math.max(limits.run_duration_ms - frame.remaining_ms, 0);
    rows.push(meterRow('Deadline', used, limits.run_duration_ms, `${fmtSeconds(frame.remaining_ms)} left`));
  }
  if (usage.subordinate_evaluations != null && limits.subordinate_evaluations) {
    rows.push(meterRow('Evaluations', usage.subordinate_evaluations, limits.subordinate_evaluations,
      `${usage.subordinate_evaluations} / ${limits.subordinate_evaluations}`));
  }
  if (limits.workflow_capability_calls) {
    rows.push(meterRow('Tool calls', calls, limits.workflow_capability_calls,
      `${calls} / ${limits.workflow_capability_calls}`));
  }
  if (usage.evaluation_memory_bytes != null && limits.evaluation_memory_bytes) {
    const bytes = numberOr(usage.evaluation_memory_bytes, limits.evaluation_memory_bytes);
    rows.push(meterRow('Retained memory', bytes, limits.evaluation_memory_bytes,
      `${fmtBytes(bytes)} / ${fmtBytes(limits.evaluation_memory_bytes)}`));
  }

  container.replaceChildren(...rows);
}

function meterRow(label, value, limit, detail) {
  const fraction = Math.max(0, Math.min(value / limit, 1));
  const level = fraction >= 0.9 ? 'critical' : fraction >= 0.75 ? 'warning' : 'normal';
  const row = document.createElement('div');
  row.className = 'live-meter';
  row.innerHTML = `
    <span class="live-meter-label"></span>
    <span class="live-meter-track"><span class="live-meter-fill" data-level="${level}"></span></span>
    <span class="live-meter-detail"></span>
  `;
  row.querySelector('.live-meter-label').textContent = label;
  row.querySelector('.live-meter-fill').style.width = `${(fraction * 100).toFixed(1)}%`;
  row.querySelector('.live-meter-detail').textContent = detail;
  return row;
}

/* ---------- heap: readout + sparkline, never a gauge ---------- */

function renderHeap(fields, heap) {
  const panel = fields['heap-panel'];
  if (!heap || !heap.peak_words) {
    panel.hidden = true;
    return;
  }
  panel.hidden = false;

  const peak = fmtBytes(heap.peak_words * WORD_BYTES);
  const ceiling = heap.ceiling_words ? fmtBytes(heap.ceiling_words * WORD_BYTES) : null;
  fields['heap-stats'].textContent = ceiling
    ? `peak ${peak} · ceiling ${ceiling}`
    : `peak ${peak}`;

  const samples = (heap.samples || []).filter(v => typeof v === 'number');
  fields.spark.replaceChildren(sparkPath(samples));
}

function sparkPath(samples) {
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  if (samples.length < 2) return path;
  const w = 240;
  const h = 36;
  const pad = 2;
  const min = Math.min(...samples);
  const max = Math.max(...samples);
  const span = Math.max(max - min, 1);
  const step = (w - pad * 2) / (samples.length - 1);
  const points = samples.map((v, i) => {
    const x = pad + i * step;
    const y = h - pad - ((v - min) / span) * (h - pad * 2);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });
  path.setAttribute('d', `M${points.join(' L')}`);
  path.setAttribute('class', 'live-spark-line');
  return path;
}

/* ---------- activity feed ---------- */

function renderActivity(list, entries) {
  const rows = entries.slice(0, 14).map(entry => {
    const li = document.createElement('li');
    li.className = `live-event kind-${entry.kind || 'other'}`;
    const name = entry.name || (entry.kind === 'evaluation' ? 'evaluation' : entry.kind);
    const status = entry.status === 'start' ? 'started' : entry.status;
    const duration = entry.duration_ms != null ? fmtSeconds(entry.duration_ms) : '';
    li.innerHTML = `
      <span class="live-event-t"></span>
      <span class="live-event-name"></span>
      <span class="live-event-status"></span>
      <span class="live-event-duration"></span>
    `;
    li.querySelector('.live-event-t').textContent = fmtClock(entry.t);
    li.querySelector('.live-event-name').textContent = name;
    li.querySelector('.live-event-status').textContent = status;
    li.querySelector('.live-event-status').dataset.status = entry.status;
    li.querySelector('.live-event-duration').textContent = duration;
    return li;
  });
  list.replaceChildren(...rows);
}

/* ---------- formatting ---------- */

function totalCalls(capabilityCalls) {
  if (!capabilityCalls) return 0;
  let total = 0;
  for (const scope of Object.values(capabilityCalls)) {
    if (scope && typeof scope === 'object') {
      for (const count of Object.values(scope)) {
        if (typeof count === 'number') total += count;
      }
    }
  }
  return total;
}

function numberOr(value, fallback) {
  return typeof value === 'number' ? value : fallback;
}

function fmtClock(ms) {
  if (typeof ms !== 'number') return '–';
  const total = Math.floor(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}

function fmtSeconds(ms) {
  if (ms >= 10_000) return `${Math.round(ms / 1000)}s`;
  if (ms >= 1000) return `${(ms / 1000).toFixed(1)}s`;
  return `${ms}ms`;
}

function fmtBytes(bytes) {
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${bytes} B`;
}
