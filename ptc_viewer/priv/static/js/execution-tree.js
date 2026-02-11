import { formatDuration, escapeHtml, truncate, findFileByTraceId } from './utils.js';
import { pairEvents, extractProgram, extractRunEvents } from './parser.js';

const MAX_DEPTH = 10;
const pendingFetches = new Map();
const nodeEvents = new Map(); // nodeId -> events array for click navigation
let nodeIdCounter = 0;

/**
 * Main entry point. Renders execution tree for tool calls that have children.
 */
export function renderExecutionTree(container, tools, state, data) {
  nodeEvents.clear();
  nodeIdCounter = 0;

  let html = '<div class="exec-tree">';
  html += '<div class="exec-tree-controls">';
  html += '<button class="exec-tree-btn" data-action="expand-all">Expand All</button>';
  html += '<button class="exec-tree-btn" data-action="collapse-all">Collapse All</button>';
  html += '</div>';

  for (const toolPair of tools) {
    const childData = resolveChildData(toolPair, state, data);
    if (!childData) continue;
    html += renderTreeNode(toolPair, childData, 0, state, data);
  }

  html += '</div>';
  container.innerHTML = html;
  wireTreeInteractions(container, state, data);
}

/**
 * Resolves child trace data for a tool call via two paths:
 * 1. File-based: look up child_trace_id in state.files
 * 2. Embedded: find run.start with parent_span_id === toolSpanId
 */
function resolveChildData(toolPair, state, data) {
  const toolSpanId = toolPair.stop?.span_id || toolPair.start?.span_id;
  const childTraceIds = toolPair.stop?.metadata?.child_trace_ids ||
    (toolPair.stop?.metadata?.child_trace_id ? [toolPair.stop.metadata.child_trace_id] : []);

  // File-based: use first child trace ID (one child per tool call)
  if (childTraceIds.length > 0) {
    const traceId = childTraceIds[0];
    const file = findFileByTraceId(state, traceId);
    if (file) {
      const fileData = state.files.get(file);
      if (fileData?.events) {
        return { events: fileData.events, traceId, needsLoad: false };
      }
    }
    return { events: null, traceId, needsLoad: true };
  }

  // Embedded: find child run.start whose parent is this tool span
  if (data?.events && toolSpanId) {
    const childRun = data.events.find(e =>
      e.event === 'run.start' && e.metadata?.parent_span_id === toolSpanId
    );
    if (childRun) {
      const childEvents = extractRunEvents(data.events, childRun.span_id);
      if (childEvents.length > 0) {
        return { events: childEvents, traceId: null, needsLoad: false };
      }
    }
  }

  return null;
}

/**
 * Builds a lightweight turn summary from events (not full renderTurnDetail).
 */
function buildCompactTurns(events) {
  const paired = pairEvents(events);

  // Find root agent span
  const allSpanIds = new Set(events.filter(e => e.span_id).map(e => e.span_id));
  const rootRun = events.find(e => e.event === 'run.start' &&
    (!e.metadata?.parent_span_id || !allSpanIds.has(e.metadata.parent_span_id)));
  const rootSpanId = rootRun?.span_id;

  const llmPairs = paired.filter(p => p.type === 'llm' &&
    (!rootSpanId || p.start?.metadata?.parent_span_id === rootSpanId || p.stop?.metadata?.parent_span_id === rootSpanId));
  const toolPairs = paired.filter(p => p.type === 'tool' &&
    (!rootSpanId || p.start?.metadata?.parent_span_id === rootSpanId || p.stop?.metadata?.parent_span_id === rootSpanId));

  return llmPairs.map((llmPair, idx) => {
    const stop = llmPair.stop;
    const start = llmPair.start;
    const turnNumber = stop?.metadata?.turn || start?.metadata?.turn || idx + 1;
    const response = stop?.metadata?.response || '';
    const program = extractProgram(response);
    const duration = stop?.duration_ms || 0;

    // Find tool calls after this LLM call and before the next
    const llmStopTime = stop?.timestamp ? new Date(stop.timestamp).getTime() : 0;
    const nextLlmStartTime = idx < llmPairs.length - 1 && llmPairs[idx + 1].start?.timestamp
      ? new Date(llmPairs[idx + 1].start.timestamp).getTime()
      : Infinity;

    const turnTools = toolPairs.filter(t => {
      const toolStart = t.start?.timestamp ? new Date(t.start.timestamp).getTime() : 0;
      return toolStart >= llmStopTime && toolStart < nextLlmStartTime;
    });

    // Find turn pair for result preview (filter to root agent to avoid cross-agent collisions)
    const turnPairs = paired.filter(p => p.type === 'turn' &&
      (!rootSpanId || p.start?.span_id === rootSpanId || p.stop?.span_id === rootSpanId));
    const turnPair = turnPairs.find(p => (p.stop?.metadata?.turn || p.start?.metadata?.turn) === turnNumber);
    const resultPreview = turnPair?.stop?.metadata?.result_preview;
    const hasError = resultPreview && (
      resultPreview.includes('Error:') ||
      resultPreview.includes(':error') ||
      resultPreview.includes(':invalid_tool') ||
      resultPreview.includes(':timeout') ||
      resultPreview.includes(':sandbox_error') ||
      /reason:\s*:/.test(resultPreview)
    );
    const hasReturn = resultPreview && !hasError && resultPreview !== 'nil';

    return {
      turnNumber,
      program,
      duration,
      hasError,
      hasReturn,
      childTools: turnTools
    };
  });
}

/**
 * Renders a single tree node as a <details>/<summary> element.
 */
function renderTreeNode(toolPair, childData, depth, state, data) {
  const toolName = toolPair.stop?.metadata?.tool_name || toolPair.start?.metadata?.tool_name || 'unknown';
  const toolDuration = toolPair.stop?.duration_ms || 0;
  const toolArgs = toolPair.start?.metadata?.args || toolPair.stop?.metadata?.args;

  // Status icon
  let statusIcon = '';
  if (toolPair.stop?.metadata?.result != null) {
    const result = toolPair.stop.metadata.result;
    const resultStr = typeof result === 'string' ? result : JSON.stringify(result);
    const isError = resultStr.includes('Error:') || resultStr.includes(':error');
    statusIcon = isError ? '<span class="exec-tree-status error">&#10007;</span>' : '<span class="exec-tree-status success">&#10003;</span>';
  }

  // Compact args summary
  let argsSummary = '';
  if (toolArgs) {
    const argsStr = typeof toolArgs === 'string' ? toolArgs : JSON.stringify(toolArgs);
    argsSummary = `<span class="exec-tree-args">${escapeHtml(truncate(argsStr, 60))}</span>`;
  }

  const nodeId = nodeIdCounter++;
  if (childData.events) {
    nodeEvents.set(nodeId, childData.events);
  }

  let html = `<details class="exec-tree-node" data-depth="${depth}" data-node-id="${nodeId}"`;
  if (childData.needsLoad && childData.traceId) {
    html += ` data-trace-id="${escapeHtml(childData.traceId)}"`;
  }
  html += '>';
  html += `<summary class="exec-tree-summary">`;
  html += `<span class="exec-tree-name">${escapeHtml(toolName)}</span>`;
  html += argsSummary;
  html += `<span class="exec-tree-duration">${formatDuration(toolDuration)}</span>`;
  html += statusIcon;
  html += '</summary>';

  html += '<div class="exec-tree-body">';

  if (childData.needsLoad) {
    html += '<div class="exec-tree-loading">Loading...</div>';
  } else if (childData.events) {
    if (depth >= MAX_DEPTH) {
      html += '<div class="exec-tree-max-depth">Max depth reached — use Drill In for full view</div>';
    } else {
      const turns = buildCompactTurns(childData.events);
      html += renderCompactTurns(turns, state, data, childData.events, depth);
    }
  }

  html += '</div></details>';
  return html;
}

/**
 * Renders compact turn rows with optional recursive subtree nodes.
 */
function renderCompactTurns(turns, state, data, childEvents, depth) {
  let html = '';
  for (const turn of turns) {
    const programPreview = turn.program ? truncate(turn.program.replace(/\n/g, ' '), 80) : '(no program)';
    const statusIcon = turn.hasError ? '<span class="exec-tree-status error">&#10007;</span>'
      : turn.hasReturn ? '<span class="exec-tree-status success">&#10003;</span>' : '';

    html += `<div class="exec-tree-turn" data-turn-num="${turn.turnNumber}">`;
    html += `<span class="exec-tree-turn-num">T${turn.turnNumber}</span>`;
    html += `<span class="exec-tree-turn-program">${escapeHtml(programPreview)}</span>`;
    html += `<span class="exec-tree-duration">${formatDuration(turn.duration)}</span>`;
    html += statusIcon;
    html += '</div>';

    // Render subtree nodes for child tool calls
    for (const tool of turn.childTools) {
      const childData = resolveChildData(tool, state, { events: childEvents });
      if (childData) {
        html += renderTreeNode(tool, childData, depth + 1, state, { events: childEvents });
      }
    }
  }
  return html;
}

/**
 * Wires up Expand All / Collapse All buttons and lazy loading.
 */
function wireTreeInteractions(container, state, data) {
  // Expand All / Collapse All
  container.querySelectorAll('.exec-tree-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      const action = btn.dataset.action;
      container.querySelectorAll('.exec-tree-node').forEach(details => {
        details.open = action === 'expand-all';
      });
    });
  });

  // Turn row click → navigate to child agent at that turn
  container.addEventListener('click', (e) => {
    const turnEl = e.target.closest('.exec-tree-turn');
    if (!turnEl) return;

    const nodeEl = turnEl.closest('.exec-tree-node');
    if (!nodeEl) return;

    const nodeId = parseInt(nodeEl.dataset.nodeId);
    const turnNum = parseInt(turnEl.dataset.turnNum);
    const events = nodeEvents.get(nodeId);
    if (!events) return;

    const toolName = nodeEl.querySelector('.exec-tree-name')?.textContent || 'agent';
    import('./app.js').then(app => {
      app.navigateTo({
        type: 'agent',
        label: toolName,
        data: { events, filename: toolName, selectedTurn: turnNum }
      });
    });
  });

  // Lazy loading on toggle
  container.addEventListener('toggle', async (e) => {
    const details = e.target;
    if (!details.classList.contains('exec-tree-node') || !details.open) return;

    const traceId = details.dataset.traceId;
    if (!traceId) return;

    const loadingEl = details.querySelector('.exec-tree-loading');
    if (!loadingEl) return;

    delete details.dataset.traceId;

    try {
      const events = await fetchChildTrace(traceId, state);
      if (events) {
        const nodeId = parseInt(details.dataset.nodeId);
        if (!isNaN(nodeId)) nodeEvents.set(nodeId, events);

        const depth = parseInt(details.dataset.depth) || 0;
        const turns = buildCompactTurns(events);
        const body = details.querySelector('.exec-tree-body');
        body.innerHTML = renderCompactTurns(turns, state, data, events, depth);
      } else {
        loadingEl.textContent = 'Failed to load trace';
        loadingEl.classList.add('error');
      }
    } catch {
      loadingEl.textContent = 'Failed to load trace';
      loadingEl.classList.add('error');
    }
  }, true); // capture phase to catch <details> toggle
}

/**
 * Fetches a child trace file on demand.
 */
async function fetchChildTrace(traceId, state) {
  // Check cache first
  const cached = findFileByTraceId(state, traceId);
  if (cached) {
    return state.files.get(cached)?.events || null;
  }

  // Dedup concurrent fetches for the same traceId
  if (pendingFetches.has(traceId)) {
    return pendingFetches.get(traceId);
  }

  const promise = (async () => {
    try {
      const resp = await fetch(`/api/traces/trace_${traceId}.jsonl`);
      if (!resp.ok) return null;

      const text = await resp.text();
      const { parseJsonl, extractTraceId } = await import('./parser.js');
      const events = parseJsonl(text);
      const fileTraceId = extractTraceId(events);
      const filename = `trace_${traceId}.jsonl`;

      state.files.set(filename, { events, traceId: fileTraceId, filename });
      return events;
    } catch {
      return null;
    } finally {
      pendingFetches.delete(traceId);
    }
  })();

  pendingFetches.set(traceId, promise);
  return promise;
}
