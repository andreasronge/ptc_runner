import { formatDuration, formatTokenBreakdown, escapeHtml, truncate } from './utils.js';

let tooltipEl = null;

export function initTooltip() {
  tooltipEl = document.getElementById('tooltip');
  if (!tooltipEl) {
    tooltipEl = document.createElement('div');
    tooltipEl.id = 'tooltip';
    tooltipEl.className = 'tooltip';
    document.body.appendChild(tooltipEl);
  }
  return tooltipEl;
}

export function showTooltip(html, event) {
  if (!tooltipEl) initTooltip();
  tooltipEl.innerHTML = html;
  tooltipEl.style.display = 'block';
  tooltipEl.style.left = (event.clientX + 12) + 'px';
  tooltipEl.style.top = (event.clientY - 10) + 'px';
}

export function hideTooltip() {
  if (tooltipEl) tooltipEl.style.display = 'none';
}

export function tooltipForDagNode(task, gateTaskIds) {
  let html = `<div class="tt-label">Task</div><div class="tt-value" style="font-weight:600;">${escapeHtml(task.id)}</div>`;
  html += `<div class="tt-label">Agent</div><div class="tt-value">${escapeHtml(task.agent)}</div>`;
  html += `<div class="tt-label">Status</div><div class="tt-value">${task.status}</div>`;
  if (task.durationMs > 0) html += `<div class="tt-label">Duration</div><div class="tt-value">${formatDuration(task.durationMs)}</div>`;
  if (task.input) html += `<div class="tt-label">Input</div><div class="tt-value" style="font-size:11px;">${escapeHtml(truncate(task.input, 120))}</div>`;
  if (task.dependsOn && task.dependsOn.length > 0) html += `<div class="tt-label">Depends on</div><div class="tt-value">${task.dependsOn.map(d => escapeHtml(d)).join(', ')}</div>`;
  if (task.signature) html += `<div class="tt-label">Signature</div><div class="tt-value" style="font-family: monospace; font-size: 11px;">${escapeHtml(task.signature)}</div>`;
  const hasGate = task.qualityGate === true || (gateTaskIds && gateTaskIds.has(task.id));
  if (hasGate) {
    const gateSource = task.qualityGate === true ? 'per-task' : 'global';
    html += `<div class="tt-label">Quality Gate</div><div class="tt-value" style="color:#6a9955;">enabled (${gateSource})</div>`;
  }
  return html;
}

export function tooltipForTurnPill(turn) {
  let html = `<div class="tt-label">Turn</div><div class="tt-value" style="font-weight:600;">${turn.turn || '?'}</div>`;
  if (turn.duration) html += `<div class="tt-label">Duration</div><div class="tt-value">${formatDuration(turn.duration)}</div>`;
  if (turn.tokens) html += `<div class="tt-label">Tokens</div><div class="tt-value">${formatTokenBreakdown(turn.tokens)}</div>`;
  return html;
}

export function tooltipForToolBar(tool) {
  let html = `<div class="tt-label">Tool</div><div class="tt-value" style="font-weight:600;">${escapeHtml(tool.name || 'unknown')}</div>`;
  if (tool.duration) html += `<div class="tt-label">Duration</div><div class="tt-value">${formatDuration(tool.duration)}</div>`;
  return html;
}
