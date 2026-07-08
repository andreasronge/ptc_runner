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
— same; (d) outer killed mid-inner-eval under the default spawn behavior —
confirm the orphaned inner dies by its own limit and nothing leaks to the
caller's mailbox; (e) repeat (d) with `link: true`/linked inner execution if
the API supports it, confirming outer death tears down the inner sooner and
does not convert a cleanup signal into caller-visible fallout.

**Pass.** (a)–(c) behave as stated; (d) has no caller-visible fallout and no
surviving inner process after its limit; (e) either passes and becomes the
kernel default cleanup mode, or is documented as unavailable/unsafe with a
bounded-orphan fallback.
**Fail.** Any shared-state crash, mailbox leak, inner limit not enforced, or
unbounded orphaned inner process.

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

**Result.** Partial kernel-path evidence, 2026-07-08. The M3 host-held memory
implementation now starts a per-`Kernel.run/2` Agent, passes its native map to
each inner `Lisp.run/2`, commits returned `step.memory` under a heap-oriented
byte cap, and returns only a bounded `memory_summary` to `agent.core`.
Deterministic kernel tests prove `(def x 41)` on turn 1 and `(return (+ x 1))`
on turn 2 returns `42`; `(defn inc2 [n] (+ n 2))` on turn 1 and
`(return (inc2 40))` on turn 2 also returns `42`, so closures round-trip
through the host-held boundary. This resolves the closure survival risk for
the kernel path without threading raw memory through the prelude.

Pinned failure fact: the host commits whatever `Lisp.run/2` returns. A
`(do (def x 41) (fail :bad))` step returns memory containing `x`, and the
terminal fail projection includes that in `memory_summary`. A runtime error
after a prior `def`, such as calling `41` as a function, currently returns the
prior memory from `Lisp.run/2`; the host cannot commit partial definitions that
the runtime does not return without extending evaluator semantics. Commands:
`mix test test/ptc_runner/kernel_test.exs test/ptc_runner/kernel/eval_test.exs`
passed 27/27; `mix ptc.kernel_eval --suite mini --case memory_persistence
--live --model deepseek --allow-failures` passed 1/1 after the live harness
forced turn 1 to `(def x 41)` and the model returned the stored `x` on turn 2.

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
`PtcRunner.LLM.callback("deepseek")`-built fn. Cases: (a) normal
completion, response text visible to the program; (b) outer `timeout: 500` so
the kill lands mid-request — check for orphaned/stuck processes and pool
health afterwards (second call still works). Skip live cases if
`OPENROUTER_API_KEY` absent and record that. Ten repetitions here are a live
smoke only; S11 owns leak/soak confidence.

**Pass.** (a) works; (b) second call succeeds after the kill; no process
accumulation across 10 repetitions.
**Fail.** Pool corruption or leaked processes → route LLM calls through a
host-side proxy process instead of calling from the sandbox.

**Result.** First M3 data point, 2026-07-08. Host-held kernel memory is capped
with the same retained-heap estimator family used by eval context
(`:erts_debug.flat_size/1 * word_size` plus referenced binary bytes). The cap
is fail-closed: the candidate memory is measured before commit; on breach the
prior committed memory is preserved and `eval-program` returns a stable
`memory_limit_exceeded` error with a summary of the prior memory. A focused
test sets a small `kernel_memory_byte_cap`, proves a larger second definition
is rejected, then successfully returns a prior `x` binding. Each eval also
emits a bounded memory-size event (`memory_bytes`, defined/changed counts) via
the kernel event/log surface. Command:
`mix test test/ptc_runner/kernel_test.exs` passed 18/18.

---

## S4 — The native-action loop is expressible (and pleasant) in PTC-Lisp

**Question.** Can `run-mission` — message-list building, native-action handling
(`run_ptc_lisp` tool call / final / protocol error), turn loop with
`loop`/`recur`, feedback rendering, budget wind-down — be written as a compiled
prelude in ~100–200 lines that reads well?

**Why it gates.** This is the thesis in miniature, testable without a kernel,
network, or API key: plain `Lisp.run` with a **scripted stub** `llm-complete`
tool (returns canned native-action envelopes per call index) and a stub
`eval-program`. If the loop fights the language (message construction, action
dispatch, string building, prelude compile restrictions on `loop`/`recur` or
big `def` constants), better to learn it before `PtcRunner.Kernel` exists. Its
source seeds `agent.core`.

**Method.** Write the prelude, compile with `Prelude.Compiler.compile/1`,
drive 3 scripted turns: turn 1 protocol error (free text or wrong tool; loop
must send a retry feedback message), turn 2 `run_ptc_lisp` program that fails,
turn 3 `run_ptc_lisp` program that returns. Assert the final value and the
exact message list sent to the stub on each turn (the message log **is** the
oracle).

**Pass.** Compiles as a prelude; 3-turn script produces the expected final
value and message sequence; author judges the source maintainable.
**Fail.** Compiler rejects needed forms or the code is unmaintainable →
record the specific gaps; consider builtins/prelude-compiler relaxations as
kernel-adjacent work items.

**Result.** PASS for the autonomous M1 vertical slice, 2026-07-07. The initial
single-namespace prelude embedded in `PtcRunner.Kernel` compiled and used
`loop`/`recur`, `case`, message-list construction, private `llm-complete`,
private `eval-program`, protocol-error feedback, model-program fail handling,
and return handling. Evidence:
`mix test test/ptc_runner/kernel/action_test.exs test/ptc_runner/kernel_test.exs`
passed with scripted responses covering happy path, protocol retry,
program-fail, private capability denial, bounded projection, and prompt
hygiene. Follow-up fix commits on 2026-07-08 showed that the first pass needed
transport normalization for retries: the kernel now sends the system prompt
through the request `:system` field, converts prelude-built messages into the
atom-keyed `ReqLLMAdapter.build_messages/1` contract, emits assistant
retry messages with `content: nil` plus structured tool calls, and wraps eval
feedback as JSON containing `untrusted_eval_result`. A live two-turn
DeepSeek/OpenRouter smoke now exercises that retry path.

M2 update, 2026-07-08: the loop moved to
`priv/preludes/agent/core.lisp`, with prompt and feedback policy in
`agent.prompt` and `agent.feedback`. The full graph compiles and preserves the
same scripted kernel behavior. Evidence:
`mix test test/ptc_runner/kernel/action_test.exs test/ptc_runner/kernel_test.exs test/ptc_runner/kernel/prelude_split_test.exs`
passed with 20 tests.

---

## S5 — Copy-volume and setup-pressure budget

**Question.** How expensive is the nested kernel-shaped path when ordinary BEAM
terms are copied host -> outer sandbox -> inner sandbox -> outer sandbox ->
host, and where do setup heap/time or result projection sizes become the
limiting factor?

**Why it gates.** The two-level sandbox is sound as a limits/authority design,
but it can still copy large maps/lists/tuples at every process boundary. D1
memory threading is the main risk: value-threading the full evolving memory map
through `eval-program` copies it into the inner sandbox and back out every turn,
which may become quadratic-feeling as memory grows. D5 also depends on this:
`eval-program` must return a bounded projection, not a raw `Step`.

**Method.** Using the S1 nested-run harness shape, run fixed-size scenarios from
R13:

- large mission context copied into the outer sandbox;
- growing memory map passed through `eval-program` for N turns;
- large inner return value;
- large `println` output;
- large prompt/spec/tool-result binaries, including sliced binaries/previews;
- projected step with and without memory/prints caps.

Record wall-clock duration, `baseline_bytes`, setup failures
(`:memory_exceeded` with `phase: :setup`), projected result term sizes, and any
GC/process fallout. Use representative payloads first; only then increase sizes
until one limit fails so the failure mode is known.

**Pass.** The bounded projection path has predictable setup/runtime growth, no
unexpected process fallout, and yields concrete initial caps for
`eval-program` args/results/prints. D1 may still choose host-held memory, but
the copy-volume reason is quantified.

**Fail.** Copy/setup pressure is high enough that full memory threading or large
result projection is untenable even for representative payloads -> D1 =
host-held memory or opaque memory token, D5 = stricter projection caps, and the
kernel design forbids returning raw large memory/results through the loop.

**Result.** First M3 data point, 2026-07-08. Host-held kernel memory is capped
with the same retained-heap estimator family used by eval context
(`:erts_debug.flat_size/1 * word_size` plus referenced binary bytes). The cap
is fail-closed: the candidate memory is measured before commit; on breach the
prior committed memory is preserved and `eval-program` returns a stable
`memory_limit_exceeded` error with a summary of the prior memory. A focused
test sets a small `kernel_memory_byte_cap`, proves a larger second definition
is rejected, then successfully returns a prior `x` binding. Each eval also
emits a bounded memory-size event (`memory_bytes`, defined/changed counts) via
the kernel event/log surface. Commands:
`mix test test/ptc_runner/kernel_test.exs test/ptc_runner/kernel/eval_test.exs`
passed 25/25; `mix ptc.kernel_eval --suite mini` passed 5/5 in mock mode.

---

## S6 — Native action protocol hardening

**Question.** Does the V1 action protocol fail closed for malformed or
ambiguous provider responses before any inner eval runs?

**Why it gates.** V1 deliberately removes Markdown/code-fence extraction and
uses native provider tool calling as the model action protocol. That simplifies
the loop only if the transport boundary normalizes and validates every provider
shape into one of: `run_ptc_lisp` action, D14-admitted terminal final, or
protocol error. Otherwise malformed text/tool-call mixtures become policy
ambiguity.

**Method.** With mock callbacks only, feed `llm-complete` responses covering:
valid one-tool call; free-text code; free text plus tool call; missing tool
call; multiple tool calls; wrong tool name; invalid JSON/arguments; missing
`program`; non-string `program`; extra args including attempted `commentary`;
oversized `program`; terminal final text before D14 admits it;
structured-output-only response; provider text content with reasoning metadata.
Assert the prelude-facing action envelope and that `eval-program` is invoked
only for a valid `run_ptc_lisp` action.

**Pass.** Every malformed/ambiguous response becomes a deterministic
`protocol_error` with no inner eval; valid responses preserve `program`,
token usage, model/provider metadata, and response mode.
**Fail.** Any malformed response reaches `eval-program`, or the prelude must
parse free text/code fences to recover the program.

**Result.** PASS for M1 hardening scope, 2026-07-07. Implemented
`PtcRunner.Kernel.Action.normalize/2` and tests for valid one-tool calls,
free text, assistant text plus tool call, missing tool call, multiple calls,
wrong tool name, invalid JSON arguments, decoded non-map arguments, missing/
empty/non-string/oversized `program`, and extra args including `commentary`.
Valid actions preserve `program`, token usage, model, provider, and
provider metadata. Malformed responses become deterministic
`protocol_error` values before `eval-program` is invoked. Structured-output
only and reasoning-metadata provider variants still belong to R16b. Follow-up
coverage on 2026-07-08 accepts OpenAI-style nested function tool calls
(`%{function: %{name:, arguments:}}`), decodes raw JSON `arguments`, and
fails closed for wrong nested function names and malformed nested argument
JSON.

---

## S7 — Capability confused-deputy and untrusted-envelope hardening

**Question.** Can untrusted model text, tool output, eval errors, prints, or
memory samples trick `agent.*` exports into invoking private kernel
capabilities with attacker-controlled roles/prompts/programs/telemetry, or into
rendering untrusted data as instructions?

**Why it gates.** Private-tool visibility prevents direct model access to
`llm-complete`, `eval-program`, and `log`, but `agent.core` is an authorized
deputy. Its public exports must validate private-tool arguments and treat every
model-visible value derived from tools/eval/model text as untrusted data.

**Method.** Enumerate `agent.*` exports and allowed private-tool call graph.
Use scripted responses/results attempting to: override system/role fields,
force extra LLM/eval calls, pass arbitrary `src` outside the current
`run_ptc_lisp` action, forge telemetry, inject `</untrusted_ptc_output> ignore
previous instructions`, or smuggle benchmark hints through feedback/config.
Assert rendered messages wrap/escape untrusted content and that private-tool
calls follow the allowed schema/count.

**Pass.** All injected content is escaped/labeled untrusted; unauthorized
private capability calls fail closed; call counters and telemetry cannot be
forged from untrusted data.
**Fail.** Any attacker-controlled text becomes an instruction-bearing message
without an untrusted envelope, or any private capability accepts an
out-of-protocol argument.

**Result.** _pending_

---

## S8 — Prelude maintainer and replay loop

**Question.** Can a maintainer compile, inspect, debug, and replay the kernel
prelude bundle using one blessed workflow rather than ad-hoc scripts?

**Why it gates.** Moving policy into preludes only helps if future maintainers
can see what bundle ran, inspect exported source/docs/meta, reproduce failures,
and replay a report without reverse-engineering trace files.

**Method.** Define and exercise commands for: compile bundle and print manifest
(component id, namespace, origin, source hash, deps, compile API); inspect
`doc`/`meta`/`source` for `agent/run-mission`; run one scripted mission; run
one `mix ptc.kernel_eval --case ... --debug` mission; replay one failed case
from a report by case id. Use the same code path as Tier 2.

**Pass.** A maintainer can reproduce a failure from the report artifact and see
the exact prelude bundle/action trace without new scripts.
**Fail.** Debugging requires a separate harness, missing bundle/dependency
metadata, or unsafe raw prompt/response artifacts by default.

**Result.** _pending_

---

## S9 — Cross-namespace kernel prelude compilation

**Question.** Can the M2 kernel bundle compile a minimal
`agent.core -> agent.feedback` dependency through the repo-supported prelude
APIs, while keeping raw `Bundle.compile/1` dep-blind and kernel private tools
scoped to the authorized core export?

**Why it gates.** The prelude split is only useful if policy namespaces can be
swapped independently and called from the loop. If cross-namespace refs require
ad-hoc compiler behavior, or if prompt/feedback namespaces inherit kernel-tool
authority from `agent.core`, M2 should stop before moving the embedded loop.

**Method.** Compile `agent.feedback` first. Compile `agent.core` with
`deps: [feedback]` and `namespace_deps: %{"agent.core" =>
["agent.feedback"]}`. Assemble both with `Bundle.compile_precompiled/2` and
the same `namespace_deps:` map. Also assert raw `Bundle.compile/1` over the
same two sources fails with `unknown namespace`, and assert direct model/user
calls to private kernel tools fail closed.

**Pass.** `agent.core` calls `agent.feedback/eval-feedback` end-to-end through
the assembled bundle; `agent.feedback/eval-feedback` has empty `tool_refs`;
`agent.core/run-once` carries only `eval-program`, `llm-complete`, and `log`;
direct `(tool/log ...)` fails with `:private_tool_unauthorized`.
**Fail.** The bundle cannot compile without unsupported APIs, raw
`Bundle.compile/1` accidentally gains dep visibility, or policy exports inherit
private kernel tools.

**Result.** PASS for 2a, 2026-07-08. Evidence:
`mix test test/ptc_runner/kernel/prelude_split_test.exs` passed with 3 tests.
The exact API shape is recorded in `architecture.md` fact 14 and `roadmap.md`
R5. This proves Build Task 2a only; the full `agent.core -> agent.prompt` +
`agent.feedback` graph is still unproven.

2b update, 2026-07-08: PASS for the default full graph. The kernel bundle now
compiles `agent.core -> [agent.prompt, agent.feedback]` from
`priv/preludes/agent/*.lisp`; `agent.core/run-mission` carries only
`eval-program`, `llm-complete`, and `log`, while all prompt/feedback public
exports carry empty `tool_refs`. The same focused suite proves raw direct
private-tool calls still fail closed.

---

## S10 — Pluggable private capability contract

**Question.** Can the kernel grant a new private capability to a prelude export
without editing the kernel source, while keeping it invisible and unauthorized
to model/user code?

**Why it gates.** M1 can hardcode `llm-complete`, `eval-program`, and `log`,
but the broader "policy as prelude diff" thesis needs an extension seam for
future private capabilities: compaction, catalogs, state handles, progress, or
policy plugins. Otherwise every future feature becomes an Elixir kernel edit.

**Method.** Configure a dummy private tool such as `state/get-summary` outside
the kernel trio. A test prelude export calls it through its inferred
`tool_refs`; direct model program calls and unrelated prelude exports fail
closed. Trace output records the capability call with provenance but not raw
secret data.

**Pass.** Adding the capability requires only run config/bundle selection, not
editing `PtcRunner.Kernel.run/2`; authorized export succeeds; unauthorized
callers fail closed; trace/report rendering includes bounded metadata.
**Fail.** The kernel must hardcode the new capability, private visibility is
lost, or trace/report attribution cannot distinguish extension tools.

**Result.** _pending_

---

## S11 — Kernel-shaped soak

**Question.** Does the kernel-shaped path accumulate processes, memory, trace
state, async collector backlog, HTTP pool state, atomics slots, pmap workers,
or full-result caches across many turns/runs?

**Why it gates.** Heap caps catch per-process runaway work, but they do not
prove long-run lifecycle hygiene. The risk areas are retained host references,
process-dictionary trace state, async trace shedding, tool-cache/full-result
retention, linked/unlinked inner sandboxes, and private capability calls under
parallel workers.

**Method.** Run two matrices:

- deterministic mock: 1,000 short kernel-shaped turns with nested evals,
  bounded tool outputs, intentional protocol errors, pmap use where allowed,
  trace logging, and host-held memory handles if D1/D13 choose them;
- live-short HTTP: a smaller run count against deepseek/OpenRouter with short
  prompts and forced timeouts/cancellations, only when `OPENROUTER_API_KEY` is
  present.

Record before/after process count, node/process memory, reductions, sandbox
PIDs, pmap worker PIDs, caller mailbox contents, TraceContext process
dictionary keys, collector mailbox length/drop/write-error counters, atomics
slots, Req/Finch pool health, and report artifact size.

**Pass.** Deltas return to baseline or stay within predeclared caps; no
surviving sandbox/pmap worker PIDs; trace drops are surfaced in reports; HTTP
pool remains healthy after cancellations; report/artifact sizes grow linearly
with configured caps.
**Fail.** Any unbounded process/memory/artifact growth, silent trace loss in
benchmark metrics, stale TraceContext state after failures, or degraded HTTP
pool health.

**Result.** _pending_

---

## S12 — Host-held state handle prototype

**Question.** If D1 chooses host-held memory or opaque handles, can state be
owned, capped, projected, shared, and cleaned up safely?

**Why it gates.** Host-held state avoids lossy/costly value-threading, but it
creates lifecycle obligations: owner process, monitor cleanup, stale-token
errors, byte caps, run-end invalidation, and behavior under parallel prelude
calls.

**Method.** Prototype an owner process for memory/journal/tool-cache-like
state. The prelude receives opaque tokens and bounded summaries/diffs only.
Exercise normal run end, outer timeout, prelude crash, owner crash, stale token,
byte cap exceeded, and concurrent access from allowed `pmap` workers.

**Pass.** Tokens cannot be forged; stale tokens fail with a stable kernel error;
owner dies or clears state on run end/crash/timeout; caps are enforced; pmap
access is serialized or rejected deterministically; prelude-visible projections
stay bounded.
**Fail.** State survives run end unexpectedly, tokens leak authority across
runs, pmap races corrupt state, or projections expose unbounded native memory.

**Result.** _pending_

---

## S13 — Cross-domain holdout and retrieval negative controls

**Question.** Does the kernel harness and `agent.*` policy remain generic when
the tasks are not demo/product/search shaped?

**Why it gates.** Demo parity is necessary, but it can overfit feedback policy
to products, orders, employees, broad range oracles, and the demo
`SearchTool`'s implicit-AND substring behavior. The thesis is stronger than
"works on the demo suite."

**Method.** Add a small holdout suite using the same Tier 2 harness but no demo
files: finance-free numeric tables, graph/topology traversal, calendar/time
intervals, text classification, nested JSON transforms, and non-search tool
orchestration. Add retrieval variants for exact-token search, ranked noisy
search, cursor-only pagination, empty-result ambiguity, and transient tool
errors. Reports stratify by domain, tool shape, oracle strength, turn-count
band, and data-visibility mode.

**Pass.** The same `agent.*` preludes and kernel harness run all cases with no
domain vocabulary in rendered prompts; reports surface failures by stratum; no
genericity claim relies only on aggregate demo pass rate.
**Fail.** Agent policy contains demo hints, harness assumptions break outside
demo data shapes, or retrieval policy only works for demo `SearchTool`
semantics.

**Result.** _pending_

---

## S14 — Release, replay, and package smoke

**Question.** Can the experiment be packaged, inspected, and replayed without
depending on local-only files, unsafe raw prompts, or a live LLM?

**Why it gates.** Moving policy into preludes creates new artifacts:
prelude source/compiled bundles, manifests, reports, trace schemas, and replay
cassettes. The repo currently packages selected `priv` files; the kernel must
decide whether `priv/preludes` is shipped, compiled into modules, or kept
experiment-internal.

**Method.** Produce one Tier 2 report with sanitized action envelopes and eval
projections, then replay a failed/successful case offline with no API key.
Run release/package smoke checks for the chosen prelude home and ensure kernel
modules/mix tasks are either documented as experimental-public or hidden.
Verify default traces contain prompt/action hashes and bounded metadata, not
raw prompts/messages, unless an unsafe debug flag is explicitly set.

**Pass.** Offline replay reproduces the recorded result; package/release smoke
matches D18; trace redaction defaults are safe; unsafe artifacts are opt-in and
excluded from benchmark claims.
**Fail.** Replay needs network/raw prompts by default, packaged artifacts are
missing or accidentally public, or trace defaults leak full prompts/messages.

**Result.** _pending_

---

## S18 — Mini kernel eval runner and DeepSeek probes

**Question.** Can the kernel run a tiny repeatable eval suite from `lib/`
without the full Tier 2 harness, and can DeepSeek handle tasks beyond
arithmetic through the native `run_ptc_lisp` loop?

**Why it gates.** M2 needs measurement before more policy is moved into
preludes. The runner must not depend on `test/support`, must avoid raw prompt
or provider dumps by default, and must make prelude policy changes observable.

**Method.** Implement `PtcRunner.Kernel.Eval` plus
`mix ptc.kernel_eval --suite mini`. Cases: arithmetic, context filter/count,
context aggregation, one granted domain tool, and forced eval retry. Mock mode
uses scripted tool calls and each case has an explicit expected value oracle.
Live mode resolves `PTC_TEST_MODEL`/`--model` via `PtcRunner.LLM.Registry`;
provider-key preflight uses the resolved provider instead of assuming
OpenRouter. The `eval_retry` live case rewrites the first
tool-call program to omit `(return ...)` so the retry path is deterministic.
Reports print per-case status, action count, eval count, and failure reason
without raw prompts/messages/provider dumps. The kernel return trace keeps
action summaries only; generated programs and public tool-call args stay out of
default success traces. The mix task exits non-zero on failed cases unless
`--allow-failures` is set for report-only probes.

**Pass.** Mock mode passes against expected values and the redaction test proves
reports omit API-key strings, raw system prompt text, message payloads,
tool-call payloads, and full programs. If `OPENROUTER_API_KEY` is present, a
live DeepSeek run completes and records the full table, including failures.
**Fail.** The mix task needs test-only helpers, leaks raw prompts/API material,
or live DeepSeek cannot complete even arithmetic/retry cases.

**Result.** PASS for the runner and partial PASS for live DeepSeek,
2026-07-08. Evidence:
`mix test test/ptc_runner/kernel/eval_test.exs` passed; `mix ptc.kernel_eval
--suite mini` passed 5/5 in mock mode with expected-value checks. A regression
test proves a scripted wrong answer fails with `expected_mismatch`, and live
mode now reports provider-specific missing key names before making requests
including the Bedrock bearer-token/key-pair distinction. Focused kernel tests
also prove inner model programs inherit the caller's tool-call cap and returned
success traces omit raw generated programs.
Initial live DeepSeek full-suite run after the split passed 2/5: arithmetic and
forced retry passed, while filter/count, aggregation, and domain tool hit
`turn_limit_exceeded`.
Prelude-only prompt changes then exposed generic context JSON, granted tool
names, concrete `(tool/name args)` syntax, and `data/x` context access; no
Elixir loop-logic change was needed. After those changes, `domain_tool` passed
as a single live case in 2 actions/2 evals, `context_aggregation` passed as a
single live case in 1 action/1 eval, and the first full live mini run passed
4/5 under the original runtime-success-only status rule. After the harness was
tightened to require expected-value matches, the oracle-checked full live run
(`mix ptc.kernel_eval --suite mini --live --model deepseek --allow-failures`)
passed 3/5:

| case | status | actions | evals | failure |
| --- | --- | ---: | ---: | --- |
| arithmetic | pass | 1 | 1 | |
| context_filter_count | pass | 2 | 2 | |
| context_aggregation | fail | 5 | 5 | turn_limit_exceeded |
| domain_tool | fail | 2 | 2 | `expected_mismatch expected=9 actual=%{"score" => 9}` |
| eval_retry | pass | 2 | 2 | |

Conclusion: compact prompt-prelude wording materially changes live behavior,
but aggregation recovery and exact scalar extraction from tool results remain
unstable and should not be promoted as solved.

M3 host-held memory update, 2026-07-08: the mini suite now has six cases,
adding `memory_persistence`. The memory case is forced in live mode to start
with `(def x 41)` so the second turn measures persistence rather than first
turn strategy. A focused live run passed 1/1. The full six-case live run:

| case | status | actions | evals | failure |
| --- | --- | ---: | ---: | --- |
| arithmetic | pass | 1 | 1 | |
| context_filter_count | pass | 1 | 1 | |
| context_aggregation | fail | 5 | 5 | turn_limit_exceeded |
| domain_tool | fail | 2 | 2 | `expected_mismatch expected=9 actual=%{"score" => 9}` |
| eval_retry | pass | 2 | 2 | |
| memory_persistence | pass | 2 | 2 | |

Memory persistence is live-green. It did not reliably fix
`context_aggregation` in the full run; that case remains an unstable retry/
feedback ownership probe. `domain_tool` stayed red as expected, consistent
with scalar extraction rather than memory.

---

## Candidate later spikes (register properly before running)

Spike IDs are claimed by both the registered sections above and this list —
take the next unused number (S20 at time of writing); do not reuse an ID.

- **S19 — Bundle swap provenance:** two bundles differing in one
  `agent.feedback` component; confirm `prelude.metadata.components` +
  `source_hash` are sufficient to attribute a run to a policy variant in turn
  logs (M3 depends on this attribution). Pre-register the follow-on
  feedback-only A/B before running it: feedback prelude is the only variable;
  prompt prelude, cases, `max_turns`, model, eval runner, and host-held memory
  behavior stay fixed; variants must preserve
  `untrusted_eval_result.memory_summary` and may only change how they describe
  it. Run N repeats per case per variant via `--runs`; report pass counts per
  case/variant. At temperature 0.0, repeats are highly correlated provider
  nondeterminism, so the result is directional evidence that a policy variant
  can or cannot recover a failure mode, not a statistical superiority claim.
  Treat `domain_tool` scalar extraction and `context_aggregation` turn-limit
  burn as separate ownership probes: a feedback-only miss on aggregation is
  evidence that prompt policy may own that failure, not a stop condition.
- **S15 — Streaming envelope:** mock streamed chunks from `llm-complete` and
  decide whether the prelude sees incremental events, the host callback sees
  them, or both. Gate: no provider-specific stream shape leaks into
  `agent.core`.
- **S16 — Catalog/discovery capability:** expose upstream catalog
  snapshot/search through a private capability and prelude wrapper while
  keeping inner eval isolated.
- **S17 — Compiled kernel artifact:** freeze `{bundle, mission config,
  capabilities manifest, optional program source}` into a reusable artifact
  executable without SubAgent compiled-agent code.
