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
- **Real embeddings** — swap n-gram embedder for a real embedding API (OpenAI, Bedrock, or local Bumblebee model). The `VectorStore` interface stays the same; only `embed/1` changes. Worth it when environments involve semantically rich text beyond room/object names.

## Operational

- **Token budget tracking** — track cumulative token usage across iterations via telemetry. Add a budget cap to control costs in longer runs.
- **Prompt caching** — MetaAgent and TaskAgent system prompts are identical across iterations. Using `LLMClient.callback("bedrock:haiku", cache: true)` would reduce latency and cost.
