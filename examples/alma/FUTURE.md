# ALMA — Future Improvements

## Avoiding "cheating"

The MetaAgent prompt must stay domain-blind. When ALMA underperforms, the temptation is to hardcode the solution (e.g., "store object locations", "use tool/store-obs"). Instead:

- **Let the Analyst discover insights** — the Analyst LLM critiques parent designs from trajectory evidence. It should identify what to improve; the MetaAgent decides how.
- **Document tools, not strategies** — the system prompt shows tool signatures and PTC-Lisp syntax. It should never prescribe *what* to store or *how* to use the tools.
- **Increase evolutionary pressure** — more iterations, more episodes, and multi-seed deployment scoring give the loop enough signal to select good designs without manual nudging.

## Benchmarking

The [original ALMA paper](https://arxiv.org/abs/2602.07755) evaluates on ALFWorld, TextWorld, Baba Is AI, and MiniHack. Our GraphWorld is simpler, so direct score comparison is not meaningful.

- **Implement ALFWorld** as an `Environment` behaviour — text-based household tasks, structurally similar to GraphWorld but richer. Wrap the [Python ALFWorld API](https://github.com/alfworld/alfworld) via a Port or HTTP bridge.
- **Scale up GraphWorld** — more rooms (8+), more objects (6+), lower connectivity (0.3), multi-step goals. Compare convergence curves against the paper's charts.
- **Compare architecture efficiency** — measure LLM calls, tokens, and wall-clock time per iteration. The paper's meta-agent does ideation + programming + verification (3 LLM calls minimum, up to 9 with debug retries). Our SubAgent typically does 1-3 turns.

## MemoryArena-Inspired Improvements

The [MemoryArena paper](https://arxiv.org/abs/2602.16313) benchmarks agent memory in multi-session interdependent agentic tasks. It formalizes a Memory-Agent-Environment loop with two abstract functions — `retrieve` and `update` — mapping directly to ALMA's `recall` and `mem-update`. Key findings that expose gaps in our current benchmark.

See [FINDINGS.md](FINDINGS.md) for trace-level evidence of the problems described below.

### Representation mismatch (current blocker)

MemoryArena finds that RAG-based memory often hurts because compressed/reordered information doesn't align with how the task agent reasons. We see exactly this: the n-gram VectorStore produces near-random similarity scores (0.17-0.22) for object queries, causing recall to confidently report wrong item locations. The task agent trusts this advice and wastes turns navigating to empty rooms.

This is the single highest-priority fix. Two paths:

- **Real embeddings** — swap the n-gram embedder for a real embedding API (OpenAI, Bedrock, or local Bumblebee model). The `VectorStore` interface stays the same; only `embed/1` changes. This would make `find-similar` actually distinguish "key" from "torch".
- **Lean on the graph store** — the graph store works correctly today. Designs that use `graph-path` for spatial navigation and avoid `find-similar` for item lookup would sidestep the embedding quality problem entirely. The evolutionary loop should discover this given enough iterations, but the DebugAgent could accelerate it by flagging low similarity scores as unreliable.

### Recall format as part of the design space

The MemoryArena representation mismatch finding also applies to recall *format*. Currently recall returns prose ("key is in room_F"), which a cheap model may misinterpret or ignore. Structured formats — action lists like `["move_to room_B", "pick_up key"]` — are easier for weak models to follow mechanically.

The evolutionary loop currently optimizes *what* to recall but not *how to format it for consumption*. Making the task agent prompt reward structured advice (e.g., "If recall returns a step-by-step plan, execute it exactly") would create selection pressure for better recall formats.

### Stale cross-episode data

Object placement is randomized per episode, but the vector store accumulates across all episodes. "Key found in room_F" from episode 2 gets recalled in episode 8 where key is in room_C. This makes item-location memories actively harmful across episodes, while graph topology (room connections) is stable within a family and genuinely useful.

The evolutionary loop needs to discover this distinction. MemoryArena's interdependent task chains (below) would make this more explicit by requiring designs to distinguish stable knowledge from ephemeral state.

### Interdependent task chains

MemoryArena's core insight: later subtasks *causally depend* on earlier ones (e.g., buy a camera body first, then a compatible lens). Currently ALMA's GraphWorld episodes are independent — each is a fresh navigate-and-fetch task. Memory helps with spatial layout, but there's no causal dependency chain between episodes.

- **Add task chains** where episode N depends on information gathered in episode N-1. For example: "find the key in episode 1" → "use the key to unlock the vault in episode 2" → "retrieve the gem from the vault in episode 3."
- This tests whether evolved memory designs can track *state* across episodes, not just spatial knowledge.
- Task chains would also make the stale-data problem more visible: designs must distinguish "key is in room_F (this episode)" from "key was in room_F (last episode)."

### Performance decay at depth (belief drift)

All methods in MemoryArena — long-context, RAG, external memory — exhibit monotonic decay in success rate as subtask depth increases. Small errors in implicit state estimates compound across sessions.

- **Measure SR@k** (success rate at episode k) to diagnose whether memory designs exhibit belief drift. Currently ALMA scores deployment as a flat average — it doesn't reveal *when* in the sequence designs start failing.
- Our trace data suggests belief drift is already occurring: later episodes get worse recall because the vector store fills with stale entries that crowd out relevant matches.

### Long-context baseline

MemoryArena finds that augmenting with external memory or RAG doesn't consistently beat long-context alone, due to representation mismatch and training mismatch (memory not jointly optimized with task agent). ALMA's evolutionary loop *is* joint optimization — it evolves memory functions specifically for the task agent.

- **Add a long-context baseline** that passes the full observation history as context to the TaskAgent (no recall/mem-update). Measure whether evolved designs beat it — this validates the evolutionary approach.
- Given that memory currently *hurts* performance, this baseline would help quantify how much of the problem is the memory system vs the task agent.

### Memory taxonomy (0D / 1D / 2D)

MemoryArena classifies memory by structural complexity: 0D (raw context, no processing), 1D (flat but consolidated), 2D (structured with graph/tree). ALMA's evolved designs naturally span this: null = 0D, vector-only = 1D, vector+graph = 2D.

- **Classify evolved designs** by this taxonomy and track whether evolution consistently discovers that 2D outperforms 1D, or whether the relationship is more nuanced (the paper finds 2D doesn't always win).
- Our findings suggest 1D (vector-only) is actively harmful with n-gram embeddings, while 2D (graph store) provides genuine value. Real embeddings might change this balance.

### Scale to stress memory compression (deferred)

External memory helps in MemoryArena when traces exceed ~120k tokens. It mitigates attention saturation by selectively abstracting and distilling.

- **Scale GraphWorld** to longer episode sequences or larger worlds where accumulated observation logs exceed what a task agent can reason over in-context. This creates natural pressure for memory designs to compress and abstract rather than store everything.
- **Deferred** — the system can't beat no-memory at current scale. Fix representation quality first.

### Dynamic environments for state tracking (deferred)

MemoryArena frames multi-session tasks as a POMDP. The real challenge isn't recall — it's tracking evolving state. Current SOTA fails at this.

- **Add environments where the world changes** between episodes (e.g., objects move, doors lock/unlock), requiring memory designs to maintain an accurate world model, not just a static spatial map.
- **Deferred** — the system can't track static state correctly yet. Solve stale cross-episode data first.

## `tool/analyze` — LLM-powered structured extraction

Memory designs currently access observation data via structured maps (`(:location (:result obs))`). This works but requires the MetaAgent to know the exact schema. `tool/analyze` would let designs extract structure from any text:

```clojure
;; Text mode — same as summarize but analysis-oriented
(tool/analyze {"text" obs-text "instruction" "what patterns do you see?"})
;; Returns: "The agent visited room_A twice but never found the target..."

;; JSON mode — returns a parsed PTC-Lisp value
(tool/analyze {"text" (str data/observation_log)
               "instruction" "extract object-room pairs"
               "format" "json"})
;; Returns: [{"object" "flask" "room" "room_B"} {"object" "key" "room" "room_C"}]
```

This enables:
- **Environment-agnostic designs** — works on GraphWorld and ALFWorld without code changes
- **Evolved extraction** — the MetaAgent can evolve *what* to extract, not just how to store it
- **Failure analysis** — "why did this episode fail?" returning structured data the design can act on

Tradeoff: one LLM call per invocation. Wait for evidence that designs need it before implementing.

## Archive and evolution

- **Additional archive seeds** — beyond null + spatial, seed with a "cheatsheet" design (uses `tool/summarize` to maintain an evolving advice document) and a "trajectory replay" design (stores full episode summaries, retrieves most similar).
- **Namespace-as-design consolidation** — store the full namespace as a single source string via `CoreToSource.export_namespace/1` instead of separate `mem_update_source` and `recall_source`. Simplifies persistence and novelty comparison.
- **Real embeddings** — see "Representation mismatch" in the MemoryArena section. This is the highest-priority infrastructure change.

## Operational

- **Token budget tracking** — track cumulative token usage across iterations via telemetry. Add a budget cap to control costs in longer runs.
- **Prompt caching** — MetaAgent and TaskAgent system prompts are identical across iterations. Using `LLMClient.callback("bedrock:haiku", cache: true)` would reduce latency and cost.
