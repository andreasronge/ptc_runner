import { highlightLisp } from './highlight.js';

const POLL_INTERVAL_MS = 1000;
const RELOAD_MARKER = 'ptc-viewer-repl-reload-attempted';

const EXAMPLES = [
  ['Runs', '(analysis/runs {})'],
  ['Run', '(analysis/open "run-id")'],
  ['Turns', '(analysis/read "run-id" {"collection" "activity"})'],
  ['Errors', '(analysis/read "run-id" {"collection" "activity" "status" "error"})']
];

const STOPPED_RETRY_ERRORS = new Map([
  ['trace_changed', 'Retry capture'],
  ['trace_source_too_large', 'Retry capture'],
  ['unsupported_trace', 'Retry capture'],
  ['trace_unavailable', 'Retry capture'],
  ['repl_start_failed', 'Retry session start']
]);

export function readViewerConfig(documentRef = document) {
  const meta = documentRef.querySelector('meta[name="ptc-viewer-config"]');
  if (!meta) return { repl_enabled: false, live_enabled: false };

  try {
    const encoded = meta.content.replace(/-/g, '+').replace(/_/g, '/');
    const padded = encoded.padEnd(Math.ceil(encoded.length / 4) * 4, '=');
    const config = JSON.parse(atob(padded));
    return config && typeof config.repl_enabled === 'boolean'
      ? config
      : { repl_enabled: false, live_enabled: false };
  } catch {
    return { repl_enabled: false, live_enabled: false };
  }
}

export function compareEnvelopes(current, candidate) {
  if (!candidate || !Number.isInteger(candidate.generation_sequence) ||
      !Number.isInteger(candidate.projection_revision) ||
      typeof candidate.server_instance_id !== 'string') return -1;
  if (!current) return 1;
  if (candidate.server_instance_id !== current.server_instance_id) return -1;
  if (candidate.generation_sequence !== current.generation_sequence) {
    return candidate.generation_sequence > current.generation_sequence ? 1 : -1;
  }
  if (candidate.projection_revision === current.projection_revision) return 0;
  return candidate.projection_revision > current.projection_revision ? 1 : -1;
}

export function continuationExplanation(effect) {
  switch (effect) {
    case 'committed_with_history':
      return 'Definitions committed; this value is available as *1.';
    case 'committed_without_history':
      return 'Definitions committed; the result was not added to value history.';
    case 'preserved':
      return 'The prior continuation was preserved; this evaluation committed no definitions.';
    default:
      return 'Continuation state was not reported.';
  }
}

export function templatePayloadMatches(current, response, capturedSession) {
  return Boolean(current && response &&
    current.server_instance_id === response.server_instance_id &&
    current.generation_sequence === response.generation_sequence &&
    current.session_id === capturedSession &&
    response.session_id === capturedSession);
}

export function openResetDialog(dialog) {
  // Browsers retain a dialog's prior returnValue. Clear it so Escape after a
  // previous confirmation is always a cancellation, never another reset.
  dialog.returnValue = '';
  dialog.showModal();
}

export function createAnalyzeButton(label, kind, runId, requestTemplate, documentRef = document) {
  const button = documentRef.createElement('button');
  button.className = 'btn secondary compact';
  button.type = 'button';
  button.textContent = label;
  button.addEventListener('click', () => requestTemplate(kind, runId));
  return button;
}

export function nextTabName(current, key, tabs = ['runs', 'repl', 'live']) {
  if (!Array.isArray(tabs) || tabs.length === 0) return current;
  if (key === 'Home') return tabs[0];
  if (key === 'End') return tabs.at(-1);
  const index = Math.max(tabs.indexOf(current), 0);
  if (key === 'ArrowLeft') return tabs[(index - 1 + tabs.length) % tabs.length];
  if (key === 'ArrowRight') return tabs[(index + 1) % tabs.length];
  return current;
}

export function createReplController({
  pageNonce,
  getSelectedRunId,
  activate,
  refreshRuns,
  onAvailabilityChange = () => {}
}) {
  const dom = collectDom();
  const state = {
    active: false,
    envelope: null,
    polling: false,
    bootstrapPromise: null,
    pollTimer: null,
    mutationActive: false,
    conflictActive: false,
    stoppedError: null,
    retryMode: null,
    retrySession: null,
    draftRevision: 0,
    templateAction: 0,
    readyTemplate: null,
    pendingTemplate: null,
    resetSession: null,
    transcriptLength: 0,
    transcriptFingerprint: null,
    sessionFingerprint: null,
    deadline: null,
    countdownTimer: null,
    reloadRequired: false,
    forcedRefreshPending: false,
    pollRecovery: null,
    availability: null,
    onAvailabilityChange,
    refreshRuns,
    runsRefreshPendingKey: null,
    runsRefreshActive: false,
    runsRefreshCompletedKeys: new Set()
  };

  setupExamples(dom, state, pageNonce, getSelectedRunId);
  setupActions(dom, state, pageNonce);
  renderControls(dom, state);
  dom.editor.addEventListener('input', () => state.draftRevision += 1);
  dom.editor.addEventListener('keydown', event => {
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      evaluate(dom, state, pageNonce);
    }
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) stopPolling(state);
    else if (state.active) refreshNow(dom, state, pageNonce);
  });

  return {
    setActive(active) {
      state.active = active;
      if (active) {
        startCountdown(dom, state);
        if (state.envelope) {
          refreshNow(dom, state, pageNonce, {
            forceStopped: state.forcedRefreshPending,
            preserveStopped: state.forcedRefreshPending
          });
        }
        else bootstrap(dom, state, pageNonce);
      } else {
        stopPolling(state);
        stopCountdown(state);
      }
    },

    async requestTemplate(kind, runId) {
      if (state.envelope && mutationBlocked(state)) {
        activate();
        announce(dom, 'Analyze is temporarily unavailable while session state is changing.', 'warning');
        return;
      }
      queueTemplate(dom, state, kind, runId);
      activate();
      if (!state.envelope) {
        await bootstrap(dom, state, pageNonce);
      }
      if (state.envelope) await drainPendingTemplate(dom, state, pageNonce);
    }
  };
}

function collectDom() {
  const byId = id => document.getElementById(id);
  return {
    status: byId('repl-status'),
    lifecycle: byId('repl-lifecycle'),
    capturedAt: byId('repl-captured-at'),
    runCount: byId('repl-run-count'),
    evaluationsLeft: byId('repl-evaluations-left'),
    timeLeft: byId('repl-time-left'),
    metadata: byId('repl-session-metadata'),
    profileBanner: byId('repl-profile-banner'),
    editor: byId('repl-editor'),
    examples: byId('repl-example-buttons'),
    evaluate: byId('repl-evaluate'),
    reset: byId('repl-reset'),
    close: byId('repl-close'),
    retry: byId('repl-retry'),
    transcript: byId('repl-transcript'),
    empty: byId('repl-empty'),
    omitted: byId('repl-omitted'),
    jump: byId('repl-jump-latest'),
    templateReady: byId('repl-template-ready'),
    templateInsert: byId('repl-template-insert'),
    templateReplace: byId('repl-template-replace'),
    resetDialog: byId('repl-reset-dialog'),
    resetConfirm: byId('repl-reset-confirm')
  };
}

function setupExamples(dom, state, pageNonce, getSelectedRunId) {
  for (const [label, source] of EXAMPLES) {
    const button = node('button', 'btn secondary compact', label);
    button.type = 'button';
    button.addEventListener('click', () => {
      const runId = getSelectedRunId();
      if (runId && (label === 'Run' || label === 'Turns')) {
        if (state.envelope && mutationBlocked(state)) {
          announce(dom, 'Wait for the current session operation to finish, then insert the selected-run query.', 'warning');
          return;
        }
        queueTemplate(dom, state, label.toLowerCase(), runId);
        drainPendingTemplate(dom, state, pageNonce);
        return;
      }
      replaceDraft(dom, state, source);
      announce(dom, `${label} example inserted. Edit it, then evaluate.`);
    });
    dom.examples.append(button);
  }

  const selectedRun = node('p', 'repl-selected-run-hint');
  selectedRun.textContent = 'For exact selected-run source, use Analyze run or Analyze turns in the Runs tab.';
  dom.examples.append(selectedRun);
}

function setupActions(dom, state, pageNonce) {
  dom.evaluate.addEventListener('click', () => evaluate(dom, state, pageNonce));
  dom.close.addEventListener('click', () => closeSession(dom, state, pageNonce));
  dom.retry.addEventListener('click', () => {
    if (state.reloadRequired) location.reload();
    else if (state.retryMode === 'reset' && state.retrySession) {
      if (retryResetBlocked(state)) {
        announce(dom, 'Session state is still reconciling. Retry reset will be available momentarily.', 'warning');
        return;
      }
      const sessionId = state.retrySession;
      state.stoppedError = null;
      state.retryMode = null;
      state.retrySession = null;
      resetSession(dom, state, pageNonce, sessionId);
    }
    else bootstrap(dom, state, pageNonce, { explicit: true });
  });
  dom.reset.addEventListener('click', () => {
    if (!state.envelope || mutationBlocked(state)) return;
    state.resetSession = state.envelope.session_id;
    openResetDialog(dom.resetDialog);
  });
  dom.resetDialog.addEventListener('close', () => {
    if (dom.resetDialog.returnValue === 'confirm' && state.resetSession) {
      resetSession(dom, state, pageNonce, state.resetSession);
    }
    state.resetSession = null;
  });
  dom.templateInsert.addEventListener('click', () => installReadyTemplate(dom, state, false));
  dom.templateReplace.addEventListener('click', () => installReadyTemplate(dom, state, true));
  dom.jump.addEventListener('click', () => {
    dom.transcript.lastElementChild?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    dom.jump.hidden = true;
  });
}

async function bootstrap(dom, state, pageNonce, { explicit = false } = {}) {
  if (state.bootstrapPromise) return state.bootstrapPromise;
  if (state.mutationActive) return false;

  const promise = performBootstrap(dom, state, pageNonce, explicit);
  state.bootstrapPromise = promise;
  try {
    const started = await promise;
    if (started) await drainPendingTemplate(dom, state, pageNonce);
    return started;
  } finally {
    if (state.bootstrapPromise === promise) state.bootstrapPromise = null;
  }
}

async function performBootstrap(dom, state, pageNonce, explicit) {
  state.polling = true;
  state.stoppedError = null;
  state.retryMode = null;
  state.retrySession = null;
  state.reloadRequired = false;
  dom.retry.hidden = true;
  renderControls(dom, state);
  announce(dom, explicit ? 'Retrying REPL session…' : 'Connecting to REPL session…');

  try {
    const response = await fetch('/api/repl', {
      headers: { 'X-PTC-Viewer-Page-Nonce': pageNonce },
      cache: 'no-store'
    });
    if (!response.ok) {
      await handleErrorResponse(dom, state, response, { type: 'bootstrap' });
      return false;
    }
    sessionStorage.removeItem(RELOAD_MARKER);
    const prior = state.envelope;
    const accepted = acceptEnvelope(dom, state, await response.json());
    if (accepted) {
      announce(dom, bootstrapAnnouncement(state.envelope.lifecycle));
      if (!prior) await refreshRunsAfterBootstrap(state);
    }
    return accepted;
  } catch {
    stopWithRetry(dom, state, 'trace_unavailable', 'The trace source is unavailable.', 'Retry capture');
    return false;
  } finally {
    state.polling = false;
    renderControls(dom, state);
    await drainPendingTemplate(dom, state, pageNonce);
    schedulePoll(dom, state, pageNonce);
  }
}

async function refreshNow(dom, state, pageNonce, { forceStopped = false, preserveStopped = false } = {}) {
  if (forceStopped) state.forcedRefreshPending = true;
  forceStopped ||= state.forcedRefreshPending;
  preserveStopped ||= state.forcedRefreshPending;
  clearTimeout(state.pollTimer);
  state.pollTimer = null;
  if (state.polling || state.mutationActive || (state.stoppedError && !forceStopped) || !state.active || document.hidden) return;
  state.polling = true;
  renderControls(dom, state);

  try {
    const response = await fetch('/api/repl', {
      headers: { 'X-PTC-Viewer-Page-Nonce': pageNonce },
      cache: 'no-store'
    });
    if (!response.ok) return handleErrorResponse(dom, state, response, { type: 'poll' });
    const prior = state.envelope;
    const recovery = state.pollRecovery;
    const accepted = acceptEnvelope(dom, state, await response.json(), { preserveStopped });
    if (accepted && forceStopped) state.forcedRefreshPending = false;
    if (accepted && recovery) {
      announce(dom, recovery);
    } else if (accepted && sessionTransitioned(prior, state.envelope)) {
      announce(dom, `Session state synchronized: ${humanize(state.envelope.lifecycle)}.`);
    }
    if (accepted) {
      await retryPendingRunsRefresh(state);
      await refreshRunsForTransition(state, prior, state.envelope);
    }
    if (accepted) state.pollRecovery = null;
  } catch {
    state.pollRecovery = 'Session refresh recovered; authoritative state is current.';
    announce(dom, 'Session refresh failed; retrying while this tab remains visible.', 'warning');
  } finally {
    state.polling = false;
    renderControls(dom, state);
    await drainPendingTemplate(dom, state, pageNonce);
    schedulePoll(dom, state, pageNonce);
  }
}

async function refreshRunsAfterBootstrap(state) {
  try {
    await state.refreshRuns();
  } catch {
    // The catalog owner reports and independently retries its own failures.
  }
}

function schedulePoll(dom, state, pageNonce) {
  clearTimeout(state.pollTimer);
  state.pollTimer = null;
  if (!state.active || document.hidden || state.stoppedError || state.polling) return;
  state.pollTimer = setTimeout(() => refreshNow(dom, state, pageNonce), POLL_INTERVAL_MS);
}

function stopPolling(state) {
  clearTimeout(state.pollTimer);
  state.pollTimer = null;
}

async function evaluate(dom, state, pageNonce) {
  const source = dom.editor.value;
  if (!source.trim()) {
    announce(dom, 'Enter PTC-Lisp source before evaluating.', 'warning');
    dom.editor.focus();
    return;
  }
  if (!canMutate(state, 'evaluate')) return;

  const sessionId = state.envelope.session_id;
  const response = await mutate(dom, state, pageNonce, '/api/repl/evaluations', 'POST', sessionId, { source }, 'Evaluating…', 'evaluate');
  if (response) {
    const priorLength = state.transcriptLength;
    const followLatest = priorLength === 0 || nearPageBottom();
    if (acceptEnvelope(dom, state, response)) {
      announce(dom, evaluationAnnouncement(response.evaluation));
      if (!followLatest) dom.jump.hidden = false;
      else dom.transcript.lastElementChild?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  }
}

async function closeSession(dom, state, pageNonce) {
  if (!canMutate(state, 'close')) return;
  const prior = state.envelope;
  const sessionId = state.envelope.session_id;
  const response = await mutate(dom, state, pageNonce, '/api/repl', 'DELETE', sessionId, null, 'Closing and persisting…', 'close');
  if (response && acceptEnvelope(dom, state, response)) {
    announce(dom, 'Session closed and analysis trace persisted. The transcript remains readable.');
    await refreshRunsForTransition(state, prior, state.envelope);
  }
}

async function resetSession(dom, state, pageNonce, capturedSessionId) {
  if (mutationBlocked(state) || !resettableLifecycle(state.envelope?.lifecycle)) return;
  const prior = state.envelope;
  const response = await mutate(dom, state, pageNonce, '/api/repl/reset', 'POST', capturedSessionId, {}, 'Persisting and refreshing snapshot…', 'reset');
  if (response && acceptEnvelope(dom, state, response)) {
    announce(dom, 'Fresh session installed. The prior analysis run is now available under Runs.');
    await refreshRunsForTransition(state, prior, state.envelope);
  } else if (state.retryMode === 'reset') {
    // Reset persisted its predecessor before replacement capture/start failed.
    // Render that authoritative closed state and refresh Runs while preserving
    // the explicit Retry reset affordance and its captured session.
    await refreshNow(dom, state, pageNonce, { forceStopped: true, preserveStopped: true });
  }
}

async function drainPendingTemplate(dom, state, pageNonce) {
  const pending = state.pendingTemplate;
  if (!pending) return;
  // A definitive start/capture error owns the visible status and preserves
  // the inert intent for the explicit retry action.
  if (state.stoppedError) return;
  if (!state.envelope || state.mutationActive || state.polling || state.conflictActive) return;
  if (pending.sessionId && pending.sessionId !== state.envelope.session_id) {
    state.pendingTemplate = null;
    announce(dom, 'The session changed before the template was formatted. Choose Analyze again.', 'warning');
    return;
  }
  if (state.envelope.lifecycle !== 'open') {
    state.pendingTemplate = null;
    announce(dom, 'Analyze requires an open REPL session. Reset or retry the session, then try again.', 'warning');
    return;
  }
  state.pendingTemplate = null;
  await requestTemplate(dom, state, pageNonce, pending.kind, pending.runId, pending);
}

function queueTemplate(dom, state, kind, runId) {
  clearReadyTemplate(dom, state);
  state.pendingTemplate = {
    actionId: ++state.templateAction,
    kind,
    runId,
    draftRevision: state.draftRevision,
    sessionId: state.envelope?.session_id || null
  };
}

async function requestTemplate(dom, state, pageNonce, kind, runId, pending = null) {
  if (!canMutate(state, 'template')) return;
  const actionId = pending?.actionId ?? ++state.templateAction;
  const draftRevision = pending?.draftRevision ?? state.draftRevision;
  const capturedSession = state.envelope.session_id;
  const response = await mutate(
    dom,
    state,
    pageNonce,
    '/api/repl/templates',
    'POST',
    capturedSession,
    { kind, run_id: runId },
    `Formatting ${kind} query…`,
    'template'
  );
  if (!response || actionId !== state.templateAction || response.session_id !== capturedSession) return;
  const envelopeAccepted = acceptEnvelope(dom, state, response);
  // Template source is an operation payload, not cached session state. A newer
  // same-generation poll may win envelope ordering while this payload remains
  // valid; a different server or generation must never insert it.
  if (!envelopeAccepted && !templatePayloadMatches(state.envelope, response, capturedSession)) return;
  const source = response.template?.source;
  if (typeof source !== 'string') return;

  if (draftRevision === state.draftRevision) {
    replaceDraft(dom, state, source);
    announce(dom, 'Server-formatted source inserted. Review or edit it before evaluating.');
  } else {
    state.readyTemplate = { source, actionId, sessionId: capturedSession };
    dom.templateReady.hidden = false;
    announce(dom, 'Template ready. Your newer draft was preserved.', 'warning');
  }
}

async function mutate(dom, state, pageNonce, path, method, sessionId, body, progress, operation) {
  state.mutationActive = true;
  renderControls(dom, state);
  announce(dom, progress);

  const options = {
    method,
    cache: 'no-store',
    headers: {
      'X-PTC-Viewer-Nonce': state.envelope.mutation_nonce,
      'X-PTC-Viewer-Session': sessionId
    }
  };
  if (body !== null) {
    options.headers['Content-Type'] = 'application/json';
    options.body = JSON.stringify(body);
  }

  try {
    const response = await fetch(path, options);
    if (!response.ok) {
      await handleErrorResponse(dom, state, response, { type: 'mutation', operation, sessionId });
      return null;
    }
    return await response.json();
  } catch {
    state.conflictActive = true;
    state.pollRecovery = 'Session state reconciled after an uncertain request. Check the transcript before retrying.';
    announce(dom, 'The request did not complete. Refresh session state before retrying.', 'error');
    return null;
  } finally {
    state.mutationActive = false;
    renderControls(dom, state);
    if (state.active) refreshNow(dom, state, pageNonce);
  }
}

async function handleErrorResponse(dom, state, response, context) {
  let code = 'adapter_failure';
  let message = 'The REPL backend failed.';
  try {
    const body = await response.json();
    code = body?.error?.code || code;
    message = body?.error?.message || message;
  } catch {
    // The server contract is fixed JSON; keep the bounded fallback if an
    // intermediary corrupts it.
  }

  if (response.status === 403 && (context.type === 'bootstrap' || context.type === 'poll')) {
    return handleStalePage(dom, state);
  }

  if (STOPPED_RETRY_ERRORS.has(code)) {
    const resetRetry = context.type === 'mutation' && context.operation === 'reset' && state.envelope;
    const label = resetRetry
      ? 'Retry reset'
      : STOPPED_RETRY_ERRORS.get(code);
    stopWithRetry(dom, state, code, message, label);
    if (resetRetry) {
      state.retryMode = 'reset';
      state.retrySession = context.sessionId;
    }
    return;
  }

  if (code === 'adapter_failure' && context.type === 'bootstrap' && !state.envelope) {
    state.stoppedError = code;
    stopPolling(state);
    dom.retry.hidden = true;
    announce(dom, 'The REPL backend failed before a session was installed. Restart the Viewer to recover.', 'error');
    renderControls(dom, state);
    return;
  }

  announce(dom, message, response.status >= 500 ? 'error' : 'warning');
  if (response.status === 409 || response.status === 412) {
    state.stoppedError = null;
    state.conflictActive = true;
    state.pollRecovery = 'Session state synchronized after a conflicting action.';
    renderControls(dom, state);
    stopPolling(state);
    queueMicrotask(() => {
      if (state.active) refreshNow(dom, state, readViewerConfig().page_bootstrap_nonce);
    });
  }
}

function handleStalePage(dom, state) {
  stopPolling(state);
  if (!sessionStorage.getItem(RELOAD_MARKER)) {
    sessionStorage.setItem(RELOAD_MARKER, '1');
    location.reload();
    return;
  }
  state.stoppedError = 'forbidden_request';
  state.reloadRequired = true;
  announce(dom, 'This page belongs to an earlier Viewer process. Reload the page to reconnect.', 'error');
  dom.retry.textContent = 'Reload page';
  dom.retry.hidden = false;
}

function stopWithRetry(dom, state, code, message, label) {
  state.stoppedError = code;
  stopPolling(state);
  announce(dom, message, 'error');
  dom.retry.textContent = label;
  dom.retry.hidden = false;
  renderControls(dom, state);
}

function acceptEnvelope(dom, state, envelope, { preserveStopped = false } = {}) {
  const comparison = compareEnvelopes(state.envelope, envelope);
  if (comparison < 0) return false;
  if (comparison === 0) {
    state.conflictActive = false;
    renderControls(dom, state);
    return true;
  }
  if (state.envelope && !sameSession(state.envelope, envelope)) {
    clearReadyTemplate(dom, state);
  }
  state.envelope = envelope;
  if (!preserveStopped) state.stoppedError = null;
  state.conflictActive = false;
  if (!preserveStopped) setHidden(dom.retry, true);
  renderSession(dom, state);
  renderTranscript(dom, state);
  renderControls(dom, state);
  return true;
}

function renderSession(dom, state) {
  const envelope = state.envelope;
  const session = envelope.session || {};
  const snapshot = session.snapshot || {};
  const usage = session.usage || {};
  const evaluations = usage.evaluations || {};

  // The budget clock is the one field that differs on every poll. It is
  // rendered from a locally ticked deadline (see `startCountdown`) so a
  // second passing never re-runs this projection, and this function is
  // fingerprinted on everything else.
  state.deadline = typeof usage.remaining_ms === 'number'
    ? Date.now() + usage.remaining_ms
    : null;
  renderCountdown(dom, state);

  const namespaces = Array.isArray(session.namespaces) ? session.namespaces.join(', ') : '—';
  const continuation = usage.continuation || {};
  const trace = session.trace || {};
  const traceCalls = usage.trace_calls || {};
  const details = [
    ['Profile', session.profile_id],
    ['Profile digest', session.profile_digest],
    ['Namespaces', namespaces],
    ['Snapshot ID', snapshot.capture_id],
    ['Captured at', snapshot.captured_at],
    ['Source bytes', snapshot.source_bytes],
    ['Retained bytes', snapshot.retained_bytes],
    ['Mission calls left', usage.mission_calls?.remaining],
    ['Definitions', continuation.defined_count],
    ['Continuation bytes', continuation.bytes],
    ['Definition bytes', continuation.memory_bytes],
    ['History bytes', continuation.history_bytes],
    ['History values', continuation.history_count],
    ['Trace persistence', trace.persistence],
    ['Trace events', trace.event_count]
  ].concat(Object.keys(traceCalls).sort().map(name => [
    `${name} calls`,
    `${number(traceCalls[name]?.used)} used / ${number(traceCalls[name]?.remaining)} left`
  ]));

  const fingerprint = JSON.stringify([
    envelope.lifecycle, session.profile_id, namespaces, snapshot.captured_at,
    snapshot.run_count, evaluations.remaining, details
  ]);
  if (fingerprint === state.sessionFingerprint) return;
  state.sessionFingerprint = fingerprint;

  setText(dom.profileBanner, `server-owned ${session.profile_id || 'analysis'} profile and ${namespaces} API`);
  setText(dom.lifecycle, humanize(envelope.lifecycle || 'unknown'));
  dom.lifecycle.dataset.state = envelope.lifecycle || 'unknown';
  setText(dom.capturedAt, `snapshot ${formatTimestamp(snapshot.captured_at)}`);
  setText(dom.runCount, `${number(snapshot.run_count)} runs`);
  setText(dom.evaluationsLeft, `${number(evaluations.remaining)} evaluations left`);

  dom.metadata.replaceChildren(...details.flatMap(([term, value]) => {
    const dt = node('dt', null, term);
    const dd = node('dd', null, value == null ? '—' : String(value));
    return [dt, dd];
  }));
}

// The remaining-budget clock ticks from a locally held deadline. Rendering it
// on the poll response instead would tie a once-per-second text change to a
// full session projection, which is what made the whole panel churn.
function renderCountdown(dom, state) {
  const remaining = state.deadline == null ? null : Math.max(0, state.deadline - Date.now());
  setText(dom.timeLeft, `${formatDuration(remaining)} left`);
}

// Ticks only while the REPL panel is active, alongside polling, so a hidden
// panel neither polls nor holds a timer.
function startCountdown(dom, state) {
  stopCountdown(state);
  state.countdownTimer = setInterval(() => renderCountdown(dom, state), 1000);
  // Browsers return an opaque handle; under node (the render test harness) it
  // is a Timeout that would otherwise keep the process alive.
  state.countdownTimer?.unref?.();
}

function stopCountdown(state) {
  if (state.countdownTimer !== null) clearInterval(state.countdownTimer);
  state.countdownTimer = null;
}

function setText(element, value) {
  if (element.textContent !== value) element.textContent = value;
}

function setDisabled(element, value) {
  if (element.disabled !== value) element.disabled = value;
}

function setHidden(element, value) {
  if (element.hidden !== value) element.hidden = value;
}

function setTitle(element, value) {
  if (element.title !== value) element.title = value;
}

function renderTranscript(dom, state) {
  const entries = Array.isArray(state.envelope.transcript) ? state.envelope.transcript : [];
  const omitted = state.envelope.transcript_omitted_count || 0;
  const fingerprint = JSON.stringify([omitted, entries]);
  if (fingerprint === state.transcriptFingerprint) return;
  state.transcriptFingerprint = fingerprint;
  state.transcriptLength = entries.length;
  dom.empty.hidden = entries.length > 0;
  dom.transcript.replaceChildren(...entries.map((entry, index) => transcriptCard(dom, state, entry, index)));

  dom.omitted.hidden = omitted === 0;
  dom.omitted.textContent = omitted ? `${omitted} older transcript ${omitted === 1 ? 'entry was' : 'entries were'} omitted by the server budget.` : '';
}

function transcriptCard(dom, state, entry, index) {
  const result = entry.result || {};
  const card = node('details', 'repl-card');
  if (index === state.transcriptLength - 1) card.open = true;
  const summary = node('summary', 'repl-card-summary');
  const outcome = result.outcome || result.status || 'unknown';
  summary.append(
    node('span', `repl-outcome outcome-${safeClass(outcome)}`, humanize(outcome)),
    node('span', 'repl-card-source', firstLine(entry.source_preview || '')),
    node('span', 'repl-card-meta', `${number(result.duration_ms)} ms · ${result.evaluation_id || 'evaluation'}`)
  );
  card.append(summary);

  const body = node('div', 'repl-card-body');
  const source = String(entry.source_preview || '');
  const sourceDisplay = source + (entry['source_truncated?'] ? '\n… source preview truncated' : '');
  body.append(section('Source', sourceDisplay, 'clojure'));
  const sourceActions = node('div', 'repl-card-actions');
  const copySource = actionButton(
    entry['source_truncated?'] ? 'Copy source preview' : 'Copy source',
    () => copyText(sourceDisplay, dom)
  );
  sourceActions.append(copySource);
  if (!entry['source_truncated?']) {
    sourceActions.append(actionButton('Edit and rerun', () => {
      replaceDraft(dom, state, source);
      dom.editor.focus();
      announce(dom, 'Source copied into the editor. It has not been executed.');
    }));
  }
  body.append(sourceActions);

  if (result.formatted != null) {
    const marker = result['formatted_truncated?'] ? '\n… formatted result truncated' : '';
    const formattedDisplay = String(result.formatted) + marker;
    body.append(section('Formatted value', formattedDisplay));
    body.append(nodeWithChild('div', 'repl-card-actions', actionButton(
      result['formatted_truncated?'] ? 'Copy result preview' : 'Copy result',
      () => copyText(formattedDisplay, dom)
    )));
  }
  if (result['value_available?']) {
    const jsonValue = prettyJson(result.value);
    body.append(section('JSON value', jsonValue));
    body.append(nodeWithChild('div', 'repl-card-actions', actionButton(
      'Copy JSON value',
      () => copyText(jsonValue, dom)
    )));
  }
  if (Array.isArray(result.prints) && (result.prints.length || result['prints_truncated?'])) {
    const marker = result.prints.length ? '\n… prints truncated' : '… prints truncated';
    const prints = result.prints.join('\n') + (result['prints_truncated?'] ? marker : '');
    body.append(section('Prints', prints));
  }
  if (result.error) body.append(section('Error', prettyJson(result.error)));
  body.append(section('Continuation', continuationExplanation(result.continuation_effect)));
  if (result.usage) body.append(section('Usage snapshot', prettyJson(result.usage)));
  if (result['optional_fields_omitted?']) {
    body.append(node('p', 'repl-truncation', 'Optional result fields were omitted to keep this transcript entry bounded.'));
  }
  card.append(body);
  return card;
}

// Every write here is conditional. `renderControls` runs on each poll leg, so
// unconditional assignment rewrote `disabled` on five buttons several times a
// second; with a background refresh no longer part of `mutationBlocked` the
// values are stable, and the guards keep an idle session from touching the DOM
// at all.
function renderControls(dom, state) {
  const lifecycle = state.envelope?.lifecycle;
  const blocked = mutationBlocked(state);
  const resettable = resettableLifecycle(lifecycle);
  setDisabled(dom.evaluate, blocked || lifecycle !== 'open');
  setDisabled(dom.reset, blocked || !resettable);
  setDisabled(dom.close, blocked || !['open', 'terminal', 'persistence_failed', 'backend_failed'].includes(lifecycle));
  setDisabled(dom.editor, lifecycle === 'backend_failed');
  setDisabled(dom.resetConfirm, blocked || !resettable);
  setDisabled(dom.retry, state.retryMode === 'reset'
    ? retryResetBlocked(state)
    : state.mutationActive || state.conflictActive);
  // A fresh page may accept one Analyze intent and carry it through the lazy
  // bootstrap. Once a session exists, Analyze follows normal mutation gates.
  const available = state.envelope
    ? !blocked && lifecycle === 'open'
    : !state.polling && !state.bootstrapPromise && !state.stoppedError;
  if (available !== state.availability) {
    state.availability = available;
    state.onAvailabilityChange(available);
  }
  setText(dom.close, lifecycle === 'persistence_failed'
    ? 'Retry persistence'
    : lifecycle === 'backend_failed'
      ? 'Close and preserve trace'
      : 'Close and persist');
  setTitle(dom.evaluate, lifecycle === 'terminal'
    ? 'The session reached a terminal budget. Close or reset it.'
    : lifecycle === 'closed'
      ? 'This session is closed. Reset to start a fresh session.'
      : '');
}

function canMutate(state, kind) {
  if (mutationBlocked(state)) return false;
  if (kind === 'evaluate' || kind === 'template') return state.envelope.lifecycle === 'open';
  if (kind === 'close') return ['open', 'terminal', 'persistence_failed', 'backend_failed'].includes(state.envelope.lifecycle);
  return true;
}

// A background poll is a read: it never changes `mutation_nonce`, and a
// response that arrives mid-mutation is rejected by `compareEnvelopes` for
// going backwards. It therefore must not gate the user's controls — doing so
// disabled every button for the duration of each poll leg, which both flickered
// and swallowed clicks that landed in the window.
function mutationBlocked(state) {
  const lifecycle = state.envelope?.lifecycle;
  const busyLifecycle = ['starting', 'evaluating', 'templating', 'resetting', 'closing', 'reconciling_start'].includes(lifecycle);
  return !state.envelope || state.mutationActive || state.conflictActive ||
    busyLifecycle || Boolean(state.stoppedError);
}

function retryResetBlocked(state) {
  const lifecycle = state.envelope?.lifecycle;
  const busyLifecycle = ['starting', 'evaluating', 'templating', 'resetting', 'closing', 'reconciling_start'].includes(lifecycle);
  return !state.envelope || state.mutationActive || state.polling || state.conflictActive ||
    busyLifecycle || !resettableLifecycle(lifecycle);
}

function resettableLifecycle(lifecycle) {
  return ['open', 'terminal', 'closed', 'persistence_failed'].includes(lifecycle);
}

function replaceDraft(dom, state, source) {
  dom.editor.value = source;
  state.draftRevision += 1;
  dom.editor.focus();
}

function installReadyTemplate(dom, state, replace) {
  if (!state.readyTemplate) return;
  const ready = state.readyTemplate;
  if (ready.actionId !== state.templateAction || ready.sessionId !== state.envelope?.session_id) {
    clearReadyTemplate(dom, state);
    return;
  }
  const source = ready.source;
  if (replace) {
    replaceDraft(dom, state, source);
  } else {
    const start = dom.editor.selectionStart;
    const end = dom.editor.selectionEnd;
    const spacer = start > 0 && !dom.editor.value.slice(0, start).endsWith('\n') ? '\n' : '';
    dom.editor.setRangeText(`${spacer}${source}`, start, end, 'end');
    state.draftRevision += 1;
    dom.editor.focus();
  }
  clearReadyTemplate(dom, state);
  announce(dom, 'Template inserted. It has not been executed.');
}

function clearReadyTemplate(dom, state) {
  state.readyTemplate = null;
  dom.templateReady.hidden = true;
}

function sameSession(left, right) {
  return left.server_instance_id === right.server_instance_id &&
    left.generation_sequence === right.generation_sequence &&
    left.session_id === right.session_id;
}

function sessionTransitioned(left, right) {
  return Boolean(left && right &&
    (!sameSession(left, right) || left.lifecycle !== right.lifecycle));
}

async function refreshRunsForTransition(state, left, right) {
  if (!left || !right || left.server_instance_id !== right.server_instance_id) return;
  const replaced = right.generation_sequence > left.generation_sequence;
  const closed = left.lifecycle !== 'closed' && right.lifecycle === 'closed';
  if (!replaced && !closed) return;
  const key = `${right.server_instance_id}:${right.generation_sequence}:${right.lifecycle === 'closed' ? 'closed' : 'replacement'}`;
  if (state.runsRefreshCompletedKeys.has(key)) return;
  state.runsRefreshPendingKey = key;
  await retryPendingRunsRefresh(state);
}

async function retryPendingRunsRefresh(state) {
  const key = state.runsRefreshPendingKey;
  if (!key || state.runsRefreshActive) return;
  state.runsRefreshActive = true;
  let refreshed = false;
  try {
    refreshed = await state.refreshRuns();
  } catch {
    // The Runs UI owns its visible fetch error. Keep the transition pending so
    // the next authoritative poll retries catalog convergence.
  } finally {
    if (refreshed !== false && state.runsRefreshPendingKey === key) {
      state.runsRefreshPendingKey = null;
      state.runsRefreshCompletedKeys.add(key);
    }
    state.runsRefreshActive = false;
  }
}

function evaluationAnnouncement(evaluation) {
  if (!evaluation) return 'Evaluation completed; transcript refreshed.';
  return `Evaluation ${evaluation.evaluation_id || ''} completed with ${humanize(evaluation.outcome || evaluation.status)}.`;
}

function bootstrapAnnouncement(lifecycle) {
  if (lifecycle === 'open') return 'REPL session is ready.';
  if (lifecycle === 'closed') return 'The REPL session is closed. Reset to start a fresh session.';
  if (lifecycle === 'terminal') return 'The REPL session reached a terminal budget. Close or reset it.';
  if (lifecycle === 'persistence_failed') return 'The REPL session could not persist its trace. Retry persistence or reset.';
  if (lifecycle === 'backend_failed') return 'The REPL backend failed. Close the session to preserve available trace data.';
  return `REPL session state: ${humanize(lifecycle)}.`;
}

function announce(dom, message, kind = 'info') {
  dom.status.textContent = message;
  dom.status.dataset.kind = kind;
}

function section(title, text, language = null) {
  const wrapper = node('section', 'repl-result-section');
  wrapper.append(node('h3', null, title));
  const pre = node('pre');
  const code = node('code', language ? `language-${language}` : null);
  if (language === 'clojure') code.innerHTML = highlightLisp(text);
  else code.textContent = text;
  pre.append(code);
  wrapper.append(pre);
  return wrapper;
}

function actionButton(label, handler) {
  const button = node('button', 'btn secondary compact', label);
  button.type = 'button';
  button.addEventListener('click', handler);
  return button;
}

async function copyText(text, dom) {
  try {
    await navigator.clipboard.writeText(text);
    announce(dom, 'Copied to clipboard.');
  } catch {
    announce(dom, 'Clipboard access was unavailable. Select the visible text to copy it.', 'warning');
  }
}

function node(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}

function nodeWithChild(tag, className, child) {
  const element = node(tag, className);
  element.append(child);
  return element;
}

function prettyJson(value) {
  try { return JSON.stringify(value, null, 2); }
  catch { return 'Value could not be formatted.'; }
}

function humanize(value) {
  return String(value || 'unknown').replaceAll('_', ' ').replace(/\b\w/g, letter => letter.toUpperCase());
}

function safeClass(value) {
  return String(value || 'unknown').replace(/[^a-z0-9_-]/gi, '-').toLowerCase();
}

function firstLine(value) {
  const line = String(value).split('\n', 1)[0];
  return line.length > 100 ? `${line.slice(0, 99)}…` : line;
}

function formatTimestamp(value) {
  if (!value) return '—';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? String(value) : date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function formatDuration(value) {
  if (!Number.isFinite(value)) return '—';
  const seconds = Math.max(0, Math.floor(value / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}

function number(value) {
  return Number.isFinite(value) ? value.toLocaleString() : '—';
}

function nearPageBottom() {
  return window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 160;
}
