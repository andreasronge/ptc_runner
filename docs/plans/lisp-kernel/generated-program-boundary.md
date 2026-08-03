# Generated program boundary

Issue [#1168](https://github.com/andreasronge/ptc_runner/issues/1168)
identified two related defects in model-authored subordinate programs: runtime
values can enter dynamic source only through text interpolation, and dynamic
source cannot be checked against its actual mission environment without
spending an evaluation. This plan fixes both without adding forms-as-data,
first-class symbols, or another compiler.

## Decisions

### Parameterize evaluation; do not construct code

`Program` remains an opaque, immutable, code-only value. Its source, byte size,
and SHA-256 digest continue to identify exactly the canonical source captured by
`(program form...)`. Runtime data does not affect that identity.

The kernel prelude gains two explicit helpers:

```clojure
(kernel/eval-with (program
                    (return (tool/fetch {"id" (get data/params "id")})))
                  {"id" incident-id})

(kernel/eval-source-with generated-source {"citations" citations})
```

Both require the second argument to be a canonical JSON value. During that one
subordinate evaluation, it is available at `data/params`; all ordinary mission
data remains available under its existing names. The host overlays the
evaluation-local `"params"` entry on the immutable mission data, so caller
parameters win only for that evaluation. Existing `kernel/eval` and
`kernel/eval-source` retain their one-argument contracts and behave as though no
parameter binding was supplied.

This is value-position substitution by reference rather than source splicing.
It covers scalar, collection, and nested-object inputs, cannot change the
program structure, and leaves the program digest stable across values. No
general value-to-source printer is introduced: `pr-str` and `CoreToSource` are
display and analyzed-artifact serializers, respectively, not safe code
construction APIs.

Reserved runtime routes bypass `Dispatcher`, so they do **not** inherit its
argument checks. Before reserving an evaluation, `kernel-eval` must run one
explicit boundary in this order: strict kernel projection,
`JSONValue.value?/1`, retained-size enforcement against
`capability_argument_bytes`, binary detachment. Native executable values,
ambiguous keys, sets, tuples, and unsupported Java objects are rejected as an
invalid kernel-evaluation request. Source independently remains bounded by
`subordinate_source_bytes`.

Reserved runtime calls also enter the evaluator tool ledger. Add a declarative
trusted-tool ledger-argument projection rather than special-casing names in the
evaluator. Both forms of `kernel-eval` retain only source/program identity and
parameter byte/hash metadata, never the source or parameter value. Parameter
`bytes` and SHA-256 are computed over `DeterministicJSON.encode/1`'s canonical
UTF-8 bytes after the retained-size boundary succeeds; the retained-size value
used for `capability_argument_bytes` enforcement is separate and is not labeled
as serialized bytes. Equivalent JSON objects therefore have one stable ledger
identity. Apply this to the existing one-argument source route as a privacy fix
as well as to the new helpers.

### Check dynamic source against the live mission

The kernel prelude gains:

```clojure
(kernel/check-source generated-source)
```

It performs the exact bounded parse, symbol-count, analysis, Core AST
validation, undefined-variable resolution, and tool-resolution phase used by a
subsequent mission evaluation. It does not execute the AST, invoke a mission
capability, acquire the continuation lease, update continuation memory/history,
or increment `subordinate_evaluations`.

The result is a bounded, model-facing value:

```clojure
{:outcome :valid
 :source_hash "<lowercase sha256>"
 :source_bytes 123}

{:outcome :invalid
 :source_hash "<lowercase sha256>"
 :source_bytes 123
 :diagnostic {:kind :unbound_var
              :message "Undefined variable: missing"
              :details {}}}
```

The response algebra is closed:

| condition | outcome | fields after identity |
|---|---|---|
| compile succeeds | `:valid` | none |
| parse, analysis, Core AST, undefined variable, or tool resolution fails | `:invalid` | `diagnostic` |
| source symbol limit is exceeded | `:invalid` | `diagnostic` with `kind: :symbol_limit_exceeded` |
| compile sandbox timeout or heap kill | `:limit_exceeded` | `reason` (`:compile_timeout` or `:compile_memory_exceeded`) |
| source is oversized | `:limit_exceeded` | `reason: :subordinate_source_bytes` |
| check quota is exhausted | `:limit_exceeded` | `reason: :subordinate_source_checks` |
| run deadline/closure wins before or after compilation | `:limit_exceeded` | `reason: :deadline_expired` or `:run_closed` |
| continuation changes during compilation | `:stale` | `reason: :continuation_changed` |

Check `byte_size/1` before hashing or reserving. An oversized source returns
only `source_bytes` plus its limit outcome/reason, so repeated oversized input
cannot force an unmetered linear hash. For sources within the byte ceiling,
identity is `source_hash` and `source_bytes` even when quota, liveness, or
compilation rejects the check. `diagnostic` appears only for `:invalid` and
contains the production compile error's finite kind, UTF-8 message truncated to
4,096 bytes, and JSON-safe details retained under the same 4,096-byte ceiling.
Other outcomes never pretend that source is invalid. Invalid callback shapes
remain protocol errors. No response contains source or continuation values.

The source hash is over the exact input bytes and permits the workflow to bind a
diagnostic to the string it later evaluates. A successful check is advisory,
not a prepared-code handle: continuation definitions can change before the
later evaluation, and the source is compiled again inside the evaluation lease.

### Meter checks separately

Add a positive `subordinate_source_checks` limit and matching usage counter.
The default is 16. `RunState.reserve_source_check/1` atomically checks run
liveness and the quota, increments the counter, and returns the current native
continuation memory plus a monotonic continuation revision. It does not hold a
lease while compilation runs. `RunState.finish_source_check/2` atomically
rechecks liveness and that revision before the callback publishes its answer;
commit increments the revision. A concurrent commit therefore yields
`:stale/:continuation_changed`, and closure/deadline always wins over a late
compile result.

Checks still share the run deadline, `evaluation_timeout_ms`,
`evaluation_heap_words`, and `subordinate_source_bytes`. Introduce an explicit
Lisp `:compile_max_heap` option whose direct-call default preserves today's
application-configured compiler ceiling; Kernel mission evaluation and source
checking both set it to `evaluation_heap_words`. This makes their compiler heap
behavior identical without silently changing direct `Lisp.run/2` callers.
Together these limits bound CPU, heap, wall time, source size, and count without
charging a no-effect compile to a mission capability or evaluation budget. The
usage and limits surfaces expose the new counter/ceiling everywhere other
Kernel limits are projected.

### Keep static `program` resolution late

`(program form...)` remains syntax-only at component compilation. A static
program may legitimately reference a definition created by an earlier
subordinate evaluation; resolving it while compiling the workflow bundle would
reject that supported continuation pattern. Workflows that want an early
answer can call `kernel/check-source` for dynamic source. An opaque `Program`
does not expose its source to workflow Lisp, so no static-program check helper
is added.

## Implementation

### 1. One production compile stage

Extract the compile phase currently embedded in `PtcRunner.Lisp.execute_program`
into one internal function/module. It accepts already normalized tool metadata,
the attached mission prelude/export mask, symbol and compile sandbox limits,
and the native continuation memory used only for bounded direct lookups of
undefined candidates. It returns either the validated Core AST or the same
`PtcRunner.Lisp.Result` compile error that execution returns today.

The execution path calls that function and then evaluates the AST. A new
internal check entry point calls the same function and projects only the fail
kind, message, and bounded details. Preserve `Lisp.validate/2` as an
environment-free adapter to the same parse/analyze/Core-AST/undefined-variable
stage; it intentionally cannot perform mission tool resolution. There must be
no duplicate implementation of any stage that the two paths claim to share.

Regression tests first demonstrate that checking and evaluating produce the
same diagnostic for parse, unbound-variable, missing-tool, timeout, memory, and
symbol-limit failures.

### 2. Parameterized subordinate evaluation

Extend the private `kernel-eval` request with an optional `"params"` field for
both embedded and source kinds. Apply the explicit reserved-route value
boundary before reserving an evaluation and overlay the detached result as the
`"params"` mission context entry passed to `Lisp.run_native/2`. Add the trusted
tool ledger projector at the same time so source and parameters are replaced by
bounded identities in successful and failed outer workflow results.

Add `kernel/eval-with` and `kernel/eval-source-with` to the shipped kernel
prelude. Keep the original helpers and callback requests valid. Test through
`Kernel.run/2`, not only the callback:

- hostile strings remain data and cannot add a form or change control flow;
- nested JSON values round-trip at `data/params`;
- the same `Program` digest is reusable with different parameters;
- mission data remains visible and an existing mission `params` value is
  shadowed only inside a parameterized evaluation;
- invalid native values and oversized parameters are rejected before the
  evaluation counter changes;
- public workflow results and normal events contain identities, not source or
  parameter values.

Standalone `ReplSession` is not a parity target for subordinate evaluation. It
already reserves the sole continuation lease for the outer interactive form,
so its registered `kernel-eval` route returns `:busy`; moreover that state owns
the REPL workflow continuation, not an independent mission continuation. This
slice does not redesign REPL ownership. Add a regression test preserving that
fail-closed behavior rather than claiming nested evaluation works there.

### 3. Mission-aware source checking

Add the `subordinate_source_checks` limit, RunState counter/reservation, usage
projection, manifest/host schema generation, mission inventory limit
projection, and focused atomic quota tests.

Add a workflow-only reserved `kernel-check-source` callback to Runner. The
callback bounds source, hashes only a source within that bound, reserves a source check,
invokes the shared compile stage with the mission bundle, capability set, and
continuation snapshot, finalizes the revision/liveness check, and returns the
structured result. Register the route as reserved/implicit and wrap it in the
same canonical capability start/stop events as other runtime tools. The
`ReplSession` registration, if required so the kernel component remains
attachable, must fail closed as `:busy` under its existing lease; no source
check is performed or charged.

Mark `kernel-check-source` with the trusted-tool ledger projector so its source
argument becomes exact hash/byte metadata in outer workflow results. This also
keeps source out of normal events; private source capture is not added in this
slice.

Add `kernel/check-source` to the kernel prelude. Integration tests prove:

- syntax, undefined-variable, missing-tool, and structural diagnostics match a
  real evaluation while `subordinate_evaluations` remains zero;
- prior committed definitions are accepted and failed evaluations do not alter
  what a check resolves;
- a successful check invokes no mission capability and does not change
  continuation memory/history;
- quota, source-size, timeout, heap, deadline, and closed-run failures are
  bounded and classified;
- a concurrent continuation commit produces `:stale`, and closure or deadline
  during compilation overrides the compile result;
- source text is absent from normal events and results, while the exact-byte
  hash is returned;
- the route cannot be supplied by either environment, is unavailable in the
  mission environment, and remains fail-closed in standalone REPL evaluation.

### 4. Durable documentation and generated artifacts

Document the helpers, `data/params` scope, advisory/stale check semantics,
diagnostic table, ledger redaction, REPL boundary, and the new limit in the
PTC-Lisp specification and Kernel maintainer guide. Update the operator-facing
host-configuration, manifest/capability, and building-agents guides. Update
generated schema artifacts and any prelude bundle/function metadata via their
source generators. The final implementation must not link code docs to this
plan.

Audit every hand-maintained limit/usage projection, including terminal event
reservation sizing in `RunConfig`, mission inventory/model context,
`AnalysisSession`, trace metadata/query projections, profile recipes, examples,
and Viewer fixtures. Canonical capability-event counts describe instrumented
route attempts and already include reserved routes; the new authoritative
`subordinate_source_checks` usage field describes the separately enforced
budget. Expose both names explicitly rather than implying the event-derived
count equals RunState's provider-capability quota.

## Verification and commit sequence

1. Commit this reviewed plan.
2. Commit the shared compiler and parameterized-evaluation slice with focused
   Lisp, Kernel, and REPL tests.
3. Commit source checking, quota/schema changes, durable docs, and generated
   artifacts.
4. Run `MIX_ENV=dev mix docs --warnings-as-errors` and `mix precommit` before
   each implementation commit as required, obtain an independent review of
   each logical diff, then run a final cumulative review against `origin/main`.
5. Push `codex/issue-1168` through the repository pre-push hook and open a draft
   pull request closing #1168.

## Explicit non-goals

- macros, reader evaluation, syntax quotation, first-class symbols, or arbitrary
  AST construction;
- interpolation or automatic escaping APIs;
- turning `CoreToSource` into a public constructor;
- changing `Program` identity or exposing its source to Lisp;
- resolving embedded programs while compiling their containing component;
- caching a successful check as an executable prepared artifact.
