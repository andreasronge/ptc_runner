// LLM token-spend panel derived from private inspection records.
//
// Providers report only aggregate token counts per llm-request, so per-section
// numbers are estimates: each call's reported input tokens are apportioned
// across the request's sections (system prompt, embedded mission inventory,
// tool schemas, message history) by character share. Character counts are
// exact; token splits are labeled as estimates. Calls without reported usage
// and partially loaded event pages are labeled rather than silently folded
// into the totals.

import { escapeHtml } from './utils.js';

const INVENTORY_MARKER = 'Frozen mission inventory (JSON):';

const USAGE_KEYS = ['input', 'output', 'cache_read', 'cache_creation', 'total_cost'];

// Fixed categorical slot order (validated palette, dark surface); color
// follows the section identity even when a section is empty.
const SECTIONS = [
  { key: 'system', label: 'System · instructions', color: '#3987e5' },
  { key: 'inventory', label: 'System · mission inventory', color: '#008300' },
  { key: 'tools', label: 'Tool schemas', color: '#d55181' },
  { key: 'user', label: 'User messages', color: '#c98500' },
  { key: 'assistant', label: 'Assistant history', color: '#199e70' },
  { key: 'feedback', label: 'Tool feedback', color: '#d95926' }
];

const RESENT_KEYS = new Set(['system', 'inventory', 'tools']);

export function buildTokenUsage(turns) {
  const calls = [];
  const composition = new Map(SECTIONS.map(section => [
    section.key,
    { ...section, chars: 0, estTokens: 0 }
  ]));

  for (const turn of turns) {
    const tokens = turn.value?.tokens;
    const reported = tokens != null && typeof tokens === 'object' &&
      USAGE_KEYS.some(key => typeof tokens[key] === 'number');
    const call = {
      turn: turn.turn,
      reported,
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
    composition: [...composition.values()],
    hasUsage: Object.values(totals).some(value => value > 0),
    estimable: totals.input > 0
  };
}

function sectionChars(request) {
  const chars = { system: 0, inventory: 0, tools: 0, user: 0, assistant: 0, feedback: 0 };

  const system = typeof request.system === 'string' ? request.system : '';
  const markerAt = system.indexOf(INVENTORY_MARKER);
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

export function renderTokenUsage(turns, options = {}) {
  const usage = buildTokenUsage(turns);
  if (!usage.calls.length) return '';

  const unreported = usage.calls.length - usage.reportedCalls;

  return `
    <div class="kt-toolbar kt-dialogue-toolbar">
      <span>LLM token spend</span>
      <span class="kt-private-chip" title="Derived from the pinned private inspection artifact">private</span>
      ${options.partial ? '<span class="kt-partial-chip" title="More canonical events exist beyond the loaded pages">partial</span>' : ''}
    </div>
    <section class="kt-tokens" aria-label="LLM token spend">
      ${options.partial ? '<p class="kt-token-note kt-token-warning">More canonical events exist beyond the loaded pages; these figures cover only the loaded events, not the whole run.</p>' : ''}
      ${usage.hasUsage ? renderTiles(usage.totals) : ''}
      ${usage.hasUsage ? renderCallTable(usage) : ''}
      ${usage.hasUsage && unreported > 0
        ? `<p class="kt-token-note kt-token-warning">Provider usage was reported for ${usage.reportedCalls} of ${usage.calls.length} calls; totals exclude the unreported calls.</p>`
        : ''}
      ${renderComposition(usage)}
    </section>
  `;
}

function renderTiles(totals) {
  const tiles = [
    [formatCount(totals.input), 'input tokens'],
    [formatCount(totals.output), 'output tokens']
  ];
  if (totals.cacheRead > 0) tiles.push([formatCount(totals.cacheRead), 'cache read']);
  if (totals.cacheCreation > 0) tiles.push([formatCount(totals.cacheCreation), 'cache creation']);
  if (totals.cost > 0) tiles.push([formatCost(totals.cost), 'reported cost']);

  return `
    <div class="kt-metrics kt-token-tiles">
      ${tiles.map(([value, label]) =>
        `<div class="kt-metric"><strong>${escapeHtml(value)}</strong><span>${escapeHtml(label)}</span></div>`
      ).join('')}
    </div>
  `;
}

function renderCallTable(usage) {
  const showCacheRead = usage.totals.cacheRead > 0;
  const showCacheCreation = usage.totals.cacheCreation > 0;
  const showCost = usage.totals.cost > 0;

  const cell = (reported, value) => `<td>${reported ? escapeHtml(value) : '—'}</td>`;

  const row = (label, call, cssClass = '') => `
    <tr${cssClass ? ` class="${cssClass}"` : ''}>
      <td>${escapeHtml(label)}</td>
      ${cell(call.reported, formatCount(call.input))}
      ${cell(call.reported, formatCount(call.output))}
      ${showCacheRead ? cell(call.reported, formatCount(call.cacheRead)) : ''}
      ${showCacheCreation ? cell(call.reported, formatCount(call.cacheCreation)) : ''}
      ${showCost ? cell(call.reported && call.cost > 0, formatCost(call.cost)) : ''}
    </tr>
  `;

  return `
    <table class="kt-token-table">
      <thead>
        <tr>
          <th>Call</th><th>Input</th><th>Output</th>
          ${showCacheRead ? '<th>Cache read</th>' : ''}
          ${showCacheCreation ? '<th>Cache creation</th>' : ''}
          ${showCost ? '<th>Cost</th>' : ''}
        </tr>
      </thead>
      <tbody>
        ${usage.calls.map(call => row(`LLM call ${call.turn + 1}`, call)).join('')}
        ${row('Total', { ...usage.totals, reported: true }, 'kt-token-total')}
      </tbody>
    </table>
  `;
}

function renderComposition(usage) {
  const measure = usage.estimable ? 'estTokens' : 'chars';
  const buckets = usage.composition.filter(bucket => bucket.chars > 0);
  const total = buckets.reduce((sum, bucket) => sum + bucket[measure], 0);
  if (!buckets.length || total <= 0) return '';

  const resent = buckets
    .filter(bucket => RESENT_KEYS.has(bucket.key))
    .reduce((sum, bucket) => sum + bucket[measure], 0);
  const resentShare = Math.round((resent / total) * 100);

  const value = bucket => usage.estimable
    ? `≈${formatCount(Math.round(bucket.estTokens))} tokens`
    : `${formatCount(bucket.chars)} chars`;

  return `
    <div class="kt-token-composition">
      <div class="kt-turn-label">Input composition${usage.estimable ? ' (estimated)' : ' (by characters)'}</div>
      <div class="kt-token-bar" role="img" aria-label="Input composition by request section">
        ${buckets.map(bucket => `
          <span class="kt-token-seg" style="flex-grow:${bucket[measure] / total};background:${bucket.color}"
            title="${escapeHtml(`${bucket.label}: ${value(bucket)} · ${Math.round((bucket[measure] / total) * 100)}%`)}"></span>
        `).join('')}
      </div>
      <ul class="kt-token-legend">
        ${buckets.map(bucket => `
          <li>
            <span class="kt-token-chip" style="background:${bucket.color}"></span>
            <span class="kt-token-name">${escapeHtml(bucket.label)}</span>
            <span class="kt-token-value">${escapeHtml(value(bucket))} · ${Math.round((bucket[measure] / total) * 100)}%</span>
          </li>
        `).join('')}
      </ul>
      ${resent > 0 && buckets.length > 1 ? `
        <p class="kt-token-note">
          System prompt and tool schemas are resent with every call:
          ${usage.estimable ? `≈${escapeHtml(formatCount(Math.round(resent)))} tokens` : `${escapeHtml(formatCount(resent))} chars`}
          (${resentShare}% of run input).
        </p>` : ''}
      <p class="kt-token-note">
        ${usage.estimable
          ? 'Providers report aggregate counts per call; section tokens apportion each call’s reported input tokens by character share.'
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
