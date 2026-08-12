// LLM token-spend panel derived from private inspection records.
//
// Providers report only aggregate token counts per llm-request, so per-section
// numbers are estimates: each call's reported input tokens are apportioned
// across the request's sections (system prompt, embedded mission inventory,
// tool schemas, message history) by character share. Character counts are
// exact; token splits are labeled as estimates. Calls without reported usage
// and partially loaded event pages are labeled rather than silently folded
// into the totals.

import { html, Fragment } from './preact.js';

const INVENTORY_HEADING = 'Available API';

const USAGE_KEYS = ['input', 'output', 'cache_read', 'cache_creation', 'total_cost'];

// Fixed categorical slot order (validated palette, dark surface); color
// follows the section identity even when a section is empty.
const SECTIONS = [
  { key: 'system', label: 'System · instructions' },
  { key: 'inventory', label: 'System · mission inventory' },
  { key: 'tools', label: 'Tool schemas' },
  { key: 'user', label: 'User messages' },
  { key: 'assistant', label: 'Assistant history' },
  { key: 'feedback', label: 'Tool feedback' }
];

const RESENT_KEYS = new Set(['system', 'inventory', 'tools']);

const PARTIAL_NOTE =
  'More canonical events exist beyond the loaded pages; these figures cover only the ' +
  'loaded events, not the whole run.';

export function buildTokenUsage(turns) {
  const calls = [];
  const composition = new Map(SECTIONS.map(section => [
    section.key,
    { ...section, chars: 0, estTokens: 0 }
  ]));

  for (const turn of turns) {
    const tokens = turn.value?.tokens;
    // A reported zero is data; a missing field is not. Presence is tracked
    // per field so legitimate zeros (scripted providers) render as zeros
    // while absent fields render as gaps.
    const fields = Object.fromEntries(
      USAGE_KEYS.map(key => [key, tokens != null && typeof tokens === 'object' &&
        typeof tokens[key] === 'number'])
    );
    const call = {
      turn: turn.turn,
      fields,
      reported: USAGE_KEYS.some(key => fields[key]),
      input: countOr0(tokens?.input),
      output: countOr0(tokens?.output),
      cacheRead: countOr0(tokens?.cache_read),
      cacheCreation: countOr0(tokens?.cache_creation),
      cost: typeof tokens?.total_cost === 'number' && tokens.total_cost > 0 ? tokens.total_cost : 0
    };
    calls.push(call);

    const chars = sectionChars(turn.request);
    const callChars = Object.values(chars).reduce((sum, value) => sum + value, 0);
    for (const [key, value] of Object.entries(chars)) {
      const bucket = composition.get(key);
      bucket.chars += value;
      if (call.input > 0 && callChars > 0) {
        bucket.estTokens += (call.input * value) / callChars;
      }
    }
  }

  const totals = calls.reduce((sums, call) => ({
    input: sums.input + call.input,
    output: sums.output + call.output,
    cacheRead: sums.cacheRead + call.cacheRead,
    cacheCreation: sums.cacheCreation + call.cacheCreation,
    cost: sums.cost + call.cost
  }), { input: 0, output: 0, cacheRead: 0, cacheCreation: 0, cost: 0 });

  return {
    calls,
    totals,
    reportedCalls: calls.filter(call => call.reported).length,
    inputReported: calls.some(call => call.fields.input),
    outputReported: calls.some(call => call.fields.output),
    composition: [...composition.values()],
    hasUsage: calls.some(call => call.reported),
    estimable: totals.input > 0
  };
}

function sectionChars(request) {
  const chars = { system: 0, inventory: 0, tools: 0, user: 0, assistant: 0, feedback: 0 };

  const system = typeof request.system === 'string' ? request.system : '';
  const markerAt = inventoryHeadingOffset(system);
  if (markerAt >= 0) {
    chars.system = markerAt;
    chars.inventory = system.length - markerAt;
  } else {
    chars.system = system.length;
  }

  const tools = Array.isArray(request.tools) ? request.tools : [];
  if (tools.length) chars.tools = JSON.stringify(tools).length;

  for (const message of Array.isArray(request.messages) ? request.messages : []) {
    const role = message?.role;
    const key = role === 'tool' ? 'feedback' : role === 'assistant' ? 'assistant' : 'user';
    if (typeof message?.content === 'string') chars[key] += message.content.length;
    else if (message?.content != null) chars[key] += JSON.stringify(message.content).length;
    if (Array.isArray(message?.tool_calls)) chars[key] += JSON.stringify(message.tool_calls).length;
  }

  return chars;
}

function inventoryHeadingOffset(system) {
  let offset = 0;

  for (const line of system.split('\n')) {
    if (line === INVENTORY_HEADING) return offset;
    offset += line.length + 1;
  }

  return -1;
}

export function TokenUsage({ turns, partial = false }) {
  const usage = buildTokenUsage(turns);
  if (!usage.calls.length) return null;

  const unreported = usage.calls.length - usage.reportedCalls;

  return html`
    <${Fragment}>
      <div class="kt-toolbar kt-dialogue-toolbar">
        <span>LLM token spend</span>
        <span class="kt-private-chip" title="Derived from the pinned private inspection artifact">private</span>
        ${partial && html`
          <span class="kt-partial-chip" title="More canonical events exist beyond the loaded pages">partial</span>`}
      </div>
      <section class="kt-tokens" aria-label="LLM token spend">
        ${partial && html`<p class="kt-token-note kt-token-warning">${PARTIAL_NOTE}</p>`}
        ${usage.hasUsage && html`<${Tiles} usage=${usage} />`}
        ${usage.hasUsage && html`<${CallTable} usage=${usage} />`}
        ${usage.hasUsage && unreported > 0 && html`<p class="kt-token-note kt-token-warning">${
          `Provider usage was reported for ${usage.reportedCalls} of ${usage.calls.length} calls; ` +
          'totals exclude the unreported calls.'}</p>`}
        <${Composition} usage=${usage} />
      </section>
    <//>
  `;
}

function Tiles({ usage }) {
  const totals = usage.totals;
  const tiles = [
    [usage.inputReported ? formatCount(totals.input) : '—', 'input tokens'],
    [usage.outputReported ? formatCount(totals.output) : '—', 'output tokens']
  ];
  if (totals.cacheRead > 0) tiles.push([formatCount(totals.cacheRead), 'cache read']);
  if (totals.cacheCreation > 0) tiles.push([formatCount(totals.cacheCreation), 'cache creation']);
  if (totals.cost > 0) tiles.push([formatCost(totals.cost), 'reported cost']);

  return html`
    <div class="kt-metrics kt-token-tiles">
      ${tiles.map(([value, label]) => html`
        <div class="kt-metric" key=${label}><strong>${value}</strong><span>${label}</span></div>`)}
    </div>
  `;
}

function CallTable({ usage }) {
  const showCacheRead = usage.totals.cacheRead > 0;
  const showCacheCreation = usage.totals.cacheCreation > 0;
  const showCost = usage.totals.cost > 0;

  const cell = (present, value) => html`<td>${present ? value : '—'}</td>`;

  const row = (label, call, fields, cssClass = '') => html`
    <tr class=${cssClass || undefined} key=${label}>
      <td>${label}</td>
      ${cell(fields.input, formatCount(call.input))}
      ${cell(fields.output, formatCount(call.output))}
      ${showCacheRead && cell(fields.cache_read, formatCount(call.cacheRead))}
      ${showCacheCreation && cell(fields.cache_creation, formatCount(call.cacheCreation))}
      ${showCost && cell(fields.total_cost && call.cost > 0, formatCost(call.cost))}
    </tr>
  `;

  const totalFields = Object.fromEntries(
    USAGE_KEYS.map(key => [key, usage.calls.some(call => call.fields[key])])
  );

  return html`
    <table class="kt-token-table">
      <thead>
        <tr>
          <th>Call</th><th>Input</th><th>Output</th>
          ${showCacheRead && html`<th>Cache read</th>`}
          ${showCacheCreation && html`<th>Cache creation</th>`}
          ${showCost && html`<th>Cost</th>`}
        </tr>
      </thead>
      <tbody>
        ${usage.calls.map(call => row(`LLM call ${call.turn + 1}`, call, call.fields))}
        ${row('Total', usage.totals, totalFields, 'kt-token-total')}
      </tbody>
    </table>
  `;
}

function Composition({ usage }) {
  const measure = usage.estimable ? 'estTokens' : 'chars';
  const buckets = usage.composition.filter(bucket => bucket.chars > 0);
  const total = buckets.reduce((sum, bucket) => sum + bucket[measure], 0);
  if (!buckets.length || total <= 0) return null;

  const resent = buckets
    .filter(bucket => RESENT_KEYS.has(bucket.key))
    .reduce((sum, bucket) => sum + bucket[measure], 0);
  const resentShare = Math.round((resent / total) * 100);

  const value = bucket => usage.estimable
    ? `≈${formatCount(Math.round(bucket.estTokens))} tokens`
    : `${formatCount(bucket.chars)} chars`;
  const share = bucket => Math.round((bucket[measure] / total) * 100);

  let offset = 0;
  const segments = buckets.map(bucket => {
    const width = (bucket[measure] / total) * 100;
    const segment = { bucket, x: offset, width };
    offset += width;
    return segment;
  });

  return html`
    <div class="kt-token-composition">
      <div class="kt-turn-label">
        Input composition${usage.estimable ? ' (estimated)' : ' (by characters)'}
      </div>
      <svg class="kt-token-bar" viewBox="0 0 100 10" preserveAspectRatio="none"
           role="img" aria-label="Input composition by request section">
        ${segments.map(({ bucket, x, width }) => html`
          <rect key=${bucket.key} class=${`kt-token-color-${bucket.key}`}
                x=${x} width=${width} height="10">
            <title>${`${bucket.label}: ${value(bucket)} · ${share(bucket)}%`}</title>
          </rect>
        `)}
      </svg>
      <ul class="kt-token-legend">
        ${buckets.map(bucket => html`
          <li key=${bucket.key}>
            <span class=${`kt-token-chip kt-token-color-${bucket.key}`}></span>
            <span class="kt-token-name">${bucket.label}</span>
            <span class="kt-token-value">${value(bucket)} · ${share(bucket)}%</span>
          </li>
        `)}
      </ul>
      ${resent > 0 && buckets.length > 1 && html`
        <p class="kt-token-note">${
          'System prompt and tool schemas are resent with every call: ' +
          (usage.estimable ? `≈${formatCount(Math.round(resent))} tokens` : `${formatCount(resent)} chars`) +
          ` (${resentShare}% of run input).`}</p>`}
      <p class="kt-token-note">
        ${usage.estimable
          ? 'Providers report aggregate counts per call; section tokens apportion each call’s reported input tokens by character share.'
          : usage.inputReported
            ? 'Input token counts were reported as zero; proportions use exact character counts of the captured requests.'
            : 'No input token counts were reported for this run; proportions use exact character counts of the captured requests.'}
      </p>
    </div>
  `;
}

function countOr0(value) {
  return typeof value === 'number' && value > 0 ? value : 0;
}

function formatCount(value) {
  return String(Math.round(value)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function formatCost(value) {
  if (!value) return '—';
  if (value < 0.000001) return '<$0.000001';
  const digits = value >= 0.01
    ? value.toFixed(value >= 1 ? 2 : 3)
    : Number(value.toPrecision(2)).toFixed(6).replace(/0+$/, '');
  return `$${digits}`;
}
