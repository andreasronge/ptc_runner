import { formatDuration, formatTokens, formatTokenBreakdown, truncate, escapeHtml, findFileByTraceId } from './utils.js';
import { pairEvents, buildSpanTree, extractRunEvents, extractThinking, extractProgram, getLastUserMessage } from './parser.js';
import { highlightLisp } from './highlight.js';
import { showTooltip, hideTooltip } from './tooltip.js';
import { renderForkJoin } from './fork-join.js';
import { renderExecutionTree } from './execution-tree.js';

export function renderAgentView(container, state, data) {
  const events = data.events;
  const paired = pairEvents(events);

  // Detect multi-run traces
  const runStarts = events.filter(e => e.event === 'run.start');
  const isMultiRun = runStarts.length > 1;

  // Agent header info
  const traceStart = events.find(e => e.event === 'trace.start');
  const runStart = events.find(e => e.event === 'run.start');
  const execStop = events.find(e => e.event === 'execution.stop');
  const runStop = events.find(e => e.event === 'run.stop');
  const traceStop = events.find(e => e.event === 'trace.stop');

  const agentName = traceStart?.metadata?.agent_name || traceStart?.metadata?.tool_name || data.filename;
  const outputMode = runStart?.metadata?.agent?.output || 'unknown';
  const totalDuration = execStop?.duration_ms || runStop?.duration_ms || traceStop?.duration_ms || 0;

  // For multi-run, find the first run with turns as default selection
  let selectedRunSpanId = null;
  if (isMultiRun) {
    if (data.selectedRunSpanId) {
      selectedRunSpanId = data.selectedRunSpanId;
    } else {
      // Default to first run that has LLM calls (turns)
      for (const rs of runStarts) {
        const runEvents = extractRunEvents(events, rs.span_id);
        if (runEvents.some(e => e.event === 'llm.start')) {
          selectedRunSpanId = rs.span_id;
          break;
        }
      }
      if (!selectedRunSpanId) selectedRunSpanId = runStarts[0].span_id;
    }
  }

  // Build turns for the selected scope
  const scopedEvents = isMultiRun ? extractRunEvents(events, selectedRunSpanId) : events;
  const scopedPaired = isMultiRun ? pairEvents(scopedEvents) : paired;
  const turns = buildTurnsFromEvents(scopedEvents, scopedPaired, isMultiRun ? selectedRunSpanId : null);

  // Compute header stats from root agent turns only
  const totalTokens = turns.reduce((sum, t) => sum + (t.tokens?.tokens || 0), 0);

  // Support pre-selecting a turn (e.g. from execution tree click)
  let initialTurnIdx = 0;
  if (typeof data.selectedTurn === 'number') {
    const found = turns.findIndex(t => t.turnNumber === data.selectedTurn);
    if (found >= 0) initialTurnIdx = found;
  }

  let html = '';

  // Agent header
  html += `<div class="agent-header">
    <h2>${escapeHtml(agentName)}</h2>
    <div class="agent-meta">
      <span class="badge">${outputMode === 'ptc_lisp' ? 'PTC-Lisp' : outputMode === 'json' ? 'JSON' : escapeHtml(outputMode)}</span>
      <span>${formatDuration(totalDuration)}</span>
      <span>${formatTokens(totalTokens)} tokens</span>
      <span>${turns.length} turns</span>
    </div>
  </div>`;

  // Multi-run: side-by-side layout (span tree left, content right)
  if (isMultiRun) {
    html += '<div class="multi-run-layout">';
    html += '<div class="multi-run-sidebar">';
    html += renderSpanTree(events, selectedRunSpanId);
    html += '</div>';
    html += '<div class="multi-run-resizer"></div>';
    html += '<div class="multi-run-content">';
  }

  // Turn lane - horizontal row of turn pills
  html += '<div class="turn-lane">';
  turns.forEach((turn, idx) => {
    const isActive = idx === initialTurnIdx;
    const statusClass = turn.hasError ? 'error' : turn.hasReturn ? 'returned' : 'normal';
    html += `<div class="turn-pill ${statusClass}${isActive ? ' active' : ''}" data-turn-idx="${idx}">
      <span class="turn-num">${turn.turnNumber || idx + 1}</span>
      ${turn.subAgentTools.length > 0 ? groupByName(turn.subAgentTools).map(({name, count}) => `<span class="turn-badge sub-agent">\u{1F33F}${escapeHtml(name)}${count > 1 ? '\u00d7' + count : ''}</span>`).join('') : ''}
      ${turn.toolCount > 0 ? `<span class="turn-badge">\u{1F527}${turn.toolCount}</span>` : ''}
      ${turn.hasError ? '<span class="turn-icon">&#10007;</span>' : turn.hasReturn ? '<span class="turn-icon">&#10003;</span>' : ''}
    </div>`;
  });
  html += '</div>';

  // Timeline overview row
  html += '<div class="turn-timeline">';
  turns.forEach((turn, idx) => {
    const label = getTimelineLabel(turn);
    const isActive = idx === initialTurnIdx;
    const isSubAgent = turn.subAgentTools.length > 0;
    html += `<span class="turn-timeline-item${isSubAgent ? ' sub-agent' : ''}${isActive ? ' active' : ''}" data-turn-idx="${idx}">T${turn.turnNumber}:\u00a0${escapeHtml(label)}</span>`;
    if (idx < turns.length - 1) {
      html += '<span class="turn-timeline-sep">\u2192</span>';
    }
  });
  html += '</div>';

  // Turn detail area
  html += '<div id="turn-detail" class="turn-detail"></div>';

  // Close multi-run layout
  if (isMultiRun) {
    html += '</div>'; // .multi-run-content
    html += '</div>'; // .multi-run-layout
  }

  container.innerHTML = html;

  // Restore sidebar scroll position and width after re-render
  if (isMultiRun) {
    const newSidebar = container.querySelector('.multi-run-sidebar');
    if (newSidebar && data._sidebarScrollTop) {
      newSidebar.scrollTop = data._sidebarScrollTop;
    }
    if (newSidebar && data._sidebarWidth) {
      newSidebar.style.width = data._sidebarWidth;
    }
  }

  // Render initial turn detail
  const detailContainer = container.querySelector('#turn-detail');
  if (turns.length > 0) {
    renderTurnDetail(detailContainer, turns[initialTurnIdx], state, data);
  }

  // Shared function to activate a turn by index
  function activateTurn(idx) {
    container.querySelectorAll('.turn-pill').forEach(p => p.classList.remove('active'));
    container.querySelectorAll('.turn-timeline-item').forEach(t => t.classList.remove('active'));
    const pill = container.querySelector(`.turn-pill[data-turn-idx="${idx}"]`);
    const timelineItem = container.querySelector(`.turn-timeline-item[data-turn-idx="${idx}"]`);
    if (pill) pill.classList.add('active');
    if (timelineItem) timelineItem.classList.add('active');
    renderTurnDetail(detailContainer, turns[idx], state, data);
  }

  // Shared function to select a run and re-render
  function selectRun(spanId) {
    // Preserve sidebar scroll position across re-render
    const sidebar = container.querySelector('.multi-run-sidebar');
    const sidebarWidth = sidebar?.style.width;
    data._sidebarScrollTop = sidebar?.scrollTop || 0;
    data._sidebarWidth = sidebarWidth || null;
    data.selectedRunSpanId = spanId;
    renderAgentView(container, state, data);
  }

  // Wire up span tree run node clicks
  if (isMultiRun) {
    container.querySelectorAll('.span-tree-node.run').forEach(node => {
      node.addEventListener('click', () => {
        selectRun(node.dataset.spanId);
      });
    });

    // Draggable sidebar resizer
    const resizer = container.querySelector('.multi-run-resizer');
    const sidebar = container.querySelector('.multi-run-sidebar');
    if (resizer && sidebar) {
      resizer.addEventListener('mousedown', (e) => {
        e.preventDefault();
        resizer.classList.add('dragging');
        const startX = e.clientX;
        const startWidth = sidebar.getBoundingClientRect().width;
        const onMouseMove = (e) => {
          const newWidth = Math.max(160, Math.min(startWidth + e.clientX - startX, window.innerWidth * 0.6));
          sidebar.style.width = newWidth + 'px';
        };
        const onMouseUp = () => {
          resizer.classList.remove('dragging');
          document.removeEventListener('mousemove', onMouseMove);
          document.removeEventListener('mouseup', onMouseUp);
        };
        document.addEventListener('mousemove', onMouseMove);
        document.addEventListener('mouseup', onMouseUp);
      });
    }
  }

  // Turn pill click handlers
  container.querySelectorAll('.turn-pill').forEach(pill => {
    pill.addEventListener('click', () => {
      activateTurn(parseInt(pill.dataset.turnIdx));
    });
  });

  // Timeline item click handlers
  container.querySelectorAll('.turn-timeline-item').forEach(item => {
    item.addEventListener('click', () => {
      activateTurn(parseInt(item.dataset.turnIdx));
    });
  });

  // Keyboard navigation (left/right arrows)
  // Clean up previous handler if any
  if (container._keyHandler) {
    document.removeEventListener('keydown', container._keyHandler);
  }

  const keyHandler = (e) => {
    if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      const pills = container.querySelectorAll('.turn-pill');
      const activeIdx = [...pills].findIndex(p => p.classList.contains('active'));
      let newIdx = activeIdx;
      if (e.key === 'ArrowLeft' && activeIdx > 0) newIdx = activeIdx - 1;
      if (e.key === 'ArrowRight' && activeIdx < pills.length - 1) newIdx = activeIdx + 1;
      if (newIdx !== activeIdx) {
        activateTurn(newIdx);
      }
    }
  };
  document.addEventListener('keydown', keyHandler);
  container._keyHandler = keyHandler;
}

// Format a tool result value, converting closure AST arrays to readable source
function formatResultValue(value) {
  if (typeof value === 'string') return value;
  if (value == null) return 'nil';

  // Map with possible closure values
  if (typeof value === 'object' && !Array.isArray(value)) {
    const entries = Object.entries(value);
    const hasClosure = entries.some(([, v]) => isClosureAst(v));
    if (hasClosure) {
      const lines = entries.map(([k, v]) => {
        if (isClosureAst(v)) {
          const params = v[1] || [];
          const paramStr = params.map(formatCoreAst).join(' ');
          return `(defn ${k} [${paramStr}]\n  ${formatCoreAst(v[2])})`;
        }
        return `(def ${k} ${formatLispValue(v)})`;
      });
      return lines.join('\n\n');
    }
  }

  return JSON.stringify(value, null, 2);
}

function isClosureAst(v) {
  return Array.isArray(v) && v[0] === 'closure';
}

// Convert a JSON-encoded Core AST node to PTC-Lisp source
function formatCoreAst(node) {
  if (node == null) return 'nil';
  if (typeof node === 'number') return String(node);
  if (typeof node === 'boolean') return String(node);
  if (typeof node === 'string') return node;

  if (!Array.isArray(node)) return JSON.stringify(node);

  const [tag, ...rest] = node;

  switch (tag) {
    case 'string': return `"${rest[0]}"`;
    case 'keyword': return `:${rest[0]}`;
    case 'var': return rest[0];
    case 'data': return `data/${rest[0]}`;

    case 'call': {
      const [target, args] = rest;
      const fn = formatCoreAst(target);
      const argStr = Array.isArray(args) ? args.map(formatCoreAst).join(' ') : '';
      return `(${fn} ${argStr})`;
    }

    case 'tool_call': {
      const [name, args] = rest;
      const argStr = Array.isArray(args) ? args.map(formatCoreAst).join(' ') : '';
      return `(tool/${name} ${argStr})`;
    }

    case 'let': {
      const [bindings, body] = rest;
      const bindStr = Array.isArray(bindings) ? bindings.map(b => {
        if (Array.isArray(b) && b[0] === 'binding') return `${formatCoreAst(b[1])} ${formatCoreAst(b[2])}`;
        return formatCoreAst(b);
      }).join('\n        ') : '';
      return `(let [${bindStr}]\n    ${formatCoreAst(body)})`;
    }

    case 'if': {
      const [cond, then, els] = rest;
      return `(if ${formatCoreAst(cond)}\n      ${formatCoreAst(then)}\n      ${formatCoreAst(els)})`;
    }

    case 'def': {
      const [name, val, _meta] = rest;
      return `(def ${name} ${formatCoreAst(val)})`;
    }

    case 'do': {
      const exprs = rest[0] || rest;
      const exprArr = Array.isArray(exprs) ? exprs : [exprs];
      return `(do\n    ${exprArr.map(formatCoreAst).join('\n    ')})`;
    }

    case 'fn': {
      const [params, body] = rest;
      const paramStr = Array.isArray(params) ? params.map(formatCoreAst).join(' ') : '';
      return `(fn [${paramStr}] ${formatCoreAst(body)})`;
    }

    case 'vector': {
      const elems = rest[0] || rest;
      return `[${(Array.isArray(elems) ? elems : []).map(formatCoreAst).join(' ')}]`;
    }

    case 'map': {
      const pairs = rest[0] || rest;
      if (Array.isArray(pairs)) {
        const inner = pairs.map(([k, v]) => `${formatCoreAst(k)} ${formatCoreAst(v)}`).join(' ');
        return `{${inner}}`;
      }
      return '{}';
    }

    case 'or': {
      const exprs = rest[0] || rest;
      return `(or ${(Array.isArray(exprs) ? exprs : []).map(formatCoreAst).join(' ')})`;
    }

    case 'and': {
      const exprs = rest[0] || rest;
      return `(and ${(Array.isArray(exprs) ? exprs : []).map(formatCoreAst).join(' ')})`;
    }

    case 'return': return `(return ${formatCoreAst(rest[0])})`;
    case 'fail': return `(fail ${formatCoreAst(rest[0])})`;

    case 'closure':
      return `(fn [${(rest[0] || []).map(formatCoreAst).join(' ')}] ${formatCoreAst(rest[1])})`;

    case 'binding':
      return `${formatCoreAst(rest[0])} ${formatCoreAst(rest[1])}`;

    // For normal/variadic runtime refs, show as placeholder
    case 'normal':
    case 'variadic':
      return rest[0] || tag;

    default:
      // Unknown tag — fall back to JSON
      return JSON.stringify(node);
  }
}

// Format a plain Lisp value (non-AST) for display
function formatLispValue(v) {
  if (v == null) return 'nil';
  if (typeof v === 'string') return `"${v}"`;
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  if (Array.isArray(v)) {
    if (isClosureAst(v)) return formatCoreAst(v);
    return `[${v.map(formatLispValue).join(' ')}]`;
  }
  if (typeof v === 'object') {
    const inner = Object.entries(v).map(([k, val]) => `"${k}" ${formatLispValue(val)}`).join(' ');
    return `{${inner}}`;
  }
  return JSON.stringify(v);
}

function renderSpanTree(events, selectedRunSpanId) {
  const tree = buildSpanTree(events);

  function getRunLabel(spanNode) {
    const runStart = spanNode.events.find(e => e.event === 'run.start');
    if (!runStart) return null;

    // Prefer name (short display label) over description (verbose docs)
    const agent = runStart.metadata?.agent || {};
    if (agent.name) return agent.name;
    if (agent.description) return agent.description;

    // Check the parent tool span for a tool_name label
    const parentSpanId = runStart.parent_span_id || runStart.metadata?.parent_span_id;
    if (parentSpanId) {
      // Find tool.start with that span_id
      const parentTool = events.find(e => e.event === 'tool.start' && e.span_id === parentSpanId);
      if (parentTool?.metadata?.tool_name) return parentTool.metadata.tool_name;
    }

    // Fallback: use prompt prefix
    if (agent.prompt) return agent.prompt.slice(0, 50) + (agent.prompt.length > 50 ? '...' : '');
    return null;
  }

  function getToolInfo(spanNode) {
    const toolStart = spanNode.events.find(e => e.event === 'tool.start');
    const toolStop = spanNode.events.find(e => e.event === 'tool.stop');
    const name = toolStart?.metadata?.tool_name || toolStop?.metadata?.tool_name || 'tool';
    const result = toolStop?.metadata?.result;
    const args = toolStart?.metadata?.args || toolStop?.metadata?.args;
    let resultSummary = '';
    let resultFull = '';
    if (result != null) {
      const formatted = formatResultValue(result);
      resultSummary = formatted.replace(/\n/g, ' ').slice(0, 60) + (formatted.length > 60 ? '...' : '');
      resultFull = formatted;
    }
    let argsFull = '';
    if (args != null) {
      argsFull = typeof args === 'string' ? args : JSON.stringify(args, null, 2);
    }
    return { name, resultSummary, resultFull, argsFull };
  }

  let runCounter = 0;

  function renderNode(spanNode, depth) {
    const isRun = spanNode.events.some(e => e.event === 'run.start');
    const isTool = spanNode.events.some(e => e.event === 'tool.start');
    const isLlm = spanNode.events.some(e => e.event === 'llm.start');
    const isTurn = spanNode.events.some(e => e.event === 'turn.start');

    // Skip turn and LLM spans - shown in detail panel
    if ((isTurn || isLlm) && !isRun && !isTool) return '';

    let html = '';

    if (isRun) {
      runCounter++;
      const runStop = spanNode.events.find(e => e.event === 'run.stop');
      const runStart = spanNode.events.find(e => e.event === 'run.start');
      const status = runStop?.metadata?.status;
      const duration = runStop?.duration_ms || 0;
      const label = getRunLabel(spanNode) || `Run #${runCounter}`;
      const isActive = spanNode.id === selectedRunSpanId;

      // Count turns (LLM calls) under this run
      const runEvents = extractRunEvents(events, spanNode.id);
      const turnCount = runEvents.filter(e => e.event === 'llm.start').length;

      const statusIcon = status === 'ok' ? '&#10003;' : status === 'error' ? '&#10007;' : '&#8943;';
      const statusClass = status === 'ok' ? 'success' : status === 'error' ? 'error' : '';

      const agentSigInput = extractSigInput(runStart?.metadata?.agent?.signature);
      html += `<div class="span-tree-node run${isActive ? ' active' : ''}" data-span-id="${spanNode.id}" style="padding-left: ${depth * 16}px">
        <span class="span-tree-icon">&#9679;</span>
        <span class="span-tree-label">${escapeHtml(label)}</span>
        ${agentSigInput ? `<span class="span-tree-sig">${escapeHtml(agentSigInput)}</span>` : ''}
        <span class="span-tree-meta">${turnCount} turn${turnCount !== 1 ? 's' : ''}, ${formatDuration(duration)}</span>
        <span class="span-tree-status ${statusClass}">${statusIcon}</span>
      </div>`;
    } else if (isTool) {
      const { name, resultSummary, resultFull, argsFull } = getToolInfo(spanNode);
      const duration = spanNode.events.find(e => e.event === 'tool.stop')?.duration_ms || 0;

      // If this tool span has child runs, render as a group header
      const hasChildRuns = spanNode.children.some(c => c.events.some(e => e.event === 'run.start'));
      if (hasChildRuns) {
        html += `<details class="span-tree-group" open>
          <summary class="span-tree-node tool-group" style="padding-left: ${depth * 16}px">
            <span class="span-tree-toggle">&#9656;</span>
            <span class="span-tree-label">${escapeHtml(name)}</span>
            <span class="span-tree-meta">${formatDuration(duration)}</span>
          </summary>`;
        for (const child of spanNode.children) {
          html += renderNode(child, depth + 1);
        }
        html += '</details>';
        return html;
      }

      // Regular tool - expandable with args/result detail
      const hasDetail = resultFull || argsFull;
      if (hasDetail) {
        html += `<details class="span-tree-tool-detail" style="padding-left: ${depth * 16}px">
          <summary class="span-tree-node tool">
            <span class="span-tree-icon">&#9675;</span>
            <span class="span-tree-label">${escapeHtml(name)}</span>
            ${resultSummary ? `<span class="span-tree-result">\u2192 ${escapeHtml(resultSummary)}</span>` : ''}
          </summary>
          <div class="span-tree-tool-body" style="padding-left: ${depth * 16 + 26}px">
            ${argsFull ? `<div class="span-tree-detail-section"><span class="span-tree-detail-label">Args</span><div class="code-block">${escapeHtml(argsFull)}</div></div>` : ''}
            ${resultFull ? `<div class="span-tree-detail-section"><span class="span-tree-detail-label">Result</span><div class="code-block">${escapeHtml(resultFull)}</div></div>` : ''}
          </div>
        </details>`;
      } else {
        html += `<div class="span-tree-node tool" style="padding-left: ${depth * 16}px">
          <span class="span-tree-icon">&#9675;</span>
          <span class="span-tree-label">${escapeHtml(name)}</span>
        </div>`;
      }
    }

    // Render children (skip if already rendered in group)
    if (!isTool || !spanNode.children.some(c => c.events.some(e => e.event === 'run.start'))) {
      for (const child of spanNode.children) {
        html += renderNode(child, depth + 1);
      }
    }

    return html;
  }

  let treeHtml = '<details class="span-tree" open>';
  treeHtml += '<summary class="span-tree-header">Execution Flow</summary>';
  treeHtml += '<div class="span-tree-body">';
  for (const root of tree) {
    treeHtml += renderNode(root, 0);
  }
  treeHtml += '</div></details>';

  return treeHtml;
}

function buildTurnsFromEvents(events, paired, targetRunSpanId = null) {
  // Find root agent span - the run.start whose parent_span_id is external
  // (not present in this file). For top-level traces it has no parent;
  // for child trace files, the parent points to the parent trace's tool span.
  const allSpanIds = new Set(events.filter(e => e.span_id).map(e => e.span_id));
  const rootRun = targetRunSpanId
    ? events.find(e => e.event === 'run.start' && e.span_id === targetRunSpanId)
    : events.find(e => e.event === 'run.start' &&
      (!e.metadata?.parent_span_id || !allSpanIds.has(e.metadata.parent_span_id)));
  const rootSpanId = rootRun?.span_id;

  // Filter to only root agent's LLM calls (parent_span_id matches root span)
  const llmPairs = paired.filter(p => p.type === 'llm' &&
    (!rootSpanId || p.start?.metadata?.parent_span_id === rootSpanId || p.stop?.metadata?.parent_span_id === rootSpanId));
  // Filter to only root agent's direct tool calls
  const toolPairs = paired.filter(p => p.type === 'tool' &&
    (!rootSpanId || p.start?.metadata?.parent_span_id === rootSpanId || p.stop?.metadata?.parent_span_id === rootSpanId));
  const pmapPairs = paired.filter(p => p.type === 'pmap' || p.type === 'pcalls');
  // Filter to root agent's turns to avoid cross-agent turn number collisions
  const turnPairs = paired.filter(p => p.type === 'turn' &&
    (!rootSpanId || p.start?.span_id === rootSpanId || p.stop?.span_id === rootSpanId));

  // Build turn lookup
  const turnByNum = {};
  turnPairs.forEach(p => {
    const num = p.stop?.metadata?.turn || p.start?.metadata?.turn;
    if (num) turnByNum[num] = p;
  });

  return llmPairs.map((llmPair, idx) => {
    const stop = llmPair.stop;
    const start = llmPair.start;
    const turnNumber = stop?.metadata?.turn || start?.metadata?.turn || idx + 1;
    const response = stop?.metadata?.response || '';
    const turnPair = turnByNum[turnNumber];

    // Find tool calls that happened after this LLM call and before the next
    const llmStopTime = stop?.timestamp ? new Date(stop.timestamp).getTime() : 0;
    const nextLlmStartTime = idx < llmPairs.length - 1 && llmPairs[idx + 1].start?.timestamp
      ? new Date(llmPairs[idx + 1].start.timestamp).getTime()
      : Infinity;

    const turnTools = toolPairs.filter(t => {
      const toolStart = t.start?.timestamp ? new Date(t.start.timestamp).getTime() : 0;
      return toolStart >= llmStopTime && toolStart < nextLlmStartTime;
    });

    // pmap events are emitted post-hoc (after sandbox returns), so their
    // timestamps cluster at the end of execution. Use the pmap's duration_ms
    // to compute its real execution window and match against this turn.
    const turnPmaps = pmapPairs.filter(p => {
      const pmapStopTime = p.stop?.timestamp ? new Date(p.stop.timestamp).getTime() : 0;
      const pmapDuration = p.stop?.duration_ms || 0;
      const pmapRealStart = pmapDuration > 0 ? pmapStopTime - pmapDuration : pmapStopTime;
      // The pmap's real execution started after this LLM response
      // and its post-hoc timestamp is before the next LLM starts (use <= for same-ms edge case)
      return pmapRealStart >= llmStopTime && pmapStopTime <= nextLlmStartTime;
    });

    // Classify tools as sub-agent vs regular
    const subAgentToolNames = [];
    let regularToolCount = 0;
    let firstRegularToolName = null;
    for (const t of turnTools) {
      const tName = t.stop?.metadata?.tool_name || t.start?.metadata?.tool_name || 'unknown';
      const childIds = t.stop?.metadata?.child_trace_ids ||
        (t.stop?.metadata?.child_trace_id ? [t.stop.metadata.child_trace_id] : []);
      const spanId = t.stop?.span_id || t.start?.span_id;
      const hasEmbedded = spanId && events.some(e =>
        e.event === 'run.start' && e.metadata?.parent_span_id === spanId
      );
      if (childIds.length > 0 || hasEmbedded) {
        subAgentToolNames.push(tName);
      } else {
        regularToolCount++;
        if (!firstRegularToolName) firstRegularToolName = tName;
      }
    }

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

    // Agent metadata — attach to first turn only for display in right panel
    const isFirstTurn = idx === 0;
    const rootAgent = isFirstTurn ? (rootRun?.metadata?.agent || {}) : null;

    return {
      turnNumber,
      llmPair,
      systemPrompt: start?.metadata?.system_prompt || null,
      prompt: getLastUserMessage(start?.metadata?.messages),
      thinking: extractThinking(response),
      program: turnPair?.stop?.metadata?.program || extractProgram(response),
      rawResponse: turnPair?.stop?.metadata?.raw_response || response || null,
      tokens: stop?.measurements || null,
      duration: stop?.duration_ms || 0,
      resultPreview,
      prints: turnPair?.stop?.metadata?.prints || null,
      tools: turnTools,
      pmaps: turnPmaps,
      hasError,
      hasReturn,
      toolCount: regularToolCount,
      subAgentTools: subAgentToolNames,
      firstToolName: firstRegularToolName,
      agentSig: rootAgent?.signature || null,
      agentToolNames: rootAgent ? Object.keys(rootAgent.tools || {}) : null,
      agentMaxTurns: rootAgent?.max_turns ?? null
    };
  });
}

function groupByName(names) {
  const counts = {};
  for (const n of names) counts[n] = (counts[n] || 0) + 1;
  return Object.entries(counts).map(([name, count]) => ({ name, count }));
}

// Extract the input parameter portion from a signature string.
// "(parents [:map]) -> ..." returns "parents [:map]"
// "(goal :string) -> ..."  returns "goal :string"
// "()" returns null
function extractSigInput(sig) {
  if (!sig) return null;
  const m = sig.match(/^\(([^)]*)\)\s*->/);
  if (!m) return null;
  const input = m[1].trim();
  return input || null;
}

function getTimelineLabel(turn) {
  if (turn.hasError) return 'error';
  if (turn.hasReturn) return 'return';
  if (turn.subAgentTools.length > 0) {
    const grouped = groupByName(turn.subAgentTools);
    const first = grouped[0];
    return '\u{1F33F}' + first.name + (first.count > 1 ? '\u00d7' + first.count : '');
  }
  if (turn.toolCount > 0) {
    return '\u{1F527}' + (turn.firstToolName || 'tool');
  }
  if (turn.program) {
    return turn.program.replace(/\n/g, ' ').trim().slice(0, 20);
  }
  return '...';
}

function renderTurnDetail(container, turn, state, data) {
  let html = '';

  // Agent info card (first turn only — shows signature, tools, max_turns)
  if (turn.agentSig || (Array.isArray(turn.agentToolNames) && turn.agentToolNames.length > 0)) {
    const toolsHtml = Array.isArray(turn.agentToolNames) && turn.agentToolNames.length > 0
      ? `<div class="agent-info-tools">${turn.agentToolNames.map(t => `<span class="agent-tool-tag">${escapeHtml(t)}</span>`).join('')}</div>`
      : '';
    const maxTurnsHtml = turn.agentMaxTurns != null
      ? `<span class="agent-info-meta">max turns: ${turn.agentMaxTurns}</span>`
      : '';
    html += `<div class="turn-section">
      <div class="section-title">Agent</div>
      <div class="agent-info-card">
        ${turn.agentSig ? `<div class="agent-info-sig">${escapeHtml(turn.agentSig)}</div>` : ''}
        ${toolsHtml}
        ${maxTurnsHtml}
      </div>
    </div>`;
  }

  // System prompt (first turn only, collapsible)
  if (turn.systemPrompt) {
    const spLen = (turn.systemPrompt.length / 1024).toFixed(1);
    html += `<div class="turn-section">
      <details>
        <summary class="section-title">System Prompt <span class="meta">(${spLen}KB)</span></summary>
        <div class="code-block system-prompt">${escapeHtml(turn.systemPrompt)}</div>
      </details>
    </div>`;
  }

  // Prompt (turn 1: full, turn 2+: collapsed as feedback)
  if (turn.prompt && !/^String\(\d+ bytes\)$/.test(turn.prompt)) {
    if (turn.turnNumber > 1) {
      html += `<div class="turn-section">
        <details>
          <summary class="section-title">Feedback from Turn ${turn.turnNumber - 1}</summary>
          <div class="code-block">${escapeHtml(turn.prompt)}</div>
        </details>
      </div>`;
    } else {
      html += `<div class="turn-section">
        <details open>
          <summary class="section-title">Prompt</summary>
          <div class="code-block">${escapeHtml(turn.prompt)}</div>
        </details>
      </div>`;
    }
  }

  // Thinking
  if (turn.thinking) {
    html += `<div class="turn-section">
      <div class="section-title">Thinking</div>
      <div class="thinking-block">${escapeHtml(turn.thinking)}</div>
    </div>`;
  }

  // Program with syntax highlighting
  if (turn.program) {
    html += `<div class="turn-section">
      <div class="section-title">Program ${turn.tokens ? `<span class="meta">${formatTokenBreakdown(turn.tokens)}</span>` : ''}</div>
      <div class="code-block">${highlightLisp(turn.program)}</div>
    </div>`;
  } else if (turn.rawResponse) {
    html += `<div class="turn-section">
      <div class="section-title">Raw LLM Response (parse failed)</div>
      <div class="code-block error-result">${escapeHtml(turn.rawResponse)}</div>
    </div>`;
  }

  // Tool calls (skip when pmaps present - fork-join viz renders those)
  const toolsWithChildren = (turn.tools.length > 0 && turn.pmaps.length === 0)
    ? turn.tools.filter(t => {
        const ids = t.stop?.metadata?.child_trace_ids ||
          (t.stop?.metadata?.child_trace_id ? [t.stop.metadata.child_trace_id] : []);
        const spanId = t.stop?.span_id || t.start?.span_id;
        const hasEmbedded = spanId && data?.events?.some(e =>
          e.event === 'run.start' && e.metadata?.parent_span_id === spanId
        );
        return ids.length > 0 || hasEmbedded;
      })
    : [];

  if (turn.tools.length > 0 && turn.pmaps.length === 0) {
    html += '<div class="turn-section"><div class="section-title">Tool Calls</div>';
    for (const tool of turn.tools) {
      const toolName = tool.stop?.metadata?.tool_name || tool.start?.metadata?.tool_name || 'unknown';
      const toolDuration = tool.stop?.duration_ms || 0;
      const toolArgs = tool.start?.metadata?.args || tool.stop?.metadata?.args;
      const toolResult = tool.stop?.metadata?.result;
      const childTraceIds = tool.stop?.metadata?.child_trace_ids ||
        (tool.stop?.metadata?.child_trace_id ? [tool.stop.metadata.child_trace_id] : []);

      html += `<div class="tool-call">
        <div class="tool-header">
          <span class="tool-name">${escapeHtml(toolName)}</span>
          <span class="tool-duration">${formatDuration(toolDuration)}</span>
          ${childTraceIds.length > 0 ? '<span class="drill-in-btn">[Drill In]</span>' : ''}
        </div>`;

      if (toolArgs) {
        html += `<details>
          <summary class="tool-section-title">Arguments</summary>
          <div class="code-block">${escapeHtml(JSON.stringify(toolArgs, null, 2))}</div>
        </details>`;
      }

      if (toolResult != null) {
        const resultStr = typeof toolResult === 'string' ? toolResult : JSON.stringify(toolResult, null, 2);
        html += `<details>
          <summary class="tool-section-title">Result</summary>
          <div class="code-block">${escapeHtml(truncate(resultStr, 2000))}</div>
        </details>`;
      }

      // Child agent drill-in
      if (childTraceIds.length > 0) {
        html += `<div class="child-traces">
          ${childTraceIds.map(id => {
            const file = findFileByTraceId(state, id);
            return `<div class="child-trace-item" data-traceid="${id}">
              <span class="id">${escapeHtml(id.slice(0, 12))}...</span>
              <span class="status">${file ? '\u2192' : '(not loaded)'}</span>
            </div>`;
          }).join('')}
        </div>`;
      }

      html += '</div>';
    }
    html += '</div>';

    if (toolsWithChildren.length > 0) {
      html += '<div class="turn-section"><div class="section-title">Execution Tree</div>';
      html += '<div id="exec-tree-container"></div>';
      html += '</div>';
    }
  }

  // Fork-join visualization for pmap/pcalls
  if (turn.pmaps.length > 0) {
    html += '<div class="turn-section"><div class="section-title">Parallel Execution</div>';
    for (const pmap of turn.pmaps) {
      const spanId = pmap.stop?.span_id || ('fj-' + Math.random().toString(36).slice(2, 8));
      html += `<div id="fork-join-${spanId}" class="fork-join-container" data-span-id="${spanId}"></div>`;
    }
    html += '</div>';
  }

  // Result/error
  if (turn.resultPreview && turn.resultPreview !== 'nil') {
    const isError = turn.hasError;
    html += `<div class="turn-section">
      <div class="section-title">${isError ? 'Error' : 'Result'}</div>
      <div class="code-block${isError ? ' error-result' : ''}">${escapeHtml(turn.resultPreview)}</div>
    </div>`;
  }

  // Prints
  if (Array.isArray(turn.prints) && turn.prints.length > 0) {
    html += `<div class="turn-section">
      <div class="section-title">Output (${turn.prints.length})</div>
      <div class="code-block">${turn.prints.map(p => escapeHtml(p)).join('\n')}</div>
    </div>`;
  }

  container.innerHTML = html;

  // Wire up fork-join rendering
  if (turn.pmaps.length > 0) {
    turn.pmaps.forEach(pmap => {
      const spanId = pmap.stop?.span_id;
      const forkJoinEl = spanId
        ? container.querySelector(`#fork-join-${spanId}`)
        : container.querySelector('.fork-join-container');
      if (forkJoinEl) {
        renderForkJoin(forkJoinEl, pmap, state, data);
      }
    });
  }

  // Wire up child trace drill-in clicks
  container.querySelectorAll('.child-trace-item').forEach(item => {
    item.addEventListener('click', () => {
      const traceId = item.dataset.traceid;
      const file = findFileByTraceId(state, traceId);
      if (file) {
        const childData = state.files.get(file);
        import('./app.js').then(app => {
          app.navigateTo({ type: 'agent', label: traceId.slice(0, 12), data: childData });
        });
      }
    });
  });

  // Wire up drill-in buttons
  container.querySelectorAll('.drill-in-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const toolCall = btn.closest('.tool-call');
      const childItem = toolCall?.querySelector('.child-trace-item');
      if (childItem) childItem.click();
    });
  });

  // Wire up execution tree
  const execTreeEl = container.querySelector('#exec-tree-container');
  if (execTreeEl && toolsWithChildren.length > 0) {
    renderExecutionTree(execTreeEl, toolsWithChildren, state, data);
  }
}
