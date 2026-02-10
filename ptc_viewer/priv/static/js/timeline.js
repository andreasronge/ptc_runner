import { formatDuration } from './utils.js';
import { getEarliestTimestamp } from './parser.js';

export function renderTimeline(container, paired, totalDurationMs) {
  container.innerHTML = '';
  if (!totalDurationMs) return;

  const startTs = getEarliestTimestamp(paired);

  for (const pair of paired) {
    if (!['llm', 'tool', 'pmap', 'pcalls', 'task'].includes(pair.type)) continue;
    const duration = pair.stop?.duration_ms || 0;
    if (duration === 0) continue;

    // Calculate position based on timestamps if available
    let left = 0;
    if (pair.start?.timestamp && startTs) {
      const eventStart = new Date(pair.start.timestamp).getTime();
      const offsetMs = eventStart - startTs;
      left = (offsetMs / totalDurationMs) * 100;
    }

    const width = (duration / totalDurationMs) * 100;

    const segment = document.createElement('div');
    segment.className = `timeline-segment ${pair.type}`;
    segment.style.left = `${Math.max(0, left)}%`;
    segment.style.width = `${Math.max(width, 1)}%`;
    segment.textContent = pair.type === 'llm' ? `T${pair.stop?.metadata?.turn || '?'}` :
      pair.type === 'task' ? (pair.stop?.metadata?.task_id || pair.start?.metadata?.task_id || 'task') : pair.type;
    segment.title = `${pair.type}: ${formatDuration(duration)}`;
    container.appendChild(segment);
  }
}
