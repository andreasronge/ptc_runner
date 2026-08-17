import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  compareEnvelopes,
  continuationExplanation,
  createAnalyzeButton,
  createReplController,
  nextTabName,
  openResetDialog,
  readViewerConfig,
  templatePayloadMatches
} from '../priv/static/js/repl.js';
import { createRunCatalog } from '../priv/static/js/run-catalog.js';
import { commitCurrentLoad } from '../priv/static/js/current-load.js';

class FakeElement {
  constructor(tag = 'div') {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.listeners = new Map();
    this.dataset = {};
    this.hidden = false;
    this.disabled = false;
    this.open = false;
    this.value = '';
    this.returnValue = '';
    this.selectionStart = 0;
    this.selectionEnd = 0;
    this.textContent = '';
    this.innerHTML = '';
  }

  get lastElementChild() { return this.children.at(-1) || null; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  addEventListener(type, listener) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }
  dispatch(type, event = {}) {
    if (type === 'click' && this.disabled) return;
    event.preventDefault ||= () => {};
    for (const listener of this.listeners.get(type) || []) listener(event);
  }
  focus() { this.focused = true; }
  scrollIntoView() {}
  showModal() { this.open = true; }
  setRangeText(source, start, end) {
    this.value = `${this.value.slice(0, start)}${source}${this.value.slice(end)}`;
    this.selectionStart = this.selectionEnd = start + source.length;
  }
}

class FakeDocument {
  constructor(ids, config) {
    this.hidden = false;
    this.documentElement = { scrollHeight: 1000 };
    this.elements = new Map(ids.map(id => [id, new FakeElement()]));
    this.listeners = new Map();
    this.config = config;
  }
  getElementById(id) { return this.elements.get(id); }
  createElement(tag) { return new FakeElement(tag); }
  addEventListener(type, listener) { this.listeners.set(type, listener); }
  querySelector(selector) {
    if (selector !== 'meta[name="ptc-viewer-config"]') return null;
    return { content: Buffer.from(JSON.stringify(this.config)).toString('base64url') };
  }
}

const envelope = (instance, generation, revision, lifecycle = 'open') => ({
  server_instance_id: instance,
  generation_sequence: generation,
  projection_revision: revision,
  session_id: `session-${generation}`,
  mutation_nonce: `mutation-${generation}-${revision}`,
  lifecycle,
  transcript: [],
  transcript_omitted_count: 0,
  session: {
    profile_id: 'run-analysis-v1',
    profile_digest: 'digest',
    namespaces: ['analysis', 'cap'],
    snapshot: { capture_id: `capture-${generation}`, captured_at: '2026-07-19T12:00:00Z', run_count: 2 },
    usage: { evaluations: { remaining: 10 }, remaining_ms: 30_000, trace_calls: {} },
    trace: { persistence: 'pending', event_count: 0 }
  }
});

assert.equal(compareEnvelopes(null, envelope('server-a', 1, 1)), 1);
assert.equal(compareEnvelopes(envelope('server-a', 1, 3), envelope('server-a', 1, 2)), -1);
assert.equal(compareEnvelopes(envelope('server-a', 2, 9), envelope('server-a', 3, 1)), 1);
assert.equal(compareEnvelopes(envelope('server-a', 3, 1), envelope('server-a', 2, 99)), -1);
assert.equal(compareEnvelopes(envelope('server-a', 1, 1), envelope('server-b', 99, 99)), -1);
assert.equal(compareEnvelopes(envelope('server-a', 1, 1), { generation_sequence: '1' }), -1);

const current = { ...envelope('server-a', 2, 9), session_id: 'session-2' };
assert.equal(templatePayloadMatches(current, { ...envelope('server-a', 2, 7), session_id: 'session-2' }, 'session-2'), true);
assert.equal(templatePayloadMatches(current, { ...envelope('server-a', 3, 1), session_id: 'session-3' }, 'session-2'), false);
assert.equal(templatePayloadMatches(current, { ...envelope('server-b', 2, 7), session_id: 'session-2' }, 'session-2'), false);

assert.match(continuationExplanation('committed_with_history'), /\*1/);
assert.match(continuationExplanation('preserved'), /preserved/);
assert.equal(nextTabName('runs', 'ArrowLeft'), 'live');
assert.equal(nextTabName('repl', 'ArrowRight'), 'live');
assert.equal(nextTabName('live', 'ArrowRight'), 'runs');
assert.equal(nextTabName('repl', 'Home'), 'runs');
assert.equal(nextTabName('runs', 'End'), 'live');
assert.equal(nextTabName('runs', 'ArrowRight', ['runs', 'live']), 'live');
assert.equal(nextTabName('live', 'ArrowLeft', ['runs', 'live']), 'runs');
assert.equal(nextTabName('runs', 'ArrowRight', ['runs', 'repl']), 'repl');
assert.equal(nextTabName('repl', 'ArrowRight', ['runs', 'repl']), 'runs');
assert.equal(nextTabName('runs', 'ArrowRight', []), 'runs');

const fakeDialog = { returnValue: 'confirm', opened: false, showModal() { this.opened = true; } };
openResetDialog(fakeDialog);
assert.equal(fakeDialog.returnValue, '');
assert.equal(fakeDialog.opened, true);

const config = { repl_enabled: true, page_bootstrap_nonce: 'nonce' };
const encoded = Buffer.from(JSON.stringify(config)).toString('base64url');
const fakeDocument = { querySelector: () => ({ content: encoded }) };
assert.deepEqual(readViewerConfig(fakeDocument), config);
assert.deepEqual(readViewerConfig({ querySelector: () => null }), {
  repl_enabled: false,
  live_enabled: false
});
assert.deepEqual(readViewerConfig({ querySelector: () => ({ content: 'not-json' }) }), {
  repl_enabled: false,
  live_enabled: false
});

const ids = [
  'repl-status', 'repl-lifecycle', 'repl-captured-at', 'repl-run-count',
  'repl-evaluations-left', 'repl-time-left', 'repl-session-metadata',
  'repl-profile-banner', 'repl-editor', 'repl-example-buttons', 'repl-evaluate',
  'repl-reset', 'repl-close', 'repl-retry', 'repl-transcript', 'repl-empty',
  'repl-omitted', 'repl-jump-latest', 'repl-template-ready',
  'repl-template-insert', 'repl-template-replace', 'repl-reset-dialog',
  'repl-reset-confirm'
];
const controllerDocument = new FakeDocument(ids, config);
globalThis.document = controllerDocument;
globalThis.window = { innerHeight: 800, scrollY: 0 };
Object.defineProperty(globalThis, 'navigator', {
  configurable: true,
  value: { clipboard: { writeText: async () => {} } }
});
globalThis.sessionStorage = { getItem: () => null, setItem() {}, removeItem() {} };
globalThis.location = { reload() { throw new Error('unexpected reload'); } };
globalThis.setTimeout = callback => ({ callback });
globalThis.clearTimeout = () => {};

const response = (body, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  async json() { return body; }
});
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
};
const flush = async () => {
  for (let index = 0; index < 12; index += 1) await Promise.resolve();
};

let currentLoadGeneration = 1;
const olderRunBody = deferred();
const newerRunBody = deferred();
const committedLoads = [];
const olderSameRunLoad = commitCurrentLoad(1, {
  isCurrent: generation => currentLoadGeneration === generation,
  load: () => olderRunBody.promise,
  commit: value => committedLoads.push(value)
});
currentLoadGeneration = 2;
const newerSameRunLoad = commitCurrentLoad(2, {
  isCurrent: generation => currentLoadGeneration === generation,
  load: () => newerRunBody.promise,
  commit: value => committedLoads.push(value)
});
newerRunBody.resolve({ run_id: 'run-a', snapshot: 'newer' });
assert.equal(await newerSameRunLoad, true);
olderRunBody.resolve({ run_id: 'run-a', snapshot: 'older' });
assert.equal(await olderSameRunLoad, false);
assert.deepEqual(committedLoads, [{ run_id: 'run-a', snapshot: 'newer' }]);

let continuationGeneration = 1;
const staleContinuationBody = deferred();
const continuationRenders = [];
const staleContinuation = commitCurrentLoad(1, {
  isCurrent: generation => continuationGeneration === generation,
  load: () => staleContinuationBody.promise,
  commit: value => continuationRenders.push(value)
});
continuationGeneration = 2;
staleContinuationBody.resolve({ run_id: 'run-a', page: 2 });
assert.equal(await staleContinuation, false);
assert.deepEqual(continuationRenders, []);

// Fresh catalog generations own rendering. Slow older responses and stale
// load-more controls cannot replace a newer post-persistence catalog, while a
// current failure schedules recovery independently of the active REPL tab.
const catalogRequests = [];
const catalogRenders = [];
const catalogErrors = [];
const catalogRetries = [];
const catalog = createRunCatalog({
  fetchPage: cursor => {
    const pending = deferred();
    catalogRequests.push({ cursor, pending });
    return pending.promise;
  },
  renderPage: (page, prior, generation) => catalogRenders.push({ page, prior, generation }),
  reportError: message => catalogErrors.push(message),
  clearError: () => catalogErrors.push(null),
  scheduleRetry: callback => {
    catalogRetries.push(callback);
    return callback;
  },
  cancelRetry: callback => {
    const index = catalogRetries.indexOf(callback);
    if (index >= 0) catalogRetries.splice(index, 1);
  }
});
const staleRefresh = catalog.refresh();
const currentRefresh = catalog.refresh();
catalogRequests[1].pending.resolve({ items: [{ run_id: 'new' }], next_cursor: 'next' });
assert.equal(await currentRefresh, true);
assert.equal(catalogRenders.at(-1).page.items[0].run_id, 'new');
const currentGeneration = catalogRenders.at(-1).generation;
catalogRequests[0].pending.resolve({ items: [{ run_id: 'stale' }] });
assert.equal(await staleRefresh, true);
assert.equal(catalogRenders.length, 1);
assert.equal(await catalog.loadMore('old-cursor', [], currentGeneration - 1), false);
assert.equal(catalogRequests.length, 2);

const failedLoadMore = catalog.loadMore('next', [{ run_id: 'new' }], currentGeneration);
catalogRequests.at(-1).pending.reject(new Error('Load more failed.'));
assert.equal(await failedLoadMore, false);
assert.equal(catalogRetries.length, 1);
const manualLoadMore = catalog.loadMore('next', [{ run_id: 'new' }], currentGeneration);
catalogRequests.at(-1).pending.resolve({ items: [{ run_id: 'next-run' }] });
assert.equal(await manualLoadMore, true);
assert.equal(catalogRetries.length, 0);
assert.equal(catalogRenders.at(-1).page.items[0].run_id, 'next-run');

const failedRefresh = catalog.refresh();
catalogRequests.at(-1).pending.reject(new Error('Catalog network failed.'));
assert.equal(await failedRefresh, false);
assert.deepEqual(catalogErrors.slice(-2), [null, 'Catalog network failed.']);
assert.equal(catalogRetries.length, 1);
catalogRetries[0]();
catalogRequests.at(-1).pending.resolve({ items: [{ run_id: 'recovered' }] });
await flush();
assert.equal(catalogRenders.at(-1).page.items[0].run_id, 'recovered');
assert.equal(catalogErrors.at(-1), null);

let authoritative = envelope('server-a', 1, 1);
let slowPoll = null;
let conflictNextEvaluation = false;
let uncertainNextEvaluation = false;
let resetCount = 0;
let resetRequests = 0;
let failNextReset = false;
let templateCount = 0;
let runsRefreshCount = 0;
let runsRefreshFailures = 2;
const templateRequests = [];

globalThis.fetch = async (path, options = {}) => {
  const method = options.method || 'GET';
  if (path === '/api/repl' && method === 'GET') {
    if (slowPoll) return slowPoll.promise;
    return response(authoritative);
  }
  if (path === '/api/repl/evaluations' && method === 'POST') {
    if (uncertainNextEvaluation) {
      uncertainNextEvaluation = false;
      authoritative = { ...authoritative, projection_revision: authoritative.projection_revision + 1 };
      throw new Error('response lost after commit');
    }
    if (conflictNextEvaluation) {
      conflictNextEvaluation = false;
      authoritative = envelope('server-a', 1, authoritative.projection_revision + 1);
      return response({ error: { code: 'stale_session', message: 'Session changed.' } }, 409);
    }
    return response(authoritative);
  }
  if (path === '/api/repl/templates' && method === 'POST') {
    templateCount += 1;
    const pending = deferred();
    templateRequests.push({ pending, session: authoritative });
    return pending.promise;
  }
  if (path === '/api/repl/reset' && method === 'POST') {
    const requestedSession = options.headers['X-PTC-Viewer-Session'];
    if (requestedSession !== authoritative.session_id) {
      return response({ error: { code: 'session_changed', message: 'The session changed; refresh before retrying.' } }, 412);
    }
    resetRequests += 1;
    if (failNextReset) {
      failNextReset = false;
      authoritative = {
        ...authoritative,
        projection_revision: authoritative.projection_revision + 1,
        lifecycle: 'closed'
      };
      return response({ error: { code: 'repl_start_failed', message: 'Replacement session did not start.' } }, 500);
    }
    resetCount += 1;
    authoritative = envelope('server-a', authoritative.generation_sequence + 1, 1);
    return response(authoritative);
  }
  if (path === '/api/repl' && method === 'DELETE') {
    authoritative = {
      ...authoritative,
      projection_revision: authoritative.projection_revision + 1,
      lifecycle: 'closed'
    };
    return response(authoritative);
  }
  throw new Error(`unexpected request ${method} ${path}`);
};

let availability = null;
let controller;
controller = createReplController({
  pageNonce: 'nonce',
  getSelectedRunId: () => 'run-1',
  activate: () => controller.setActive(true),
  refreshRuns: async () => {
    runsRefreshCount += 1;
    if (runsRefreshFailures > 0) {
      runsRefreshFailures -= 1;
      return false;
    }
    return true;
  },
  onAvailabilityChange: value => { availability = value; }
});
assert.equal(availability, true);
const editor = controllerDocument.getElementById('repl-editor');

// Exercise the same Runs-side Analyze button factory used by app.js. A fresh
// page accepts the click and lets the controller perform its lazy bootstrap.
const analyzeButton = createAnalyzeButton(
  'Analyze run',
  'run',
  'run-1',
  (kind, runId) => controller.requestTemplate(kind, runId),
  controllerDocument
);
analyzeButton.disabled = !availability;
analyzeButton.dispatch('click');
await flush();
assert.equal(templateRequests.length, 1);
templateRequests[0].pending.resolve(response({
  ...authoritative,
  projection_revision: 2,
  template: { source: '(analysis/open "run-1")' }
}));
authoritative = { ...authoritative, projection_revision: 2 };
await flush();
assert.equal(editor.value, '(analysis/open "run-1")');
assert.equal(runsRefreshCount, 1);
templateRequests.shift();

controller.setActive(true);
await flush();
assert.equal(availability, true);

// A background authoritative read is a pure GET: it never changes
// mutation_nonce, and a response that arrives mid-mutation is rejected by
// compareEnvelopes for going backwards. It must therefore leave the user's
// controls alone. Gating them on it disabled every button for the duration of
// each poll leg, which flickered once a second and swallowed clicks and
// keystrokes that landed in the window.
slowPoll = deferred();
controller.setActive(true);
assert.equal(controllerDocument.getElementById('repl-evaluate').disabled, false);

// The keyboard shortcut executes rather than reporting that it could not.
editor.value = '(analysis/runs {})';
controllerDocument.getElementById('repl-editor').dispatch('keydown', { key: 'Enter', ctrlKey: true });
assert.doesNotMatch(controllerDocument.getElementById('repl-status').textContent, /refreshing/);
await flush();

// Analyze is accepted rather than refused while a read is outstanding: the
// intent is queued and drains when the read lands, instead of being rejected
// with a "wait for the current operation" warning the user did not cause.
const templatesBeforeBusyExample = templateCount;
controllerDocument.getElementById('repl-example-buttons').children[1].dispatch('click');
assert.doesNotMatch(controllerDocument.getElementById('repl-status').textContent, /Wait for/);

authoritative = envelope('server-a', 1, 2);
slowPoll.resolve(response(authoritative));
slowPoll = null;
await flush();
assert.equal(templateCount, templatesBeforeBusyExample + 1);

// That queued template is now a real in-flight mutation, which does gate the
// controls; they free up again once it lands.
assert.equal(controllerDocument.getElementById('repl-evaluate').disabled, true);
templateRequests[0].pending.resolve(response({
  ...authoritative,
  template: { source: '(analysis/open "run-1")' }
}));
await flush();
templateRequests.shift();
assert.equal(controllerDocument.getElementById('repl-evaluate').disabled, false);

// A 409 converges through an authoritative read and replaces the obsolete
// warning with visible recovered state.
conflictNextEvaluation = true;
editor.value = '(analysis/runs {})';
controllerDocument.getElementById('repl-evaluate').dispatch('click');
await flush();
assert.match(controllerDocument.getElementById('repl-status').textContent, /synchronized/);
assert.equal(availability, true);

// A lost mutation response blocks replay until polling has reconciled, then
// replaces the failure with explicit transcript-check guidance.
uncertainNextEvaluation = true;
editor.value = '(analysis/read "run-id" {"collection" "execution_errors"})';
controllerDocument.getElementById('repl-evaluate').dispatch('click');
await flush();
assert.match(controllerDocument.getElementById('repl-status').textContent, /uncertain request/);
assert.equal(availability, true);

// A formatted template that protects a newer draft cannot be restored after
// a later Analyze action supersedes it.
editor.value = 'draft-a';
editor.dispatch('input');
const firstTemplate = controller.requestTemplate('run', 'run-1');
await flush();
editor.value = 'newer-draft';
editor.dispatch('input');
templateRequests[0].pending.resolve(response({
  ...authoritative,
  projection_revision: authoritative.projection_revision + 1,
  template: { source: '(analysis/open "run-1")' }
}));
authoritative = { ...authoritative, projection_revision: authoritative.projection_revision + 1 };
await firstTemplate;
await flush();
assert.equal(controllerDocument.getElementById('repl-template-ready').hidden, false);

const secondTemplate = controller.requestTemplate('turns', 'run-1');
await flush();
assert.equal(controllerDocument.getElementById('repl-template-ready').hidden, true);
templateRequests[1].pending.resolve(response({
  ...authoritative,
  projection_revision: authoritative.projection_revision + 1,
  template: { source: '(analysis/read "run-1" {"collection" "activity"})' }
}));
authoritative = { ...authoritative, projection_revision: authoritative.projection_revision + 1 };
await secondTemplate;
await flush();
assert.equal(editor.value, '(analysis/read "run-1" {"collection" "activity"})');
controllerDocument.getElementById('repl-template-replace').dispatch('click');
assert.equal(editor.value, '(analysis/read "run-1" {"collection" "activity"})');

// Reset confirmation is consumed once. A later Escape-style close has an
// empty returnValue and cannot repeat the mutation.
const resetDialog = controllerDocument.getElementById('repl-reset-dialog');
controllerDocument.getElementById('repl-reset').dispatch('click');
resetDialog.returnValue = 'confirm';
resetDialog.open = false;
resetDialog.dispatch('close');
await flush();
assert.equal(resetCount, 1);
assert.equal(runsRefreshCount, 3);

// Polling continues behind an open dialog, and — like every other control —
// Confirm stays usable across the read rather than blinking disabled. It
// retains its captured predecessor and receives a stale-session response
// after another tab advances the generation.
controllerDocument.getElementById('repl-reset').dispatch('click');
const capturedDraft = editor.value;
slowPoll = deferred();
controller.setActive(true);
assert.equal(resetDialog.open, true);
assert.equal(controllerDocument.getElementById('repl-reset-confirm').disabled, false);
authoritative = envelope('server-a', authoritative.generation_sequence + 1, 1);
slowPoll.resolve(response(authoritative));
slowPoll = null;
await flush();
assert.equal(controllerDocument.getElementById('repl-reset-confirm').disabled, false);
assert.equal(runsRefreshCount, 4);
resetDialog.returnValue = 'confirm';
resetDialog.open = false;
resetDialog.dispatch('close');
await flush();
assert.equal(resetCount, 1);
assert.equal(editor.value, capturedDraft);

controllerDocument.getElementById('repl-reset').dispatch('click');
assert.equal(resetDialog.returnValue, '');
resetDialog.open = false;
resetDialog.dispatch('close');
await flush();
assert.equal(resetCount, 1);

// A failed replacement exposes Retry reset while its forced reconciliation is
// still in flight. The disabled retry preserves that exact intent and captured
// predecessor until the authoritative read completes.
failNextReset = true;
slowPoll = deferred();
controllerDocument.getElementById('repl-reset').dispatch('click');
resetDialog.returnValue = 'confirm';
resetDialog.open = false;
resetDialog.dispatch('close');
controller.setActive(false);
await flush();
const requestsBeforeBlockedRetry = resetRequests;
assert.equal(controllerDocument.getElementById('repl-retry').textContent, 'Retry reset');
assert.equal(controllerDocument.getElementById('repl-retry').disabled, false);
controller.setActive(true);
assert.equal(controllerDocument.getElementById('repl-retry').disabled, true);
controllerDocument.getElementById('repl-retry').dispatch('click');
assert.equal(resetRequests, requestsBeforeBlockedRetry);
slowPoll.resolve(response(authoritative));
slowPoll = null;
await flush();
assert.equal(controllerDocument.getElementById('repl-retry').disabled, false);
controllerDocument.getElementById('repl-retry').dispatch('click');
await flush();
assert.equal(resetRequests, requestsBeforeBlockedRetry + 1);
assert.equal(controllerDocument.getElementById('repl-retry').hidden, true);

// A print larger than the server projection budget may leave no retained print
// strings. Its truncation flag must still produce visible feedback.
authoritative = {
  ...authoritative,
  projection_revision: authoritative.projection_revision + 1,
  transcript: [{
    source_preview: '(println huge)',
    source_truncated: false,
    result: {
      evaluation_id: 'evaluation-print',
      status: 'ok',
      outcome: 'continued',
      continuation_effect: 'committed_with_history',
      duration_ms: 1,
      prints: [],
      'prints_truncated?': true
    }
  }]
};
controller.setActive(true);
await flush();
const printCardBody = controllerDocument.getElementById('repl-transcript').children[0].children[1];
const printSection = printCardBody.children.find(child => child.children[0]?.textContent === 'Prints');
assert.equal(printSection.children[1].children[0].textContent, '… prints truncated');

// Analyze is unavailable after a terminal lifecycle transition, and direct
// requests receive actionable feedback without issuing a template mutation.
authoritative = { ...authoritative, projection_revision: authoritative.projection_revision + 1, lifecycle: 'terminal' };
controller.setActive(true);
await flush();
assert.equal(availability, false);
const priorTemplateCount = templateCount;
await controller.requestTemplate('run', 'run-1');
await flush();
assert.equal(templateCount, priorTemplateCount);
assert.match(controllerDocument.getElementById('repl-status').textContent, /open REPL session/);

// A dialog opened while terminal becomes close-only if authoritative polling
// reports backend failure.
controllerDocument.getElementById('repl-reset').dispatch('click');
authoritative = {
  ...authoritative,
  projection_revision: authoritative.projection_revision + 1,
  lifecycle: 'backend_failed'
};
controller.setActive(true);
await flush();
assert.equal(controllerDocument.getElementById('repl-reset-confirm').disabled, true);
resetDialog.returnValue = 'cancel';
resetDialog.open = false;
resetDialog.dispatch('close');
const runsRefreshesBeforeClose = runsRefreshCount;
controllerDocument.getElementById('repl-close').dispatch('click');
await flush();
assert.equal(runsRefreshCount, runsRefreshesBeforeClose + 1);

// A selected-run intent survives a definitive capture failure without
// replacing the catalog error, then runs exactly once after explicit retry.
const retryDocument = new FakeDocument(ids, config);
globalThis.document = retryDocument;
let retryController;
let retryAvailable;
let bootstrapAttempts = 0;
let retryTemplateCount = 0;
globalThis.fetch = async (path, options = {}) => {
  const method = options.method || 'GET';
  if (path === '/api/repl' && method === 'GET') {
    bootstrapAttempts += 1;
    if (bootstrapAttempts === 1) {
      return response({ error: { code: 'trace_unavailable', message: 'The trace source is unavailable.' } }, 503);
    }
    return response(envelope('server-retry', 1, 1));
  }
  if (path === '/api/repl/templates' && method === 'POST') {
    retryTemplateCount += 1;
    return response({
      ...envelope('server-retry', 1, 2),
      template: { source: '(analysis/open "retry-run")' }
    });
  }
  throw new Error(`unexpected retry request ${method} ${path}`);
};
retryController = createReplController({
  pageNonce: 'nonce',
  getSelectedRunId: () => 'retry-run',
  activate: () => retryController.setActive(true),
  refreshRuns: async () => {},
  onAvailabilityChange: value => { retryAvailable = value; }
});
const retryAnalyze = createAnalyzeButton(
  'Analyze run',
  'run',
  'retry-run',
  (kind, runId) => retryController.requestTemplate(kind, runId),
  retryDocument
);
retryAnalyze.disabled = !retryAvailable;
retryAnalyze.dispatch('click');
await flush();
assert.equal(retryTemplateCount, 0);
assert.equal(retryDocument.getElementById('repl-status').textContent, 'The trace source is unavailable.');
assert.equal(retryDocument.getElementById('repl-retry').hidden, false);
retryDocument.getElementById('repl-retry').dispatch('click');
await flush();
assert.equal(retryTemplateCount, 1);
assert.equal(retryDocument.getElementById('repl-editor').value, '(analysis/open "retry-run")');

// Initial bootstrap status follows the authoritative lifecycle instead of
// describing a closed session as ready.
const closedDocument = new FakeDocument(ids, config);
globalThis.document = closedDocument;
globalThis.fetch = async () => response(envelope('server-closed', 1, 1, 'closed'));
const closedController = createReplController({
  pageNonce: 'nonce',
  getSelectedRunId: () => null,
  activate: () => {},
  refreshRuns: async () => true
});
closedController.setActive(true);
await flush();
assert.match(closedDocument.getElementById('repl-status').textContent, /closed/);
assert.doesNotMatch(closedDocument.getElementById('repl-status').textContent, /ready/);

// The decoded run ID must never reach the DOM as an attribute a parser could
// reinterpret. It travels as a closure argument into the router, and through
// the URL only as an encoded hash segment.
const appSource = fs.readFileSync(new URL('../priv/static/js/app.js', import.meta.url), 'utf8');
assert.doesNotMatch(appSource, /data-run-id/);
assert.doesNotMatch(appSource, /dataset\.runId/);
assert.match(appSource, /onClick=\$\{\(\) => selectRun\(run\.run_id\)\}/);
assert.match(appSource, /location\.hash = runId \? `#\/run\/\$\{encodeURIComponent\(runId\)\}`/);
assert.match(appSource, /decodeURIComponent\(match\[1\]\)/);
assert.match(appSource, /loadRun\(route\.runId, routeGeneration\)/);
assert.match(appSource, /encodeURIComponent\(runId\)\}`\),/);
assert.match(appSource, /run\.workflow_prelude\?\.hash/);
assert.match(appSource, /run\.evaluations \?\? 0/);
assert.match(appSource, /renderSemanticConversation\(container, null\)/);
assert.match(appSource, /commitCurrentLoad\(routeGeneration,/);
const loadMoreSource = appSource.slice(
  appSource.indexOf('onLoadMore:'),
  appSource.indexOf('function activateTab')
);
assert.match(loadMoreSource, /commitCurrentLoad\(routeGeneration,/);

process.stdout.write('ok');
