import { renderKernelTranscript } from './kernel-transcript.js';
import { renderInspection } from './inspection.js';
import { createAnalyzeButton, createReplController, nextTabName, readViewerConfig } from './repl.js';
import { createRunCatalog } from './run-catalog.js';
import { truncate } from './utils.js';

function formatDate(isoString) {
  const date = new Date(isoString);
  const pad = value => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

const state = {
  currentRun: null,
  repl: null,
  activeTab: 'runs',
  scrollPositions: { runs: 0, repl: 0 },
  replAvailable: false,
  analyzeActions: new Set()
};

function setReplAvailability(available) {
  state.replAvailable = available;
  for (const button of state.analyzeActions) {
    if (!button.isConnected) {
      state.analyzeActions.delete(button);
      continue;
    }
    button.disabled = !available;
    button.title = available ? '' : 'Analyze requires an open, ready REPL session.';
  }
}

function showNotice(message, owner = 'general') {
  let notice = document.getElementById('viewer-notice');
  if (!notice) {
    notice = document.createElement('div');
    notice.id = 'viewer-notice';
    notice.className = 'viewer-notice';
    const picker = document.getElementById('file-picker');
    picker.parentNode.insertBefore(notice, picker);
  }
  notice.dataset.owner = owner;
  notice.textContent = message;
  notice.style.display = '';
}

function clearNotice(owner) {
  const notice = document.getElementById('viewer-notice');
  if (notice?.dataset.owner === owner) notice.style.display = 'none';
}

async function safeBodyText(response) {
  try {
    const text = await response.text();
    return truncate(text.trim() || response.statusText, 200);
  } catch {
    return response.statusText;
  }
}

async function fetchRunsPage(cursor = null) {
  const suffix = cursor ? `&cursor=${encodeURIComponent(cursor)}` : '';
  const response = await fetch(`/api/kernel/runs?limit=100${suffix}`);

  if (!response.ok) {
    throw new Error(`Canonical run listing failed (HTTP ${response.status}: ${await safeBodyText(response)}).`);
  }

  return response.json();
}

function setupRunPicker(page, priorRuns = [], catalogGeneration) {
  const runs = [...priorRuns, ...(page.items || [])];
  const picker = document.getElementById('file-picker');
  picker.replaceChildren();

  const header = element('div', 'file-picker-header');
  header.id = 'file-picker-toggle';
  const heading = element('h3', null, 'Kernel Runs ');
  heading.append(element('span', 'file-picker-count', `${runs.length}${page.truncated ? '+' : ''} runs`));
  header.append(heading, element('span', 'file-picker-expand', '▾'));

  const list = element('div', 'file-picker-list');
  runs.forEach(run => list.append(runPickerItem(run)));

  if (page.next_cursor) {
    const more = element('button', 'btn kernel-load-more', 'Load more runs');
    more.type = 'button';
    more.addEventListener('click', async () => {
      more.disabled = true;
      const loaded = await runCatalog.loadMore(page.next_cursor, runs, catalogGeneration);
      if (!loaded && more.isConnected) more.disabled = false;
    });
    list.append(more);
  }

  picker.append(header, list);
  picker.style.display = 'block';
  header.addEventListener('click', () => picker.classList.toggle('collapsed'));
}

const runCatalog = createRunCatalog({
  fetchPage: fetchRunsPage,
  renderPage: setupRunPicker,
  reportError: message => showNotice(message, 'run-catalog'),
  clearError: () => clearNotice('run-catalog')
});

function runPickerItem(run) {
  const item = element('button', 'file-picker-item');
  item.type = 'button';
  const main = element('span', 'file-picker-main');
  main.append(element('span', 'filename', run.name || run.run_id));

  const meta = element('span', 'file-meta');
  meta.append(element('span', `trace-kind badge-${run.status === 'ok' ? 'agent' : 'error'}`, run.status || 'incomplete'));
  if (run.start_timestamp) meta.append(element('span', 'modified', formatDate(run.start_timestamp)));
  meta.append(element('span', 'size', `${run.subordinate_evaluations || 0} evaluations`));
  main.append(meta);
  item.append(main, element('span', 'file-picker-query', run.run_id));

  // The decoded run ID stays in this closure. It never crosses an HTML
  // attribute or parser boundary before reaching the typed template request.
  item.addEventListener('click', async () => {
    item.classList.add('loading');
    await loadRun(run.run_id);
    item.classList.remove('loading');
  });
  return item;
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// Bounded page budget for the eager turn fetch. Run-level projections
// (metrics, dialogue, token spend) must not silently summarize a prefix, so
// all pages are loaded up front; a run exceeding the budget keeps its
// next_cursor and is explicitly rendered as partial.
const MAX_TURN_PAGES = 20;

async function fetchAllTurns(runId) {
  let merged = null;
  let cursor = null;

  for (let page = 0; page < MAX_TURN_PAGES; page++) {
    const suffix = cursor ? `&cursor=${encodeURIComponent(cursor)}` : '';
    const response = await fetch(
      `/api/kernel/runs/${encodeURIComponent(runId)}/turns?limit=100${suffix}`
    );
    if (!response.ok) return { failed: response };

    const pageData = await response.json();
    merged = merged
      ? { ...pageData, items: [...merged.items, ...(pageData.items || [])] }
      : { ...pageData, items: pageData.items || [] };
    cursor = pageData.next_cursor;
    if (!cursor) break;
  }

  return { turns: merged };
}

async function loadRun(runId) {
  const [runResponse, turnsResult, inspectionResponse] = await Promise.all([
    fetch(`/api/kernel/runs/${encodeURIComponent(runId)}`),
    fetchAllTurns(runId),
    fetch(`/api/inspection/runs/${encodeURIComponent(runId)}`)
  ]);

  if (!runResponse.ok || turnsResult.failed) {
    const failed = runResponse.ok ? turnsResult.failed : runResponse;
    showNotice(`Failed to load run ${runId} (HTTP ${failed.status}: ${await safeBodyText(failed)}).`);
    return;
  }

  const inspection = inspectionResponse.ok ? await inspectionResponse.json() : null;
  let inspectionStatus;
  if (inspectionResponse.ok) {
    inspectionStatus = { state: 'loaded', status: inspectionResponse.status };
  } else {
    const reason = await safeBodyText(inspectionResponse);
    inspectionStatus = {
      state: reason === 'Inspection artifact unavailable' ? 'not-configured' : 'error',
      status: inspectionResponse.status,
      reason
    };
  }
  renderRun({ metadata: await runResponse.json(), turns: turnsResult.turns, inspection, inspectionStatus });
}

function renderRun(data) {
  state.currentRun = data;
  const { metadata, turns, inspection, inspectionStatus } = data;
  const breadcrumb = document.getElementById('breadcrumb');
  const home = element('button', 'breadcrumb-item breadcrumb-home', 'Runs');
  home.type = 'button';
  breadcrumb.replaceChildren(
    home,
    element('span', 'breadcrumb-sep', '/'),
    element('span', 'breadcrumb-item active', metadata.name || metadata.run_id)
  );

  if (state.repl) {
    const analyzeRun = createAnalyzeButton(
      'Analyze run',
      'run',
      metadata.run_id,
      (kind, runId) => state.repl.requestTemplate(kind, runId)
    );
    const analyzeTurns = createAnalyzeButton(
      'Analyze turns',
      'turns',
      metadata.run_id,
      (kind, runId) => state.repl.requestTemplate(kind, runId)
    );
    breadcrumb.append(analyzeRun, analyzeTurns);
    state.analyzeActions.add(analyzeRun);
    state.analyzeActions.add(analyzeTurns);
    setReplAvailability(state.replAvailable);
  }

  home.addEventListener('click', () => {
    state.currentRun = null;
    document.getElementById('view-container').replaceChildren();
    breadcrumb.replaceChildren();
  });

  renderKernelTranscript(document.getElementById('view-container'), data, {
    onLoadMore: async button => {
      button.disabled = true;
      button.textContent = 'Loading…';
      const response = await fetch(
        `/api/kernel/runs/${encodeURIComponent(metadata.run_id)}/turns?limit=100&cursor=${encodeURIComponent(turns.next_cursor)}`
      );

      if (!response.ok) {
        button.disabled = false;
        button.textContent = 'Load more events';
        return;
      }

      const nextPage = await response.json();
      renderRun({
        metadata,
        inspection,
        inspectionStatus,
        turns: { ...nextPage, items: [...(turns.items || []), ...(nextPage.items || [])] }
      });
    }
  });
  renderInspection(document.getElementById('view-container'), inspection);
  if (state.activeTab === 'runs') window.scrollTo({ top: 0, behavior: 'auto' });
  else state.scrollPositions.runs = 0;
}

function activateTab(name, { focus = false } = {}) {
  if (!state.repl && name === 'repl') return;
  if (name === state.activeTab) {
    if (focus) document.getElementById(`${name}-tab`).focus();
    return;
  }
  state.scrollPositions[state.activeTab] = window.scrollY;
  state.activeTab = name;
  const isRuns = name === 'runs';
  document.getElementById('runs-panel').hidden = !isRuns;
  document.getElementById('repl-panel').hidden = isRuns;
  document.getElementById('breadcrumb').hidden = !isRuns;

  for (const [tabName, tab] of [['runs', document.getElementById('runs-tab')], ['repl', document.getElementById('repl-tab')]]) {
    const selected = tabName === name;
    tab.classList.toggle('active', selected);
    tab.setAttribute('aria-selected', String(selected));
    tab.tabIndex = selected ? 0 : -1;
  }
  if (focus) document.getElementById(`${name}-tab`).focus();
  state.repl?.setActive(!isRuns);
  requestAnimationFrame(() => window.scrollTo(0, state.scrollPositions[name] || 0));
}

function setupTabs() {
  const tabs = document.getElementById('primary-tabs');
  tabs.hidden = false;
  for (const name of ['runs', 'repl']) {
    document.getElementById(`${name}-tab`).addEventListener('click', () => activateTab(name));
  }
  tabs.addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const current = event.target.id === 'runs-tab' ? 'runs'
      : event.target.id === 'repl-tab' ? 'repl'
        : state.activeTab;
    const next = nextTabName(current, event.key);
    activateTab(next, { focus: true });
  });
}

const config = readViewerConfig();
if (config.repl_enabled) {
  setupTabs();
  state.repl = createReplController({
    pageNonce: config.page_bootstrap_nonce,
    getSelectedRunId: () => state.currentRun?.metadata?.run_id || null,
    activate: () => activateTab('repl'),
    refreshRuns: () => runCatalog.refresh(),
    onAvailabilityChange: setReplAvailability
  });
}

void runCatalog.refresh();
