// Canonical Kernel TraceLog transcript view.
//
// This is intentionally a projection of the shared sanitized event vocabulary,
// not the private evaluator transcript format. Authorized conversation and
// prelude projections may enrich the view, but raw inspection records never
// reach this renderer.
//
// Rendering is Preact. The span derivations below stay pure functions over
// canonical events so they remain independently testable, and the view is
// a component tree over their output. Two properties matter here and are the
// reason the string/`innerHTML` renderer was replaced: a re-render (loading a
// further event page) diffs instead of rebuilding, so open disclosures and the
// scroll position survive it, and every interpolated value is escaped by the
// `html` tag rather than by remembering `escapeHtml` at each site.

import { html, mount, rawHtml, toMarkup } from './preact.js';
import { highlightLisp } from './highlight.js';

const SUCCESS = new Set(['ok', 'continued', 'returned', 'completed', 'success']);
const FAILURE = new Set([
  'error', 'failed', 'timeout', 'memory_exceeded', 'limit_exceeded',
  'evaluation_error', 'protocol_error'
]);
// Long prose lives in constants so the rendered text node is one clean line
// rather than carrying this file's source indentation into the DOM.
const SANITIZED_NOTE =
  'Prompts, responses, generated source and capability payloads are not present. ' +
  'Use the semantic analysis views for authorized private evidence.';
const LLM_SANITIZED_NOTE =
  'The canonical trace records this LLM boundary without retaining the model-visible ' +
  'request or provider response.';

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
  metadata = {}, turns = {}, conversation = null, preludes = null, options = {}
}) {
  const events = [...(turns.items || [])].sort((left, right) => left.sequence - right.sequence);
  const transcript = buildTranscript(events);
  const partial = Boolean(turns.next_cursor);
  const preludeIndex = buildPreludeIndex(preludes);
  const privatePrograms = new Map();
  const privateResults = new Map();

  for (const stream of conversation?.streams || []) {
    const streamTurns = stream.turns || [];

    streamTurns.forEach((turn, index) => {
      const generated = turn.generated || [];
      generated.forEach(program => {
        if (program?.evaluation_id) privatePrograms.set(program.evaluation_id, program);
      });

      const feedback = streamTurns[index + 1]?.feedback || [];
      if (!feedback.length) return;

      generated.forEach(program => {
        if (!program?.evaluation_id || program['association_ambiguous?']) return;

        const callIds = new Set(
          (turn.assistant?.tool_calls || [])
            .filter(call => call?.args?.program === program.source && call?.id)
            .map(call => call.id)
        );
        const matched = feedback.filter(message => callIds.has(message?.tool_call_id));
        const result = matched.length ? matched : generated.length === 1 ? feedback : [];
        if (result.length) privateResults.set(program.evaluation_id, result);
      });
    });
  }

  transcript.evaluations.forEach(evaluation => {
    evaluation.privateProgram = privatePrograms.get(evaluation.id) || null;
    evaluation.privateResult = privateResults.get(evaluation.id) || null;
  });

  return html`
    <section class="kernel-transcript">
      <${Hero} metadata=${metadata} transcript=${transcript}
               eventCount=${events.length} truncatedPage=${partial} />
      <${Provenance} />
      <${Reference} metadata=${metadata} transcript=${transcript}
                    preludeIndex=${preludeIndex} options=${options} />
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

function Provenance() {
  return html`<div class="kt-provenance" role="status">
    <strong>Sanitized canonical trace.</strong>
    ${' '}${SANITIZED_NOTE}
  </div>`;
}

// --- Reference material ---------------------------------------------------
//
// Supporting canonical evidence stays one click away instead of expanding a
// small run to several screens of prelude chips and raw event JSON.

function Reference({ metadata, transcript, preludeIndex, options }) {
  return html`
    <section class="kt-reference" aria-label="Run reference">
      <${Disclosure} className="kt-reference-panel" summary="Environment"
                     hint="Preludes, mission inventory and connector fingerprints">
        <${Preludes} metadata=${metadata} preludeIndex=${preludeIndex} />
        <${Fingerprints} metadata=${metadata} />
      <//>
      <${Disclosure} className="kt-reference-panel" summary="Execution transcript"
                     hint=${`${transcript.evaluations.length} evaluations · ${transcript.capabilities.length} capability calls`}
                     open=${true}>
        <div class="kt-toolbar">
          <span>Evaluations in canonical order</span>
          <div>
            <button type="button" class="kt-text-button" data-kt-action="expand"
                    onClick=${() => options.onExpandAll?.(true)}>Expand all</button>
            <button type="button" class="kt-text-button" data-kt-action="collapse"
                    onClick=${() => options.onExpandAll?.(false)}>Collapse all</button>
          </div>
        </div>
        <${Execution} transcript=${transcript} preludeIndex=${preludeIndex} />
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

function Preludes({ metadata, preludeIndex }) {
  const entries = [
    ['Workflow prelude', 'workflow', null, metadata.workflow_prelude],
    ...missionEntries(metadata).map(([name, mission]) =>
      [`Mission prelude · ${name}`, 'mission', name, mission.prelude])
  ];

  return html`
    <div class="kt-preludes">
      ${entries.map(([title, environment, mission, prelude]) => html`
        <${PreludeCard} key=${mission || environment} title=${title} prelude=${prelude}
                        environment=${environment} mission=${mission}
                        preludeIndex=${preludeIndex} />`)}
    </div>
  `;
}

function PreludeCard({ title, prelude, environment, mission, preludeIndex }) {
  const ids = Array.isArray(prelude?.component_ids) ? prelude.component_ids : [];
  const components = dependencyGraph(prelude);
  const hasPrivateSources = ids.some(id =>
    preludeIndex.byComponent.has(scopeComponentKey(environment, mission, id))
  );

  return html`
    <article class="kt-prelude-card">
      <div class="kt-card-label">
        ${title}
        ${ids.length > 0 && html`<span class="kt-card-count">${ids.length} component${ids.length === 1 ? '' : 's'}</span>`}
        ${hasPrivateSources && html`<span class="kt-private-badge">private evidence</span>`}
      </div>
      ${components
        ? html`<${ComponentRows} components=${components} environment=${environment}
                                mission=${mission} preludeIndex=${preludeIndex} />`
        : html`<${ComponentChips} ids=${ids} environment=${environment}
                                mission=${mission} preludeIndex=${preludeIndex} />`}
      ${ids.length > 1 && html`<div class="kt-prelude-order-note">Load order — dependencies before dependants.</div>`}
      <div class="kt-hash" title=${String(prelude?.hash || '')}>${shorten(prelude?.hash) || 'No bundle hash'}</div>
    </article>
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

function ComponentChips({ ids, environment, mission, preludeIndex }) {
  return html`
    <div class="kt-component-list">
      ${ids.length
        ? ids.map((id, index) => html`
            <${ComponentSource} key=${id} component=${{ id, dependencies: [] }} position=${index}
                                environment=${environment} mission=${mission}
                                preludeIndex=${preludeIndex} compact=${true} />`)
        : html`<em>No components</em>`}
    </div>
  `;
}

function ComponentRows({ components, environment, mission, preludeIndex }) {
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
          <${ComponentSource} component=${component} dependants=${dependants.get(component.id)}
                              environment=${environment} mission=${mission}
                              preludeIndex=${preludeIndex} />
        </li>
      `)}
    </ol>
  `;
}

function ComponentSource({
  component, position, dependants, environment, mission, preludeIndex, compact = false
}) {
  const source = preludeIndex.byComponent.get(scopeComponentKey(environment, mission, component.id));
  const label = html`
    ${compact && html`<em class="kt-component-order">${position + 1}</em>`}
    <code>${component.id}</code>
    ${dependants && html`
      <span class="kt-component-used-by" title="Direct dependants">↳ used by ${dependants}</span>`}
    ${component.dependencies.length > 0 && html`
      <span class="kt-component-deps">needs ${component.dependencies.map(dependency =>
        html`<span key=${dependency}>${dependency}</span>`)}</span>`}
  `;

  if (!source) return compact ? html`<span>${label}</span>` : label;

  return html`
    <details class=${compact ? 'kt-component-source kt-component-source-compact' : 'kt-component-source'}
             id=${source.domId}>
      <summary>
        ${label}
        <span class="kt-component-source-label">source</span>
      </summary>
      <div class="kt-component-source-meta">
        ${source.source_bytes ?? '?'} bytes · ${shorten(source.source_hash) || 'no source hash'}
      </div>
      ${rawHtml('pre', 'kt-code kt-code-lisp', highlightPreludeSource(source))}
    </details>
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

// --- Execution transcript -------------------------------------------------

function Execution({ transcript, preludeIndex }) {
  if (!transcript.evaluations.length) {
    return html`<div class="kt-empty">No evaluation events were recorded for this run.</div>`;
  }

  return html`
    <div class="kt-execution">
      ${transcript.evaluations.map(evaluation => html`
        <${Evaluation} key=${evaluation.id} evaluation=${evaluation}
                       preludeIndex=${preludeIndex} />`)}
    </div>
  `;
}

function Evaluation({ evaluation, preludeIndex }) {
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
        <${EvaluationSource} evaluation=${evaluation} preludeIndex=${preludeIndex} />
        <${Capabilities} capabilities=${evaluation.capabilities} />
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

function EvaluationSource({ evaluation, preludeIndex }) {
  const canonicalHash = evaluation.start?.data?.source_hash;
  const program = evaluation.privateProgram;

  const sourceBlock = program?.source != null
    ? html`
      <details class="kt-private-source" open=${environmentOf(evaluation) === 'workflow'}>
        <summary>
          Program source
          <span class="kt-private-badge">private evidence</span>
        </summary>
        ${rawHtml('pre', 'kt-code kt-code-lisp', highlightLisp(program.source))}
        <${PreludeCalls} program=${program} evaluation=${evaluation}
                         preludeIndex=${preludeIndex} />
      </details>
    `
    : canonicalHash
      ? html`<p class="kt-sanitized-note">${
          `Program source is omitted from the canonical trace (source_hash ${shorten(canonicalHash)}, ` +
          `${evaluation.start?.data?.source_bytes ?? '?'} bytes).`}</p>`
      : null;

  const resultBlock = evaluation.privateResult?.length
    ? html`
      <details class="kt-private-source">
        <summary>
          Execution result
          <span class="kt-private-badge">private evidence</span>
        </summary>
        ${evaluation.privateResult.map((message, index) => html`
          <pre class="kt-code" key=${message?.tool_call_id || index}>${message?.content ?? json(message)}</pre>`)}
      </details>
    `
    : null;

  return html`${sourceBlock}${resultBlock}`;
}

function PreludeCalls({ program, evaluation, preludeIndex }) {
  const calls = Array.isArray(program.prelude_calls) ? program.prelude_calls : [];
  if (!calls.length) return null;

  const environment = program.environment || environmentOf(evaluation);
  const mission = program.mission_name || missionNameOf(evaluation);

  return html`
    <div class="kt-prelude-calls" aria-label="Captured prelude calls">
      <span>Prelude calls</span>
      ${calls.map((call, index) => {
        const item = preludeIndex.byComponent.get(
          scopeComponentKey(environment, mission, call?.component_id)
        );
        const target = item ? preludeCallTarget(item, call?.ref) : null;
        const label = call?.ref || call?.component_id || 'unknown';

        return target
          ? html`<a class="kt-prelude-call" key=${`${label}-${index}`} href=${`#${target}`}
                    data-prelude-target=${target} onClick=${revealPreludeSource}
                    title=${`Open ${label} in ${call.component_id}`}>${label}</a>`
          : html`<span class="kt-prelude-call kt-prelude-call-unavailable"
                       key=${`${label}-${index}`}>${label}</span>`;
      })}
    </div>
  `;
}

function Capabilities({ capabilities }) {
  if (!capabilities.length) {
    return html`<div class="kt-subsection-empty">No capability calls in this environment.</div>`;
  }

  return html`
    <section class="kt-subsection">
      <h4>Capability calls <span>${capabilities.length}</span></h4>
      <div class="kt-call-list">
        ${capabilities.map(capability => html`
          <${Capability} key=${capability.id} capability=${capability} />`)}
      </div>
    </section>
  `;
}

function Capability({ capability }) {
  const name = nameOf(capability) || 'unknown capability';
  const status = statusOf(capability);
  const elapsed = capability.stop?.data?.duration_ms;
  const llm = name === 'llm-request';

  return html`
    <details class=${`kt-call${llm ? ' kt-call-llm' : ''}`} open=${isFailure(status)}>
      <summary>
        <span class="kt-call-icon" aria-hidden="true">${llm ? '✦' : '⌁'}</span>
        <strong>${name}</strong>
        <span class="kt-call-meta">
          ${elapsed != null && html`<span>${duration(elapsed)}</span>`}
          <${StatusBadge} status=${status} />
        </span>
      </summary>
      <div class="kt-call-body">
        ${llm && html`<p class="kt-sanitized-note">${LLM_SANITIZED_NOTE}</p>`}
        <${RawDetails} title="Started" event=${capability.start} />
        ${capability.stop
          ? html`<${RawDetails} title="Stopped" event=${capability.stop} />`
          : html`<p class="kt-missing">Capability has no stop event</p>`}
      </div>
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

// --- Private prelude source navigation -----------------------------------

function buildPreludeIndex(preludes) {
  const byComponent = new Map();

  (preludes?.items || []).forEach((record, index) => {
    if (!record || typeof record.source !== 'string') return;

    const item = {
      ...record,
      definitions: definitionNames(record.source),
      domId: `kt-prelude-${record.sequence ?? 'unknown'}-${index}`
    };
    const key = scopeComponentKey(record.environment, record.mission_name, record.component_id);
    if (!byComponent.has(key)) byComponent.set(key, item);
  });

  return { byComponent };
}

function definitionNames(source) {
  const names = new Set();
  const pattern = /\(defn-?\s+([^\s()[\]{}]+)/g;
  let match;
  while ((match = pattern.exec(String(source))) !== null) names.add(match[1]);
  return names;
}

function scopeComponentKey(environment, mission, component) {
  return `${JSON.stringify([environment || '', mission || ''])}\u0000${component || ''}`;
}

function functionDomId(item, name) {
  const encoded = Array.from(String(name), character => character.codePointAt(0).toString(16)).join('-');
  return `${item.domId}-function-${encoded}`;
}

function preludeCallTarget(item, ref) {
  const name = String(ref || '').split('/').at(-1);
  return name && item.definitions.has(name) ? functionDomId(item, name) : item.domId;
}

function highlightPreludeSource(item) {
  return highlightLisp(item.source).replace(
    /(<span class="hljs-keyword">defn-?<\/span>\s+)<span class="hljs-title">([^<]+)<\/span>/g,
    (markup, prefix, encodedName) => {
      const name = decodeHighlightedText(encodedName);
      if (!item.definitions.has(name)) return markup;
      return `${prefix}<span class="hljs-title kt-prelude-definition" id="${functionDomId(item, name)}">${encodedName}</span>`;
    }
  );
}

function decodeHighlightedText(value) {
  return String(value)
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#x27;', "'")
    .replaceAll('&amp;', '&');
}

function revealPreludeSource(event) {
  const targetId = event.currentTarget?.dataset?.preludeTarget;
  const target = targetId ? document.getElementById(targetId) : null;
  if (!target) return;

  event.preventDefault();
  for (let node = target; node; node = node.parentElement) {
    if (node.tagName === 'DETAILS') node.open = true;
  }
  document.querySelectorAll('.kt-prelude-definition-active')
    .forEach(definition => definition.classList.remove('kt-prelude-definition-active'));
  target.classList.add('kt-prelude-definition-active');
  target.scrollIntoView({ block: 'center', behavior: 'smooth' });
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
