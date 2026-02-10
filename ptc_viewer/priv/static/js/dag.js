import { formatDuration, truncate, escapeHtml } from './utils.js';
import { tooltipForDagNode } from './tooltip.js';

function computeGraphLayout(model) {
  const nodeW = 180, nodeH = 72;
  const phaseGap = 60, nodeGap = 20;
  const padX = 40, padY = 50;
  const positions = {};

  const maxTasksInPhase = Math.max(...model.phases.map(p => p.taskIds.length), 1);
  const totalContentH = maxTasksInPhase * nodeH + (maxTasksInPhase - 1) * nodeGap;

  for (const phase of model.phases) {
    const x = padX + phase.phase * (nodeW + phaseGap);
    const phaseH = phase.taskIds.length * nodeH + (phase.taskIds.length - 1) * nodeGap;
    const offsetY = padY + 20 + (totalContentH - phaseH) / 2;
    for (let i = 0; i < phase.taskIds.length; i++) {
      positions[phase.taskIds[i]] = {
        x,
        y: offsetY + i * (nodeH + nodeGap),
        w: nodeW,
        h: nodeH
      };
    }
  }

  const maxPhase = model.phases.length > 0 ? model.phases[model.phases.length - 1].phase : 0;
  const svgW = padX * 2 + (maxPhase + 1) * (nodeW + phaseGap) - phaseGap;
  const svgH = padY + 20 + totalContentH + padX;

  return { positions, svgW, svgH, nodeW, nodeH, padX, padY };
}

function getNodeStroke(task) {
  if (task.type === 'synthesis_gate' || task.type === 'synthesis') return '#c586c0';
  if (task.status === 'ok') return '#4ec9b0';
  if (task.status === 'error' || task.status === 'failed') return '#f44747';
  if (task.status === 'running') return '#569cd6';
  return '#808080';
}

function getNodeFill(task) {
  if (task.type === 'synthesis_gate' || task.type === 'synthesis') return 'rgba(197, 134, 192, 0.15)';
  if (task.status === 'ok') return 'rgba(78, 201, 176, 0.12)';
  if (task.status === 'error' || task.status === 'failed') return 'rgba(244, 71, 71, 0.12)';
  if (task.status === 'running') return 'rgba(86, 156, 214, 0.15)';
  return 'rgba(128, 128, 128, 0.1)';
}

function computeEdgePath(fromPos, toPos, nodeW, nodeH) {
  const x1 = fromPos.x + nodeW;
  const y1 = fromPos.y + nodeH / 2;
  const x2 = toPos.x;
  const y2 = toPos.y + nodeH / 2;
  const cx = (x1 + x2) / 2;
  return `M ${x1} ${y1} C ${cx} ${y1}, ${cx} ${y2}, ${x2} ${y2}`;
}

function truncateId(id, maxLen) {
  return id.length > maxLen ? id.slice(0, maxLen - 1) + '\u2026' : id;
}

export function renderDAG(container, attempts, events, options = {}) {
  // Collect task IDs that had quality gate events
  const gateTaskIds = new Set(
    events.filter(e => e.event === 'quality_gate.start')
      .map(e => e.metadata?.task_id)
      .filter(Boolean)
  );

  if (attempts.length === 0) {
    container.classList.add('hidden');
    return;
  }

  // Set up DAG section structure
  const totalTasks = attempts[0].model.tasks.length;
  const totalPhases = attempts[0].model.phases.length;
  let metaText = `${totalTasks} tasks, ${totalPhases} phases`;
  if (attempts.length > 1) metaText += `, ${attempts.length - 1} replan(s)`;

  let html = `
    <div class="dag-header" id="dagHeader">
      <span class="toggle">\u25B6</span>
      <h3>Task Execution Graph <span style="color: var(--muted); font-size: 12px;">${metaText}</span></h3>
    </div>
    <div class="dag-body">`;

  if (attempts.length > 1) {
    html += '<div class="dag-tabs">';
    attempts.forEach((attempt, idx) => {
      const isReplan = idx > 0;
      html += `<button class="dag-tab${idx === 0 ? ' active' : ''}${isReplan ? ' replan' : ''}" data-attempt="${idx}">${attempt.label}</button>`;
    });
    html += '</div>';
  }

  html += '<div id="dagReplanInfo"></div><div id="dagSvgContainer"></div>';
  html += '</div>';

  container.innerHTML = html;
  container.classList.add('dag-section', 'expanded');
  container.classList.remove('hidden');

  // Wire up collapse toggle
  const header = container.querySelector('#dagHeader');
  header.addEventListener('click', () => container.classList.toggle('expanded'));

  const svgContainer = container.querySelector('#dagSvgContainer');
  const replanInfo = container.querySelector('#dagReplanInfo');

  // Create a persistent tooltip element
  let tooltip = document.getElementById('dagTooltip');
  if (!tooltip) {
    tooltip = document.createElement('div');
    tooltip.id = 'dagTooltip';
    tooltip.className = 'dag-tooltip';
    document.body.appendChild(tooltip);
  }

  // Render first attempt
  renderDAGForModel(attempts[0], svgContainer, tooltip, replanInfo, gateTaskIds, options);

  // Tab click handlers
  if (attempts.length > 1) {
    container.querySelectorAll('.dag-tab').forEach(tab => {
      tab.addEventListener('click', () => {
        container.querySelectorAll('.dag-tab').forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        const idx = parseInt(tab.dataset.attempt);
        renderDAGForModel(attempts[idx], svgContainer, tooltip, replanInfo, gateTaskIds, options);
      });
    });
  }
}

function renderDAGForModel(attempt, svgContainer, tooltip, replanInfoEl, gateTaskIds, options) {
  const model = attempt.model;

  // Show replan info banner if applicable
  if (attempt.triggerTaskId) {
    replanInfoEl.innerHTML = `<div class="dag-replan-info">
      Triggered by failed task <span class="trigger">${escapeHtml(attempt.triggerTaskId)}</span>
      ${attempt.diagnosis ? ` \u2014 ${escapeHtml(truncate(attempt.diagnosis, 150))}` : ''}
    </div>`;
  } else {
    replanInfoEl.innerHTML = '';
  }

  const layout = computeGraphLayout(model);
  const { positions, svgW, svgH, nodeW, nodeH, padX, padY } = layout;
  const taskMap = {};
  for (const t of model.tasks) taskMap[t.id] = t;

  // Build SVG
  let svg = `<svg width="${svgW}" height="${svgH}" xmlns="http://www.w3.org/2000/svg" style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;">`;

  // Arrowhead markers
  svg += `<defs><marker id="dagArrow" viewBox="0 0 10 7" refX="10" refY="3.5" markerWidth="8" markerHeight="6" orient="auto-start-reverse"><polygon points="0 0, 10 3.5, 0 7" class="dag-arrowhead"/></marker>`;
  svg += `<marker id="dagArrowHL" viewBox="0 0 10 7" refX="10" refY="3.5" markerWidth="8" markerHeight="6" orient="auto-start-reverse"><polygon points="0 0, 10 3.5, 0 7" class="dag-arrowhead highlighted"/></marker></defs>`;

  // Phase labels
  for (const phase of model.phases) {
    const x = padX + phase.phase * (nodeW + 60) + nodeW / 2;
    svg += `<text x="${x}" y="${padY - 5}" text-anchor="middle" class="dag-phase-label">Phase ${phase.phase}</text>`;
  }

  // Edges
  for (const edge of model.edges) {
    const from = positions[edge.from];
    const to = positions[edge.to];
    if (!from || !to) continue;
    const path = computeEdgePath(from, to, nodeW, nodeH);
    svg += `<path d="${path}" class="dag-edge" data-from="${edge.from}" data-to="${edge.to}" marker-end="url(#dagArrow)"/>`;
  }

  // Nodes
  for (const task of model.tasks) {
    const pos = positions[task.id];
    if (!pos) continue;
    const stroke = getNodeStroke(task);
    const fill = getNodeFill(task);
    const displayId = truncateId(task.id, 22);

    let statusIcon = '';
    if (task.status === 'ok') statusIcon = '\u2713';
    else if (task.status === 'error' || task.status === 'failed') statusIcon = '\u2717';
    else if (task.status === 'running') statusIcon = '\u25cb';
    else statusIcon = '\u2022';

    let badgeSvg = '';
    if (task.outputMode === 'ptc_lisp') {
      badgeSvg = `<rect x="${pos.x + nodeW - 42}" y="${pos.y + 4}" width="36" height="16" rx="3" fill="#569cd6" opacity="0.8"/><text x="${pos.x + nodeW - 24}" y="${pos.y + 15}" text-anchor="middle" class="node-badge" fill="#fff">PTC</text>`;
    } else if (task.type === 'synthesis_gate' || task.type === 'synthesis') {
      badgeSvg = `<rect x="${pos.x + nodeW - 56}" y="${pos.y + 4}" width="50" height="16" rx="3" fill="#c586c0" opacity="0.8"/><text x="${pos.x + nodeW - 31}" y="${pos.y + 15}" text-anchor="middle" class="node-badge" fill="#fff">SYNTH</text>`;
    } else if (task.outputMode === 'json') {
      badgeSvg = `<rect x="${pos.x + nodeW - 46}" y="${pos.y + 4}" width="40" height="16" rx="3" fill="#808080" opacity="0.6"/><text x="${pos.x + nodeW - 26}" y="${pos.y + 15}" text-anchor="middle" class="node-badge" fill="#fff">JSON</text>`;
    }

    // Quality gate badge
    const hasGate = task.qualityGate === true || (gateTaskIds && gateTaskIds.has(task.id));
    let gateBadgeSvg = '';
    if (hasGate) {
      gateBadgeSvg = `<rect x="${pos.x + nodeW - 48}" y="${pos.y + nodeH - 20}" width="42" height="16" rx="3" fill="#6a9955" opacity="0.8"/><text x="${pos.x + nodeW - 27}" y="${pos.y + nodeH - 9}" text-anchor="middle" class="node-badge" fill="#fff">GATE</text>`;
    }

    svg += `<g class="dag-node" data-taskid="${task.id}">`;
    svg += `<rect x="${pos.x}" y="${pos.y}" width="${nodeW}" height="${nodeH}" fill="${fill}" stroke="${stroke}"/>`;
    svg += badgeSvg;
    svg += gateBadgeSvg;
    svg += `<text x="${pos.x + 10}" y="${pos.y + 26}" class="node-id" fill="${stroke}">${statusIcon} ${escapeHtml(displayId)}</text>`;
    svg += `<text x="${pos.x + 10}" y="${pos.y + 42}" class="node-agent" fill="#808080">\u2192 ${escapeHtml(task.agent)}</text>`;
    if (task.durationMs > 0) {
      svg += `<text x="${pos.x + 10}" y="${pos.y + 58}" class="node-duration" fill="#808080">${formatDuration(task.durationMs)}</text>`;
    }
    svg += `</g>`;
  }

  svg += `</svg>`;
  svgContainer.innerHTML = svg;

  // Attach interactions
  svgContainer.querySelectorAll('.dag-node').forEach(node => {
    const taskId = node.dataset.taskid;
    const task = taskMap[taskId];

    node.addEventListener('click', () => {
      tooltip.style.display = 'none';
      if (options.onNodeClick) {
        options.onNodeClick(taskId);
      } else {
        // Default: scroll to the event card
        const card = document.querySelector(`.event-card[data-taskid="${taskId}"]`);
        if (card) {
          card.scrollIntoView({ behavior: 'smooth', block: 'center' });
          card.classList.remove('dag-highlight');
          void card.offsetWidth;
          card.classList.add('dag-highlight');
          if (!card.classList.contains('expanded')) card.classList.add('expanded');
        }
      }
    });

    node.addEventListener('mouseenter', (evt) => {
      svgContainer.querySelectorAll('.dag-edge').forEach(edge => {
        if (edge.dataset.from === taskId || edge.dataset.to === taskId) {
          edge.classList.add('highlighted');
          edge.setAttribute('marker-end', 'url(#dagArrowHL)');
        }
      });
      if (task) {
        tooltip.innerHTML = tooltipForDagNode(task, gateTaskIds);
        tooltip.style.display = 'block';
        const rect = node.getBoundingClientRect();
        tooltip.style.left = (rect.right + 8) + 'px';
        tooltip.style.top = rect.top + 'px';
      }
    });

    node.addEventListener('mouseleave', () => {
      svgContainer.querySelectorAll('.dag-edge.highlighted').forEach(edge => {
        edge.classList.remove('highlighted');
        edge.setAttribute('marker-end', 'url(#dagArrow)');
      });
      tooltip.style.display = 'none';
    });
  });
}
