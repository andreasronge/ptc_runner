// Small shared helpers. Rendering moved to Preact components, so the former
// HTML-string helpers (manual escaping, markup-returning badge builders) are
// gone: interpolation is escaped by the `html` tag instead.

export function truncate(str, len) {
  return str && str.length > len ? str.slice(0, len) + '...' : str || '';
}

/**
 * Line-level diff of two texts as a flat list of `{kind, text}` where `kind` is
 * `add`, `remove` or `context`. Used to report how a run's system prompt
 * changed between calls instead of reprinting the whole prompt each time.
 *
 * Standard LCS over lines. Prompts are bounded by the capture limits, so the
 * O(n·m) table is acceptable; above `MAX_DIFF_LINES` the inputs are reported as
 * wholly replaced rather than diffed, which keeps a pathological input from
 * allocating a huge table.
 */
const MAX_DIFF_LINES = 2000;
const CONTEXT_LINES = 2;

export function diffLines(before, after) {
  const left = String(before ?? '').split('\n');
  const right = String(after ?? '').split('\n');

  if (left.length > MAX_DIFF_LINES || right.length > MAX_DIFF_LINES) {
    return [
      ...left.map(text => ({ kind: 'remove', text })),
      ...right.map(text => ({ kind: 'add', text }))
    ];
  }

  const lengths = Array.from({ length: left.length + 1 }, () => new Uint32Array(right.length + 1));
  for (let i = left.length - 1; i >= 0; i--) {
    for (let j = right.length - 1; j >= 0; j--) {
      lengths[i][j] = left[i] === right[j]
        ? lengths[i + 1][j + 1] + 1
        : Math.max(lengths[i + 1][j], lengths[i][j + 1]);
    }
  }

  const changes = [];
  let i = 0;
  let j = 0;
  while (i < left.length && j < right.length) {
    if (left[i] === right[j]) {
      changes.push({ kind: 'context', text: left[i] });
      i++;
      j++;
    } else if (lengths[i + 1][j] >= lengths[i][j + 1]) {
      changes.push({ kind: 'remove', text: left[i++] });
    } else {
      changes.push({ kind: 'add', text: right[j++] });
    }
  }
  while (i < left.length) changes.push({ kind: 'remove', text: left[i++] });
  while (j < right.length) changes.push({ kind: 'add', text: right[j++] });

  return collapseContext(changes);
}

// Keep a couple of unchanged lines around each edit so a change reads in
// context, and replace longer unchanged stretches with one elision marker.
function collapseContext(changes) {
  const keep = new Set();
  changes.forEach((change, index) => {
    if (change.kind === 'context') return;
    for (let offset = -CONTEXT_LINES; offset <= CONTEXT_LINES; offset++) {
      const neighbour = index + offset;
      if (neighbour >= 0 && neighbour < changes.length) keep.add(neighbour);
    }
  });

  const result = [];
  let skipped = 0;
  changes.forEach((change, index) => {
    if (keep.has(index)) {
      if (skipped > 0) {
        result.push({ kind: 'elision', text: `… ${skipped} unchanged line${skipped === 1 ? '' : 's'}` });
        skipped = 0;
      }
      result.push(change);
    } else {
      skipped++;
    }
  });
  if (skipped > 0) {
    result.push({ kind: 'elision', text: `… ${skipped} unchanged line${skipped === 1 ? '' : 's'}` });
  }
  return result;
}
