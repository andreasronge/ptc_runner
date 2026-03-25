export function parseJsonl(text) {
  return text.trim().split('\n').filter(l => l.trim()).map(line => {
    try { return JSON.parse(line); } catch { return null; }
  }).filter(Boolean);
}

export function pairEvents(events) {
  const pairs = [];
  const pending = {};

  for (const event of events) {
    if (!event.event) continue;
    const [type, action] = event.event.split('.');

    // Use span_id for pairing (most reliable), fallback to type+turn/tool_name
    const spanId = event.span_id;
    const key = spanId ? `${type}-${spanId}` :
      `${type}-${event.task_id || event.turn || event.tool_name || ''}`;

    if (action === 'start') {
      pending[key] = event;
    } else if (action === 'stop') {
      const startEvent = pending[key];
      if (startEvent) {
        pairs.push({ type, start: startEvent, stop: event });
        delete pending[key];
      } else {
        // No matching start - create a stop-only pair for display
        pairs.push({ type, start: null, stop: event });
      }
    }
  }

  // Surface unpaired start events (e.g., from truncated/crashed traces)
  for (const [key, startEvent] of Object.entries(pending)) {
    const type = key.split('-')[0];
    pairs.push({ type, start: startEvent, stop: null });
  }

  return pairs;
}

export function buildSpanTree(events) {
  const spans = new Map();
  const roots = [];

  for (const event of events) {
    if (!event.span_id) continue;
    if (!spans.has(event.span_id)) {
      spans.set(event.span_id, { id: event.span_id, events: [], children: [] });
    }
    spans.get(event.span_id).events.push(event);
  }

  for (const [id, span] of spans) {
    const parentId = span.events.find(e => e.parent_span_id)?.parent_span_id;
    if (parentId && spans.has(parentId)) {
      spans.get(parentId).children.push(span);
    } else {
      roots.push(span);
    }
  }

  return roots;
}

export function extractTraceId(events) {
  return events.find(e => e.event === 'trace.start')?.trace_id || 'unknown';
}

export function extractChildTraceIds(events) {
  const ids = new Set();
  for (const e of events) {
    (e.child_trace_ids || []).forEach(id => ids.add(id));
    if (e.child_trace_id) ids.add(e.child_trace_id);
    (e.data?.child_trace_ids || []).forEach(id => ids.add(id));
    if (e.data?.child_trace_id) ids.add(e.data.child_trace_id);
  }
  return [...ids];
}

export function extractThinking(response) {
  if (!response) return '';
  const match = response.match(/thinking:\s*([\s\S]*?)(?=```|$)/i);
  return match ? match[1].trim() : '';
}

export function extractProgram(response) {
  if (!response) return '';
  const match = response.match(/```clojure\n([\s\S]*?)```/);
  return match ? match[1].trim() : '';
}

export function getLastUserMessage(messages) {
  if (!messages) return '';
  const userMsgs = messages.filter(m => m.role === 'user');
  return userMsgs.length > 0 ? userMsgs[userMsgs.length - 1].content : '';
}

// Extract all events belonging to a specific run (by span_id),
// including all descendant spans (turn, llm, tool events under this run)
export function extractRunEvents(events, runSpanId) {
  // Build the set of all descendant span_ids
  const spanIds = new Set([runSpanId]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const e of events) {
      if (e.parent_span_id && spanIds.has(e.parent_span_id) && e.span_id && !spanIds.has(e.span_id)) {
        spanIds.add(e.span_id);
        changed = true;
      }
    }
  }
  return events.filter(e => spanIds.has(e.span_id));
}

export function getEarliestTimestamp(pairs) {
  let earliest = null;
  for (const pair of pairs) {
    if (pair.start?.timestamp) {
      const ts = new Date(pair.start.timestamp).getTime();
      if (!earliest || ts < earliest) earliest = ts;
    }
  }
  return earliest;
}
