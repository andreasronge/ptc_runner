# Named mission spaces — spike status

Branch `spike/mission-spaces`. Spike code: it answers design questions and is
not a merge candidate as written. Full root suite green (`5912 passed`).

## The question

Two agents in one run share a single mission continuation and a single mission
environment. Definitions collide, `*1` is shared, and every agent holds the same
tool grants. Can a run instead declare **named mission spaces**, so each agent
gets its own definitions, its own prompt-visible API, and its own authority?

## Answer: yes

One name → one mission environment → one continuation. No second concept.

```json
"providers": {"mission": [
  {"name": "notes_write", "config": {"allow": ["notes.commit"]}},
  {"name": "notes_read"}
]},
"missions": {
  "writing": {"components": [...], "providers": ["notes_write"]},
  "review":  {"components": [...], "providers": ["notes_read"]}
}
```

```clojure
(agent.core/run-value task {"max_turns" 4 "mission" "writing"})
(agent.core/run-value task {"max_turns" 4 "mission" "review"})
```

A space may only narrow what `providers.mission` already selected, so a space
can never widen run authority.

## What is proven, and by what

| Claim | Evidence |
|---|---|
| Definitions and `*1` isolate per space | `mission_spaces_spike_test.exs` |
| An undeclared space is refused, not defaulted | same |
| Each agent's prompt renders only its own API | live DeepSeek run, prompt bytes read from private inspection |
| Each model calls only its own space's API | same, generated source read from inspection |
| Shipped `agent.core` drives spaces via cfg | `mission_spaces_e2e_test.exs` |
| Traces attribute work per agent | `evaluations_by_space`, `space` filter on `log/turns` |
| Inspection attributes generated code per agent | verified against a live run |
| Spaces declarable with no Elixir | `mission_spaces_manifest_test.exs` |
| A space cannot reach an ungranted provider | `mission_spaces_authority_e2e_test.exs` |

The last row is the load-bearing one. The review space's attempt at the write
tool is not a runtime denial:

```
Unknown tool: notes.commit. Available tools: cap-describe, cap-list,
notes.read, runtime-remaining, runtime-usage
```

`capability_activity?` is `false` — nothing was dispatched. "Read-only" is a
property of environment assembly, not an instruction the model may ignore.

## Design decisions worth keeping

- **One evaluation lease for the whole run.** Per-space leases would allow
  concurrency that is unusable anyway: `pmap` has a 5s deadline the Kernel never
  raises, and `return`/`fail` are banned inside it.
- **Per-space *and* run-wide retained bytes share the existing ceiling.**
  Enforcing only the per-space figure would silently multiply retained heap by
  the number of spaces.
- **Acquisition untouched.** It still acquires the whole selection once, keyed by
  `destination: :workflow | :mission`. `finalize_capabilities` now also retains
  the per-occurrence grouping so the builder can partition it. Widening the
  destination model was the alternative and is far larger.
- **`space` is optional in inspection records.** Requiring it failed 20 existing
  fixtures — the correct signal, since persisted evidence must stay readable.

## Open issues before this can ship

1. **`continuation_revision` is global.** A commit in space B invalidates an
   outstanding `check-source` in space A. Safe direction, but wrong. Fixing it
   means threading the space through `SourceCheck`.
2. **`counters["evaluations"]` includes the workflow's own evaluation**, so it
   reads `1` when no mission program ran. Actively misleading in a multi-agent
   trace; `evaluations_by_space` is the honest figure. Rename or split.
3. **Spike affordance:** singular `"mission"` still works as the `default` space.
   Kept so the existing suite and examples stay green; the real slice should
   decide whether to collapse to `missions` only.
4. **Not regenerated:** `priv/semantic_build_projection.json`. `mix regen`
   rewrites it, but that is a main-only step before tagging.

## What a hand-rolled loop costs

The first e2e used a hand-written agent loop and died on an ordinary prose reply
because it treated a protocol error as fatal, where `agent.core` corrects it.
The same loop also never called `workflow.event/annotate`, so the canonical
trace was completely silent about the fault — `agent.core` records
`kind=protocol-error` every turn. Threading `"mission"` through the shipped loop
removed the reason to hand-roll one, and fixed the diagnosability hole with it.
