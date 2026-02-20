# ALMA Debug Agent — Implementation Plan

## Problem Statement

ALMA's evolutionary loop generates memory designs (mem-update + recall functions)
but the meta-agent has **no visibility into what actually happened at runtime**.
It sees parent source code, scores, metrics, and 2 compressed sample episodes —
but never:

- What the vector store and graph store actually contain after collection
- What `tool/find-similar` and `tool/graph-path` returned inside recall
- Whether store-obs/graph-update were called correctly in mem-update
- Why the task agent failed (e.g., "moved to room_E but it's not adjacent")
- Whether recall advice was actually used by the task agent

This means the meta-agent designs improvements **blindly** — it reads the source
code and guesses what went wrong, rather than seeing evidence. The analyst (current
implementation) has the same limitation: it's a plain LLM call that reads source +
metrics but can't inspect runtime state.

**Result**: all designs converge to the same pattern because the meta-agent lacks
the diagnostic information needed to identify and fix specific failure modes.
The feedback loop is broken — scores go in, but root causes don't.

### Example of the Gap

A design's recall calls `(tool/graph-path {"from" start "to" dest})` and gets
`nil` because the graph only has 6 edges after 3 episodes. The meta-agent never
learns this. It sees "score: 0.35" and the recall source code, but not:

```
[tool] graph-path("room_A" -> "room_E") -> nil
[log] no path found, graph has only 6 edges
[advice] "horn in room_B (path unavailable)"
```

With this log visible, the meta-agent (or a debug agent) could identify: "the
graph is too sparse — recall should fall back to graph-neighbors for partial
connectivity info when graph-path returns nil."

## Solution: Logging + Debug Agent

### Core Idea

1. **Memory designs emit log messages** using `(println ...)` — like `logger.info`
   in application code. The meta-agent is encouraged to add logging when writing
   mem-update and recall.

2. **The system captures logs + tool calls** from mem-update/recall execution
   (currently discarded by memory_harness.ex).

3. **A debug agent** (PTC-Lisp SubAgent with `builtin_tools: [:grep]`) analyzes
   the combined log after evaluation — grepping through it like a developer
   debugging a log file.

4. **Debug agent findings** feed into the meta-agent context for the next
   iteration, replacing the current Analyst.

### Why Grep?

The evaluation log can be large (hundreds of lines across episodes). The debug
agent doesn't need to see all of it — it needs to search for patterns:

- `grep "graph-path.*nil"` — find failed pathfinding calls
- `grep "FAILED"` — find failed episodes
- `grep "not adjacent"` — find navigation errors
- `grep "store-obs"` — verify mem-update is storing data
- `grep "find-similar.*\[\]"` — find empty search results

This matches how developers actually debug: scan logs for error patterns, then
read context around the matches. The `:grep` builtin already exists in
PtcRunner's SubAgent.

### Trace Integration

The logs should also be visible in ptc-viewer via the existing trace system.
Mem-update and recall already run inside `Alma.Trace.span` wrappers, so inner
tool calls already emit telemetry. Adding println output as trace events makes
the full execution visible in the viewer.

## Implementation Phases

### Phase 1: Capture prints and tool_calls in memory_harness

**Goal**: Stop discarding diagnostic data from mem-update/recall Lisp.run calls.

**Changes**:

- `memory_harness.ex` — `run_with_tools/5` and `run_with_shared_agents/6`
  already get `step` back from `Lisp.run`. Capture `step.prints` and
  `step.tool_calls` and return them alongside existing results.
- `retrieve/4` — return `{advice, prints, tool_calls, error}` instead of
  `{advice, error}`
- `update/4` — return `{memory, prints, tool_calls, error}` instead of
  `{memory, error}`
- `evaluate_collection/3` and `evaluate_deployment/4` — attach prints and
  tool_calls to each episode result
- Emit trace events for println output so ptc-viewer can display them

**Testing**: Run `mix alma.smoke`, verify that prints and tool_calls appear in
results. Inspect trace file to confirm visibility.

### Phase 2: Generate test fixtures from a real run

**Goal**: Produce realistic evaluation data for testing the debug agent.

**Changes**:

- Run a small benchmark (2-3 generations, 3 episodes) with the Phase 1 changes
- Save the archive entry data (including prints, tool_calls, store contents,
  task agent results) as a test fixture
- Alternatively: write a mix task or script that runs evaluation and dumps the
  structured data to a file

**Deliverable**: A fixture file containing real mem-update/recall logs, tool
calls, store contents, and task agent trajectories from LLM-generated designs.

### Phase 3: Build DebugLog formatter and debug agent

**Goal**: Format evaluation data into a greppable log and test the debug agent.

**Changes**:

- New `Alma.DebugLog` module — takes an archive entry (with the new prints/
  tool_calls data) and produces a structured text log:

  ```
  === VECTOR STORE (12 entries) ===
  [1] collection=objects "horn seen in room_B" metadata={item:horn, room:room_B}
  ...

  === GRAPH STORE (6 nodes, 8 edges) ===
  room_A -> [room_B, room_D]
  ...

  === EPISODE 1: collection (SUCCESS, 3 steps) ===
  --- mem-update ---
  [log] processing 4 observations
  [tool] store-obs({"text":"visited room_A"}) -> "stored:1"
  [tool] graph-update({"edges":[["room_A","room_B"]]}) -> "ok"
  --- recall ---
  [tool] find-similar({"query":"horn","k":3}) -> [{text:"horn in room_B",score:0.9}]
  [tool] graph-path({"from":"room_C","to":"room_E"}) -> nil
  [log] no path found, using direct advice
  [advice] "horn seen in room_B, deliver to room_E"
  --- task-agent ---
  [1] recall -> "horn seen in room_B, deliver to room_E"
  [2] look -> {location:room_C, exits:[room_A,room_D], objects:[]}
  [3] move_to(room_A) -> ok
  ...

  === EPISODE 2: collection (FAILED, 8 steps) ===
  ...
  ```

- New debug agent — SubAgent with:
  - `builtin_tools: [:grep]`
  - The log text provided as context
  - Prompt: "Investigate why this memory design scored poorly. Use grep to
    search the evaluation log. Report specific findings about store contents,
    recall behavior, and task agent outcomes."

- Test with fixture data from Phase 2: does the debug agent find real issues?
  Does grep work at this log size? Are the findings actionable?

**Testing**: E2E test with real LLM — give the debug agent the fixture log,
verify it produces useful analysis.

### Phase 4: Wire into the ALMA loop

**Goal**: Replace the Analyst with the debug agent in the evolutionary loop.

**Changes**:

- `loop.ex` — after evaluation, build the debug log from the archive entry
  and run the debug agent
- `meta_agent.ex` — receive debug agent findings as context (replacing
  analyst_critique)
- Remove or simplify `analyst.ex`
- Update meta-agent prompt to encourage `(println ...)` logging:
  "Add logging statements in your mem-update and recall functions. A debug
  agent analyzes these logs to provide feedback for future improvements."

**Testing**: Run full benchmark, compare design quality and diversity against
the current Analyst-based approach.

## Open Questions

1. **Log size**: With 3+ episodes, the log could be 500+ lines. Is grep
   sufficient or do we need pagination / summarization?

2. **println adoption**: Will the LLM actually add println statements if
   encouraged? Need to verify with haiku and sonnet.

3. **Debug agent model**: Should the debug agent use the same model as the
   meta-agent (haiku) or a different one? Grep-based analysis might work
   fine with haiku since it's more about pattern matching than code generation.

4. **Store snapshots**: Should we include full store contents in the log or
   just summary stats (entry count, node count)? Full contents are more
   useful but add log size.

5. **Recall tool call capture in deployment**: During deployment, recall runs
   concurrently with shared store agents. Need to verify that tool_calls are
   still captured correctly per-task in the concurrent case.
