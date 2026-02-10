import { formatDuration, escapeHtml, truncate } from './utils.js';
import { showTooltip, hideTooltip } from './tooltip.js';

export function renderForkJoin(container, parallelEvent, state, data) {
  const stop = parallelEvent.stop;
  const start = parallelEvent.start;
  if (!stop) return;

  const count = stop.metadata?.count || 0;
  const results = stop.metadata?.results || [];
  const durations = stop.metadata?.durations || [];
  const totalDuration = stop.duration_ms || 0;

  // Extract child events from the parallel span's time window
  const startTime = start?.timestamp ? new Date(start.timestamp).getTime() : 0;
  const stopTime = stop?.timestamp ? new Date(stop.timestamp).getTime() : Infinity;

  // Find tool events within this parallel span
  const childTools = [];
  if (data?.events) {
    const toolStarts = {};
    const toolStops = [];
    for (const event of data.events) {
      const eventTime = event.timestamp ? new Date(event.timestamp).getTime() : 0;
      if (eventTime < startTime || eventTime > stopTime) continue;
      if (event.event === 'tool.start' && event.span_id) toolStarts[event.span_id] = event;
      if (event.event === 'tool.stop' && event.span_id) toolStops.push(event);
    }

    for (const toolStop of toolStops) {
      const toolStart = toolStarts[toolStop.span_id];
      childTools.push({
        name: toolStop.metadata?.tool_name || toolStart?.metadata?.tool_name || 'unknown',
        duration: toolStop.duration_ms || 0,
        args: toolStart?.metadata?.args,
        result: toolStop.metadata?.result,
        childTraceId: toolStop.metadata?.child_trace_id
      });
    }
  }

  // If no child tools found, use durations/results from metadata
  const branches = childTools.length > 0 ? childTools : results.map((r, i) => ({
    name: `Branch ${i + 1}`,
    duration: durations[i] || 0,
    result: r
  }));

  if (branches.length === 0) {
    container.innerHTML = `<div class="fork-join-empty">No parallel branches found</div>`;
    return;
  }

  // Find bottleneck (longest duration)
  const maxDuration = Math.max(...branches.map(b => b.duration));
  const maxBranchDuration = maxDuration || totalDuration || 1;

  // Check if D3 is available
  if (typeof d3 === 'undefined') {
    renderForkJoinFallback(container, branches, parallelEvent, maxDuration, totalDuration, count, state);
    return;
  }

  // Render using D3
  const margin = { top: 20, right: 30, bottom: 20, left: 30 };
  const barHeight = 28;
  const barGap = 6;
  const forkWidth = 40;
  const width = Math.max(400, container.clientWidth - margin.left - margin.right);
  const innerWidth = width - margin.left - margin.right - forkWidth * 2;
  const height = margin.top + margin.bottom + branches.length * (barHeight + barGap);

  const svg = d3.select(container)
    .append('svg')
    .attr('width', width)
    .attr('height', height)
    .attr('class', 'fork-join-svg');

  const g = svg.append('g')
    .attr('transform', `translate(${margin.left}, ${margin.top})`);

  const xScale = d3.scaleLinear()
    .domain([0, maxBranchDuration])
    .range([0, innerWidth]);

  // Fork point
  const forkX = 0;
  const joinX = forkWidth + innerWidth + forkWidth;
  const midY = (branches.length * (barHeight + barGap) - barGap) / 2;

  // Fork and join circles
  g.append('circle').attr('cx', forkX).attr('cy', midY).attr('r', 5).attr('fill', '#569cd6');
  g.append('circle').attr('cx', joinX).attr('cy', midY).attr('r', 5).attr('fill', '#569cd6');

  branches.forEach((branch, i) => {
    const y = i * (barHeight + barGap);
    const barX = forkWidth;
    const barW = Math.max(xScale(branch.duration), 4);
    const isBottleneck = branch.duration === maxDuration && branches.length > 1;

    // Fork line to bar
    g.append('line')
      .attr('x1', forkX).attr('y1', midY)
      .attr('x2', barX).attr('y2', y + barHeight / 2)
      .attr('stroke', '#3c3c3c').attr('stroke-width', 1.5);

    // Join line from bar
    g.append('line')
      .attr('x1', barX + barW).attr('y1', y + barHeight / 2)
      .attr('x2', joinX).attr('y2', midY)
      .attr('stroke', '#3c3c3c').attr('stroke-width', 1.5);

    // Bar
    const barGroup = g.append('g').attr('class', 'fork-join-bar');

    barGroup.append('rect')
      .attr('x', barX)
      .attr('y', y)
      .attr('width', barW)
      .attr('height', barHeight)
      .attr('rx', 4)
      .attr('fill', isBottleneck ? 'rgba(244, 71, 71, 0.3)' : 'rgba(86, 156, 214, 0.3)')
      .attr('stroke', isBottleneck ? '#f44747' : '#569cd6')
      .attr('stroke-width', isBottleneck ? 2 : 1);

    // Label
    barGroup.append('text')
      .attr('x', barX + 8)
      .attr('y', y + barHeight / 2 + 4)
      .attr('fill', '#d4d4d4')
      .attr('font-size', '11px')
      .text(`${branch.name} (${formatDuration(branch.duration)})`);

    // Tooltip on hover
    barGroup
      .on('mouseenter', (event) => {
        let tooltipHtml = `<div class="tt-label">Tool</div><div class="tt-value">${escapeHtml(branch.name)}</div>`;
        tooltipHtml += `<div class="tt-label">Duration</div><div class="tt-value">${formatDuration(branch.duration)}</div>`;
        if (isBottleneck) tooltipHtml += `<div class="tt-value" style="color:#f44747;">Bottleneck</div>`;
        if (branch.args) tooltipHtml += `<div class="tt-label">Args</div><div class="tt-value" style="font-size:11px;">${escapeHtml(truncate(JSON.stringify(branch.args), 120))}</div>`;
        if (branch.result) {
          const resultStr = typeof branch.result === 'string' ? branch.result : JSON.stringify(branch.result);
          tooltipHtml += `<div class="tt-label">Result</div><div class="tt-value" style="font-size:11px;">${escapeHtml(truncate(resultStr, 120))}</div>`;
        }
        showTooltip(tooltipHtml, event);
      })
      .on('mouseleave', () => hideTooltip());

    // Drill-in affordance for child agents
    if (branch.childTraceId) {
      barGroup.append('text')
        .attr('x', barX + barW + 4)
        .attr('y', y + barHeight / 2 + 4)
        .attr('fill', '#569cd6')
        .attr('font-size', '10px')
        .attr('cursor', 'pointer')
        .text('[Drill In]')
        .on('click', () => {
          const file = findFileByTraceId(state, branch.childTraceId);
          if (file) {
            import('./app.js').then(app => {
              const childData = app.getState().files.get(file);
              if (childData) {
                app.navigateTo({ type: 'agent', label: branch.name, data: childData });
              }
            });
          }
        });
    }
  });

  // Title
  svg.append('text')
    .attr('x', margin.left)
    .attr('y', 14)
    .attr('fill', '#808080')
    .attr('font-size', '11px')
    .text(`${parallelEvent.type} \u2014 ${count} branches, ${formatDuration(totalDuration)} total`);
}

function renderForkJoinFallback(container, branches, parallelEvent, maxDuration, totalDuration, count, state) {
  const type = parallelEvent.type || 'pmap';
  let html = `<div class="fork-join-fallback">
    <div class="fork-join-title">${escapeHtml(type)} \u2014 ${count} branches, ${formatDuration(totalDuration)} total</div>`;

  for (const branch of branches) {
    const isBottleneck = branch.duration === maxDuration && branches.length > 1;
    const widthPct = maxDuration > 0 ? Math.max((branch.duration / maxDuration) * 100, 2) : 50;

    html += `<div class="fork-join-fallback-row">
      <span class="fork-join-fallback-label">${escapeHtml(branch.name)}</span>
      <div class="fork-join-fallback-bar-bg">
        <div class="fork-join-fallback-bar ${isBottleneck ? 'bottleneck' : ''}" style="width: ${widthPct}%"></div>
      </div>
      <span class="fork-join-fallback-dur">${formatDuration(branch.duration)}</span>
    </div>`;
  }

  html += '</div>';
  container.innerHTML = html;
}

function findFileByTraceId(state, traceId) {
  for (const [name, data] of state.files) {
    if (data.traceId === traceId) return name;
  }
  return null;
}
