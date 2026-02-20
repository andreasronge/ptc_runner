# ALMA Findings

## Run: 2026-02-20 (bedrock:haiku, 5 iterations, 8 rooms, seed 42)

Baseline (no memory): **0.59**
Best design score: **0.0** (null baseline — no evolved design beat having no memory)

All 5 generations scored negative:

| Gen | Collection | Deployment | Normalized |
|-----|-----------|-----------|------------|
| 1   | 0.20      | 0.15      | -0.44      |
| 2   | 0.43      | 0.34      | -0.24      |
| 3   | 0.73      | 0.51      | -0.08      |
| 4   | 0.66      | 0.44      | -0.14      |
| 5   | 0.25      | 0.28      | -0.31      |

## Problems Found

### 1. Hallucinated Object Locations (Primary)

`find-similar` returns semantically similar but **wrong** entries, and recall treats them as truth.

**Example (Gen 1, Episode 4):** Goal is "Bring key to room_E". Recall queries `find-similar` for "find key", gets back `[{item: "torch", location: "room_F", score: 0.18}]` — score is 0.18/1.0 but the code reads `metadata["location"]` and reports "key is in room_F". Agent navigates there, `pick_up key` → "key is not here". Episode wasted.

The recall code never checks whether the retrieved item name matches the target.

### 2. Stale Cross-Episode Data

Objects are in **different rooms each episode** (randomized placement), but the vector store accumulates observations across ALL episodes. "Key found in room_F" from episode 2 gets recalled in episode 8 where key is actually in room_C.

This is the fundamental design flaw: the evolutionary loop hasn't discovered that item-location memories are actively harmful across episodes, while graph topology (room connections) is the only reliably transferable knowledge.

### 3. Task Agent Returns on Turn 1

~18% of episodes end on turn 1. Haiku generates PTC-Lisp that calls `(return current-state)` after looking around — never actually attempting the goal.

### 4. Vague/Empty Recall Fallbacks

When `find-similar` returns `[]`, recall falls back to generic advice like "Search for potion. Then deliver to room_E" — no better than no memory, but wastes a tool call.

### 5. Gen 4 Arity Error

```
"#Function<...> with arity 3 called with 2 arguments"
```
Design tried to iterate over room data with wrong function arity. Recovered on retry but replacement still scored -0.14.

## Key Insight

The task agent **does follow recall advice** — that's not the problem. The problem is the advice itself is **confidently wrong**. Low-similarity vector matches get reported as fact, and stale item locations from prior episodes actively mislead the agent.

## What the Evolutionary Loop Needs to Discover

1. **Graph topology** (room connections) is the only cross-episode knowledge worth storing — stable across episodes in the same family
2. **Object locations** change every episode and must NOT be recalled as cross-episode facts
3. Recall should return **paths** from the graph store, not item locations from the vector store
4. A confidence threshold on `find-similar` scores would prevent low-quality matches from being reported

Gen 3 came closest (-0.08) likely because its design used the graph store more and relied less on stale item locations.

## Possible Fixes (Without Code Edits)

These can be addressed through prompt engineering or model selection:

1. **Structured recall format** — nudge MetaAgent to have recall return action lists (`["move_to room_B", "move_to room_F", "pick_up feather"]`) instead of prose
2. **Stronger task agent prompt** — "If recall returns a specific path, execute it step-by-step before exploring"
3. **Better meta-model** — a stronger model for MetaAgent/DebugAgent may discover the "don't recall item locations" insight faster
4. **DebugAgent constraints** — add mandatory constraints about confidence thresholds and graph-only cross-episode storage
