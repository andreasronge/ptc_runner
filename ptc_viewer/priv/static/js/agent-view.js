import { formatDuration, formatTokens, formatTokenBreakdown, truncate, escapeHtml } from './utils.js';
import { pairEvents, extractThinking, extractProgram, getLastUserMessage } from './parser.js';
import { highlightLisp } from './highlight.js';
import { showTooltip, hideTooltip } from './tooltip.js';
import { renderForkJoin } from './fork-join.js';

export function renderAgentView(container, state, data) {
  const events = data.events;
  const paired = pairEvents(events);

  // Agent header info
  const traceStart = events.find(e => e.event === 'trace.start');
  const runStart = events.find(e => e.event === 'run.start');
  const execStop = events.find(e => e.event === 'execution.stop');
  const runStop = events.find(e => e.event === 'run.stop');
  const traceStop = events.find(e => e.event === 'trace.stop');

  const agentName = traceStart?.metadata?.agent_name || traceStart?.metadata?.tool_name || data.filename;
  const outputMode = runStart?.metadata?.agent?.output || 'unknown';
  const totalDuration = execStop?.duration_ms || runStop?.duration_ms || traceStop?.duration_ms || 0;
  // Build turns array (filtered to root agent only)
  const turns = buildTurnsFromEvents(events, paired);

  // Compute header stats from root agent turns only
  const totalTokens = turns.reduce((sum, t) => sum + (t.tokens?.tokens || 0), 0);

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

  // Turn lane - horizontal row of turn pills
  html += '<div class="turn-lane">';
  turns.forEach((turn, idx) => {
    const isActive = idx === 0;
    const statusClass = turn.hasError ? 'error' : turn.hasReturn ? 'returned' : 'normal';
    html += `<div class="turn-pill ${statusClass}${isActive ? ' active' : ''}" data-turn-idx="${idx}">
      <span class="turn-num">${turn.turnNumber || idx + 1}</span>
      ${turn.hasError ? '<span class="turn-icon">&#10007;</span>' : turn.hasReturn ? '<span class="turn-icon">&#10003;</span>' : ''}
    </div>`;
  });
  html += '</div>';

  // Turn detail area
  html += '<div id="turn-detail" class="turn-detail"></div>';

  container.innerHTML = html;

  // Render first turn detail
  const detailContainer = container.querySelector('#turn-detail');
  if (turns.length > 0) {
    renderTurnDetail(detailContainer, turns[0], state, data);
  }

  // Turn pill click handlers
  container.querySelectorAll('.turn-pill').forEach(pill => {
    pill.addEventListener('click', () => {
      container.querySelectorAll('.turn-pill').forEach(p => p.classList.remove('active'));
      pill.classList.add('active');
      const idx = parseInt(pill.dataset.turnIdx);
      renderTurnDetail(detailContainer, turns[idx], state, data);
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
        pills[activeIdx].classList.remove('active');
        pills[newIdx].classList.add('active');
        renderTurnDetail(detailContainer, turns[newIdx], state, data);
      }
    }
  };
  document.addEventListener('keydown', keyHandler);
  container._keyHandler = keyHandler;
}

function buildTurnsFromEvents(events, paired) {
  // Find root agent span - the run.start whose parent_span_id is external
  // (not present in this file). For top-level traces it has no parent;
  // for child trace files, the parent points to the parent trace's tool span.
  const allSpanIds = new Set(events.filter(e => e.span_id).map(e => e.span_id));
  const rootRun = events.find(e => e.event === 'run.start' &&
    (!e.metadata?.parent_span_id || !allSpanIds.has(e.metadata.parent_span_id)));
  const rootSpanId = rootRun?.span_id;

  // Filter to only root agent's LLM calls (parent_span_id matches root span)
  const llmPairs = paired.filter(p => p.type === 'llm' &&
    (!rootSpanId || p.start?.metadata?.parent_span_id === rootSpanId || p.stop?.metadata?.parent_span_id === rootSpanId));
  // Filter to only root agent's direct tool calls
  const toolPairs = paired.filter(p => p.type === 'tool' &&
    (!rootSpanId || p.start?.metadata?.parent_span_id === rootSpanId || p.stop?.metadata?.parent_span_id === rootSpanId));
  const pmapPairs = paired.filter(p => p.type === 'pmap' || p.type === 'pcalls');
  const turnPairs = paired.filter(p => p.type === 'turn');

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
      llmPair,
      systemPrompt: start?.metadata?.system_prompt || null,
      prompt: getLastUserMessage(start?.metadata?.messages),
      thinking: extractThinking(response),
      program: extractProgram(response),
      tokens: stop?.measurements || null,
      duration: stop?.duration_ms || 0,
      resultPreview,
      prints: turnPair?.stop?.metadata?.prints || null,
      tools: turnTools,
      pmaps: turnPmaps,
      hasError,
      hasReturn
    };
  });
}

function renderTurnDetail(container, turn, state, data) {
  let html = '';

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
          <div class="code-block">${escapeHtml(truncate(turn.prompt, 2000))}</div>
        </details>
      </div>`;
    } else {
      html += `<div class="turn-section">
        <details open>
          <summary class="section-title">Prompt</summary>
          <div class="code-block">${escapeHtml(truncate(turn.prompt, 2000))}</div>
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
  }

  // Tool calls (skip when pmaps present - fork-join viz renders those)
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
}

function findFileByTraceId(state, traceId) {
  for (const [name, data] of state.files) {
    if (data.traceId === traceId) return name;
  }
  return null;
}
