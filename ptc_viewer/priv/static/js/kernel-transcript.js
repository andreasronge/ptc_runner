// Canonical Kernel TraceLog transcript view.
//
// This is intentionally a projection of the shared sanitized event vocabulary,
// not the private evaluator transcript format. Canonical traces expose bounded
// run/evaluation/capability facts while omitting prompt, result, argument and
// prelude-source payloads. When the host pins a private inspection artifact,
// its exact payloads are joined to canonical IDs and rendered inside clearly
// marked private panels; nothing is inferred or reconstructed without it.

import { escapeHtml } from './utils.js';
import { highlightLisp } from './highlight.js';
import { indexInspection } from './inspection.js';
import { renderTokenUsage } from './token-usage.js';

const SUCCESS = new Set(['ok', 'returned', 'completed', 'success']);
const FAILURE = new Set([
  'error', 'failed', 'timeout', 'memory_exceeded', 'limit_exceeded',
  'evaluation_error', 'protocol_error'
]);

export function renderKernelTranscript(container, { metadata = {}, turns = {}, inspection = null }, options = {}) {
  container.innerHTML = renderKernelTranscriptMarkup({ metadata, turns, inspection });

  container.querySelector('[data-kt-action="expand"]')?.addEventListener('click', () => {
    container.querySelectorAll('.kernel-transcript details').forEach(details => { details.open = true; });
  });

  container.querySelector('[data-kt-action="collapse"]')?.addEventListener('click', () => {
    container.querySelectorAll('.kernel-transcript details').forEach(details => { details.open = false; });
  });

  const loadMore = container.querySelector('.kernel-load-more');
  if (loadMore && options.onLoadMore) loadMore.addEventListener('click', () => options.onLoadMore(loadMore));
}

export function renderKernelTranscriptMarkup({ metadata = {}, turns = {}, inspection = null }) {
  const events = [...(turns.items || [])].sort((left, right) => left.sequence - right.sequence);
  const transcript = buildTranscript(events);
  const privateIndex = indexInspection(inspection);
  const dialogueTurns = buildDialogueTurns(transcript, privateIndex);

  return `
    <section class="kernel-transcript">
      ${renderHeader(metadata, transcript, events.length, Boolean(turns.next_cursor))}
      ${renderPreludes(metadata, privateIndex)}
      ${renderFingerprints(metadata)}
      ${renderTokenUsage(dialogueTurns, { partial: Boolean(turns.next_cursor) })}
      ${renderDialogue(dialogueTurns, { partial: Boolean(turns.next_cursor) })}
      ${renderToolbar()}
      ${renderExecution(transcript, privateIndex)}
      ${renderLooseEvents(transcript.looseEvents)}
      ${turns.next_cursor ? '<button class="btn kernel-load-more" type="button">Load more events</button>' : ''}
    </section>
  `;
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
  `;
}

function renderToolbar() {
  return `
    <div class="kt-toolbar">
      <span>Execution transcript</span>
      <div>
        <button type="button" class="kt-text-button" data-kt-action="expand">Expand all</button>
        <button type="button" class="kt-text-button" data-kt-action="collapse">Collapse all</button>
      </div>
    </div>
  `;
}

function renderPreludes(metadata, index) {
  const entries = [
    ['Workflow prelude', 'workflow', metadata.workflow_prelude],
    ['Mission prelude', 'mission', metadata.mission_prelude]
  ];

  return `
    <div class="kt-preludes">
      ${entries
        .map(([title, environment, prelude]) => renderPreludeCard(title, environment, prelude, index))
        .join('')}
    </div>
  `;
}

function renderPreludeCard(title, environment, prelude, index) {
  const ids = Array.isArray(prelude?.component_ids) ? prelude.component_ids : [];
  const components = dependencyGraph(prelude);

  return `
    <article class="kt-prelude-card">
      <div class="kt-card-label">${escapeHtml(title)}${ids.length ? ` <span class="kt-card-count">${ids.length} component${ids.length === 1 ? '' : 's'}</span>` : ''}</div>
      ${components ? renderComponentRows(components) : renderComponentChips(ids)}
      ${ids.length > 1 ? '<div class="kt-prelude-order-note">Load order — dependencies before dependants.</div>' : ''}
      ${renderComponentSources(environment, ids, index)}
      <div class="kt-hash" title="${escapeHtml(String(prelude?.hash || ''))}">${escapeHtml(shorten(prelude?.hash) || 'No bundle hash')}</div>
    </article>
  `;
}

// Exact effective component source is available only through the pinned
// private inspection artifact; without it the card shows identity and
// dependency facts alone.
function renderComponentSources(environment, ids, index) {
  const records = ids
    .map(id => [id, index.byComponent.get(`${environment}/${id}`)])
    .filter(([, record]) => typeof record?.payload?.source === 'string');
  if (!records.length) return '';

  return `
    <div class="kt-turn-label">Component source <span class="kt-private-chip">private</span></div>
    ${records.map(([id, record]) => `
      <details class="kt-raw kt-private-payload">
        <summary>${escapeHtml(id)} <span>${escapeHtml(String(record.payload.source_bytes))} bytes</span></summary>
        <pre class="kt-code kt-code-lisp">${highlightLisp(record.payload.source)}</pre>
      </details>
    `).join('')}
  `;
}

// Dependency edges are rendered from the planned compact projection:
// `component_ids` plus positionally aligned `dependency_indices`, where every
// index points to an earlier component (frozen dependency-before-dependant
// order). The complete graph must validate; any malformed input falls back to
// ordered chips — never partially rendered edges, reordered IDs, or inferred
// dependencies.
function dependencyGraph(prelude) {
  const ids = prelude?.component_ids;
  const indices = prelude?.dependency_indices;
  if (!Array.isArray(ids) || !ids.length || !Array.isArray(indices)) return null;
  if (indices.length !== ids.length) return null;
  if (!ids.every(id => typeof id === 'string')) return null;
  if (new Set(ids).size !== ids.length) return null;

  const components = [];
  for (let position = 0; position < ids.length; position++) {
    const dependencyList = indices[position];
    if (!Array.isArray(dependencyList)) return null;
    let previous = -1;
    for (const index of dependencyList) {
      if (!Number.isInteger(index) || index < 0 || index >= position || index <= previous) return null;
      previous = index;
    }
    components.push({ id: ids[position], dependencies: dependencyList.map(index => ids[index]) });
  }

  return components;
}

function renderComponentChips(ids) {
  return `
    <div class="kt-component-list">
      ${ids.length
        ? ids.map((id, index) => `<span><em class="kt-component-order">${index + 1}</em>${escapeHtml(String(id))}</span>`).join('')
        : '<em>No components</em>'}
    </div>
  `;
}

function renderComponentRows(components) {
  const dependants = new Map();
  for (const component of components) {
    for (const dependency of component.dependencies) {
      dependants.set(dependency, (dependants.get(dependency) || 0) + 1);
    }
  }

  return `
    <ol class="kt-component-rows">
      ${components.map(component => `
        <li>
          <code>${escapeHtml(component.id)}</code>
          ${dependants.has(component.id) ? `<span class="kt-component-used-by" title="Direct dependants">↳ used by ${dependants.get(component.id)}</span>` : ''}
          ${component.dependencies.length
            ? `<span class="kt-component-deps">needs ${component.dependencies.map(dependency => `<span>${escapeHtml(dependency)}</span>`).join('')}</span>`
            : ''}
        </li>
      `).join('')}
    </ol>
  `;
}

function renderFingerprints(metadata) {
  const connectors = metadata.connector_snapshots || [];
  const inventoryHash = metadata.mission_inventory_hash;
  if (!inventoryHash && !connectors.length) return '';

  return `
    <section class="kt-fingerprints" aria-label="Frozen run fingerprints">
      <article class="kt-prelude-card">
        <div class="kt-card-label">Mission inventory</div>
        <div class="kt-fingerprint-summary">${escapeHtml(String(metadata.mission_inventory_bytes ?? 0))} bytes</div>
        <div class="kt-hash" title="${escapeHtml(String(inventoryHash || ''))}">${escapeHtml(shorten(inventoryHash) || 'No inventory hash')}</div>
      </article>
      ${connectors.map(connector => `
        <article class="kt-prelude-card">
          <div class="kt-card-label">Connector · ${escapeHtml(String(connector.provider || 'unknown'))}</div>
          <div class="kt-fingerprint-summary">${escapeHtml(String(connector.protocol || 'unknown protocol'))} · ${(connector.tools || []).length} tools</div>
          <div class="kt-hash" title="${escapeHtml(String(connector.snapshot_hash || ''))}">${escapeHtml(shorten(connector.snapshot_hash) || 'No snapshot hash')}</div>
        </article>
      `).join('')}
    </section>
  `;
}

// --- Model dialogue -------------------------------------------------------
//
// Reconstructs the agent loop turn by turn from private llm-request records:
// what the model was told (including feedback on its previous program), the
// program it generated, and how that program's evaluation ended.

function renderDialogue(turns, options = {}) {
  if (!turns.length) return '';

  return `
    <div class="kt-toolbar kt-dialogue-toolbar">
      <span>Model dialogue</span>
      <span class="kt-private-chip" title="Joined from the pinned private inspection artifact">private</span>
      ${options.partial ? '<span class="kt-partial-chip" title="More canonical events exist beyond the loaded pages; later turns may be missing">partial</span>' : ''}
    </div>
    <section class="kt-dialogue" aria-label="Model dialogue">
      ${turns.map(renderDialogueTurn).join('')}
    </section>
  `;
}

export function buildDialogueTurns(transcript, index) {
  const llmCalls = transcript.capabilities.filter(call =>
    nameOf(call) === 'llm-request' && index.byCapability.get(call.id)?.input
  );
  if (!llmCalls.length) return [];

  const missionEvaluations = transcript.evaluations.filter(evaluation =>
    environmentOf(evaluation) === 'mission'
  );
  let previousMessageCount = 0;

  return llmCalls.map((call, turnIndex) => {
    const records = index.byCapability.get(call.id);
    const request = records.input?.payload?.arguments || {};
    const messages = Array.isArray(request.messages) ? request.messages : [];
    const newMessages = messages.slice(previousMessageCount);
    previousMessageCount = messages.length;

    const result = records.output?.payload?.result;
    const value = result && typeof result === 'object' ? result.value || {} : {};
    const toolCalls = Array.isArray(value.tool_calls) ? value.tool_calls : [];

    // Pair a mission evaluation only on an exact captured-source match with
    // one of this turn's generated programs — never positionally. A window
    // without a verifiable match renders unpaired rather than guessed.
    const lowerBound = call.stop?.sequence ?? call.start?.sequence ?? 0;
    const nextCall = llmCalls[turnIndex + 1];
    const upperBound = nextCall ? sequenceOf(nextCall) : Infinity;
    const programs = toolCalls
      .map(toolCall => toolCall?.args?.program)
      .filter(program => typeof program === 'string');
    const evaluation = missionEvaluations.find(candidate => {
      const sequence = sequenceOf(candidate);
      if (sequence <= lowerBound || sequence >= upperBound) return false;
      const record = index.byEvaluation.get(candidate.id);
      return typeof record?.payload?.source === 'string' &&
        programs.includes(record.payload.source);
    }) || null;
    const sourceRecord = evaluation ? index.byEvaluation.get(evaluation.id) || null : null;

    return {
      turn: turnIndex,
      call,
      request,
      newMessages,
      result,
      value,
      toolCalls,
      evaluation,
      sourceRecord,
      sourceVerified: Boolean(
        sourceRecord?.payload?.source_hash &&
        evaluation?.start?.data?.source_hash &&
        sourceRecord.payload.source_hash === evaluation.start.data.source_hash
      )
    };
  });
}

function renderDialogueTurn(turn) {
  const requestStatus = turn.result && typeof turn.result === 'object' ? turn.result.status : null;
  const evaluationStatus = turn.evaluation ? statusOf(turn.evaluation) : null;

  return `
    <article class="kt-turn">
      <header class="kt-turn-header">
        <strong>LLM call ${turn.turn + 1}</strong>
        <span class="kt-turn-meta">
          ${turn.call.stop?.data?.duration_ms == null ? '' : `<span>${escapeHtml(duration(turn.call.stop.data.duration_ms))}</span>`}
          ${requestStatus ? statusBadge(requestStatus) : ''}
          <span class="kt-sequence">#${escapeHtml(String(sequenceOf(turn.call)))}</span>
        </span>
      </header>
      <div class="kt-turn-in">
        <div class="kt-turn-label">${turn.turn === 0 ? 'Sent to model' : 'New since previous call'}</div>
        ${turn.newMessages.length
          ? turn.newMessages.map(renderMessage).join('')
          : '<p class="kt-missing">No new messages recorded for this call.</p>'}
        ${renderFullRequest(turn.request)}
      </div>
      <div class="kt-turn-out">
        <div class="kt-turn-label">Model response</div>
        ${renderResponse(turn)}
      </div>
      ${renderTurnEvaluation(turn, evaluationStatus)}
    </article>
  `;
}

function renderMessage(message) {
  const role = String(message?.role || 'unknown');
  const feedback = role === 'tool';

  if (role === 'assistant' && Array.isArray(message.tool_calls) && message.tool_calls.length) {
    return `
      <div class="kt-msg kt-msg-assistant">
        <span class="kt-msg-role">assistant</span>
        ${message.tool_calls.map(toolCall => renderProgram(toolCall?.args?.program, toolCall?.name)).join('')}
      </div>
    `;
  }

  return `
    <div class="kt-msg kt-msg-${safeClass(role)}">
      <span class="kt-msg-role">${escapeHtml(role)}${feedback ? ' · feedback' : ''}</span>
      <div class="kt-msg-content">${escapeHtml(messageText(message))}</div>
    </div>
  `;
}

function messageText(message) {
  const content = message?.content;
  if (typeof content === 'string') return content;
  if (content == null) return '(no content)';
  return JSON.stringify(content, null, 2);
}

function renderFullRequest(request) {
  const messages = Array.isArray(request.messages) ? request.messages : [];
  const tools = Array.isArray(request.tools) ? request.tools : [];

  return `
    <details class="kt-raw kt-turn-request">
      <summary>Exact request sent to the model <span>${messages.length} messages · ${tools.length} tools${request.system ? ' · system prompt' : ''}</span></summary>
      ${request.system ? `<div class="kt-turn-label">System prompt</div><pre class="kt-code">${escapeHtml(String(request.system))}</pre>` : ''}
      <div class="kt-turn-label">Messages</div>
      ${messages.map(renderMessage).join('')}
      ${tools.length ? `<div class="kt-turn-label">Tools</div><pre class="kt-code">${json(tools)}</pre>` : ''}
    </details>
  `;
}

function renderResponse(turn) {
  if (!turn.result) return '<p class="kt-missing">No response was captured for this call (the attempt may have been interrupted).</p>';

  const parts = [];
  if (turn.toolCalls.length) {
    parts.push(turn.toolCalls.map(toolCall => renderProgram(toolCall?.args?.program, toolCall?.name)).join(''));
  }
  if (typeof turn.value.content === 'string' && turn.value.content.trim()) {
    parts.push(`<div class="kt-msg kt-msg-assistant"><span class="kt-msg-role">assistant · prose</span><div class="kt-msg-content">${escapeHtml(turn.value.content)}</div></div>`);
  }
  if (!parts.length) {
    parts.push(`<pre class="kt-code">${json(turn.result)}</pre>`);
  }

  const tokens = turn.value.tokens;
  if (tokens && (tokens.input || tokens.output)) {
    const extras = [
      tokens.cache_read > 0 ? `${tokens.cache_read} cache read` : '',
      tokens.cache_creation > 0 ? `${tokens.cache_creation} cache creation` : '',
      typeof tokens.total_cost === 'number' && tokens.total_cost > 0 ? `$${Number(tokens.total_cost.toPrecision(2))}` : ''
    ].filter(Boolean).map(extra => ` · ${escapeHtml(extra)}`).join('');
    parts.push(`<div class="kt-turn-tokens">${escapeHtml(String(tokens.input ?? 0))} in · ${escapeHtml(String(tokens.output ?? 0))} out tokens${extras}</div>`);
  }

  return parts.join('');
}

function renderProgram(program, label) {
  if (typeof program !== 'string' || !program) return '';
  return `
    <div class="kt-program">
      <div class="kt-program-label">${escapeHtml(String(label || 'run_ptc_lisp'))} · generated program</div>
      <pre class="kt-code kt-code-lisp">${highlightLisp(program)}</pre>
    </div>
  `;
}

function renderTurnEvaluation(turn, evaluationStatus) {
  if (!turn.evaluation) {
    return turn.toolCalls.length
      ? '<div class="kt-turn-eval"><span class="kt-turn-label">Evaluation</span><p class="kt-missing">No mission evaluation with captured source exactly matching this response was found; pairing is omitted rather than inferred.</p></div>'
      : '';
  }

  return `
    <div class="kt-turn-eval">
      <span class="kt-turn-label">Evaluation</span>
      <span class="kt-turn-eval-facts">
        <code>${escapeHtml(String(turn.evaluation.id))}</code>
        ${statusBadge(evaluationStatus)}
        ${turn.evaluation.stop?.data?.duration_ms == null ? '' : `<span>${escapeHtml(duration(turn.evaluation.stop.data.duration_ms))}</span>`}
        ${hashBadge(turn)}
      </span>
    </div>
  `;
}

function hashBadge(turn) {
  if (!turn.sourceRecord) return '';
  return turn.sourceVerified
    ? '<span class="kt-hash-ok" title="Captured source hash matches the canonical evaluation-started source_hash">source hash verified</span>'
    : '<span class="kt-hash-bad" title="Captured source hash does not match the canonical evaluation-started source_hash">source hash mismatch</span>';
}

// --- Execution transcript -------------------------------------------------

function renderExecution(transcript, index) {
  if (!transcript.evaluations.length) {
    return '<div class="kt-empty">No evaluation events were recorded for this run.</div>';
  }

  return `<div class="kt-execution">${transcript.evaluations.map(evaluation => renderEvaluation(evaluation, index)).join('')}</div>`;
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
          <small>${escapeHtml(evaluation.id || '')}</small>
        </span>
        <span class="kt-summary-meta">
          ${elapsed == null ? '' : `<span>${escapeHtml(duration(elapsed))}</span>`}
          ${statusBadge(status)}
          <span class="kt-sequence">#${escapeHtml(String(sequence))}</span>
        </span>
      </summary>
      <div class="kt-evaluation-body">
        ${renderEvaluationSource(evaluation, index)}
        ${renderCapabilities(evaluation.capabilities, index)}
        ${renderAnnotations(evaluation.annotations)}
        ${renderLimits(evaluation.limits)}
        ${rawDetails('Evaluation start', evaluation.start)}
        ${evaluation.stop ? rawDetails('Evaluation stop', evaluation.stop) : missing('Evaluation has no stop event')}
      </div>
    </details>
  `;
}

function renderEvaluationSource(evaluation, index) {
  const record = index.byEvaluation.get(evaluation.id);
  const canonicalHash = evaluation.start?.data?.source_hash;
  if (!record) {
    return canonicalHash
      ? `<p class="kt-sanitized-note">Program source is omitted from the canonical trace (source_hash ${escapeHtml(shorten(canonicalHash))}, ${escapeHtml(String(evaluation.start?.data?.source_bytes ?? '?'))} bytes).</p>`
      : '';
  }

  const payload = record.payload || {};
  const verified = Boolean(payload.source_hash && canonicalHash && payload.source_hash === canonicalHash);

  return `
    <section class="kt-subsection kt-private-section">
      <h4>Program source <span class="kt-private-chip">private</span>
        ${payload.source_hash && canonicalHash
          ? (verified
            ? '<span class="kt-hash-ok" title="Captured source hash matches the canonical evaluation-started source_hash">source hash verified</span>'
            : '<span class="kt-hash-bad" title="Captured source hash does not match the canonical evaluation-started source_hash">source hash mismatch</span>')
          : ''}
      </h4>
      <pre class="kt-code kt-code-lisp">${highlightLisp(String(payload.source ?? ''))}</pre>
      <div class="kt-turn-tokens">${escapeHtml(String(payload.program_kind || ''))} · ${escapeHtml(String(payload.source_bytes ?? '?'))} bytes</div>
    </section>
  `;
}

function renderCapabilities(capabilities, index) {
  if (!capabilities.length) return '<div class="kt-subsection-empty">No capability calls in this environment.</div>';

  return `
    <section class="kt-subsection">
      <h4>Capability calls <span>${capabilities.length}</span></h4>
      <div class="kt-call-list">${capabilities.map(capability => renderCapability(capability, index)).join('')}</div>
    </section>
  `;
}

function renderCapability(capability, index) {
  const name = nameOf(capability) || 'unknown capability';
  const status = statusOf(capability);
  const elapsed = capability.stop?.data?.duration_ms;
  const llm = name === 'llm-request';
  const records = index.byCapability.get(capability.id);

  return `
    <details class="kt-call${llm ? ' kt-call-llm' : ''}"${isFailure(status) ? ' open' : ''}>
      <summary>
        <span class="kt-call-icon" aria-hidden="true">${llm ? '✦' : '⌁'}</span>
        <strong>${escapeHtml(name)}</strong>
        <span class="kt-call-meta">
          ${records ? '<span class="kt-private-chip">private</span>' : ''}
          ${elapsed == null ? '' : `<span>${escapeHtml(duration(elapsed))}</span>`}
          ${statusBadge(status)}
        </span>
      </summary>
      <div class="kt-call-body">
        ${llm && !records ? '<p class="kt-sanitized-note">The canonical trace records this LLM boundary without retaining the model-visible request or provider response.</p>' : ''}
        ${records ? renderCapabilityPayloads(records) : ''}
        ${rawDetails('Started', capability.start)}
        ${capability.stop ? rawDetails('Stopped', capability.stop) : missing('Capability has no stop event')}
      </div>
    </details>
  `;
}

function renderCapabilityPayloads(records) {
  return `
    ${records.input ? privatePayload('Arguments', records.input.payload?.arguments) : ''}
    ${records.output
      ? privatePayload('Result', records.output.payload?.result)
      : '<p class="kt-missing">No output record was captured (the attempt may have been interrupted).</p>'}
  `;
}

function privatePayload(title, payload) {
  return `
    <details class="kt-raw kt-private-payload">
      <summary>${escapeHtml(title)} <span class="kt-private-chip">private</span></summary>
      <pre class="kt-code">${json(payload)}</pre>
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
