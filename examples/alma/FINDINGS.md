# ALMA Findings

Based on trace analysis of multiple benchmark runs (most recent: `alma_1771567110.jsonl`).

Config: bedrock:haiku (meta), groq:gpt-oss (task), 5 generations, 3 episodes, 8 rooms.

---

## Core Problem: Memory Adds No Value

Baseline score (no memory): **0.43**. Best design score: **0.07 normalized** (0.50 raw).
The memory system barely outperforms random chance improvement. Most designs score
at or below baseline.

The fundamental issue: **recall never returns cross-episode knowledge**. Every recall
output is either goal-restating text or a generic fallback. The `mem-update` function
stores data that the `recall` function then fails to retrieve or format correctly.

---

## Finding 1: All Designs Converge to the Same Pattern

Across all runs (9+ designs analyzed), every design follows this identical template:

**mem-update** (40-80 lines): Parse observations → build spatial map with `defonce` +
`assoc` → track object locations → record search history.

**recall** (10-20 lines): Deterministic cond/if chain:
```
if has_object_in_inventory → "Deliver X to room_Y"
else if know_object_location → "Get X from room_Z, deliver to room_Y"
else if have_unexplored_rooms → "Search for X in room_W"
else → "Explore to find X"
```

No design uses `tool/find-similar`, `tool/graph-path`, or any injected tool.
The meta-agent builds its own in-memory data structures (`defonce spatial-map {}`,
`defonce object-locations {}`) rather than using the provided vector/graph stores.

---

## Finding 2: Haiku Cannot Write Correct PTC-Lisp

Across runs, ~30% of design attempts fail the examine step:

- **Type errors**: `filter: invalid argument types: function, nil`
- **Trivial output**: recall returning `"look()"` (6 chars)
- **Broken interpolation**: `"Explore to find ."` (missing object name),
  `"Already completed -> before."` (missing variables)
- **Wrong key access**: `(:task_type data/task)` when key doesn't exist → nil bucketing

Even "successful" designs have subtle bugs that only manifest at runtime. Haiku
struggles with PTC-Lisp's Clojure-like syntax, particularly `defonce` state
management and string interpolation.

---

## Finding 3: Recall Advice Is Not Actionable

Analysis of 35+ recall outputs:

| Category | % | Example |
|---|---|---|
| Generic/vague | 63% | "Search for X in unexplored rooms" |
| Specific (names a room) | 20% | "Try moving to room_A to search for potion" |
| Trivial (raw command) | 9% | "move_to(room_A)", "look()" |
| Broken/empty | 8% | "", "Explore to find ." |

The advice never contains actual learned spatial knowledge like "potion was found
in room_B" or "room_A connects to room_E via room_H". It restates information the
task agent already has from the goal description.

---

## Finding 4: Task Agent Navigation Errors

The task model (groq:gpt-oss) makes systematic errors:

- **13 "not adjacent" errors** per run — agent tries to move to rooms not connected
  to current location, wasting steps
- **"Max steps exceeded"** — 18 occurrences where episodes exhaust the 15-turn budget
- **move_to return misread** — agents do `(:location (tool/move_to ...))` expecting a
  state map, get nil, waste turns recovering with extra `look` calls

---

## Finding 5: No Evolutionary Diversity

Despite analyst critiques correctly identifying weaknesses (stale data, no task
progress tracking, generic fallbacks), the meta-model produces incremental variations
rather than fundamentally different approaches. Every design is a variant of
"track rooms + track objects + format advice string."

The analyst feedback loop works (critiques are specific and accurate) but haiku
cannot act on them to produce structurally different designs.

---

## Finding 6: Timing Profile

- **54% of time** in LLM calls (meta: ~11s/call, task: ~1.2s/call)
- **Environment tools** are essentially free (<3ms each)
- **690s total** for 5 generations (11.5 minutes)
- Deployment runs in parallel (3 seeds concurrent)

---

## Recommended Fixes

### Priority 1: Templatize Recall

Since recall always degenerates to the same 4-case cond, replace arbitrary Lisp with
a structured template. The meta-agent populates fields, the system formats advice:

```yaml
recall:
  priority_cases:
    - when: object_in_inventory
      advice: "Deliver {object} to {destination}"
    - when: object_location_known
      advice: "Get {object} from {location}, deliver to {destination}"
    - when: unexplored_rooms_exist
      advice: "Search for {object} in {next_unexplored}"
    - fallback: "Explore to find {object}"
```

This eliminates recall bugs entirely and frees the meta-agent to focus on mem-update.

### Priority 2: Require Tool Usage in mem-update

Change from "tools available" to "designs MUST use `tool/store-obs` and
`tool/graph-update`". This forces use of the vector/graph stores (which persist
and support similarity search) rather than reinventing them with `defonce` maps.

A structured contract:
```
mem-update must:
  1. Call store-obs with extracted spatial/object facts
  2. Call graph-update with room connectivity edges
  3. Optionally call summarize/analyze for higher-level patterns
```

### Priority 3: Simplify the Design Space

Instead of "write arbitrary Lisp for both mem-update and recall", constrain the
meta-agent to choose **parameters**:
- What observations to extract (object locations, room connections, action outcomes)
- What to store (which collections, what metadata)
- How to query at recall time (similarity threshold, which collections)

This reduces the design space from "arbitrary code" to "configuration choices" and
eliminates the PTC-Lisp correctness problem.

### Priority 4: Upgrade Meta-Model (if keeping free-form Lisp)

If the free-form Lisp approach is kept, upgrade from haiku to sonnet. Sonnet would
likely:
- Write correct PTC-Lisp more consistently
- Discover that `find-similar` enables generalization across tasks with different
  room names (which `defonce` maps cannot do)
- Produce more structurally diverse designs

But this is more expensive and may still converge to the same local optimum.

### Priority 5: Improve Task Agent Robustness

- Add verification: "call `look` after `put_down` to confirm success"
- Handle `move_to` return format correctly in prompt examples
- Consider increasing max_turns or adding navigation error recovery hints

---

## What Works Well

1. **Static analysis** catches bugs before side effects — `defonce` errors are caught
   cleanly, the meta-agent can retry without partial state
2. **Self-correction** — meta-agent recovers from errors in subsequent turns
3. **Examine step** correctly rejects trivial/broken designs (e.g., "look()" advice)
4. **Parallel deployment** — 3 seeds run concurrently, good resource utilization
5. **Trace system** provides full visibility into every LLM call and tool execution
6. **Sandbox isolation** works — no process crashes or heap overflows in task agents
   (after the trace sanitizer fix)
