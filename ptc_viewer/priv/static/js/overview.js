import { formatDuration, formatTokens, formatTokenBreakdown, escapeHtml, truncate, truncatePlan } from './utils.js';
import { pairEvents, extractPlanData, extractChildTraceIds, buildExecutionAttempts, getEarliestTimestamp, findRunForTask, extractRunEvents } from './parser.js';
import { renderDAG } from './dag.js';
import { renderTimeline } from './timeline.js';
import { navigateTo } from './app.js';

export function renderOverview(container, state, data) {
  const events = data.events;
  const paired = pairEvents(events);
  const llmEvents = paired.filter(e => e.type === 'llm');

  // Calculate summary stats
  const execStop = events.find(e => e.event === 'execution.stop');
  const runStop = events.find(e => e.event === 'run.stop');
  const traceStop = events.find(e => e.event === 'trace.stop');
  const totalDuration = execStop?.duration_ms || runStop?.duration_ms || traceStop?.duration_ms || 0;
  const totalTokens = llmEvents.reduce((sum, e) => sum + (e.stop?.measurements?.tokens || 0), 0);
  const totalInputTokens = llmEvents.reduce((sum, e) => sum + (e.stop?.measurements?.input_tokens || 0), 0);
  const totalOutputTokens = llmEvents.reduce((sum, e) => sum + (e.stop?.measurements?.output_tokens || 0), 0);
  const totalCacheRead = llmEvents.reduce((sum, e) => sum + (e.stop?.measurements?.cache_read_tokens || 0), 0);
  const maxTurn = llmEvents.reduce((max, e) => Math.max(max, e.stop?.metadata?.turn || 0), 0);
  const taskEvents = paired.filter(e => e.type === 'task');
  const childIds = extractChildTraceIds(events);

  let tokenBreakdown = '';
  if (totalInputTokens || totalOutputTokens) {
    tokenBreakdown = `${formatTokens(totalInputTokens)} in / ${formatTokens(totalOutputTokens)} out`;
    if (totalCacheRead > 0) tokenBreakdown += ` (${formatTokens(totalCacheRead)} cached)`;
  }

  // Build HTML
  let html = '';

  // Summary stats
  html += `<div class="summary visible">
    <div class="summary-grid">
      <div class="summary-item"><div class="summary-value">${formatDuration(totalDuration)}</div><div class="summary-label">Duration</div></div>
      <div class="summary-item"><div class="summary-value">${maxTurn}</div><div class="summary-label">Turns</div></div>
      <div class="summary-item"><div class="summary-value">${llmEvents.length}</div><div class="summary-label">LLM Calls</div></div>
      <div class="summary-item">
        <div class="summary-value">${totalTokens.toLocaleString()}</div>
        <div class="summary-label">Tokens</div>
        ${tokenBreakdown ? `<div class="token-breakdown">${tokenBreakdown}</div>` : ''}
      </div>
      ${taskEvents.length > 0 ? `<div class="summary-item"><div class="summary-value">${taskEvents.length}</div><div class="summary-label">Tasks</div></div>` : ''}
      <div class="summary-item"><div class="summary-value">${childIds.length}</div><div class="summary-label">Children</div></div>
    </div>
  </div>`;

  // Timeline
  html += '<div id="overview-timeline" class="timeline visible"><h3>Timeline</h3><div class="timeline-bar" id="overview-timeline-bar"></div></div>';

  // DAG
  html += '<div id="overview-dag"></div>';

  // Plan card
  const { plan, mission, agents } = extractPlanData(events);
  if (plan || mission) {
    html += renderPlanCard(plan, mission, agents);
  }

  container.innerHTML = html;

  // Render timeline
  const timelineBar = container.querySelector('#overview-timeline-bar');
  if (timelineBar) renderTimeline(timelineBar, paired, totalDuration);

  // Render DAG
  const dagContainer = container.querySelector('#overview-dag');
  const attempts = buildExecutionAttempts(events);
  if (attempts.length > 0) {
    renderDAG(dagContainer, attempts, events, {
      onNodeClick: (taskId) => {
        // Find the trace for this task and drill in
        const taskPair = paired.find(p => p.type === 'task' && (p.stop?.metadata?.task_id === taskId || p.start?.metadata?.task_id === taskId));
        if (taskPair) {
          const childTraceId = taskPair.stop?.metadata?.child_trace_id;
          if (childTraceId) {
            const childFile = findFileByTraceId(state, childTraceId);
            if (childFile) {
              const childData = state.files.get(childFile);
              navigateTo({ type: 'agent', label: taskId, data: childData });
              return;
            }
          }
        }
        // Fallback: extract run events from the same trace file (single-file traces)
        const runSpanId = findRunForTask(events, taskId);
        if (runSpanId) {
          const runEvents = extractRunEvents(events, runSpanId);
          if (runEvents.length > 0) {
            navigateTo({ type: 'agent', label: taskId, data: { events: runEvents, traceId: taskId, filename: taskId } });
          }
        }
      }
    });
  }

  // Wire up plan card toggle
  const planHeader = container.querySelector('.plan-header');
  if (planHeader) {
    planHeader.addEventListener('click', () => {
      planHeader.closest('.plan-card').classList.toggle('expanded');
    });
  }
}

function findFileByTraceId(state, traceId) {
  for (const [name, data] of state.files) {
    if (data.traceId === traceId) return name;
  }
  return null;
}

function renderPlanCard(plan, mission, agents) {
  let html = '<div class="plan-card visible expanded">';
  html += '<div class="plan-header"><span class="toggle">\u25B6</span><h3>Execution Plan</h3>';

  if (plan?.tasks) {
    html += `<span style="color: var(--muted); font-size: 12px;">${plan.tasks.length} tasks</span>`;
  }
  html += '</div>';
  html += '<div class="plan-body">';

  if (mission) {
    html += `<div class="plan-section"><div class="plan-section-title">Mission</div><div class="mission-text">${escapeHtml(truncatePlan(mission, 1500))}</div></div>`;
  }

  // Agents section
  const planAgents = plan?.agents || agents;
  if (planAgents && typeof planAgents === 'object') {
    const agentNames = Object.keys(planAgents);
    html += `<div class="plan-section">
      <div class="plan-section-title">Agents <span class="count">${agentNames.length}</span></div>
      <div class="agent-cards">${agentNames.map(name => renderAgentCard(name, planAgents[name])).join('')}</div>
    </div>`;
  }

  // Tasks section
  if (plan?.tasks && Array.isArray(plan.tasks)) {
    html += `<div class="plan-section">
      <div class="plan-section-title">Tasks <span class="count">${plan.tasks.length}</span></div>
      <div class="task-flow">${plan.tasks.map(task => renderTaskItem(task)).join('')}</div>
    </div>`;
  }

  html += '</div></div>';
  return html;
}

function renderAgentCard(name, agent) {
  const tools = agent.tools || [];
  const prompt = agent.prompt || '';

  return `
    <div class="agent-card">
      <div class="agent-card-header">
        <span class="agent-card-name">${escapeHtml(name)}</span>
      </div>
      ${prompt ? `<div class="agent-card-prompt">${escapeHtml(truncatePlan(prompt, 150))}</div>` : ''}
      ${tools.length > 0 ? `
        <div class="agent-card-tools">
          ${tools.map(t => `<span class="agent-tool-tag">${escapeHtml(t)}</span>`).join('')}
        </div>
      ` : '<div style="font-size: 11px; color: var(--muted);">No tools</div>'}
    </div>`;
}

function renderTaskItem(task) {
  const taskType = task.type || 'task';
  const isSynthesis = taskType === 'synthesis_gate' || taskType === 'synthesis';
  const isHumanReview = taskType === 'human_review';
  const typeClass = isSynthesis ? 'synthesis' : (isHumanReview ? 'human_review' : '');

  const deps = task.depends_on || [];
  const verification = task.verification;
  const signature = task.signature;

  return `
    <div class="task-item ${typeClass}">
      <div class="task-item-header">
        <span class="task-id">${escapeHtml(task.id || 'unnamed')}</span>
        ${taskType !== 'task' ? `<span class="task-type-badge">${escapeHtml(taskType)}</span>` : ''}
        ${task.output ? `<span class="task-type-badge" style="background: ${task.output === 'ptc_lisp' ? 'var(--accent)' : 'var(--muted)'}; color: var(--bg);">${task.output === 'ptc_lisp' ? 'PTC-Lisp' : 'JSON'}</span>` : ''}
        ${task.agent ? `<span class="task-agent-ref">\u2192 ${escapeHtml(task.agent)}</span>` : ''}
      </div>
      ${task.input ? `<div class="task-input">${escapeHtml(truncatePlan(task.input, 200))}</div>` : ''}
      ${deps.length > 0 ? `
        <div class="task-deps">
          <span style="font-size: 10px; color: var(--muted);">depends on:</span>
          ${deps.map(d => `<span class="task-dep-tag">${escapeHtml(d)}</span>`).join('')}
        </div>
      ` : ''}
      ${signature ? `
        <div class="task-verification">
          <span style="color: var(--muted);">Output signature:</span>
          <code>${escapeHtml(signature)}</code>
        </div>
      ` : ''}
      ${verification ? `
        <div class="task-verification">
          <span style="color: var(--muted);">Verification:</span>
          <code>${escapeHtml(verification)}</code>
        </div>
      ` : ''}
    </div>`;
}
