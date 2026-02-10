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
      `${type}-${event.metadata?.task_id || event.metadata?.turn || event.metadata?.tool_name || ''}`;

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
    (e.metadata?.child_trace_ids || []).forEach(id => ids.add(id));
  }
  return [...ids];
}

export function extractPlanData(events) {
  // Look for plan.generated event or run.start with plan metadata
  const planGenerated = events.find(e => e.event === 'plan.generated');
  const runStart = events.find(e => e.event === 'run.start');

  let plan = null;
  let mission = null;
  let agents = null;

  // Primary source: plan.generated event from PlanExecutor
  if (planGenerated?.metadata) {
    plan = planGenerated.metadata.plan;
    mission = planGenerated.metadata.mission;
  }

  // Fallback: run.start metadata (for SubAgent runs)
  if (!mission && runStart?.metadata?.agent) {
    const agentMeta = runStart.metadata.agent;
    mission = agentMeta.prompt || agentMeta.mission;
    if (!plan && agentMeta.plan && typeof agentMeta.plan === 'object') {
      plan = agentMeta.plan;
    }
  }

  // Extract from trace.start meta
  const traceStart = events.find(e => e.event === 'trace.start');
  if (!mission && traceStart?.meta?.mission) {
    mission = traceStart.meta.mission;
  }

  // Last resort: scan all events for plan-like structures
  if (!plan) {
    for (const event of events) {
      const meta = event.metadata || {};
      if (meta.tasks && Array.isArray(meta.tasks)) {
        plan = { tasks: meta.tasks, agents: meta.agents };
        break;
      }
      if (meta.plan?.tasks) {
        plan = meta.plan;
        break;
      }
    }
  }

  return { plan, mission, agents };
}

export function detectTraceType(events) {
  const hasPlan = events.some(e => e.event === 'plan.generated' || e.event === 'execution.start');
  return hasPlan ? 'plan' : 'agent';
}

export function buildExecutionAttempts(events) {
  const planEvt = events.find(e => e.event === 'plan.generated');
  const execStart = events.find(e => e.event === 'execution.start');
  if (!planEvt?.metadata?.plan?.tasks) return [];

  const agents = planEvt.metadata.plan.agents || {};

  // Collect all replan boundaries
  const replanStarts = events.filter(e => e.event === 'replan.start');
  const replanStops = events.filter(e => e.event === 'replan.stop');

  // Collect all task.start / task.stop events with timestamps
  const allTaskStarts = events.filter(e => e.event === 'task.start');
  const allTaskStops = events.filter(e => e.event === 'task.stop');

  // Helper: group task events by time window
  function taskEventsInWindow(startTime, endTime) {
    const starts = {};
    const stops = {};
    for (const e of allTaskStarts) {
      const t = new Date(e.timestamp).getTime();
      if (t >= startTime && t < endTime && e.metadata?.task_id) {
        starts[e.metadata.task_id] = e;
      }
    }
    for (const e of allTaskStops) {
      const t = new Date(e.timestamp).getTime();
      if (t >= startTime && t < endTime && e.metadata?.task_id) {
        stops[e.metadata.task_id] = e;
      }
    }
    return { starts, stops };
  }

  const attempts = [];

  if (replanStarts.length === 0) {
    // Single attempt
    const taskStarts = {};
    const taskStops = {};
    for (const e of allTaskStarts) if (e.metadata?.task_id) taskStarts[e.metadata.task_id] = e;
    for (const e of allTaskStops) if (e.metadata?.task_id) taskStops[e.metadata.task_id] = e;

    const model = buildExecutionModel(
      planEvt.metadata.plan.tasks,
      execStart?.metadata?.phases || [],
      agents,
      taskStarts,
      taskStops
    );
    if (model) attempts.push({ label: 'Plan', model });
    return attempts;
  }

  // Multiple attempts - split at replan boundaries
  const execStartTime = execStart ? new Date(execStart.timestamp).getTime() : 0;
  const firstReplanTime = new Date(replanStarts[0].timestamp).getTime();
  const a0Events = taskEventsInWindow(execStartTime, firstReplanTime);

  const initialModel = buildExecutionModel(
    planEvt.metadata.plan.tasks,
    execStart?.metadata?.phases || [],
    agents,
    a0Events.starts,
    a0Events.stops
  );
  if (initialModel) attempts.push({ label: 'Initial Plan', model: initialModel });

  // Replan attempts
  for (let i = 0; i < replanStarts.length; i++) {
    const rpStart = replanStarts[i];
    const rpStop = replanStops[i];
    if (!rpStop) continue;

    const triggerTaskId = rpStart.metadata?.task_id || '';
    const diagnosis = rpStart.metadata?.diagnosis || '';

    const windowStart = new Date(rpStop.timestamp).getTime();
    const windowEnd = replanStarts[i + 1]
      ? new Date(replanStarts[i + 1].timestamp).getTime()
      : Infinity;

    const segEvents = taskEventsInWindow(windowStart, windowEnd);

    const repairTasks = Object.values(segEvents.starts).map(e => {
      const taskDef = e.metadata?.task || {};
      return {
        id: e.metadata?.task_id || taskDef.id,
        agent: e.metadata?.agent || taskDef.agent || '',
        depends_on: taskDef.depends_on || [],
        type: taskDef.type || 'task',
        output: taskDef.output || null,
        input: e.metadata?.input || taskDef.input || '',
        signature: taskDef.signature || '',
        quality_gate: taskDef.quality_gate ?? null
      };
    });

    if (repairTasks.length === 0) continue;

    const model = buildExecutionModel(repairTasks, [], agents, segEvents.starts, segEvents.stops);
    if (model) {
      attempts.push({
        label: `Replan ${i + 1}`,
        model,
        triggerTaskId,
        diagnosis
      });
    }
  }

  return attempts;
}

export function buildExecutionModel(planTasks, phases, agents, taskStarts, taskStops) {
  // Compute phases from dependency graph if not provided
  let phaseMap = {};
  if (phases.length > 0) {
    for (const p of phases) {
      for (const tid of p.task_ids) phaseMap[tid] = p.phase;
    }
  } else {
    // Topological sort fallback
    const taskIds = new Set(planTasks.map(t => t.id));
    const resolved = new Set();
    let phase = 0;
    const remaining = [...planTasks];
    while (remaining.length > 0) {
      const batch = remaining.filter(t =>
        (t.depends_on || []).every(d => resolved.has(d) || !taskIds.has(d))
      );
      if (batch.length === 0) break;
      for (const t of batch) { phaseMap[t.id] = phase; resolved.add(t.id); }
      remaining.splice(0, remaining.length, ...remaining.filter(t => !resolved.has(t.id)));
      phase++;
    }
  }

  const tasks = planTasks.map(t => {
    const stopEvt = taskStops[t.id];
    const startEvt = taskStarts[t.id];
    return {
      id: t.id,
      agent: t.agent || '',
      phase: phaseMap[t.id] ?? 0,
      type: t.type || 'task',
      outputMode: startEvt?.metadata?.task?.output || t.output || null,
      status: stopEvt?.metadata?.status || (startEvt ? 'running' : 'pending'),
      durationMs: stopEvt?.duration_ms || stopEvt?.metadata?.duration_ms || 0,
      dependsOn: t.depends_on || [],
      input: t.input || '',
      signature: t.signature || '',
      qualityGate: t.quality_gate ?? null
    };
  });

  const edges = [];
  for (const t of tasks) {
    for (const dep of t.dependsOn) {
      edges.push({ from: dep, to: t.id });
    }
  }

  // Build phases array
  const phaseGroups = {};
  for (const t of tasks) {
    if (!phaseGroups[t.phase]) phaseGroups[t.phase] = [];
    phaseGroups[t.phase].push(t.id);
  }
  const sortedPhases = Object.keys(phaseGroups).sort((a, b) => a - b).map(p => ({
    phase: parseInt(p),
    taskIds: phaseGroups[p]
  }));

  return { tasks, phases: sortedPhases, agents, edges };
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

// Find the run span_id that corresponds to a given task_id
// by matching run context.input to task.start metadata.input
export function findRunForTask(events, taskId) {
  const taskStart = events.find(e => e.event === 'task.start' && e.metadata?.task_id === taskId);
  if (!taskStart) return null;
  const taskInput = taskStart.metadata?.input;

  const runStarts = events.filter(e => e.event === 'run.start');
  // Try matching by context.input
  if (taskInput) {
    for (const run of runStarts) {
      const runInput = run.metadata?.context?.input;
      if (runInput && runInput === taskInput) return run.span_id;
    }
  }

  // Fallback: match by agent name in the prompt
  const agentName = taskStart.metadata?.agent;
  if (agentName) {
    for (const run of runStarts) {
      const prompt = run.metadata?.agent?.prompt || '';
      const name = run.metadata?.agent?.name;
      if (name === agentName) return run.span_id;
    }
  }

  return null;
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
