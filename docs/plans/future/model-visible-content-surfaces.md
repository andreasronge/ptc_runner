# Model-Visible Content Surfaces

**Status:** discussion material, not an implementation plan. This note records a
possible common direction for truncation, presentation, and prior-turn
inspection. It is deliberately not a committed feature shape.

## Context

Every model-facing surface has the same tension: the runner must keep context
bounded, but the model often needs to inspect more than the default preview.
This shows up for evidence content, source text, eval results, printed output,
turn summaries, tool-call summaries, diffs, and logs.

The current default behavior is useful but coarse. A large value gets a bounded
preview, and the turn log can usually prove that an item or tool was touched.
It often cannot prove which span the model actually saw, whether a search was
used instead of a read, or whether a later claim was grounded in the visible
part of a prior result.

## Working Principle

Default views should orient; explicit reads should substantiate.

The default presentation should be brief, stable, and good enough for ordinary
use. When the model needs more, it should have explicit bounded ways to drill
down, and those drill-down actions should be visible in the trace.

## Sketch: General Content References

One possible abstraction is a common content surface over different backing
kinds:

```clojure
(content/preview ref)
(content/page ref {:offset 1200 :limit 800})
(content/search ref "next_cursor")
(content/sections ref)
(content/coverage ref)
```

The same shape could cover refs such as:

```clojure
evidence:stage2-analyst-output:content
source:paged_stream@1:collect-events
result:session-id:turn-10
print:session-id:turn-12:stdout
turn:session-id:turn-12:program
turn:session-id:turn-12:tool-calls
log:stage3:turns
```

This is not a proposal to add exactly these string formats. The point is the
boundary: the runner owns bounded dereference, permissions, lifetime, and
provenance; preludes can own navigation strategies over that boundary.

## Prior-Turn Drill-Down

A particularly valuable version is model access to its own prior turns. Instead
of repeating an evidence or upstream call because an old preview fell out of
context, the model could inspect the already-recorded turn artifact:

```clojure
(turns/list {:limit 10})
(turns/get 12)
(turns/summary 12)
(turns/data 12)
(content/page "turn:12:prints" {:offset 0 :limit 2000})
(content/search "turn:10:result" "next_cursor")
```

This separates two operations that currently blur together:

- re-reading evidence asks the source system again;
- inspecting a prior turn asks the session log what already happened.

That distinction matters for budget, reproducibility, and audit. Turn-log
inspection should itself be logged, so a later audit can distinguish knowledge
obtained from a fresh source read from knowledge recovered from a prior turn.

## Prelude-Level Presentation

The model-editable layer should probably be normal prelude code over stable
primitives, not arbitrary replacement of runner rendering internals:

```clojure
(view/brief ref)
(view/first-tail ref)
(view/around ref needle)
(view/headings ref)
(view/coverage-report ref)
(view/read-all-pages ref)
```

This gives the loop an improvement target: models can propose better navigation
helpers without weakening the trusted boundary. A defective navigation helper is
also testable: it can claim coverage, and the runner can compare that claim
against the actual spans paged or searched.

## Defaults and Overrides

The runner still needs good defaults. A reasonable default preview might include:

- a compact preview;
- total byte/character count;
- shown range;
- whether content was omitted;
- one or two obvious next inspection forms.

Overrides should be simple and mostly named, not an explosion of renderer
knobs. Possible profile names:

- `compact`;
- `first_tail`;
- `source_first`;
- `debug`;
- `coverage`.

Automatic turn summaries are a special case. They should remain brief and
runner-owned by default, because they are infrastructure rather than task data.
A small named-mode override may be useful, but arbitrary prelude-rendered
automatic summaries would be easy to make noisy or misleading. Richer turn data
can stay explicit through `turns/*` and `content/*` style calls.

## Why Not Just Raise Truncation Limits?

Raising limits treats the symptom and makes context cost less predictable. The
more interesting issue is navigation and provenance: what did the model see,
what did it search, and what did it merely have available behind a ref?

For small friction cases, a hint may be enough: "bind large content once and
slice the bound value." A content surface is only justified if it improves
provenance, repeated-read behavior, or downstream correctness enough to offset
the extra discovery surface.

## Risks

- New namespaces and handles can increase discovery cost.
- A second "world" of content refs can confuse models when ordinary values are
  already sliceable.
- Search hits are knowledge without full reading; provenance needs to represent
  that honestly.
- Refs must be session-scoped or otherwise bounded in lifetime.
- Grant checks must happen at dereference time, not just when the ref is
  created.
- Replay stability depends on keeping default rendering byte-stable unless a
  boot/profile explicitly opts into new presentation.

## Experiment Shape

This is a good candidate for measured treatment cells, not a hotfix:

- baseline: current bounded previews;
- treatment A: better preview metadata plus bind/slice hints;
- treatment B: content refs and page/search primitives;
- treatment C: model-editable navigation prelude over those primitives.

Metrics could include repeated reads, assistant turns, tool calls, missed
tail/middle facts, byte-span coverage, search-vs-read provenance, and whether
coverage reports match actual paged spans.

The important pre-registration discipline: if a richer primitive increases
discovery cost without improving provenance or correctness on the motivating
tasks, it should be demoted rather than promoted.

