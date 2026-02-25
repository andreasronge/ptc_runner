# ALMA — Future Improvements

## Avoiding "cheating"

The MetaAgent prompt must stay domain-blind. When ALMA underperforms, the temptation is to hardcode the solution (e.g., "store object locations", "use tool/store-obs"). Instead:

- **Let the Analyst discover insights** — the Analyst LLM critiques parent designs from trajectory evidence. It should identify what to improve; the MetaAgent decides how.
- **Document tools, not strategies** — the system prompt shows tool signatures and PTC-Lisp syntax. It should never prescribe *what* to store or *how* to use the tools.
- **Increase evolutionary pressure** — more iterations, more episodes, and multi-seed deployment scoring give the loop enough signal to select good designs without manual nudging.

## Domain leakage audit

The CLAUDE.md project rules require domain-blind orchestration: "System prompts, planner prompts, and agent configurations must not contain hints about test data, benchmark domains, or expected answer patterns." An audit of the ALMA codebase found the following:

### Clean (no leakage)

- **Loop / Harness** — Parameterized via `env_module` and `context_schema`. No GraphWorld knowledge.
- **Analysis** — Delegates to `env_module.summarize_observation/2`. Explicitly states "this module is domain-blind."
- **DebugAgent** — Generic tool patterns (`"ERROR:"`, `"TOOL find-similar.*\\[\\]"`), no domain hints.
- **Environment interface** — Proper `Alma.Environment` behaviour with `context_schema/0`, `summarize_observation/2`, `format_goal/1` callbacks.
- **DebugLog** — Generic formatting with minor `:message` field assumption from action results.

### Moderate leakage

- **MetaAgent system prompt** (`meta_agent.ex`) — Examples say "rooms visited, exits seen, objects found", "spatial data", "room names and object locations", "horn location". The tool documentation and design pattern examples embed navigation/inventory assumptions. The instructions themselves are generic (use tools to store/retrieve), but the motivating examples are GraphWorld-specific.

### Severe leakage

- **TaskAgent prompt** (`task_agent.ex`) — Hardcodes "Navigate connected rooms", "pick_up then move_to, or look then move_to". Tool descriptions say "Look around the current room", "Move to an adjacent room". Cannot be reused with a different environment without full rewrite.
- **Seed baseline** (`archive.ex`) — `spatial_baseline_source` references `(:location result)`, `(:exits result)`, `(:objects result)`, builds a spatial graph, queries object locations. Entirely GraphWorld-specific.

### Pluggability: adding a new environment

The architecture supports new environments via the `Alma.Environment` behaviour, but three things block easy adoption:

1. **TaskAgent** — No abstraction for prompt or tool descriptions. A new environment needs a completely rewritten task agent.
2. **Seed designs** — Hardcoded for GraphWorld. A new environment needs its own baseline.
3. **MetaAgent examples** — Concrete "rooms/objects/spatial" language biases the LLM toward navigation designs.

### Recommended fixes (priority order)

1. **TaskAgent**: Add environment callbacks (`task_prompt/0`, `task_tools/0`) so each environment provides its own task agent prompt and tool descriptions. The orchestration layer just passes them through.
2. **Seed baseline**: Add `Environment.seed_design/0` callback. Each environment provides its own baseline mem-update/recall source. Remove the hardcoded `spatial_baseline_source` from `archive.ex`.
3. **MetaAgent examples**: Replace "rooms", "objects", "spatial", "horn location" with neutral language — "environment entities", "discovered items", "regions". Use the `context_schema` descriptions instead of hardcoded examples.

## Benchmarking

The [original ALMA paper](https://arxiv.org/abs/2602.07755) evaluates on ALFWorld, TextWorld, Baba Is AI, and MiniHack. Our GraphWorld is simpler, so direct score comparison is not meaningful.

- **Implement ALFWorld** — see [ALFWorld integration plan](#alfworld-integration-plan) below.
- **Scale up GraphWorld** — more rooms (8+), more objects (6+), lower connectivity (0.3), multi-step goals. Compare convergence curves against the paper's charts.
- **Compare architecture efficiency** — measure LLM calls, tokens, and wall-clock time per iteration. The paper's meta-agent does ideation + programming + verification (3 LLM calls minimum, up to 9 with debug retries). Our SubAgent typically does 1-3 turns.

## ALFWorld Integration Plan

[ALFWorld](https://github.com/alfworld/alfworld) is a text-based household task simulation built on TextWorld/ALFRED. An agent navigates rooms, manipulates objects (take, put, open, close, heat, cool, clean, toggle) to complete goals like "put a clean mug on the shelf". It provides text observations, a dynamic admissible-command list at each step, and binary success reward. The original ALMA paper uses ALFWorld as its primary benchmark (53.9% vs 41.1% baseline with GPT-5-mini).

### Prerequisites: domain leakage fixes

The [domain leakage audit](#domain-leakage-audit) identifies three blockers that must be resolved before any new environment can be added:

1. **TaskAgent** — currently hardcodes GraphWorld tools and prompt. Needs environment callbacks.
2. **Seed baseline** — hardcoded spatial design. Needs `Environment.seed_design/0`.
3. **MetaAgent examples** — GraphWorld-specific language ("rooms", "objects", "spatial").

These fixes benefit both ALFWorld and any future environment.

### Approach: Python sidecar via Elixir Port

ALFWorld runs as a Python library (`alfworld.agents.environment`). The simplest integration is a thin Python script communicating with Elixir over stdin/stdout JSON lines.

**Why this approach:**
- ALFWorld's API is tiny: `reset()` → `(obs, info)` and `step(action)` → `(obs, score, done, info)`
- Elixir's `Port` is battle-tested for process communication
- No Docker, NIFs, or HTTP servers required
- Python dependency is isolated in a conda env

### ALFWorld setup (one-time)

```bash
conda create -n alfworld python=3.9
conda activate alfworld
pip install alfworld
alfworld-download   # stores data in ~/.cache/alfworld/
```

Python 3.9 is required — ALFWorld's TextWorld dependency has native C extensions that are fragile on newer versions. macOS ARM needs `CONDA_SUBDIR=osx-64`.

### Components

#### 1. Python bridge script (`priv/alfworld_bridge.py`, ~60 lines)

JSON-line protocol over stdin/stdout:

```
→ {"cmd": "reset", "game_file": "/path/to/task.tw-pddl"}
← {"obs": "You are in the middle of a room...", "admissible_commands": ["go to desk 1", ...], "done": false, "score": 0}

→ {"cmd": "step", "action": "go to desk 1"}
← {"obs": "You arrive at desk 1...", "admissible_commands": ["take mug 1 from desk 1", ...], "done": false, "score": 0}

→ {"cmd": "step", "action": "take mug 1 from desk 1"}
← {"obs": "You pick up the mug 1...", "admissible_commands": [...], "done": true, "score": 1}

→ {"cmd": "shutdown"}
```

The script loads the ALFWorld config, initializes `AlfredTWEnv`, and stays alive for multiple episodes. Uses the `AlfredDemangler` wrapper for readable entity names.

#### 2. `Alma.Environments.ALFWorld` (~150 lines)

Implements `Alma.Environment` behaviour:

- **`reset/1`** — opens `Port` to Python script, sends `reset` with game file path, returns initial state
- **`step/2`** — sends `step` with text action string, returns `{result, new_state}`
- **`observe/1`** — returns `%{obs: text, admissible_commands: [strings], goal: text}`
- **`success?/1`** — `state.done && state.score > 0`
- **`context_schema/0`** — describes ALFWorld data shapes for mem-update/recall:

```elixir
%{
  "mem_update" => %{
    "data/task" => "map — :obs (initial observation string), :goal (task goal string)",
    "data/actions" => "list of action strings taken during the episode",
    "data/success" => "boolean",
    "data/observation_log" => "list of maps — :action (string), :obs (string), :admissible_commands (list)"
  },
  "recall" => %{
    "data/task" => "map — :goal (task goal string)",
    "data/current_observation" => "map — :obs (string), :admissible_commands (list of valid action strings)"
  }
}
```

- **`summarize_observation/2`** — parses text actions:
  - `"go to desk 1"` → `%{action_summary: "go_to(desk 1)", state_identifier: "desk 1", discovery: nil}`
  - `"take mug 1 from desk 1"` → `%{action_summary: "take(mug 1, desk 1)", state_identifier: nil, discovery: "took mug 1"}`
- **`format_goal/1`** — extracts goal text from initial observation
- **Task discovery** — scans PDDL files from `~/.cache/alfworld/json_2.1.1/{train,valid_seen,valid_unseen}/`

#### 3. Refactor TaskAgent to be environment-generic

The task agent interaction differs between environments:

| | GraphWorld | ALFWorld |
|---|-----------|----------|
| Action interface | Structured tool calls (`move_to`, `pick_up`) | Text selection from admissible list |
| Observations | Structured maps | Free-text paragraphs |
| Action space | Fixed 4 tools | Dynamic per step (10-40 options) |

**Recommended approach:** Each environment provides its own task agent configuration via new callbacks:

```elixir
@callback task_prompt() :: String.t()
@callback task_tools(agent_pid :: pid(), knowledge :: String.t()) :: map()
# or for text-mode agents:
@callback task_output_mode() :: :ptc_lisp | :text
```

For ALFWorld, a **text-mode SubAgent** (no PTC-Lisp) is simplest — matching the Python ALMA approach where the LLM outputs the action text directly. The prompt includes admissible commands and the LLM picks one.

#### 4. Wire environment selection

- `alma.ex` / `loop.ex` — accept `env_module` parameter (already partially done)
- `mix alma.run --env alfworld` — new flag, defaults to `graph_world`
- Config for ALFWorld: `--python /path/to/conda/envs/alfworld/bin/python`, `--alfworld-data ~/.cache/alfworld`

### Key differences from GraphWorld

| Aspect | GraphWorld | ALFWorld |
|--------|-----------|----------|
| Task source | Procedurally generated in Elixir | PDDL files from dataset (~3500 train, ~140 eval) |
| Max steps | 20 | 30 |
| Reward | Binary (object in destination) | Binary (task completed) |
| Task types | 1 (pick & place) | 6 (pick & place, examine, clean, heat, cool, pick two) |
| Family concept | Shared topology seed | Task type category |
| State | Pure Elixir map | External Python process |

### ALFWorld task types

1. **Pick & Place** — move object to receptacle (closest to GraphWorld)
2. **Examine in Light** — bring object to lamp and examine
3. **Clean & Place** — clean object at sink, place it
4. **Heat & Place** — heat object in microwave, place it
5. **Cool & Place** — cool object in fridge, place it
6. **Pick Two & Place** — find and place two instances of an object

### Estimated effort

| Component | Effort | Depends on |
|-----------|--------|------------|
| Domain leakage fixes (TaskAgent, seeds, MetaAgent examples) | Medium | — |
| `priv/alfworld_bridge.py` | Easy | — |
| `Alma.Environments.ALFWorld` | Medium | Bridge script |
| Wire env selection in alma.ex/loop.ex/mix tasks | Easy | ALFWorld env module |
| ALFWorld seed baseline design | Medium | Domain leakage fixes |
| Testing and tuning | Medium | All above |

### Risks

- **Python 3.9 dependency** — ALFWorld's TextWorld has native C extensions. Isolated via conda but adds setup friction.
- **Port lifecycle** — the Python process must survive across many episodes within an ALMA iteration. Need robust error handling and restart logic.
- **Admissible command parsing** — the LLM must output an exact match from the list. Fuzzy matching or retry logic may be needed.
- **Cost** — ALFWorld episodes are longer (30 steps vs ~10) and the benchmark dataset is larger. Token costs scale accordingly.

## MemoryArena-Inspired Improvements

The [MemoryArena paper](https://arxiv.org/abs/2602.16313) benchmarks agent memory in multi-session interdependent agentic tasks. It formalizes a Memory-Agent-Environment loop with two abstract functions — `retrieve` and `update` — mapping directly to ALMA's `recall` and `mem-update`. Key findings that expose gaps in our current benchmark.

See [FINDINGS.md](FINDINGS.md) for trace-level evidence of the problems described below.

### Representation mismatch (current blocker)

MemoryArena finds that RAG-based memory often hurts because compressed/reordered information doesn't align with how the task agent reasons. We see exactly this: the n-gram VectorStore produces near-random similarity scores (0.17-0.22) for object queries, causing recall to confidently report wrong item locations. The task agent trusts this advice and wastes turns navigating to empty rooms.

This is the single highest-priority fix. Two paths:

- **Real embeddings** — ✅ Done. `LLMClient.embed/2` wires real embedding APIs (OpenAI, Google, Ollama) through `VectorStore`. Use `--embed-model openai:text-embedding-3-small` to enable. VectorStore now accepts pre-computed dense vectors; n-gram fallback is preserved when no embed model is configured.
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
- **Real embeddings** — ✅ Done. See `LLMClient.embed/2` and `--embed-model` CLI option.

## ALFWorld Benchmark Parity

The original Python ALMA uses significantly larger runs than our current defaults. To get meaningful ALFWorld results, we should test with comparable settings:

| Parameter | Original Python | Current PTC Runner default |
|---|---|---|
| Evolutionary iterations (`--steps`) | 10 | 5 |
| Collection episodes (memory build-up) | 15 (half of `--train_size 30`) | 3 |
| Deployment episodes | 15 × 3 runs = 45 | 3 × 3 seeds = 9 |
| Max steps per episode | 30 | 10 |
| Examine/test sample | 5 tasks (quick design verification) | None |
| Meta-model | gpt-4.1 | Same as `--model` |

Key things to test:

- **Raise `max_turns` to 30** for ALFWorld — 10 is far too low; most tasks timeout before the agent can complete multi-step household goals.
- **Raise `result_max_chars`** or move admissible commands into the prompt body — the 500-char truncation cuts the action list to ~7 items when there are 15-25 available.
- **Increase episodes to 15+** for collection — 3-4 episodes produces too sparse a memory for deployment to benefit from.
- **Use a stronger meta-model** — the original uses gpt-4.1 for design generation/analysis while using cheaper models for task execution.
- **Add ALFWorld action type descriptions** to the task prompt — the original explains all 9 action types (go to, take from, put in/on, open, close, toggle, clean, heat, cool); our prompt just says "pick one from the list."
- **Structured memory injection** — the original injects retrieved memory as structured JSON in the system prompt, not a flat text string.

## Operational

- **Token budget tracking** — track cumulative token usage across iterations via telemetry. Add a budget cap to control costs in longer runs.
- **Prompt caching** — MetaAgent and TaskAgent system prompts are identical across iterations. Using `LLMClient.callback("bedrock:haiku", cache: true)` would reduce latency and cost.