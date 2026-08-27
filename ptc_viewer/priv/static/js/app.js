import { html, mount } from './preact.js';
import { renderKernelTranscript } from './kernel-transcript.js';
import { renderSemanticConversation } from './semantic-conversation.js';
import { createAnalyzeButton, createReplController, nextTabName, readViewerConfig } from './repl.js';
import { createRunCatalog } from './run-catalog.js';
import { createLiveController, liveTokenFromSearch } from './live.js';
import { commitCurrentLoad } from './current-load.js';
import { displayRunName, emptyRunsMessage, formatRunBudget, formatRunSpend, searchableRunFields, traceSourceNotes } from './run-display.js';
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
  analyzeActions: new Set(),
  runs: [],
  page: null,
  project: null,
  catalogGeneration: 0,
  routeGeneration: 0,
  query: '',
  selectedRunId: null
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

  if (response.status === 409) {
    const error = new Error('Trace source changed');
    error.code = 'source_changed';
    throw error;
  }

  if (!response.ok) {
    throw new Error(`Canonical run listing failed (HTTP ${response.status}: ${await safeBodyText(response)}).`);
  }

  return response.json();
}

async function refreshCapturedRuns() {
  const response = await fetch('/api/kernel/refresh', { method: 'POST' });
  if (!response.ok) {
    throw new Error(`Run snapshot refresh failed (HTTP ${response.status}: ${await safeBodyText(response)}).`);
  }
  return runCatalog.refresh();
}

// --- Run picker -----------------------------------------------------------
//
// The catalog owner still serializes fetches behind a generation; this layer
// only holds the latest page and re-renders. Because the picker is a component
// tree rather than an `innerHTML` rebuild, the search box keeps focus and
// caret position across a background catalog refresh.

function setupRunPicker(page, priorRuns = [], catalogGeneration) {
  state.runs = [...priorRuns, ...(page.items || [])];
  state.page = page;
  state.catalogGeneration = catalogGeneration;
  renderRunPicker();
}

function renderRunPicker() {
  mount(document.getElementById('file-picker'), html`<${RunPicker} />`);
}

function matchesQuery(run, query) {
  if (!query) return true;
  const needle = query.toLowerCase();
  return searchableRunFields(run, state.project)
    .some(field => field.toLowerCase().includes(needle));
}

function RunPicker() {
  const { runs, page, query, selectedRunId } = state;
  const visible = runs.filter(run => matchesQuery(run, query));
  const selected = runs.find(run => run.run_id === selectedRunId) || null;
  const sourceNotes = traceSourceNotes(page);

  // With a run open the list is reference material, not the task at hand: it
  // collapses to one control that both names the current run and returns to
  // the list. That control is the only "back to runs" affordance, replacing
  // the tab-plus-breadcrumb pair that used to sit two labels apart.
  if (selected) {
    const displayName = displayRunName(selected, state.project);
    return html`
      <div class="file-picker-bar">
        <button type="button" class="btn secondary file-picker-back" onClick=${() => selectRun(null)}>
          ← All runs <span class="file-picker-count">${runs.length}${page?.truncated ? '+' : ''}</span>
        </button>
        <span class="file-picker-current">
          <span class=${`trace-kind badge-${selected.status === 'ok' ? 'agent' : 'error'}`}>
            ${selected.status || 'incomplete'}
          </span>
          <span class="file-picker-current-name">
            <strong>${displayName}</strong>
            ${displayName !== selected.run_id && html`<small>${selected.run_id}</small>`}
          </span>
        </span>
      </div>
    `;
  }

  return html`
      <div class="file-picker-panel">
      <div class="file-picker-header">
        <h3>Kernel runs <span class="file-picker-count">${runs.length}${page?.truncated ? '+' : ''}</span></h3>
        <button type="button" class="btn secondary compact" onClick=${event => {
          const button = event.currentTarget;
          button.disabled = true;
          refreshCapturedRuns()
            .catch(error => showNotice(error instanceof Error ? error.message : 'Run snapshot refresh failed.', 'run-catalog'))
            .finally(() => { if (button.isConnected) button.disabled = false; });
        }}>Refresh</button>
        ${runs.length > 0 && sourceNotes.map(note => html`<p class="file-picker-note" key=${note}>${note}</p>`)}
        <p class="file-picker-note">Captured snapshot — Refresh to include runs that finished after this Viewer started.</p>
        <input type="search" class="file-picker-search" placeholder="Filter by run id, status or bundle"
               aria-label="Filter runs" value=${query}
               onInput=${event => { state.query = event.currentTarget.value; renderRunPicker(); }} />
      </div>
      <div class="file-picker-list">
        ${visible.map(run => html`<${RunRow} key=${run.run_id} run=${run} />`)}
        ${!visible.length && html`<p class="file-picker-empty">
          ${runs.length ? `No run matches “${query}”.` : emptyRunsMessage(page)}
        </p>`}
        ${page?.next_cursor && !query && html`<${LoadMoreRuns} cursor=${page.next_cursor} />`}
      </div>
    </div>
  `;
}

function RunRow({ run }) {
  const displayName = displayRunName(run, state.project);
  const usage = [...formatRunSpend(run.llm_spend), ...formatRunBudget(run.llm_budget)];

  return html`
    <button type="button" class="file-picker-item" onClick=${() => selectRun(run.run_id)}>
      <span class="file-picker-main">
        <span class=${`trace-kind badge-${run.status === 'ok' ? 'agent' : 'error'}`}>
          ${run.status || 'incomplete'}
        </span>
        <span class="file-picker-identity">
          <span class="filename">${displayName}</span>
          ${displayName !== run.run_id && html`<span class="file-picker-run-id">${run.run_id}</span>`}
        </span>
      </span>
      <span class="file-meta">
        ${run.start_timestamp && html`<span class="modified">${formatDate(run.start_timestamp)}</span>`}
        <span class="size">${run.evaluations ?? 0} evaluations</span>
        ${usage.map(value => html`<span class="file-picker-usage">${value}</span>`)}
        ${Object.entries(run.tags || {}).map(([key, value]) => html`
          <span class="file-picker-tag">${key}: ${value}</span>
        `)}
        <span class="file-picker-query" title=${run.workflow_prelude?.hash || ''}>
          ${shortenHash(run.workflow_prelude?.hash)}
        </span>
      </span>
    </button>
  `;
}

function LoadMoreRuns({ cursor }) {
  return html`
    <button type="button" class="btn kernel-load-more" onClick=${async event => {
      const button = event.currentTarget;
      button.disabled = true;
      const loaded = await runCatalog.loadMore(cursor, state.runs, state.catalogGeneration);
      if (!loaded && button.isConnected) button.disabled = false;
    }}>Load more runs</button>
  `;
}

function shortenHash(value) {
  if (!value) return '';
  const text = String(value);
  return text.length > 22 ? `${text.slice(0, 22)}…` : text;
}

const runCatalog = createRunCatalog({
  fetchPage: fetchRunsPage,
  renderPage: setupRunPicker,
  reportError: message => showNotice(message, 'run-catalog'),
  clearError: () => clearNotice('run-catalog')
});

// --- Routing --------------------------------------------------------------
//
// The selected run and active tab live in the URL, so a run view can be
// bookmarked, shared and reloaded, and Back returns to the list.

function currentRoute() {
  const hash = location.hash.replace(/^#\/?/, '');
  if (hash === 'repl') return { tab: 'repl', runId: null };
  if (hash === 'live' && state.live) return { tab: 'live', runId: null };
  const match = hash.match(/^run\/(.+)$/);
  if (match) return { tab: 'runs', runId: decodeURIComponent(match[1]) };
  return { tab: 'runs', runId: null };
}

function selectRun(runId) {
  location.hash = runId ? `#/run/${encodeURIComponent(runId)}` : '#/';
}

async function applyRoute() {
  const route = currentRoute();
  if (route.tab !== state.activeTab) activateTab(route.tab);

  if (route.runId === state.selectedRunId) return;
  state.selectedRunId = route.runId;
  state.routeGeneration += 1;
  const routeGeneration = state.routeGeneration;

  if (!route.runId) {
    state.currentRun = null;
    const container = document.getElementById('view-container');
    renderSemanticConversation(container, null);
    mount(container, null);
    document.getElementById('breadcrumb').replaceChildren();
    renderRunPicker();
    return;
  }

  renderRunPicker();
  await loadRun(route.runId, routeGeneration);
}

// Bounded page budget for the eager turn fetch. Run-level canonical metrics
// must not silently summarize a prefix, so all pages are loaded up front; a
// run exceeding the budget keeps its next_cursor and is explicitly partial.
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

async function loadRun(runId, routeGeneration) {
  const [
    runResponse, turnsResult, conversationResponse, preludesResponse,
    executionErrorsResponse, explicitFailureValuesResponse
  ] = await Promise.all([
    fetch(`/api/kernel/runs/${encodeURIComponent(runId)}`),
    fetchAllTurns(runId),
    fetch(`/api/analysis/runs/${encodeURIComponent(runId)}/conversation`),
    fetch(`/api/analysis/runs/${encodeURIComponent(runId)}/preludes`),
    fetch(`/api/analysis/runs/${encodeURIComponent(runId)}/execution-errors`),
    fetch(`/api/analysis/runs/${encodeURIComponent(runId)}/explicit-failure-values`)
  ]);

  await commitCurrentLoad(routeGeneration, {
    isCurrent: candidate => state.routeGeneration === candidate,
    load: async () => {
      if (!runResponse.ok || turnsResult.failed) {
        const failed = runResponse.ok ? turnsResult.failed : runResponse;
        return {
          error: `Failed to load run ${runId} (HTTP ${failed.status}: ${await safeBodyText(failed)}).`
        };
      }

      const conversation = conversationResponse.ok
        ? await conversationResponse.json()
        : {
            'available?': false,
            status: conversationResponse.status,
            reason: await safeBodyText(conversationResponse)
          };
      // Both private routes report an absence the same way, because the
      // transcript states it the same way: the reason code, not the status.
      const preludes = preludesResponse.ok
        ? await preludesResponse.json()
        : {
            'available?': false,
            status: preludesResponse.status,
            reason: await safeBodyText(preludesResponse)
          };
      const execution_errors = executionErrorsResponse.ok
        ? await executionErrorsResponse.json()
        : {
            'available?': false,
            status: executionErrorsResponse.status,
            reason: await safeBodyText(executionErrorsResponse)
          };
      const explicit_failure_values = explicitFailureValuesResponse.ok
        ? await explicitFailureValuesResponse.json()
        : {
            'available?': false,
            status: explicitFailureValuesResponse.status,
            reason: await safeBodyText(explicitFailureValuesResponse)
          };

      return {
        data: {
          metadata: await runResponse.json(),
          turns: turnsResult.turns,
          conversation,
          preludes,
          execution_errors,
          explicit_failure_values,
          last_evaluation_error: state.live?.lastEvaluationError?.(runId) || null
        }
      };
    },
    commit: result => {
      if (result.error) showNotice(result.error);
      else renderRun(result.data, { fresh: true, routeGeneration });
    }
  });
}

function renderRun(data, { fresh = false, routeGeneration = state.routeGeneration } = {}) {
  state.currentRun = data;
  const { metadata, turns, conversation } = data;
  const breadcrumb = document.getElementById('breadcrumb');
  breadcrumb.replaceChildren();

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

  const container = document.getElementById('view-container');
  renderKernelTranscript(container, data, {
    title: displayRunName(metadata, state.project),
    onLoadMore: async button => {
      button.disabled = true;
      button.textContent = 'Loading…';
      await commitCurrentLoad(routeGeneration, {
        isCurrent: candidate => state.routeGeneration === candidate,
        load: async () => {
          const response = await fetch(
            `/api/kernel/runs/${encodeURIComponent(metadata.run_id)}/turns?limit=100&cursor=${encodeURIComponent(turns.next_cursor)}`
          );

          if (!response.ok) return { error: true };
          return { nextPage: await response.json() };
        },
        commit: result => {
          if (result.error) {
            if (button.isConnected) {
              button.disabled = false;
              button.textContent = 'Load more events';
            }
            return;
          }

          // Not `fresh`: appending a page diffs into the existing tree, so open
          // disclosures and the reading position are kept.
          renderRun({
            metadata,
            conversation,
            preludes: data.preludes,
            execution_errors: data.execution_errors,
            explicit_failure_values: data.explicit_failure_values,
            last_evaluation_error: data.last_evaluation_error || null,
            turns: {
              ...result.nextPage,
              items: [...(turns.items || []), ...(result.nextPage.items || [])]
            }
          }, { routeGeneration });
        }
      });
    }
  });
  renderSemanticConversation(container, conversation);

  if (!fresh) return;
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
  document.getElementById('repl-panel').hidden = name !== 'repl';
  document.getElementById('live-panel').hidden = name !== 'live';
  document.getElementById('breadcrumb').hidden = !isRuns;

  for (const tabName of ['runs', 'repl', 'live']) {
    const tab = document.getElementById(`${tabName}-tab`);
    if (!tab) continue;
    const selected = tabName === name;
    tab.classList.toggle('active', selected);
    tab.setAttribute('aria-selected', String(selected));
    tab.tabIndex = selected ? 0 : -1;
  }
  if (focus) document.getElementById(`${name}-tab`).focus();
  state.repl?.setActive(name === 'repl');
  state.live?.setActive(name === 'live');
  requestAnimationFrame(() => window.scrollTo(0, state.scrollPositions[name] || 0));
}

function navigateToTab(name) {
  if (name === 'repl') {
    location.hash = '#/repl';
    return;
  }
  if (name === 'live') {
    location.hash = '#/live';
    return;
  }
  location.hash = state.selectedRunId ? `#/run/${encodeURIComponent(state.selectedRunId)}` : '#/';
}

function setupTabs() {
  const tabs = document.getElementById('primary-tabs');
  tabs.hidden = false;
  for (const name of ['runs', 'repl', 'live']) {
    document.getElementById(`${name}-tab`).addEventListener('click', () => navigateToTab(name));
  }
  tabs.addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const current = event.target.id === 'runs-tab' ? 'runs'
      : event.target.id === 'repl-tab' ? 'repl'
        : state.activeTab;
    const enabledTabs = ['runs', 'repl', 'live']
      .filter(name => !document.getElementById(`${name}-tab`).hidden);
    const next = nextTabName(current, event.key, enabledTabs);
    navigateToTab(next);
    activateTab(next, { focus: true });
  });
}

const config = readViewerConfig();
const liveToken = liveTokenFromSearch(location.search);

if (liveToken) {
  const url = new URL(location.href);
  url.searchParams.delete('live_token');
  history.replaceState(history.state, '', `${url.pathname}${url.search}${url.hash}`);
}

setupTabs();
if (config.repl_enabled) {
  state.repl = createReplController({
    pageNonce: config.page_bootstrap_nonce,
    getSelectedRunId: () => state.currentRun?.metadata?.run_id || null,
    activate: () => { location.hash = '#/repl'; },
    refreshRuns: () => runCatalog.refresh(),
    onAvailabilityChange: setReplAvailability
  });
} else {
  document.getElementById('repl-tab').hidden = true;
}
if (config.live_enabled) {
  state.live = createLiveController({
    mutationNonce: config.live_mutation_nonce,
    liveToken,
    onProject: project => {
      state.project = project;
      renderRunPicker();
      if (state.currentRun) renderRun(state.currentRun);
    },
    onInspectRun: runId => {
      void runCatalog.refresh();
      selectRun(runId);
    },
    onLiveCount: count => {
      document.getElementById('live-tab').classList.toggle('has-live', count > 0);
    }
  });
} else {
  document.getElementById('live-tab').hidden = true;
}

window.addEventListener('hashchange', () => void applyRoute());

void runCatalog.refresh().then(() => applyRoute());
