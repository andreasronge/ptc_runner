// Canonical Kernel TraceLog transcript view.
//
// This is intentionally a projection of the shared sanitized event vocabulary,
// not the private evaluator transcript format. Canonical traces expose bounded
// run/evaluation/capability facts while omitting prompt, result, argument and
// prelude-source payloads.

import { escapeHtml } from './utils.js';

const SUCCESS = new Set(['ok', 'returned', 'completed', 'success']);
const FAILURE = new Set(['error', 'failed', 'timeout', 'memory_exceeded', 'limit_exceeded']);

export function renderKernelTranscript(container, { metadata = {}, turns = {} }, options = {}) {
  const events = [...(turns.items || [])].sort((left, right) => left.sequence - right.sequence);
  const transcript = buildTranscript(events);

  container.innerHTML = `
    <section class="kernel-transcript">
      ${renderHeader(metadata, transcript, events.length, Boolean(turns.next_cursor))}
      ${renderPreludes(metadata)}
      ${renderExecution(transcript)}
      ${renderLooseEvents(transcript.looseEvents)}
      ${turns.next_cursor ? '<button class="btn kernel-load-more" type="button">Load more events</button>' : ''}
    </section>
  `;

  container.querySelector('[data-kt-action="expand"]')?.addEventListener('click', () => {
    container.querySelectorAll('.kernel-transcript details').forEach(details => { details.open = true; });
  });

  container.querySelector('[data-kt-action="collapse"]')?.addEventListener('click', () => {
    container.querySelectorAll('.kernel-transcript details').forEach(details => { details.open = false; });
  });

  const loadMore = container.querySelector('.kernel-load-more');
  if (loadMore && options.onLoadMore) loadMore.addEventListener('click', () => options.onLoadMore(loadMore));
}

export function buildTranscript(events) {
  const evaluations = pairSpans(events, 'evaluation-started', 'evaluation-stopped', 'evaluation_id');
  const capabilities = pairSpans(events, 'capability-started', 'capability-stopped', 'capability_id');
  const claimed = new Set();

  evaluations.forEach(span => claimSpan(claimed, span));

  const annotations = events.filter(event => event.type === 'workflow-annotation');
  const limits = events.filter(event => event.type === 'limit-exceeded');

  for (const evaluation of evaluations) {
    evaluation.capabilities = capabilities.filter(capability =>
      inSpan(capability.start || capability.stop, evaluation) &&
      environmentOf(capability) === environmentOf(evaluation)
    );
    evaluation.capabilities.forEach(span => claimSpan(claimed, span));
    evaluation.annotations = [];
    evaluation.limits = [];
  }

  for (const annotation of annotations) {
    const owner = smallestOwner(annotation, evaluations, 'workflow');
    if (owner) {
      owner.annotations.push(annotation);
      claimed.add(annotation.sequence);
    }
  }

  for (const limit of limits) {
    const owner = smallestOwner(limit, evaluations, limit.data?.environment);
    if (owner) {
      owner.limits.push(limit);
      claimed.add(limit.sequence);
    }
  }

  const looseEvents = events.filter(event =>
    !claimed.has(event.sequence) && !['run-started', 'run-stopped'].includes(event.type)
  );

  return { evaluations, capabilities, annotations, limits, looseEvents };
}

function pairSpans(events, startType, stopType, idKey) {
  const spans = [];
  const pending = new Map();

  for (const event of events) {
    const id = event.data?.[idKey];
    if (!id) continue;

    if (event.type === startType) {
      const span = { id, start: event, stop: null };
      spans.push(span);
      pending.set(id, span);
    } else if (event.type === stopType) {
      const span = pending.get(id);
      if (span) {
        span.stop = event;
        pending.delete(id);
      } else {
        spans.push({ id, start: null, stop: event });
      }
    }
  }

  return spans.sort((left, right) => sequenceOf(left) - sequenceOf(right));
}

function renderHeader(metadata, transcript, eventCount, truncatedPage) {
  const status = metadata.status || (metadata.complete ? 'complete' : 'incomplete');
  const facts = [
    ['Run', metadata.run_id],
    ['Trace', metadata.trace_id],
    ['Duration', duration(metadata.duration_ms)],
    ['Model', metadata.model],
    ['Provider', metadata.provider],
    ['Source', metadata.source]
  ].filter(([, value]) => value !== null && value !== undefined && value !== '');
  const errorCount = metadata.error_count ?? transcript.limits.length;

  return `
    <div class="kt-hero">
      <div class="kt-title-row">
        <div>
          <div class="kt-eyebrow">Canonical Kernel trace</div>
          <h2>${escapeHtml(String(metadata.name || metadata.run_id || 'Kernel run'))}</h2>
        </div>
        ${statusBadge(status)}
      </div>
      <div class="kt-facts">
        ${facts.map(([key, value]) => fact(key, value)).join('')}
      </div>
      ${renderTags(metadata.tags || metadata.labels?.tags)}
      <div class="kt-privacy-note">
        <span class="kt-privacy-icon" aria-hidden="true">◈</span>
        <span><strong>Sanitized trace.</strong> Prompts, responses, capability payloads and private prelude source are intentionally omitted.</span>
      </div>
    </div>
    <div class="kt-metrics" aria-label="Run summary">
      ${metric(transcript.evaluations.length, 'evaluations')}
      ${metric(transcript.capabilities.length, 'capability calls')}
      ${metric(transcript.capabilities.filter(call => nameOf(call) === 'llm-request').length, 'LLM calls')}
      ${metric(errorCount, 'errors', errorCount > 0 ? 'error' : '')}
      ${metric(eventCount, truncatedPage ? 'events loaded' : 'events')}
    </div>
    <div class="kt-toolbar">
      <span>Execution transcript</span>
      <div>
        <button type="button" class="kt-text-button" data-kt-action="expand">Expand all</button>
        <button type="button" class="kt-text-button" data-kt-action="collapse">Collapse all</button>
      </div>
    </div>
  `;
}

function renderPreludes(metadata) {
  const entries = [
    ['Workflow prelude', metadata.workflow_prelude],
    ['Mission prelude', metadata.mission_prelude]
  ];

  return `
    <div class="kt-preludes">
      ${entries.map(([title, prelude]) => {
        const ids = prelude?.component_ids || [];
        return `
          <article class="kt-prelude-card">
            <div class="kt-card-label">${escapeHtml(title)}</div>
            <div class="kt-component-list">
              ${ids.length ? ids.map(id => `<span>${escapeHtml(String(id))}</span>`).join('') : '<em>No components</em>'}
            </div>
            <div class="kt-hash" title="${escapeHtml(String(prelude?.hash || ''))}">${escapeHtml(shorten(prelude?.hash) || 'No bundle hash')}</div>
          </article>
        `;
      }).join('')}
    </div>
  `;
}

function renderExecution(transcript) {
  if (!transcript.evaluations.length) {
    return '<div class="kt-empty">No evaluation events were recorded for this run.</div>';
  }

  return `<div class="kt-execution">${transcript.evaluations.map(renderEvaluation).join('')}</div>`;
}

function renderEvaluation(evaluation, index) {
  const environment = environmentOf(evaluation) || 'unknown';
  const status = statusOf(evaluation);
  const sequence = sequenceOf(evaluation);
  const elapsed = evaluation.stop?.data?.duration_ms;
  const open = environment === 'workflow' || isFailure(status) ? ' open' : '';

  return `
    <details class="kt-evaluation kt-evaluation-${safeClass(environment)}"${open}>
      <summary>
        <span class="kt-flow-marker" aria-hidden="true">${environment === 'mission' ? 'M' : 'W'}</span>
        <span class="kt-summary-main">
          <strong>${capitalize(environment)} evaluation</strong>
          <small>${escapeHtml(evaluation.id || `#${index + 1}`)}</small>
        </span>
        <span class="kt-summary-meta">
          ${elapsed == null ? '' : `<span>${escapeHtml(duration(elapsed))}</span>`}
          ${statusBadge(status)}
          <span class="kt-sequence">#${escapeHtml(String(sequence))}</span>
        </span>
      </summary>
      <div class="kt-evaluation-body">
        ${renderCapabilities(evaluation.capabilities)}
        ${renderAnnotations(evaluation.annotations)}
        ${renderLimits(evaluation.limits)}
        ${rawDetails('Evaluation start', evaluation.start)}
        ${evaluation.stop ? rawDetails('Evaluation stop', evaluation.stop) : missing('Evaluation has no stop event')}
      </div>
    </details>
  `;
}

function renderCapabilities(capabilities) {
  if (!capabilities.length) return '<div class="kt-subsection-empty">No capability calls in this environment.</div>';

  return `
    <section class="kt-subsection">
      <h4>Capability calls <span>${capabilities.length}</span></h4>
      <div class="kt-call-list">${capabilities.map(renderCapability).join('')}</div>
    </section>
  `;
}

function renderCapability(capability) {
  const name = nameOf(capability) || 'unknown capability';
  const status = statusOf(capability);
  const elapsed = capability.stop?.data?.duration_ms;
  const llm = name === 'llm-request';

  return `
    <details class="kt-call${llm ? ' kt-call-llm' : ''}"${isFailure(status) ? ' open' : ''}>
      <summary>
        <span class="kt-call-icon" aria-hidden="true">${llm ? '✦' : '⌁'}</span>
        <strong>${escapeHtml(name)}</strong>
        <span class="kt-call-meta">
          ${elapsed == null ? '' : `<span>${escapeHtml(duration(elapsed))}</span>`}
          ${statusBadge(status)}
        </span>
      </summary>
      <div class="kt-call-body">
        ${llm ? '<p class="kt-sanitized-note">The canonical trace records this LLM boundary without retaining the model-visible request or provider response.</p>' : ''}
        ${rawDetails('Started', capability.start)}
        ${capability.stop ? rawDetails('Stopped', capability.stop) : missing('Capability has no stop event')}
      </div>
    </details>
  `;
}

function renderAnnotations(annotations) {
  if (!annotations.length) return '';
  return `
    <section class="kt-subsection">
      <h4>Workflow annotations <span>${annotations.length}</span></h4>
      ${annotations.map(event => `
        <details class="kt-annotation">
          <summary><strong>${escapeHtml(String(event.data?.annotation_type || 'annotation'))}</strong><span>#${event.sequence}</span></summary>
          <pre>${json(event.data?.data)}</pre>
        </details>
      `).join('')}
    </section>
  `;
}

function renderLimits(limits) {
  if (!limits.length) return '';
  return `
    <section class="kt-subsection kt-limit-section">
      <h4>Limits reached <span>${limits.length}</span></h4>
      ${limits.map(event => `<div class="kt-limit"><strong>${escapeHtml(String(event.data?.reason || 'limit exceeded'))}</strong><span>#${event.sequence}</span></div>`).join('')}
    </section>
  `;
}

function renderLooseEvents(events) {
  if (!events.length) return '';
  return `
    <details class="kt-loose-events">
      <summary>Other canonical events <span>${events.length}</span></summary>
      <div>${events.map(event => rawDetails(`#${event.sequence} ${event.type}`, event)).join('')}</div>
    </details>
  `;
}

function rawDetails(title, event) {
  if (!event) return '';
  return `
    <details class="kt-raw">
      <summary>${escapeHtml(title)} <span>${escapeHtml(formatTimestamp(event.timestamp))}</span></summary>
      <pre>${json(event)}</pre>
    </details>
  `;
}

function renderTags(tags) {
  const entries = tags && typeof tags === 'object' ? Object.entries(tags) : [];
  if (!entries.length) return '';
  return `<div class="kt-tags">${entries.map(([key, value]) => `<span>${escapeHtml(key)}: ${escapeHtml(String(value))}</span>`).join('')}</div>`;
}

function claimSpan(claimed, span) {
  if (span.start) claimed.add(span.start.sequence);
  if (span.stop) claimed.add(span.stop.sequence);
}

function inSpan(event, span) {
  if (!event) return false;
  const lower = span.start?.sequence ?? span.stop?.sequence ?? -Infinity;
  const upper = span.stop?.sequence ?? Infinity;
  return event.sequence >= lower && event.sequence <= upper;
}

function smallestOwner(event, evaluations, environment) {
  return evaluations
    .filter(evaluation =>
      inSpan(event, evaluation) && (!environment || environmentOf(evaluation) === environment)
    )
    .sort((left, right) => spanWidth(left) - spanWidth(right))[0];
}

function spanWidth(span) {
  return (span.stop?.sequence ?? Infinity) - (span.start?.sequence ?? 0);
}

function sequenceOf(span) {
  return span.start?.sequence ?? span.stop?.sequence ?? 0;
}

function environmentOf(span) {
  return span.start?.data?.environment || span.stop?.data?.environment;
}

function nameOf(span) {
  return span.start?.data?.name || span.stop?.data?.name;
}

function statusOf(span) {
  return String(span.stop?.data?.status || span.stop?.data?.outcome || (span.stop ? 'complete' : 'incomplete'));
}

function isFailure(status) {
  return FAILURE.has(String(status));
}

function statusBadge(status) {
  const normalized = String(status || 'incomplete');
  const tone = SUCCESS.has(normalized) ? 'success' : isFailure(normalized) ? 'error' : 'neutral';
  return `<span class="kt-status kt-status-${tone}">${escapeHtml(normalized.replaceAll('_', ' '))}</span>`;
}

function fact(key, value) {
  return `<span class="kt-fact"><small>${escapeHtml(key)}</small><strong title="${escapeHtml(String(value))}">${escapeHtml(String(value))}</strong></span>`;
}

function metric(value, label, tone = '') {
  return `<div class="kt-metric${tone ? ` kt-metric-${tone}` : ''}"><strong>${escapeHtml(String(value ?? 0))}</strong><span>${escapeHtml(label)}</span></div>`;
}

function missing(message) {
  return `<p class="kt-missing">${escapeHtml(message)}</p>`;
}

function duration(milliseconds) {
  if (milliseconds === null || milliseconds === undefined) return '—';
  if (milliseconds < 1000) return `${milliseconds} ms`;
  return `${(milliseconds / 1000).toFixed(milliseconds < 10_000 ? 2 : 1)} s`;
}

function formatTimestamp(timestamp) {
  if (!timestamp) return '';
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return String(timestamp);
  return date.toLocaleString([], { hour12: false });
}

function shorten(hash) {
  if (!hash) return '';
  const value = String(hash);
  return value.length > 18 ? `${value.slice(0, 18)}…` : value;
}

function capitalize(value) {
  const string = String(value || '');
  return string.charAt(0).toUpperCase() + string.slice(1);
}

function safeClass(value) {
  return String(value).replace(/[^a-z0-9-]/gi, '-').toLowerCase();
}

function json(value) {
  return escapeHtml(JSON.stringify(value ?? null, null, 2));
}
