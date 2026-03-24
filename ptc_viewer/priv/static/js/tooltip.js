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
