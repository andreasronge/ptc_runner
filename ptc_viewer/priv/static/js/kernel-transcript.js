// Canonical Kernel TraceLog transcript view.
//
// This is intentionally a projection of the shared sanitized event vocabulary,
// not the private evaluator transcript format. Canonical traces expose bounded
// run/evaluation/capability facts while omitting prompt, result, argument and
// prelude-source payloads. When the host pins a private inspection artifact,
// its exact payloads are joined to canonical IDs and rendered inside clearly
// marked private panels; nothing is inferred or reconstructed without it.
//
// Rendering is Preact. The span/dialogue derivations below stay pure functions
// over canonical events so they remain independently testable, and the view is
// a component tree over their output. Two properties matter here and are the
// reason the string/`innerHTML` renderer was replaced: a re-render (loading a
// further event page) diffs instead of rebuilding, so open disclosures and the
// scroll position survive it, and every interpolated value is escaped by the
// `html` tag rather than by remembering `escapeHtml` at each site.

import { html, rawHtml, mount, toMarkup, Fragment } from './preact.js';
import { diffLines } from './utils.js';
import { highlightLisp } from './highlight.js';
import { indexInspection } from './inspection.js';
import { TokenUsage } from './token-usage.js';

const SUCCESS = new Set(['ok', 'continued', 'returned', 'completed', 'success']);
const FAILURE = new Set([
  'error', 'failed', 'timeout', 'memory_exceeded', 'limit_exceeded',
  'evaluation_error', 'protocol_error'
]);
// Long prose lives in constants so the rendered text node is one clean line
// rather than carrying this file's source indentation into the DOM.
const SANITIZED_NOTE =
  'Prompts, responses, generated source and capability payloads are not present. ' +
  'Start the Viewer with a matching local inspection artifact to inspect model context.';
const OVERLAY_NOTE =
  'Canonical events remain sanitized; model requests, responses, generated programs, ' +
  'feedback and capability payloads shown below come from the pinned local artifact.';
const NO_RESPONSE_NOTE =
  'No response was captured for this call (the attempt may have been interrupted).';
const NO_OUTPUT_NOTE =
  'No output record was captured (the attempt may have been interrupted).';
const UNPAIRED_NOTE =
  'No mission evaluation with captured source exactly matching this response was found; ' +
  'pairing is omitted rather than inferred.';
const LLM_SANITIZED_NOTE =
  'The canonical trace records this LLM boundary without retaining the model-visible ' +
  'request or provider response.';

const RESERVED_CAPABILITIES = new Set([
  'kernel-check-source', 'kernel-eval', 'kernel-mission-inventory', 'kernel-mission-model-context',
  'runtime-usage', 'runtime-remaining', 'cap-list', 'cap-describe', 'workflow-annotate'
]);

export function renderKernelTranscript(container, data, options = {}) {
  mount(container, html`<${KernelTranscript} ...${data} options=${{
    ...options,
    onExpandAll: open => {
      container.querySelectorAll('.kernel-transcript details')
        .forEach(details => { details.open = open; });
    }
  }} />`);
}

export function renderKernelTranscriptMarkup(data) {
  return toMarkup(html`<${KernelTranscript} ...${data} />`);
}

function KernelTranscript({
  metadata = {}, turns = {}, inspection = null, inspectionStatus = null, options = {}
}) {
  const events = [...(turns.items || [])].sort((left, right) => left.sequence - right.sequence);
  const transcript = buildTranscript(events);
  const privateIndex = indexInspection(inspection);
  const dialogueTurns = buildDialogueTurns(transcript, privateIndex);
  const partial = Boolean(turns.next_cursor);

  return html`
    <section class="kernel-transcript">
      <${Hero} metadata=${metadata} transcript=${transcript}
               eventCount=${events.length} truncatedPage=${partial} />
      <${Provenance} metadata=${metadata} turns=${turns} transcript=${transcript}
                     index=${privateIndex} inspection=${inspection}
                     inspectionStatus=${inspectionStatus} />
      <${TokenUsage} turns=${dialogueTurns} partial=${partial} />
      <${Dialogue} turns=${dialogueTurns} partial=${partial} />
      <${Reference} metadata=${metadata} index=${privateIndex}
                    dialogueTurns=${dialogueTurns} transcript=${transcript}
                    hasDialogue=${dialogueTurns.length > 0} options=${options} />
      ${turns.next_cursor && html`
        <button class="btn kernel-load-more" type="button"
                onClick=${event => options.onLoadMore?.(event.currentTarget)}>
          Load more events
        </button>`}
    </section>
  `;
}

// --- Identity and summary -------------------------------------------------

function Hero({ metadata, transcript, eventCount, truncatedPage }) {
  const status = metadata.status || (metadata.complete ? 'complete' : 'incomplete');
  // The run ID is the identity a reader recognises and can act on; the bundle
  // hash identifies the workflow, and two runs of one workflow share it. It
  // stays available as a secondary fact rather than as the heading.
  const title = metadata.run_id || metadata.name || 'Kernel run';
  // Sanitized traces carry hashed model/provider identities; they are shown
  // abbreviated with the full value on hover, like every other digest here.
  const facts = [
    ['Trace', metadata.trace_id],
    ['Duration', duration(metadata.duration_ms)],
    ['Model', abbreviate(metadata.model), metadata.model],
    ['Provider', abbreviate(metadata.provider), metadata.provider],
    ['Source', metadata.source],
    ['Bundle', abbreviate(metadata.name), metadata.name]
  ].filter(([, value]) => value !== null && value !== undefined && value !== '');
  const errorCount = metadata.error_count ?? transcript.limits.length;

  return html`
    <div class="kt-hero">
      <div class="kt-title-row">
        <div>
          <div class="kt-eyebrow">Canonical Kernel trace</div>
          <h2>${String(title)}</h2>
        </div>
        <${StatusBadge} status=${status} />
      </div>
      <div class="kt-facts">
        ${facts.map(([key, value, full]) => html`
          <${Fact} key=${key} label=${key} value=${value} full=${full} />`)}
      </div>
      <${Tags} tags=${metadata.tags || metadata.labels?.tags} />
    </div>
    <div class="kt-metrics" aria-label="Run summary">
      <${Metric} value=${transcript.evaluations.length} label="evaluations" />
      <${Metric} value=${transcript.capabilities.length} label="capability calls" />
      <${Metric} value=${transcript.capabilities.filter(call => nameOf(call) === 'llm-request').length}
                 label="LLM calls" />
      <${Metric} value=${errorCount} label="errors" tone=${errorCount > 0 ? 'error' : ''} />
      <${Metric} value=${eventCount} label=${truncatedPage ? 'events loaded' : 'events'} />
    </div>
  `;
}

function Provenance({ metadata, turns, transcript, index, inspection, inspectionStatus }) {
  const llmCalls = transcript.capabilities.filter(call => nameOf(call) === 'llm-request');
  const dispatchCalls = transcript.capabilities.filter(call => !RESERVED_CAPABILITIES.has(nameOf(call)));
  const llm = joinCounts(llmCalls, index);
  const dispatch = joinCounts(dispatchCalls, index);
  const evidenceComplete = Boolean(metadata.complete) && !metadata.truncated && !turns.next_cursor;
  const conflict = index.conflicts.length > 0;

  if (inspectionStatus?.state === 'error') {
    const status = inspectionStatus.status ? `HTTP ${inspectionStatus.status}` : 'request failed';
    const reason = inspectionStatus.reason ? `: ${inspectionStatus.reason}` : '';
    return html`<div class="kt-provenance kt-provenance-warning" role="status">
      <strong>Private inspection overlay could not be loaded (${status + reason}).</strong>
      ${' '}${'The canonical trace remains available and sanitized.'}
    </div>`;
  }

  if (!inspection) {
    return html`<div class="kt-provenance" role="status">
      <strong>Sanitized canonical trace.</strong>
      ${' '}${SANITIZED_NOTE}
    </div>`;
  }

  const counts = `${llm.joined}/${llm.expected} LLM calls joined · ${dispatch.joined}/${dispatch.expected} dispatch calls joined`;

  if (llm.joined === llm.expected && dispatch.joined === dispatch.expected && evidenceComplete && !conflict) {
    return html`<div class="kt-provenance kt-provenance-private" role="status">
      <strong>Private inspection overlay loaded.</strong>
      ${' '}${OVERLAY_NOTE}
      ${' '}<span>${counts}</span>
    </div>`;
  }

  const interrupted = llm.interrupted ? ` · ${llm.interrupted} interrupted` : '';
  const evidence = evidenceComplete ? '' : ' Canonical evidence incomplete.';
  const conflicts = conflict ? ' Conflicting private records were ignored.' : '';
  return html`<div class="kt-provenance kt-provenance-warning" role="status">
    <strong>Private inspection overlay is incomplete: ${llm.joined}/${llm.expected} LLM calls joined.</strong>
    ${interrupted} ${`${dispatch.joined}/${dispatch.expected} dispatch calls joined.`}${evidence + conflicts}
  </div>`;
}

function joinCounts(calls, index) {
  let joined = 0;
  let interrupted = 0;

  for (const call of calls) {
    const records = index.byCapability.get(call.id);
    const complete = Boolean(records?.input && (!call.stop || records.output));
    if (complete) joined += 1;
    else if (records?.input && call.stop && !records.output) interrupted += 1;
  }

  return { expected: calls.length, joined, interrupted };
}

// --- Reference material ---------------------------------------------------
//
// Everything below the dialogue is supporting evidence rather than the story
// of the run. It stays one click away instead of expanding a small run to
// several screens of prelude chips, prompt text and raw event JSON.

function Reference({ metadata, index, dialogueTurns, transcript, hasDialogue, options }) {
  return html`
    <section class="kt-reference" aria-label="Run reference">
      <${Disclosure} className="kt-reference-panel" summary="Environment"
                     hint="Preludes, mission inventory and connector fingerprints">
        <${Preludes} metadata=${metadata} index=${index} />
        <${Fingerprints} metadata=${metadata} />
      <//>
      <${ModelContext} turns=${dialogueTurns} />
      ${/* Without a private artifact there is no dialogue, and the canonical
            execution transcript is the whole run rather than its detail — so
            it opens by default exactly when nothing else tells the story. */''}
      <${Disclosure} className="kt-reference-panel" summary="Execution transcript"
                     hint=${`${transcript.evaluations.length} evaluations · ${transcript.capabilities.length} capability calls`}
                     open=${!hasDialogue}>
        <div class="kt-toolbar">
          <span>Evaluations in canonical order</span>
          <div>
            <button type="button" class="kt-text-button" data-kt-action="expand"
                    onClick=${() => options.onExpandAll?.(true)}>Expand all</button>
            <button type="button" class="kt-text-button" data-kt-action="collapse"
                    onClick=${() => options.onExpandAll?.(false)}>Collapse all</button>
          </div>
        </div>
        <${Execution} transcript=${transcript} index=${index} />
        <${LooseEvents} events=${transcript.looseEvents} />
      <//>
    </section>
  `;
}

function Disclosure({ className, summary, hint, open = false, children }) {
  return html`
    <details class=${className} open=${open}>
      <summary>
        <span class="kt-disclosure-title">${summary}</span>
        ${hint && html`<span class="kt-disclosure-hint">${hint}</span>`}
      </summary>
      <div class="kt-disclosure-body">${children}</div>
    </details>
  `;
}

function Preludes({ metadata, index }) {
  const entries = [
    ['Workflow prelude', 'workflow', null, metadata.workflow_prelude],
    ...missionEntries(metadata).map(([name, mission]) =>
      [`Mission prelude · ${name}`, 'mission', name, mission.prelude])
  ];

  return html`
    <div class="kt-preludes">
      ${entries.map(([title, environment, mission, prelude]) => html`
        <${PreludeCard} key=${mission || environment} title=${title} environment=${environment}
                        mission=${mission} prelude=${prelude} index=${index} />`)}
    </div>
  `;
}

function PreludeCard({ title, environment, mission, prelude, index }) {
  const ids = Array.isArray(prelude?.component_ids) ? prelude.component_ids : [];
  const components = dependencyGraph(prelude);

  return html`
    <article class="kt-prelude-card">
      <div class="kt-card-label">
        ${title}
        ${ids.length > 0 && html`<span class="kt-card-count">${ids.length} component${ids.length === 1 ? '' : 's'}</span>`}
      </div>
      ${components ? html`<${ComponentRows} components=${components} />` : html`<${ComponentChips} ids=${ids} />`}
      ${ids.length > 1 && html`<div class="kt-prelude-order-note">Load order — dependencies before dependants.</div>`}
      <${ComponentSources} environment=${environment} mission=${mission} ids=${ids} index=${index} />
      <div class="kt-hash" title=${String(prelude?.hash || '')}>${shorten(prelude?.hash) || 'No bundle hash'}</div>
    </article>
  `;
}

// Exact effective component source is available only through the pinned
// private inspection artifact; without it the card shows identity and
// dependency facts alone.
function ComponentSources({ environment, mission, ids, index }) {
  const records = ids
    .map(id => [id, index.byComponent.get(
      mission ? `${environment}/${mission}/${id}` : `${environment}/${id}`
    )])
    .filter(([, record]) => typeof record?.payload?.source === 'string');
  if (!records.length) return null;

  return html`
    <${Fragment}>
      <div class="kt-turn-label">Component source <span class="kt-private-chip">private</span></div>
      ${records.map(([id, record]) => html`
        <details class="kt-raw kt-private-payload" key=${id}>
          <summary>${id} <span>${String(record.payload.source_bytes)} bytes</span></summary>
          ${rawHtml('pre', 'kt-code kt-code-lisp', highlightLisp(record.payload.source))}
        </details>
      `)}
    <//>
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

function ComponentChips({ ids }) {
  return html`
    <div class="kt-component-list">
      ${ids.length
        ? ids.map((id, index) => html`<span key=${id}><em class="kt-component-order">${index + 1}</em>${String(id)}</span>`)
        : html`<em>No components</em>`}
    </div>
  `;
}

function ComponentRows({ components }) {
  const dependants = new Map();
  for (const component of components) {
    for (const dependency of component.dependencies) {
      dependants.set(dependency, (dependants.get(dependency) || 0) + 1);
    }
  }

  return html`
    <ol class="kt-component-rows">
      ${components.map(component => html`
        <li key=${component.id}>
          <code>${component.id}</code>
          ${dependants.has(component.id) && html`
            <span class="kt-component-used-by" title="Direct dependants">↳ used by ${dependants.get(component.id)}</span>`}
          ${component.dependencies.length > 0 && html`
            <span class="kt-component-deps">needs ${component.dependencies.map(dependency =>
              html`<span key=${dependency}>${dependency}</span>`)}</span>`}
        </li>
      `)}
    </ol>
  `;
}

function Fingerprints({ metadata }) {
  const connectors = metadata.connector_snapshots || [];
  const missions = missionEntries(metadata);
  if (!missions.some(([, mission]) => mission.inventory_hash) && !connectors.length) return null;

  return html`
    <section class="kt-fingerprints" aria-label="Frozen run fingerprints">
      ${missions.map(([name, mission]) => html`
        <article class="kt-prelude-card" key=${name}>
          <div class="kt-card-label">Mission inventory · ${name}</div>
          <div class="kt-fingerprint-summary">${String(mission.inventory_bytes ?? 0)} bytes</div>
          <div class="kt-hash" title=${String(mission.inventory_hash || '')}>
            ${shorten(mission.inventory_hash) || 'No inventory hash'}
          </div>
        </article>`)}
      ${connectors.map((connector, position) => {
        const acquisition = connector.acquisition || connector;
        return html`
          <article class="kt-prelude-card" key=${connector.snapshot_hash || position}>
            <div class="kt-card-label">Connector · ${String(connector.provider || 'unknown')}</div>
            <div class="kt-fingerprint-summary">
              ${String(acquisition.protocol || 'unknown protocol')} · ${(acquisition.tools || []).length} tools
            </div>
            <div class="kt-hash" title=${String(connector.snapshot_hash || '')}>
              ${shorten(connector.snapshot_hash) || 'No snapshot hash'}
            </div>
          </article>
        `;
      })}
    </section>
  `;
}

function missionEntries(metadata) {
  if (metadata.missions && typeof metadata.missions === 'object') {
    return Object.entries(metadata.missions).sort(([left], [right]) => left.localeCompare(right));
  }

  if (metadata.mission_prelude || metadata.mission_inventory_hash) {
    return [['default', {
      prelude: metadata.mission_prelude,
      inventory_hash: metadata.mission_inventory_hash,
      inventory_bytes: metadata.mission_inventory_bytes,
      model_context_hash: metadata.mission_model_context_hash,
      model_context_bytes: metadata.mission_model_context_bytes
    }]];
  }

  return [];
}

// --- Model dialogue -------------------------------------------------------
//
// Reconstructs the agent loop turn by turn from private llm-request records:
// what the model was told (including feedback on its previous program), the
// prose it wrote, the program it generated, and how that program's evaluation
// ended.

function ModelContext({ turns }) {
  if (!turns.length) return null;
  const system = turns[0].request?.system;
  if (typeof system !== 'string') return null;
  const bytes = new TextEncoder().encode(system).length;

  return html`
    <${Disclosure} className="kt-reference-panel kt-model-context" summary="Captured model request"
                   hint=${`system prompt · LLM call ${turns[0].turn + 1} · ${bytes} bytes · private`}>
      <${SystemPrompt} system=${system} />
    <//>
  `;
}

function SystemPrompt({ system }) {
  if (!system.startsWith('PTC_AGENT_PROMPT_V1\n')) {
    return html`
      <${Fragment}>
        <p class="kt-sanitized-note">Edited or unknown prompt format; showing the exact captured prompt.</p>
        <pre class="kt-code kt-code-prompt">${system}</pre>
      <//>
    `;
  }

  const sections = splitPromptSections(system);
  if (!sections) return html`<pre class="kt-code kt-code-prompt">${system}</pre>`;

  return html`
    <${Fragment}>
      <div class="kt-prompt-version">${sections.version}</div>
      ${sections.items.map(section => html`
        <section class="kt-prompt-section" key=${section.heading}>
          <h4>${section.heading}</h4>
          <pre>${section.body}</pre>
        </section>
      `)}
      <details class="kt-raw kt-prompt-exact">
        <summary>Exact captured prompt</summary>
        <pre class="kt-code kt-code-raw">${system}</pre>
      </details>
    <//>
  `;
}

function splitPromptSections(system) {
  const lines = system.split('\n');
  const version = lines.shift();
  const fixedHeadings = ['Instructions', 'PTC-Lisp', 'Examples'];
  const apiHeading = 'Available API';
  const headings = new Set([...fixedHeadings, apiHeading]);
  const items = [];
  let current = null;

  for (const line of lines) {
    if (headings.has(line)) {
      if (current) items.push({ ...current, body: current.lines.join('\n').trim() });
      current = { heading: line, lines: [] };
    } else if (current) {
      current.lines.push(line);
    } else if (line.trim()) {
      return null;
    }
  }
  if (current) items.push({ ...current, body: current.lines.join('\n').trim() });
  const found = new Set(items.map(item => item.heading));
  const complete = fixedHeadings.every(heading => found.has(heading)) &&
    found.has(apiHeading) &&
    items.length === fixedHeadings.length + 1;
  return complete ? { version, items } : null;
}

function Dialogue({ turns, partial }) {
  if (!turns.length) return null;

  return html`
    <${Fragment}>
      <div class="kt-toolbar kt-dialogue-toolbar">
        <span>Model dialogue</span>
        <span class="kt-private-chip" title="Joined from the pinned private inspection artifact">private</span>
        ${partial && html`
          <span class="kt-partial-chip"
                title="More canonical events exist beyond the loaded pages; later turns may be missing">partial</span>`}
      </div>
      <section class="kt-dialogue" aria-label="Model dialogue">
        ${turns.map(turn => html`<${DialogueTurn} key=${turn.call.id} turn=${turn} />`)}
      </section>
    <//>
  `;
}

export function buildDialogueTurns(transcript, index) {
  const canonicalLlmCalls = transcript.capabilities.filter(call => nameOf(call) === 'llm-request');
  const llmCalls = canonicalLlmCalls
    .map((call, ordinal) => ({ call, ordinal, nextCall: canonicalLlmCalls[ordinal + 1] }))
    .filter(({ call }) => index.byCapability.get(call.id)?.input);
  if (!llmCalls.length) return [];

  const missionEvaluations = transcript.evaluations.filter(evaluation =>
    environmentOf(evaluation) === 'mission'
  );
  const firstSystem = index.byCapability.get(llmCalls[0].call.id)?.input?.payload?.arguments?.system;
  let previousMessageCount = null;

  return llmCalls.map(({ call, ordinal, nextCall }, joinedIndex) => {
    const records = index.byCapability.get(call.id);
    const request = records.input?.payload?.arguments || {};
    const messages = Array.isArray(request.messages) ? request.messages : [];
    const previousJoined = llmCalls[joinedIndex - 1];
    const previousAvailable = ordinal === 0 || previousJoined?.ordinal === ordinal - 1;
    const messageRelation = ordinal === 0 ? 'initial' : previousAvailable ? 'delta' : 'unavailable';
    const newMessages = messageRelation === 'delta' ? messages.slice(previousMessageCount) : messages;
    previousMessageCount = messages.length;

    const result = records.output?.payload?.result;
    const value = result && typeof result === 'object' ? result.value || {} : {};
    const toolCalls = Array.isArray(value.tool_calls) ? value.tool_calls : [];

    // Pair a mission evaluation only on an exact captured-source match with
    // one of this turn's generated programs — never positionally. A window
    // without a verifiable match renders unpaired rather than guessed.
    const lowerBound = call.stop?.sequence ?? call.start?.sequence ?? 0;
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
      turn: ordinal,
      firstCaptured: joinedIndex === 0,
      messageRelation,
      call,
      request,
      firstSystem,
      newMessages,
      result,
      value,
      toolCalls,
      evaluation,
      sourceRecord,
      systemRelation: joinedIndex === 0
        ? 'first'
        : previousAvailable ? request.system === firstSystem ? 'same' : 'changed' : 'unanchored',
      sourceVerified: Boolean(
        sourceRecord?.payload?.source_hash &&
        evaluation?.start?.data?.source_hash &&
        sourceRecord.payload.source_hash === evaluation.start.data.source_hash
      )
    };
  });
}

function DialogueTurn({ turn }) {
  const requestStatus = turn.result && typeof turn.result === 'object' ? turn.result.status : null;
  const evaluationStatus = turn.evaluation ? statusOf(turn.evaluation) : null;

  return html`
    <article class="kt-turn">
      <header class="kt-turn-header">
        <strong>LLM call ${turn.turn + 1}</strong>
        <span class="kt-turn-meta">
          ${turn.call.stop?.data?.duration_ms != null &&
            html`<span>${duration(turn.call.stop.data.duration_ms)}</span>`}
          ${requestStatus && html`<${StatusBadge} status=${requestStatus} />`}
          <span class="kt-sequence">#${String(sequenceOf(turn.call))}</span>
        </span>
      </header>
      <div class="kt-turn-in">
        <div class="kt-turn-label">${turn.messageRelation === 'initial'
          ? 'Sent to model'
          : turn.messageRelation === 'delta'
            ? 'New since previous call'
            : 'Captured messages · previous request unavailable'}</div>
        ${turn.newMessages.length
          ? turn.newMessages.map((message, position) => html`
              <${Message} key=${position} message=${message} targetCall=${turn.turn + 1} />`)
          : html`<p class="kt-missing">No new messages recorded for this call.</p>`}
        <${PromptRelation} turn=${turn} />
        <${FullRequest} turn=${turn} />
      </div>
      <div class="kt-turn-out">
        <div class="kt-turn-label">Model response</div>
        <${Response} turn=${turn} />
      </div>
      <${TurnEvaluation} turn=${turn} evaluationStatus=${evaluationStatus} />
    </article>
  `;
}

// A changed system prompt is reported as the change itself. Re-printing the
// whole prompt on every call buried the run in repeated identical text and
// still left the reader to spot the difference by eye.
function PromptRelation({ turn }) {
  if (['first', 'unanchored'].includes(turn.systemRelation) || typeof turn.request?.system !== 'string') {
    return null;
  }
  if (turn.systemRelation === 'same') {
    return html`<p class="kt-prompt-same">System prompt: same as LLM call 1.</p>`;
  }

  const changes = diffLines(String(turn.firstSystem ?? ''), turn.request.system);
  const added = changes.filter(change => change.kind === 'add').length;
  const removed = changes.filter(change => change.kind === 'remove').length;

  return html`
    <details class="kt-system-prompt kt-prompt-revision">
      <summary>
        System prompt changed
        <span>LLM call ${turn.turn + 1} · +${added} −${removed} lines vs LLM call 1</span>
      </summary>
      <div class="kt-prompt-diff" aria-label="System prompt difference from LLM call 1">
        ${changes.map((change, position) => html`
          <div class=${`kt-diff-line kt-diff-${change.kind}`} key=${position}>
            <span class="kt-diff-marker" aria-hidden="true">
              ${change.kind === 'add' ? '+' : change.kind === 'remove' ? '−' : ' '}
            </span>
            <span class="kt-diff-text">${change.text}</span>
          </div>
        `)}
      </div>
      <details class="kt-raw kt-prompt-exact">
        <summary>Exact captured prompt for this call</summary>
        <pre class="kt-code kt-code-raw">${turn.request.system}</pre>
      </details>
    </details>
  `;
}

// Assistant turns can carry prose alongside their tool call. The prose is the
// model's stated reasoning about what it is about to run, so it is rendered
// next to the generated program rather than dropped when a tool call exists.
function Message({ message, targetCall }) {
  const role = String(message?.role || 'unknown');
  const feedback = role === 'tool';
  const toolCalls = Array.isArray(message?.tool_calls) ? message.tool_calls : [];
  const prose = typeof message?.content === 'string' ? message.content : '';

  if (role === 'assistant' && toolCalls.length) {
    return html`
      <div class="kt-msg kt-msg-assistant">
        <span class="kt-msg-role">assistant</span>
        ${prose.trim() && html`
          <div class="kt-msg-prose">
            <span class="kt-msg-prose-label">prose</span>
            <div class="kt-msg-content">${prose}</div>
          </div>`}
        ${toolCalls.map((toolCall, position) => html`
          <${Program} key=${position} program=${toolCall?.args?.program} label=${toolCall?.name} />`)}
      </div>
    `;
  }

  return html`
    <div class=${`kt-msg kt-msg-${safeClass(role)}`}>
      <span class="kt-msg-role">
        ${role}${feedback ? ` · feedback · Feedback sent to LLM call ${String(targetCall || '?')}` : ''}
      </span>
      <div class="kt-msg-content">${messageText(message)}</div>
    </div>
  `;
}

function messageText(message) {
  const content = message?.content;
  if (typeof content === 'string') return content;
  if (content == null) return '(no content)';
  return JSON.stringify(content, null, 2);
}

function FullRequest({ turn }) {
  const request = turn.request;
  const messages = Array.isArray(request.messages) ? request.messages : [];
  const tools = Array.isArray(request.tools) ? request.tools : [];

  return html`
    <details class="kt-raw kt-turn-request">
      <summary>
        Raw captured request
        <span>
          ${messages.length} messages · ${tools.length} tools${request.system
            ? ` · ${turn.firstCaptured ? 'system prompt shown above' : 'system prompt captured'}`
            : ''}
        </span>
      </summary>
      <pre class="kt-code kt-code-raw">${json(request)}</pre>
    </details>
  `;
}

function Response({ turn }) {
  if (!turn.result) {
    return html`<p class="kt-missing">${NO_RESPONSE_NOTE}</p>`;
  }

  const prose = typeof turn.value.content === 'string' ? turn.value.content : '';
  const tokens = turn.value.tokens;
  const extras = tokens && (tokens.input || tokens.output)
    ? [
        tokens.cache_read > 0 ? `${tokens.cache_read} cache read` : '',
        tokens.cache_creation > 0 ? `${tokens.cache_creation} cache creation` : '',
        typeof tokens.total_cost === 'number' && tokens.total_cost > 0
          ? `$${Number(tokens.total_cost.toPrecision(2))}` : ''
      ].filter(Boolean)
    : null;

  return html`
    <${Fragment}>
      ${prose.trim() && html`
        <div class="kt-msg kt-msg-assistant kt-msg-reasoning">
          <span class="kt-msg-role">assistant · prose <span class="kt-private-chip">private</span></span>
          <div class="kt-msg-content">${prose}</div>
        </div>`}
      ${turn.toolCalls.map((toolCall, position) => html`
        <${Program} key=${position} program=${toolCall?.args?.program} label=${toolCall?.name} />`)}
      ${!prose.trim() && !turn.toolCalls.length && html`<pre class="kt-code">${json(turn.result)}</pre>`}
      ${extras && html`
        <div class="kt-turn-tokens">
          ${String(tokens.input ?? 0)} in · ${String(tokens.output ?? 0)} out tokens${extras.map(extra => ` · ${extra}`).join('')}
        </div>`}
    <//>
  `;
}

function Program({ program, label }) {
  if (typeof program !== 'string' || !program) return null;
  return html`
    <div class="kt-program">
      <div class="kt-program-label">${String(label || 'run_ptc_lisp')} · generated program</div>
      ${rawHtml('pre', 'kt-code kt-code-lisp', highlightLisp(program))}
    </div>
  `;
}

function TurnEvaluation({ turn, evaluationStatus }) {
  if (!turn.evaluation) {
    return turn.toolCalls.length
      ? html`<div class="kt-turn-eval">
          <span class="kt-turn-label">Evaluation</span>
          <p class="kt-missing">${UNPAIRED_NOTE}</p>
        </div>`
      : null;
  }

  return html`
    <div class="kt-turn-eval">
      <span class="kt-turn-label">Evaluation</span>
      <span class="kt-turn-eval-facts">
        <code>${String(turn.evaluation.id)}</code>
        <${StatusBadge} status=${evaluationStatus} />
        ${turn.evaluation.stop?.data?.duration_ms != null &&
          html`<span>${duration(turn.evaluation.stop.data.duration_ms)}</span>`}
        <${HashBadge} turn=${turn} />
      </span>
    </div>
  `;
}

function HashBadge({ turn }) {
  if (!turn.sourceRecord) return null;
  return turn.sourceVerified
    ? html`<span class="kt-hash-ok"
        title="Captured source hash matches the canonical evaluation-started source_hash">source hash verified</span>`
    : html`<span class="kt-hash-bad"
        title="Captured source hash does not match the canonical evaluation-started source_hash">source hash mismatch</span>`;
}

// --- Execution transcript -------------------------------------------------

function Execution({ transcript, index }) {
  if (!transcript.evaluations.length) {
    return html`<div class="kt-empty">No evaluation events were recorded for this run.</div>`;
  }

  return html`
    <div class="kt-execution">
      ${transcript.evaluations.map(evaluation => html`
        <${Evaluation} key=${evaluation.id} evaluation=${evaluation} index=${index} />`)}
    </div>
  `;
}

function Evaluation({ evaluation, index }) {
  const environment = environmentOf(evaluation) || 'unknown';
  const missionName = missionNameOf(evaluation);
  const status = statusOf(evaluation);
  const elapsed = evaluation.stop?.data?.duration_ms;

  return html`
    <details class=${`kt-evaluation kt-evaluation-${safeClass(environment)}`}
             open=${environment === 'workflow' || isFailure(status)}>
      <summary>
        <span class="kt-flow-marker" aria-hidden="true">${environment === 'mission' ? 'M' : 'W'}</span>
        <span class="kt-summary-main">
          <strong>${capitalize(environment)} evaluation${missionName ? ` · ${missionName}` : ''}</strong>
          <small>${evaluation.id || ''}</small>
        </span>
        <span class="kt-summary-meta">
          ${elapsed != null && html`<span>${duration(elapsed)}</span>`}
          <${StatusBadge} status=${status} />
          <span class="kt-sequence">#${String(sequenceOf(evaluation))}</span>
        </span>
      </summary>
      <div class="kt-evaluation-body">
        <${EvaluationSource} evaluation=${evaluation} index=${index} />
        <${Capabilities} capabilities=${evaluation.capabilities} index=${index} />
        <${Annotations} annotations=${evaluation.annotations} />
        <${Limits} limits=${evaluation.limits} />
        <${RawDetails} title="Evaluation start" event=${evaluation.start} />
        ${evaluation.stop
          ? html`<${RawDetails} title="Evaluation stop" event=${evaluation.stop} />`
          : html`<p class="kt-missing">Evaluation has no stop event</p>`}
      </div>
    </details>
  `;
}

function EvaluationSource({ evaluation, index }) {
  const record = index.byEvaluation.get(evaluation.id);
  const canonicalHash = evaluation.start?.data?.source_hash;
  if (!record) {
    return canonicalHash
      ? html`<p class="kt-sanitized-note">${
          `Program source is omitted from the canonical trace (source_hash ${shorten(canonicalHash)}, ` +
          `${evaluation.start?.data?.source_bytes ?? '?'} bytes).`}</p>`
      : null;
  }

  const payload = record.payload || {};
  const verified = Boolean(payload.source_hash && canonicalHash && payload.source_hash === canonicalHash);

  return html`
    <section class="kt-subsection kt-private-section">
      <h4>
        Program source <span class="kt-private-chip">private</span>
        ${payload.source_hash && canonicalHash && (verified
          ? html`<span class="kt-hash-ok"
              title="Captured source hash matches the canonical evaluation-started source_hash">source hash verified</span>`
          : html`<span class="kt-hash-bad"
              title="Captured source hash does not match the canonical evaluation-started source_hash">source hash mismatch</span>`)}
      </h4>
      ${rawHtml('pre', 'kt-code kt-code-lisp', highlightLisp(String(payload.source ?? '')))}
      <div class="kt-turn-tokens">
        ${String(payload.program_kind || '')} · ${String(payload.source_bytes ?? '?')} bytes
      </div>
    </section>
  `;
}

function Capabilities({ capabilities, index }) {
  if (!capabilities.length) {
    return html`<div class="kt-subsection-empty">No capability calls in this environment.</div>`;
  }

  return html`
    <section class="kt-subsection">
      <h4>Capability calls <span>${capabilities.length}</span></h4>
      <div class="kt-call-list">
        ${capabilities.map(capability => html`
          <${Capability} key=${capability.id} capability=${capability} index=${index} />`)}
      </div>
    </section>
  `;
}

function Capability({ capability, index }) {
  const name = nameOf(capability) || 'unknown capability';
  const status = statusOf(capability);
  const elapsed = capability.stop?.data?.duration_ms;
  const llm = name === 'llm-request';
  const records = index.byCapability.get(capability.id);

  return html`
    <details class=${`kt-call${llm ? ' kt-call-llm' : ''}`} open=${isFailure(status)}>
      <summary>
        <span class="kt-call-icon" aria-hidden="true">${llm ? '✦' : '⌁'}</span>
        <strong>${name}</strong>
        <span class="kt-call-meta">
          ${records && html`<span class="kt-private-chip">private</span>`}
          ${elapsed != null && html`<span>${duration(elapsed)}</span>`}
          <${StatusBadge} status=${status} />
        </span>
      </summary>
      <div class="kt-call-body">
        ${llm && !records && html`<p class="kt-sanitized-note">${LLM_SANITIZED_NOTE}</p>`}
        ${records && html`
          <${Fragment}>
            ${records.input && html`<${PrivatePayload} title="Arguments" payload=${records.input.payload?.arguments} />`}
            ${records.output
              ? html`<${PrivatePayload} title="Result" payload=${records.output.payload?.result} />`
              : html`<p class="kt-missing">${NO_OUTPUT_NOTE}</p>`}
          <//>`}
        <${RawDetails} title="Started" event=${capability.start} />
        ${capability.stop
          ? html`<${RawDetails} title="Stopped" event=${capability.stop} />`
          : html`<p class="kt-missing">Capability has no stop event</p>`}
      </div>
    </details>
  `;
}

function PrivatePayload({ title, payload }) {
  return html`
    <details class="kt-raw kt-private-payload">
      <summary>${title} <span class="kt-private-chip">private</span></summary>
      <pre class="kt-code">${json(payload)}</pre>
    </details>
  `;
}

function Annotations({ annotations }) {
  if (!annotations.length) return null;
  return html`
    <section class="kt-subsection">
      <h4>Workflow annotations <span>${annotations.length}</span></h4>
      ${annotations.map(event => html`
        <details class="kt-annotation" key=${event.sequence}>
          <summary>
            <strong>${String(event.data?.annotation_type || 'annotation')}</strong>
            <span>#${event.sequence}</span>
          </summary>
          <pre>${json(event.data?.data)}</pre>
        </details>
      `)}
    </section>
  `;
}

function Limits({ limits }) {
  if (!limits.length) return null;
  return html`
    <section class="kt-subsection kt-limit-section">
      <h4>Limits reached <span>${limits.length}</span></h4>
      ${limits.map(event => html`
        <div class="kt-limit" key=${event.sequence}>
          <strong>${String(event.data?.reason || 'limit exceeded')}</strong>
          <span>#${event.sequence}</span>
        </div>
      `)}
    </section>
  `;
}

function LooseEvents({ events }) {
  if (!events.length) return null;
  return html`
    <details class="kt-loose-events">
      <summary>Other canonical events <span>${events.length}</span></summary>
      <div>
        ${events.map(event => html`
          <${RawDetails} key=${event.sequence} title=${`#${event.sequence} ${event.type}`} event=${event} />`)}
      </div>
    </details>
  `;
}

function RawDetails({ title, event }) {
  if (!event) return null;
  return html`
    <details class="kt-raw">
      <summary>${title} <span>${formatTimestamp(event.timestamp)}</span></summary>
      <pre>${json(event)}</pre>
    </details>
  `;
}

function Tags({ tags }) {
  const entries = tags && typeof tags === 'object' ? Object.entries(tags) : [];
  if (!entries.length) return null;
  return html`
    <div class="kt-tags">
      ${entries.map(([key, value]) => html`<span key=${key}>${key}: ${String(value)}</span>`)}
    </div>
  `;
}

// --- Canonical span derivation --------------------------------------------

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
      environmentOf(capability) === environmentOf(evaluation) &&
      (environmentOf(evaluation) !== 'mission' ||
        !missionNameOf(capability) ||
        missionNameOf(capability) === missionNameOf(evaluation))
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

function missionNameOf(span) {
  return span?.start?.data?.mission_name || span?.stop?.data?.mission_name || null;
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

// --- Shared presentation atoms --------------------------------------------

function StatusBadge({ status }) {
  const normalized = String(status || 'incomplete');
  const tone = SUCCESS.has(normalized) ? 'success' : isFailure(normalized) ? 'error' : 'neutral';
  return html`<span class=${`kt-status kt-status-${tone}`}>${normalized.replaceAll('_', ' ')}</span>`;
}

function Fact({ label, value, full }) {
  return html`
    <span class="kt-fact">
      <small>${label}</small>
      <strong title=${String(full ?? value)}>${String(value)}</strong>
    </span>
  `;
}

// Digest-shaped values are abbreviated; anything else is left alone so a plain
// model name or provider slug still reads in full.
function abbreviate(value) {
  if (value == null || value === '') return value;
  const text = String(value);
  return /^[a-z0-9]+:[0-9a-f]{32,}$/i.test(text) || /^[0-9a-f]{32,}$/i.test(text)
    ? shorten(text)
    : text;
}

function Metric({ value, label, tone = '' }) {
  return html`
    <div class=${`kt-metric${tone ? ` kt-metric-${tone}` : ''}`}>
      <strong>${String(value ?? 0)}</strong>
      <span>${label}</span>
    </div>
  `;
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
  return JSON.stringify(value ?? null, null, 2);
}
