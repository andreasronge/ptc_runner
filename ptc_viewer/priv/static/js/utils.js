export function formatDuration(ms) {
  if (ms == null) return '-';
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  return `${(ms / 60000).toFixed(1)}m`;
}

export function formatTokens(n) {
  if (!n) return '0';
  if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
  return n.toString();
}

export function formatTokenBreakdown(measurements) {
  if (!measurements) return '';
  const input = measurements.input_tokens;
  const output = measurements.output_tokens;
  const total = measurements.tokens || 0;
  if (input || output) {
    let s = `${formatTokens(input || 0)} in / ${formatTokens(output || 0)} out`;
    const cache = measurements.cache_read_tokens;
    if (cache > 0) s += ` (${formatTokens(cache)} cached)`;
    return s;
  }
  return total ? `${total.toLocaleString()} tk` : '';
}

export function truncate(str, len) {
  return str && str.length > len ? str.slice(0, len) + '...' : str || '';
}

export function escapeHtml(text) {
  if (!text) return '';
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

export function truncatePlan(str, len) {
  if (!str) return '';
  // Handle truncated strings from tracer
  if (str.includes('[String truncated')) {
    const match = str.match(/^([\s\S]*?)\.\.\.\s*\n?\n?\[String truncated/);
    if (match) {
      return match[1] + '... [truncated]';
    }
  }
  return str.length > len ? str.slice(0, len) + '...' : str;
}
