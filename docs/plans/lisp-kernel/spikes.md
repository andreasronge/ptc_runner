# Lisp Kernel — Spike Registry

**Status:** active, branch `exp/lisp-kernel`. Append-only evidence log.

Rules:

- Register the question and pass/fail criterion **before** writing spike code.
- Spike code is throwaway: lives under `spikes/` in this worktree, is never
  imported from `lib/`, and may be deleted once its Result section is filled.
- A spike result is a fact with a date and the commit it was observed at.
  Record failures as prominently as passes — a failed spike that redirects
  the design is a success of the method.
- Each result feeds a decision (D#) or gate in
  [`architecture.md`](architecture.md) / [`roadmap.md`](roadmap.md).

---

## S1 — Nested `Lisp.run` from inside a sandboxed tool closure

**Question.** Does `PtcRunner.Lisp.run/2` work when called from an Elixir tool
closure that is itself executing inside a sandbox process — with correct
independent limits — and what happens to the inner run when the outer is
killed?

**Why it gates.** The entire two-level design routes every model-program eval
through the `eval-program` capability, i.e. a grandchild sandbox. If nesting
trips shared state (telemetry, `TraceContext`, `ParallelBudget`), the design
needs a proxy-to-host mechanism instead.

**Method.** Outer `Lisp.run` with `timeout: 30_000, max_heap:` relaxed and a
`tools: %{"inner-eval" => fn %{"src" => s} -> Lisp.run(s, timeout: 1_000) end}`
closure. Cases: (a) inner success returns value; (b) inner infinite loop —
inner times out at ~1s, outer survives and sees the error; (c) inner heap bomb
— same; (d) outer killed mid-inner-eval — confirm the orphaned inner dies by
its own limit and nothing leaks to the caller's mailbox.

**Pass.** (a)–(c) behave as stated; (d) has no caller-visible fallout.
**Fail.** Any shared-state crash, mailbox leak, or inner limit not enforced.

**Result.** _pending_

---

## S2 — Memory round-trip through the tool boundary

**Question.** Can the loop prelude thread mission memory as a plain value —
out of `eval-program` (projected `Step.memory`) and back in as an arg — such
that a model-defined `defn` from turn N is callable in turn N+1? Closures are
`{:closure, params, body, captured_env, ...}` tuples; do they survive tool-arg
normalization in both directions?

**Why it gates.** Decides D1 (architecture.md): value-threaded memory (memory
is just data in the loop — the elegant design) vs host-held memory inside the
`eval-program` closure (fallback; still small, less pure).

**Known boundary behavior (verified, review round 1).** The tool-arg boundary
is normalizing by design: map keys stringified recursively, `LispKeyword`
values collapsed to plain name strings (eval.ex ~1166–1270); tuples — including
`{:closure, ...}` — pass the catch-all untouched, and native memory projection
preserves closure tuples (lisp.ex:1209). So the spike does NOT expect
"unchanged" round-trips; it measures whether the *documented* normalization
breaks memory semantics in practice.

**Method.** Turn 1: `eval-program` with `(defn double [x] (* 2 x))` and no
`(return ...)`; capture projected memory `m1`. Turn 2: `eval-program` with
`(return (double 21))` and `memory: m1` passed back through the tool boundary.
Additionally store `{:mode :fast, "rows" [1 2]}` in memory on turn 1 and read
it back on turn 2, asserting the exact post-normalization shape.

**Pass.** Turn 2 returns `42` (closure callable after round-trip), and the
data value comes back in a *predictable documented* shape (string keys;
keyword values as strings) that a loop prelude could compensate for — record
the exact shape observed.
**Fail.** Closures not callable after round-trip, or normalization of nested
values (e.g. inside `captured_env`) is destructive/unpredictable → D1 =
host-held memory (or opaque memory token) and the spike documents why.
Note: even on PASS, keyword-lossiness is a semantic divergence from today's
host-side threading — D1 weighs that against the purity win.

**Result.** _pending_

---

## S3 — Blocking LLM call inside the sandbox

**Question.** Does a real multi-second HTTPS LLM call from a tool closure
inside a relaxed-limit sandbox behave sanely: latency billed only against the
outer wall-clock, response heap billed against the outer budget, and
kill-mid-HTTP leaving no stuck processes?

**Why it gates.** Capability #1 (`llm-complete`). Upstream MCP calls already
block inside evals (with `call_timeout_ms`), so this is expected to pass —
but nobody has held an LLM HTTP call in a sandbox process before, and the
HTTP client's process ownership (req/finch pools are outside the sandbox)
deserves one honest look.

**Method.** Outer `Lisp.run` (`timeout: 60_000`) with a tool closure calling
`PtcRunner.LLM.callback("gemini-flash-lite")`-built fn. Cases: (a) normal
completion, response text visible to the program; (b) outer `timeout: 500` so
the kill lands mid-request — check for orphaned/stuck processes and pool
health afterwards (second call still works). Skip live cases if
`OPENROUTER_API_KEY` absent and record that.

**Pass.** (a) works; (b) second call succeeds after the kill; no process
accumulation across 10 repetitions.
**Fail.** Pool corruption or leaked processes → route LLM calls through a
host-side proxy process instead of calling from the sandbox.

**Result.** _pending_

---

## S4 — The loop is expressible (and pleasant) in PTC-Lisp

**Question.** Can `run-mission` — message-list building, code extraction via
regex, turn loop with `loop`/`recur`, feedback rendering, budget wind-down —
be written as a compiled prelude in ~100–200 lines that reads well?

**Why it gates.** This is the thesis in miniature, testable without a kernel,
network, or API key: plain `Lisp.run` with a **scripted stub** `llm-complete`
tool (returns canned responses per call index) and a stub `eval-program`.
If the loop fights the language (string building, regex ergonomics,
prelude compile restrictions on `loop`/`recur` or big `def` constants), better
to learn it before `PtcRunner.Kernel` exists. Its source seeds `agent.core`.

**Method.** Write the prelude, compile with `Prelude.Compiler.compile/1`,
drive 3 scripted turns: turn 1 unparseable response (loop must send a retry
feedback message), turn 2 program that fails, turn 3 program that returns.
Assert the final value and the exact message list sent to the stub on each
turn (the message log **is** the oracle).

**Pass.** Compiles as a prelude; 3-turn script produces the expected final
value and message sequence; author judges the source maintainable.
**Fail.** Compiler rejects needed forms or the code is unmaintainable →
record the specific gaps; consider builtins/prelude-compiler relaxations as
kernel-adjacent work items.

**Result.** _pending_

---

## Candidate later spikes (register properly before running)

- **S5 — Outer-heap headroom:** long mission (20 turns, large responses)
  under the relaxed cap; where does message-list accumulation actually bite?
- **S6 — Bundle swap provenance:** two bundles differing in one
  `agent.feedback` component; confirm `prelude.metadata.components` +
  `source_hash` are sufficient to attribute a run to a policy variant in turn
  logs (M3 depends on this attribution).
