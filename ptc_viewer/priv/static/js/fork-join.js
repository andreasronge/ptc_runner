import { formatDuration, escapeHtml, truncate, findFileByTraceId } from './utils.js';
import { showTooltip, hideTooltip } from './tooltip.js';

export function renderForkJoin(container, parallelEvent, state, data) {
  const stop = parallelEvent.stop;
  const start = parallelEvent.start;
  if (!stop) return;

  const count = stop.metadata?.count || 0;
  const results = stop.metadata?.results || [];
  const durations = stop.metadata?.durations || [];
  const totalDuration = stop.duration_ms || 0;

  // Compute the actual time window for finding child tool events.
  // pmap events are emitted post-hoc (after sandbox returns), so use
  // stop.timestamp - duration_ms to get the real execution start time.
  const stopTime = stop?.timestamp ? new Date(stop.timestamp).getTime() : Infinity;
  const startTime = (stopTime !== Infinity && totalDuration > 0)
    ? stopTime - totalDuration
    : (start?.timestamp ? new Date(start.timestamp).getTime() : 0);

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
        startTime: toolStart?.timestamp ? new Date(toolStart.timestamp).getTime() : 0,
        stopTime: toolStop.timestamp ? new Date(toolStop.timestamp).getTime() : 0,
        args: toolStart?.metadata?.args,
        result: toolStop.metadata?.result,
        childTraceId: toolStop.metadata?.child_trace_id,
        toolSpanId: toolStop.span_id
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
  const minDuration = Math.min(...branches.map(b => b.duration));
  const maxBranchDuration = maxDuration || totalDuration || 1;

  // Compute stats
  const sortedDurations = branches.map(b => b.duration).sort((a, b) => a - b);
  const medianDuration = sortedDurations[Math.floor(sortedDurations.length / 2)];

  // Check if D3 is available
  if (typeof d3 === 'undefined') {
    renderForkJoinFallback(container, branches, parallelEvent, maxDuration, totalDuration, count, state);
    return;
  }

  // Use Gantt timeline when we have actual timestamps and many branches
  const hasTimestamps = branches.some(b => b.startTime && b.stopTime);
  const compact = branches.length > 8;

  if (compact && hasTimestamps) {
    renderGanttTimeline(container, branches, parallelEvent, state, data, {
      count, totalDuration, maxDuration, minDuration, medianDuration
    });
  } else {
    renderForkJoinD3(container, branches, parallelEvent, state, data, {
      count, totalDuration, maxDuration, maxBranchDuration, compact
    });
  }
}

function renderGanttTimeline(container, branches, parallelEvent, state, data, stats) {
  const { count, totalDuration, maxDuration, minDuration, medianDuration } = stats;

  // Sort by start time to show real execution order
  branches.sort((a, b) => a.startTime - b.startTime);

  const timelineStart = Math.min(...branches.map(b => b.startTime));
  const timelineEnd = Math.max(...branches.map(b => b.stopTime));
  const timelineSpan = timelineEnd - timelineStart || 1;

  const barHeight = 14;
  const barGap = 2;
  const margin = { top: 44, right: 20, bottom: 24, left: 20 };
  const width = Math.max(400, container.clientWidth - margin.left - margin.right);
  const innerWidth = width - margin.left - margin.right;
  const barsHeight = branches.length * (barHeight + barGap);
  const height = margin.top + margin.bottom + barsHeight;

  const svg = d3.select(container)
    .append('svg')
    .attr('width', width)
    .attr('height', height)
    .attr('class', 'fork-join-svg');

  const g = svg.append('g')
    .attr('transform', `translate(${margin.left}, ${margin.top})`);

  const xScale = d3.scaleLinear()
    .domain([0, timelineSpan])
    .range([0, innerWidth]);

  // Time axis ticks
  const tickCount = Math.min(6, Math.floor(innerWidth / 80));
  const tickInterval = timelineSpan / tickCount;
  for (let i = 0; i <= tickCount; i++) {
    const x = xScale(i * tickInterval);
    g.append('line')
      .attr('x1', x).attr('y1', -4)
      .attr('x2', x).attr('y2', barsHeight)
      .attr('stroke', '#2a2a2a').attr('stroke-width', 1);
    g.append('text')
      .attr('x', x).attr('y', barsHeight + 14)
      .attr('fill', '#606060').attr('font-size', '9px').attr('text-anchor', 'middle')
      .text(formatDuration(i * tickInterval));
  }

  branches.forEach((branch, i) => {
    const y = i * (barHeight + barGap);
    const barX = xScale(branch.startTime - timelineStart);
    const barW = Math.max(xScale(branch.duration), 3);
    const isBottleneck = branch.duration === maxDuration && branches.length > 1;

    const barGroup = g.append('g').attr('class', 'fork-join-bar');

    barGroup.append('rect')
      .attr('x', barX)
      .attr('y', y)
      .attr('width', barW)
      .attr('height', barHeight)
      .attr('rx', 2)
      .attr('fill', isBottleneck ? 'rgba(244, 71, 71, 0.4)' : 'rgba(86, 156, 214, 0.4)')
      .attr('stroke', isBottleneck ? '#f44747' : '#569cd6')
      .attr('stroke-width', isBottleneck ? 1.5 : 0.5);

    // Tooltip
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
        if (branch.childTraceId) tooltipHtml += `<div class="tt-value" style="color:#569cd6;">Click to drill in</div>`;
        showTooltip(tooltipHtml, event);
      })
      .on('mouseleave', () => hideTooltip());

    if (branch.childTraceId || branch.toolSpanId) {
      barGroup.attr('cursor', 'pointer')
        .on('click', () => drillIntoChild(state, branch, data));
    }
  });

  // Title line 1: summary
  svg.append('text')
    .attr('x', margin.left).attr('y', 14)
    .attr('fill', '#808080').attr('font-size', '11px')
    .text(`${parallelEvent.type} \u2014 ${count} branches, ${formatDuration(totalDuration)} wall clock`);

  // Title line 2: stats
  svg.append('text')
    .attr('x', margin.left).attr('y', 28)
    .attr('fill', '#808080').attr('font-size', '11px')
    .text(`min ${formatDuration(minDuration)} / median ${formatDuration(medianDuration)} / max ${formatDuration(maxDuration)} (bottleneck)`);
}

function renderForkJoinD3(container, branches, parallelEvent, state, data, opts) {
  const { count, totalDuration, maxDuration, maxBranchDuration, compact } = opts;

  // Sort by duration for cleaner visualization
  branches.sort((a, b) => a.duration - b.duration);

  const barHeight = 28;
  const barGap = 6;
  const forkWidth = 40;
  const margin = { top: 20, right: 30, bottom: 10, left: 30 };
  const width = Math.max(400, container.clientWidth - margin.left - margin.right);
  const innerWidth = width - margin.left - margin.right - forkWidth * 2;
  const barsHeight = branches.length * (barHeight + barGap);
  const height = margin.top + margin.bottom + barsHeight;

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

  const forkX = 0;
  const joinX = forkWidth + innerWidth + forkWidth;
  const midY = (barsHeight - barGap) / 2;

  // Fork and join circles
  g.append('circle').attr('cx', forkX).attr('cy', midY).attr('r', 5).attr('fill', '#569cd6');
  g.append('circle').attr('cx', joinX).attr('cy', midY).attr('r', 5).attr('fill', '#569cd6');

  branches.forEach((branch, i) => {
    const y = i * (barHeight + barGap);
    const barX = forkWidth;
    const barW = Math.max(xScale(branch.duration), 4);
    const isBottleneck = branch.duration === maxDuration && branches.length > 1;

    // Fork/join lines
    g.append('line')
      .attr('x1', forkX).attr('y1', midY)
      .attr('x2', barX).attr('y2', y + barHeight / 2)
      .attr('stroke', '#3c3c3c').attr('stroke-width', 1.5);
    g.append('line')
      .attr('x1', barX + barW).attr('y1', y + barHeight / 2)
      .attr('x2', joinX).attr('y2', midY)
      .attr('stroke', '#3c3c3c').attr('stroke-width', 1.5);

    const barGroup = g.append('g').attr('class', 'fork-join-bar');

    barGroup.append('rect')
      .attr('x', barX).attr('y', y)
      .attr('width', barW).attr('height', barHeight)
      .attr('rx', 4)
      .attr('fill', isBottleneck ? 'rgba(244, 71, 71, 0.3)' : 'rgba(86, 156, 214, 0.3)')
      .attr('stroke', isBottleneck ? '#f44747' : '#569cd6')
      .attr('stroke-width', isBottleneck ? 2 : 1);

    barGroup.append('text')
      .attr('x', barX + 8).attr('y', y + barHeight / 2 + 4)
      .attr('fill', '#d4d4d4').attr('font-size', '11px')
      .text(`${branch.name} (${formatDuration(branch.duration)})`);

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
        if (branch.childTraceId || branch.toolSpanId) tooltipHtml += `<div class="tt-value" style="color:#569cd6;">Click to drill in</div>`;
        showTooltip(tooltipHtml, event);
      })
      .on('mouseleave', () => hideTooltip());

    if (branch.childTraceId || branch.toolSpanId) {
      barGroup.append('text')
        .attr('x', barX + barW + 4).attr('y', y + barHeight / 2 + 4)
        .attr('fill', '#569cd6').attr('font-size', '10px').attr('cursor', 'pointer')
        .text('[Drill In]')
        .on('click', () => drillIntoChild(state, branch, data));
    }
  });

  // Title
  svg.append('text')
    .attr('x', margin.left).attr('y', 14)
    .attr('fill', '#808080').attr('font-size', '11px')
    .text(`${parallelEvent.type} \u2014 ${count} branches, ${formatDuration(totalDuration)} total`);
}

function drillIntoChild(state, branch, data) {
  const file = findFileByTraceId(state, branch.childTraceId);
  if (file) {
    import('./app.js').then(app => {
      const childData = app.getState().files.get(file);
      if (childData) {
        app.navigateTo({ type: 'agent', label: branch.name, data: childData });
      }
    });
    return;
  }

  // Fallback: extract child run events from the current trace (embedded child traces)
  if (data?.events && branch.toolSpanId) {
    import('./parser.js').then(parser => {
      // Find the run.start whose parent_span_id is the tool's span_id
      const childRun = data.events.find(e =>
        e.event === 'run.start' && e.metadata?.parent_span_id === branch.toolSpanId
      );
      if (childRun) {
        const childEvents = parser.extractRunEvents(data.events, childRun.span_id);
        if (childEvents.length > 0) {
          import('./app.js').then(app => {
            app.navigateTo({
              type: 'agent',
              label: branch.name,
              data: { events: childEvents, filename: branch.name }
            });
          });
        }
      }
    });
  }
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

