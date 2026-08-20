// Live run dashboard.
//
// Consumes the SSE stream at /api/live/stream. Every frame is self-contained,
// so rendering is idempotent: cards are created once per run and their fields
// updated in place (keeps CSS animations and text selection stable). Cards
// sort newest-first by the store's `first_seen_at` stamp, matching
// `GET /api/live/runs`.
//
// Honesty rules mirrored from the runtime side:
//  - Budget meters are true enforced fractions (deadline, evaluations, calls).
//  - Heap is a high-water readout + sparkline, deliberately NOT a gauge:
//    the max_heap check runs only at GC, so kills can occur far below ceiling.

import { formatRunUsage } from './run-display.js';

const WORD_BYTES = 8;

export function liveTokenFromSearch(search) {
  const value = new URLSearchParams(search).get('live_token');
  return value || null;
}

export function liveReadPath(path, liveToken) {
  if (!liveToken) return path;
  const separator = path.includes('?') ? '&' : '?';
  return `${path}${separator}live_token=${encodeURIComponent(liveToken)}`;
}

export function launchPollDelay(responseOk, launch) {
  if (!responseOk) return 3000;
  return launch?.status === 'running' ? 1500 : null;
}

// Snapshot and live frames share one insertion rule: newer `first_seen_at`
// stamps go closer to the top, so hydrating newest-first or oldest-first
// yields the same DOM order.
export function newerFirstInsertIndex(stamps, stamp) {
  const value = typeof stamp === 'string' ? stamp : '';
  const index = stamps.findIndex(existing => value >= (existing || ''));
  return index === -1 ? stamps.length : index;
}

export function formatFirstSeenAt(value) {
  if (!value) return '';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false
  });
}

export function isNewestEndedStamp(existingStamps, stamp) {
  const value = typeof stamp === 'string' ? stamp : '';
  return existingStamps.every(existing => value >= (existing || ''));
}

export function projectDisplayPath(project) {
  return project?.project || project?.manifest || '';
}

export function createLiveController({ onInspectRun, onLiveCount, onProject, mutationNonce, liveToken } = {}) {
  const runsEl = document.getElementById('live-runs');
  const runsHeadEl = document.getElementById('live-runs-head');
  const clearEndedEl = document.getElementById('live-clear-ended');
  const emptyEl = document.getElementById('live-empty');
  const connEl = document.getElementById('live-connection');
  const launchEl = document.getElementById('live-launch');
  const projectEl = document.getElementById('live-project');
  const cards = new Map(); // run_id -> { frame, el, fields, ended, collapsed }

  const commandEl = emptyEl.querySelector('.live-empty-cmd');
  if (commandEl) {
    commandEl.textContent = `PTC_VIEWER_URL=${location.origin} ptc run manifest.json ...`;
  }

  let source = null;
  // Only the most recently ended run stays expanded; the one before it folds
  // away so a finished run cannot keep dominating the page.
  let newestEndedId = null;

  connect();
  clearEndedEl.addEventListener('click', () => clearEnded());
  // One project fetch feeds both panels: the details disclosure and the
  // launch card's environment chips.
  loadProject(liveToken)
    .then(project => {
      onProject?.(project);
      initProject(projectEl, project);
      return initLaunch(launchEl, project, mutationNonce, liveToken);
    })
    .catch(() => {});

  function connect() {
    source = new EventSource(liveReadPath('/api/live/stream', liveToken));
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
      card.fields.close.addEventListener('click', () => removeRun(frame.run_id));
      card.fields.toggle.addEventListener('click', () => setCollapsed(card, !card.collapsed));
      card.fields.inspect.addEventListener('click', event => {
        event.preventDefault();
        void inspectRun(card, frame.run_id);
      });
      cards.set(frame.run_id, card);
      placeCard(runsEl, card.el, frame.first_seen_at);
    }
    if (card.frame && typeof frame.seq === 'number' && frame.seq < card.frame.seq) return;
    card.frame = frame;
    updateCard(card, frame);
    trackLifecycle(card, frame);
    refreshChrome();
  }

  // Only the newest ended run stays expanded. Compare first_seen_at rather than
  // arrival order so a newest-first SSE snapshot does not expand the oldest card.
  function trackLifecycle(card, frame) {
    const wasEnded = card.ended;
    card.ended = frame.phase !== 'running';
    card.fields.inspect.hidden = !card.ended;

    if (!card.ended) {
      setCollapsed(card, false);
      return;
    }

    if (!wasEnded) {
      const incoming = frame.first_seen_at || '';
      const otherStamps = [];
      for (const other of cards.values()) {
        if (other === card || !other.ended) continue;
        otherStamps.push(other.frame?.first_seen_at || '');
      }
      const newest = isNewestEndedStamp(otherStamps, incoming);
      if (newest) {
        for (const other of cards.values()) {
          if (other !== card && other.ended) setCollapsed(other, true);
        }
        newestEndedId = frame.run_id;
      }
      setCollapsed(card, !newest);
      return;
    }

    setCollapsed(card, card.collapsed);
  }

  function setCollapsed(card, collapsed) {
    card.collapsed = Boolean(collapsed) && card.ended;
    card.el.classList.toggle('collapsed', card.collapsed);

    const { toggle, summary } = card.fields;
    toggle.hidden = !card.ended;
    toggle.textContent = card.collapsed ? '▸' : '▾';
    toggle.setAttribute('aria-expanded', String(!card.collapsed));
    toggle.setAttribute('aria-label', card.collapsed ? 'Expand run' : 'Collapse run');
    summary.hidden = !card.collapsed;
  }

  // Optimistic: the card goes now, the store forgets it so a reload agrees.
  function removeRun(runId) {
    const card = cards.get(runId);
    if (!card) return;
    card.el.remove();
    cards.delete(runId);
    if (newestEndedId === runId) newestEndedId = null;
    refreshChrome();
    fetch(`/api/live/runs/${encodeURIComponent(runId)}`, {
      method: 'DELETE',
      headers: mutationHeaders(mutationNonce, liveToken),
    }).catch(() => {});
  }

  function clearEnded() {
    for (const [runId, card] of [...cards]) if (card.ended) removeRun(runId);
  }

  async function inspectRun(card, runId) {
    const link = card.fields.inspect;
    if (!card.ended || link.dataset.loading === 'true') return;
    link.dataset.loading = 'true';
    link.textContent = 'Opening…';

    try {
      const response = await fetch(`/api/live/runs/${encodeURIComponent(runId)}/inspect`, {
        method: 'POST',
        headers: mutationHeaders(mutationNonce, liveToken),
      });
      if (!response.ok) throw new Error('result unavailable');
      link.textContent = 'View result';
      link.title = '';
      delete link.dataset.loading;
      onInspectRun?.(runId);
    } catch {
      link.textContent = 'Retry result';
      link.title = 'The canonical run result is not available yet';
      delete link.dataset.loading;
    }
  }

  function refreshChrome() {
    const values = [...cards.values()];
    const liveCount = values.filter(c => c.frame?.phase === 'running').length;
    emptyEl.hidden = cards.size > 0;
    runsHeadEl.hidden = !values.some(c => c.ended);
    onLiveCount?.(liveCount);
  }

  function setActive(_active) {
    // The stream stays open regardless of tab visibility: frames are tiny and
    // keeping state current makes tab switches instant.
  }

  return { setActive };
}

function mutationHeaders(mutationNonce, liveToken, extra = {}) {
  const headers = { ...extra, 'x-ptc-viewer-live-nonce': mutationNonce };
  if (liveToken) headers.authorization = `Bearer ${liveToken}`;
  return headers;
}

function readHeaders(liveToken) {
  return liveToken ? { authorization: `Bearer ${liveToken}` } : {};
}

/* ---------- launch panel (fixed target, editable input) ---------- */

async function initLaunch(root, project, mutationNonce, liveToken) {
  const response = await fetch('/api/live/launch', { headers: readHeaders(liveToken) });
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
      <div class="live-launch-envs" data-role="envs" hidden></div>
      <label class="live-launch-label" data-role="input-label">Input object — the only thing the browser controls; passed to the project's run input</label>
      <textarea class="live-launch-input" data-role="editor" spellcheck="false" rows="10"></textarea>
      <label class="live-launch-label" data-role="expr-label" hidden>Expression — evaluated once in this mission session; no live frames yet, the result is the output tail below</label>
      <input type="text" class="live-launch-expr" data-role="expr" spellcheck="false" placeholder="(dir)" hidden />
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

  // `mission: null` is the workflow, which is the only environment that
  // produces live frames today.
  const state = { running: spec.launch?.status === 'running', polling: null, mission: null };

  const validate = () => {
    if (state.mission) {
      const expression = fields.expr.value.trim();
      fields.validity.textContent = expression ? `mission ${state.mission}` : 'expression required';
      fields.validity.dataset.state = expression ? 'ok' : 'bad';
      fields.run.disabled = !expression || state.running;
      return expression || null;
    }

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

  const selectEnvironment = (mission, chips) => {
    state.mission = mission;
    for (const chip of chips) {
      chip.setAttribute('aria-pressed', String((chip.dataset.mission || null) === mission));
    }
    fields['input-label'].hidden = Boolean(mission);
    fields.editor.hidden = Boolean(mission);
    fields['expr-label'].hidden = !mission;
    fields.expr.hidden = !mission;
    validate();
  };

  renderEnvironmentChips(fields.envs, project, selectEnvironment);

  const setStatus = (status) => {
    state.running = status?.status === 'running';
    fields.run.disabled = state.running || fields.validity.dataset.state === 'bad';
    for (const chip of fields.envs.querySelectorAll('button')) chip.disabled = state.running;
    fields.run.textContent = state.running ? 'Running…' : '▶ Run';
    if (!status || status.status === 'idle') {
      fields.status.hidden = true;
      return;
    }
    fields.status.hidden = false;
    const presentation = launchStatusPresentation(status, state.mission);
    fields.status.dataset.state = presentation.state;
    if (!presentation.output) {
      fields.status.textContent = presentation.line;
    } else {
      fields.status.replaceChildren();
      const line = document.createElement('div');
      line.textContent = presentation.line;
      const pre = document.createElement('pre');
      pre.textContent = presentation.output;
      fields.status.append(line, pre);
    }
  };

  const poll = async () => {
    try {
      const res = await fetch('/api/live/launch', { headers: readHeaders(liveToken) });
      if (!res.ok) {
        state.polling = setTimeout(poll, launchPollDelay(false, null));
        return;
      }
      const current = await res.json();
      setStatus(current.launch);
      const delay = launchPollDelay(true, current.launch);
      if (delay != null) state.polling = setTimeout(poll, delay);
    } catch {
      state.polling = setTimeout(poll, launchPollDelay(false, null));
    }
  };

  fields.editor.addEventListener('input', validate);
  fields.expr.addEventListener('input', validate);
  fields.run.addEventListener('click', async () => {
    const parsed = validate();
    if (!parsed || state.running) return;
    setStatus({ status: 'running' });
    const body = state.mission
      ? { mission: state.mission, expression: parsed }
      : { input: parsed };
    try {
      const res = await fetch('/api/live/launch', {
        method: 'POST',
        headers: mutationHeaders(mutationNonce, liveToken, { 'content-type': 'application/json' }),
        body: JSON.stringify(body),
      });
      if (res.status !== 202) {
        const responseBody = await res.json().catch(() => ({}));
        setStatus({
          status: 'error',
          output_tail: `launch refused: ${responseBody.error || res.status}`,
        });
        return;
      }
    } catch {
      setStatus({
        status: 'error',
        output_tail: 'launch request failed; checking whether the run started…',
      });
      clearTimeout(state.polling);
      state.polling = setTimeout(poll, launchPollDelay(false, null));
      return;
    }
    clearTimeout(state.polling);
    state.polling = setTimeout(poll, launchPollDelay(true, { status: 'running' }));
  });

  validate();
  setStatus(spec.launch);
  if (state.running) state.polling = setTimeout(poll, 1500);
}

export function launchStatusPresentation(status, mission = null) {
  if (status?.status === 'running') {
    return {
      state: 'running',
      line: mission
        ? `Mission ${mission} evaluating — mission sessions do not report frames; the result appears here.`
        : 'Run launched — its card appears below as frames arrive.',
      output: null,
    };
  }
  if (status?.status === 'ok') {
    return {
      state: 'ok',
      line: 'Last launch completed (exit 0):',
      output: status.output_tail || '(no output captured)',
    };
  }
  return {
    state: 'error',
    line: 'Last launch failed:',
    output: status?.output_tail || '(no output captured)',
  };
}

// Chips appear only when the project actually declares missions; a
// workflow-only project keeps the panel exactly as it was.
function renderEnvironmentChips(container, project, select) {
  const missions = missionNames(project);
  if (!missions.length) return;

  const chips = [];
  for (const name of [null, ...missions]) {
    const chip = el('button', 'live-env-chip', name || 'workflow');
    chip.type = 'button';
    if (name) chip.dataset.mission = name;
    chip.setAttribute('aria-pressed', String(name === null));
    chips.push(chip);
  }

  for (const chip of chips) {
    chip.addEventListener('click', () => select(chip.dataset.mission || null, chips));
  }

  container.hidden = false;
  container.replaceChildren(...chips);
}

export function missionNames(project) {
  if (!project || !Array.isArray(project.environments)) return [];
  return project.environments
    .filter(environment => environment && environment.kind === 'mission')
    .map(environment => environment.name)
    .filter(name => typeof name === 'string' && name !== '');
}

/* ---------- project details (host-injected, opaque) ---------- */

// The payload comes from a host adapter the Viewer does not interpret, so
// every field is treated as possibly absent. Source text is inserted as
// textContent — never innerHTML — because it is arbitrary program text.
async function loadProject(liveToken) {
  try {
    const response = await fetch('/api/live/project', { headers: readHeaders(liveToken) });
    if (!response.ok) return null;
    const project = await response.json();
    return project?.enabled ? project : null;
  } catch {
    return null;
  }
}

function initProject(root, project) {
  if (!project) return;

  root.hidden = false;
  root.innerHTML = `
    <div class="live-project-strip">
      <span class="live-project-name" data-role="name"></span>
      <span class="live-project-path" data-role="manifest"></span>
      <span class="live-project-entry" data-role="entry"></span>
      <button type="button" class="live-project-disclose" data-role="disclose" aria-expanded="false">Details ▸</button>
    </div>
    <div class="live-project-panel" data-role="panel" hidden>
      <section class="live-project-section">
        <button type="button" class="live-project-head" data-role="env-head" aria-expanded="false">
          <span class="live-section-label">Environments</span>
          <span class="live-project-count" data-role="env-count"></span>
        </button>
        <div class="live-project-body" data-role="env-body" hidden></div>
      </section>
      <section class="live-project-section">
        <button type="button" class="live-project-head" data-role="limit-head" aria-expanded="false">
          <span class="live-section-label">Limits</span>
          <span class="live-project-count" data-role="limit-count"></span>
        </button>
        <div class="live-project-body" data-role="limit-body" hidden></div>
      </section>
      <section class="live-project-section">
        <button type="button" class="live-project-head" data-role="comp-head" aria-expanded="false">
          <span class="live-section-label">Components &amp; preludes</span>
          <span class="live-project-count" data-role="comp-count"></span>
        </button>
        <div class="live-project-body" data-role="comp-body" hidden></div>
      </section>
      <div class="live-project-source" data-role="source" hidden>
        <div class="live-project-source-head">
          <span data-role="source-title"></span>
          <button type="button" class="live-card-close" data-role="source-close" aria-label="Close source">✕</button>
        </div>
        <pre data-role="source-body"></pre>
      </div>
    </div>
  `;

  const f = {};
  for (const node of root.querySelectorAll('[data-role]')) f[node.dataset.role] = node;

  f.name.textContent = project.name || '(unnamed project)';
  f.manifest.textContent = projectDisplayPath(project);
  f.entry.textContent = project.entry || '';

  const environments = Array.isArray(project.environments) ? project.environments : [];
  const limits = Array.isArray(project.limits) ? project.limits : [];
  const components = uniqueComponents(environments);

  const showSource = component => {
    f.source.hidden = false;
    f['source-title'].textContent = [component.id, component.path].filter(Boolean).join(' · ');
    f['source-body'].textContent = component.source || '(source unavailable)';
  };

  f['env-count'].textContent = plural(environments.length, 'environment');
  f['comp-count'].textContent = plural(components.length, 'component');
  const leading = leadingLimitRows(limits);
  f['limit-count'].textContent = limitSummary(leading);
  renderEnvironments(f['env-body'], environments, showSource);
  renderLimits(f['limit-body'], limits, leading);
  f['comp-body'].replaceChildren(componentList(components, showSource));

  f.disclose.addEventListener('click', () => {
    const open = f.panel.hidden;
    f.panel.hidden = !open;
    f.disclose.setAttribute('aria-expanded', String(open));
    f.disclose.textContent = open ? 'Details ▾' : 'Details ▸';
  });

  f['source-close'].addEventListener('click', () => {
    f.source.hidden = true;
  });

  for (const [head, body] of [
    [f['env-head'], f['env-body']],
    [f['limit-head'], f['limit-body']],
    [f['comp-head'], f['comp-body']],
  ]) {
    head.addEventListener('click', () => toggleSection(head, body));
  }
}

function toggleSection(head, body) {
  const open = body.hidden;
  body.hidden = !open;
  head.setAttribute('aria-expanded', String(open));
}

function renderEnvironments(container, environments, showSource) {
  container.replaceChildren(
    ...environments.map(environment => {
      const row = el('div', 'live-env');
      const head = el('button', 'live-env-head');
      head.type = 'button';
      head.setAttribute('aria-expanded', 'false');

      const counts = [
        plural(countOf(environment.components), 'component'),
        plural(countOf(environment.providers), 'provider'),
      ];
      if (countOf(environment.tools)) counts.push(plural(countOf(environment.tools), 'tool'));

      head.append(
        el('span', 'live-env-name', environment.name || '(unnamed)'),
        el('span', 'live-env-kind', environment.kind || ''),
        el('span', 'live-env-counts', counts.join(' · ')),
      );

      const body = el('div', 'live-env-body');
      body.hidden = true;

      if (countOf(environment.tools)) {
        const tools = el('div', 'live-tools');
        for (const tool of environment.tools) {
          const chip = el('span', 'live-tool');
          chip.append(el('span', 'live-tool-name', tool.name || '(unnamed tool)'));
          if (tool.effect) chip.append(el('span', 'live-tool-effect', tool.effect));
          tools.append(chip);
        }
        body.append(el('div', 'live-project-sub', 'Tools'), tools);
      }

      if (countOf(environment.providers)) {
        const names = environment.providers
          .map(provider => (provider.source ? `${provider.name} (${provider.source})` : provider.name))
          .join(', ');
        body.append(el('div', 'live-project-sub', 'Providers'), el('div', 'live-project-line', names));
      }

      if (countOf(environment.components)) {
        body.append(
          el('div', 'live-project-sub', 'Components'),
          componentList(environment.components, showSource),
        );
      }

      head.addEventListener('click', () => toggleSection(head, body));
      row.append(head, body);
      return row;
    }),
  );
}

// Deltas and operator-gated rows lead; the complete catalog stays one click
// away so the panel never implies the manifest set only these rows.
function renderLimits(container, limits, leading) {
  const deltas = el('div', 'live-limit-rows');
  deltas.replaceChildren(...leading.map(limitRow));

  const all = el('div', 'live-limit-rows');
  all.hidden = true;
  all.replaceChildren(...limits.map(limitRow));

  const toggle = el('button', 'live-project-toggle', 'show all');
  toggle.type = 'button';
  toggle.addEventListener('click', () => {
    all.hidden = !all.hidden;
    toggle.textContent = all.hidden ? 'show all' : 'show deltas only';
    deltas.hidden = !all.hidden;
  });

  container.replaceChildren(
    leading.length ? deltas : el('div', 'live-project-line', 'Every limit is at its default.'),
    toggle,
    all,
  );
}

// The third column answers whichever question the value provokes. A moved
// limit always keeps its default in view; the installed ceiling rides along
// because that is how much further the manifest can raise it. A row already
// at that ceiling says so, because editing the manifest alone will not help.
function limitRow(limit) {
  const row = el('div', 'live-limit');
  row.append(
    el('span', 'live-limit-name', limit.name),
    el('span', 'live-limit-value', fmtLimit(limit.effective, limit.unit)),
    el('span', 'live-limit-default', limitNote(limit)),
  );
  return row;
}

export function atInstalledCeiling(limit) {
  return limit.ceiling != null && limit.effective >= limit.ceiling;
}

export function leadingLimitRows(limits) {
  return (Array.isArray(limits) ? limits : []).filter(
    limit => limit.effective !== limit.default || atInstalledCeiling(limit),
  );
}

export function limitSummary(leading) {
  const moved = leading.filter(limit => limit.effective !== limit.default).length;
  const gated = leading.filter(atInstalledCeiling).length;
  if (moved && gated) return `${moved} differ from defaults · ${gated} at installed ceiling`;
  if (moved) return `${moved} differ from defaults`;
  if (gated) return `${gated} at installed ceiling`;
  return 'all at defaults';
}

export function limitNote(limit) {
  const moved = limit.effective !== limit.default;
  const defaultNote = moved ? `default ${fmtLimit(limit.default, limit.unit)}` : null;
  const ceilingNote = atInstalledCeiling(limit)
    ? 'at installed ceiling'
    : (limit.ceiling != null ? `ceiling ${fmtLimit(limit.ceiling, limit.unit)}` : null);

  if (defaultNote && ceilingNote) return `${defaultNote} · ${ceilingNote}`;
  return defaultNote || ceilingNote || '';
}

function componentList(components, showSource) {
  const list = el('div', 'live-components');
  for (const component of components) {
    const button = el('button', 'live-component');
    button.type = 'button';
    button.append(el('span', 'live-component-id', component.id || '(unnamed)'));
    if (component.library) button.append(el('span', 'live-component-tag', 'shipped'));
    button.addEventListener('click', () => showSource(component));
    list.append(button);
  }
  return list;
}

export function uniqueComponents(environments) {
  const seen = new Map();
  for (const environment of environments) {
    for (const component of environment.components || []) {
      if (component && !seen.has(component.id)) seen.set(component.id, component);
    }
  }
  return [...seen.values()];
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function countOf(value) {
  return Array.isArray(value) ? value.length : 0;
}

export function plural(count, noun) {
  return `${count} ${noun}${count === 1 ? '' : 's'}`;
}

export function fmtLimit(value, unit) {
  if (typeof value !== 'number') return '–';
  const grouped = String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  if (unit === 'milliseconds') return `${grouped} ms`;
  if (unit === 'bytes') return `${grouped} B`;
  if (unit === 'heap_words') return `${grouped} words`;
  return grouped;
}

export function formatLiveSpend(spend) {
  const state = spend?.state;
  if (state === 'incomplete') {
    return { state, value: 'incomplete', fields: [] };
  }
  if (state === 'available' || state === 'unpriced') {
    const fields = formatRunUsage(spend);
    return {
      state,
      value: fields.join(' · ') || (state === 'unpriced' ? 'unpriced' : '–'),
      fields
    };
  }
  return { state: 'empty', value: '–', fields: [] };
}

/* ---------- card construction ---------- */

function createCard(runId) {
  const el = document.createElement('article');
  el.className = 'live-card';
  el.innerHTML = `
    <header class="live-card-head">
      <div class="live-card-title">
        <button type="button" class="live-card-toggle" data-role="toggle" aria-expanded="true" aria-label="Collapse run" hidden>▾</button>
        <span class="live-badge" data-role="badge"><span class="live-badge-dot"></span><span data-role="badge-text">RUNNING</span></span>
        <h2 data-role="label"></h2>
      </div>
      <div class="live-card-meta">
        <span class="live-card-summary" data-role="summary" hidden></span>
        <span class="live-run-id" data-role="run-id"></span>
        <span class="live-first-seen" data-role="first-seen" hidden></span>
        <span class="live-elapsed" data-role="elapsed"></span>
        <a class="live-card-inspect" data-role="inspect" hidden>View result</a>
        <button type="button" class="live-card-close" data-role="close" aria-label="Close run" title="Close run">✕</button>
      </div>
    </header>

    <div class="live-failure" data-role="failure" role="status" hidden></div>

    <div class="live-kpis">
      <div class="live-kpi"><span class="live-kpi-value" data-role="kpi-calls">–</span><span class="live-kpi-label">tool calls</span></div>
      <div class="live-kpi"><span class="live-kpi-value" data-role="kpi-evals">–</span><span class="live-kpi-label">evaluations</span></div>
      <div class="live-kpi"><span class="live-kpi-value" data-role="kpi-left">–</span><span class="live-kpi-label">time left</span></div>
      <div class="live-kpi live-kpi-workers">
        <span class="live-kpi-value" data-role="kpi-workers">–</span>
        <span class="live-worker-dots" data-role="worker-dots" aria-hidden="true"></span>
        <span class="live-kpi-label">workers</span>
      </div>
      <div class="live-kpi live-kpi-spend" data-role="kpi-spend-tile" data-spend-state="empty">
        <span class="live-kpi-value" data-role="kpi-spend">–</span>
        <span class="live-kpi-label">spend</span>
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
  fields.inspect.href = runRoute(runId);
  return { frame: null, el, fields, ended: false, collapsed: false };
}

export function runRoute(runId) {
  return `#/run/${encodeURIComponent(runId)}`;
}

function placeCard(runsEl, el, stamp) {
  const children = [...runsEl.children];
  const stamps = children.map(child => child.dataset.firstSeenAt || '');
  const index = newerFirstInsertIndex(stamps, stamp);
  el.dataset.firstSeenAt = typeof stamp === 'string' ? stamp : '';
  if (index >= children.length) {
    runsEl.append(el);
  } else {
    runsEl.insertBefore(el, children[index]);
  }
}

/* ---------- per-frame update ---------- */

function updateCard(card, frame) {
  const f = card.fields;
  const usage = frame.usage || {};
  const limits = frame.limits || {};

  f.label.textContent = frame.label || frame.run_id;
  f.elapsed.textContent = fmtClock(frame.elapsed_ms);
  const started = formatFirstSeenAt(frame.first_seen_at);
  f['first-seen'].textContent = started ? `started ${started}` : '';
  f['first-seen'].hidden = !started;

  updateBadge(card, frame);
  updateFailure(f.failure, frame);

  const calls = totalCalls(usage.capability_calls);
  f['kpi-calls'].textContent = String(calls);
  f.summary.textContent = `${calls} tool ${calls === 1 ? 'call' : 'calls'}`;
  f['kpi-evals'].textContent = usage.subordinate_evaluations ?? '–';
  f['kpi-left'].textContent = frame.remaining_ms == null ? '–' : fmtSeconds(frame.remaining_ms);
  updateWorkers(f, frame.parallel);
  const spend = formatLiveSpend(usage.llm_spend);
  f['kpi-spend'].textContent = spend.value;
  f['kpi-spend-tile'].dataset.spendState = spend.state;

  renderMeters(f.meters, frame, usage, limits, calls);
  renderHeap(f, frame.heap);
  renderActivity(f.activity, frame.activity || []);
}

// The frame names the breached setting in `outcome_limit`; the old three-name
// prefix list silently demoted every other ceiling — an agent turn limit, the
// evaluation ceiling, a transcript or result limit — to a generic failure.
export function failurePresentation(frame) {
  if (frame?.phase !== 'error' || !frame.outcome_reason) return null;
  const reason = String(frame.outcome_reason).replace(/^:/, '');
  return frame.outcome_limit
    ? `Limit exceeded: ${reason}`
    : `Failure reason: ${reason}`;
}

function updateFailure(element, frame) {
  const presentation = failurePresentation(frame);
  element.hidden = presentation == null;
  element.textContent = presentation || '';
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
    const workflowCalls = scopeCalls(usage.capability_calls, 'workflow');
    rows.push(meterRow('Tool calls', workflowCalls, limits.workflow_capability_calls,
      `${workflowCalls} / ${limits.workflow_capability_calls}`));
  }
  if (usage.capability_calls?.mission && limits.mission_capability_calls) {
    const missionCalls = scopeCalls(usage.capability_calls, 'mission');
    rows.push(meterRow('Mission calls', missionCalls, limits.mission_capability_calls,
      `${missionCalls} / ${limits.mission_capability_calls}`));
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
  const level =
    value >= limit ? 'exceeded'
      : fraction >= 0.9 ? 'critical'
        : fraction >= 0.75 ? 'warning' : 'normal';
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

function scopeCalls(capabilityCalls, scope) {
  const counts = capabilityCalls && capabilityCalls[scope];
  if (!counts || typeof counts !== 'object') return 0;
  let total = 0;
  for (const count of Object.values(counts)) {
    if (typeof count === 'number') total += count;
  }
  return total;
}

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
