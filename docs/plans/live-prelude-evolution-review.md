# Review — Prelude Evolution and Versioning Plan

**Reviews:** `docs/plans/live-prelude-evolution.md`
**Method:** multi-agent review — 7 track-finders (BEAM/Store-Identity, security/authority,
compiler integration, API/core-first, phasing/YAGNI, testability, cross-plan consistency),
adversarial per-finding verification (every finding re-opened against source), lead synthesis.
35 findings raised, 27 confirmed/adjusted, 8 refuted. No finding survived at "blocker" severity.

## Verdict

The plan is **not ready to implement as-is**, but it is close: the architecture (handle-backed
store, compile-on-write, candidate wrapping the existing `%Prelude{}`, consumer-bound `requires`,
the `log/`-style two-layer split) is sound and well-grounded in real BEAM/sandbox/compiler
behavior, and the verifiers refuted every claimed *blocker*. The single most consequential
correction is that **C1 ("store id == single namespace contradicts the compiler") is NOT a
blocker** — the plan deliberately separates a store-level invariant from the compiled struct shape
(lines 186-188), so multi-namespace use is handled by per-id splitting + concatenate-then-compile,
not blocked. What MUST be settled before coding: (1) name the concrete `:ets.new/2` owner and
supervision/heir for the store so "long-lived host ownership" is real (A1), (2) define the write
concurrency / read-your-writes contract, which drives the ETS-vs-GenServer choice (A4), (3) commit
E3 to a single composition mechanism (C2), and (4) **split E4** — it silently bundles four
independent hard subsystems and hides the security-load-bearing origin check inside the largest
phase. None of these block starting on E1/E2; they block E2's backing-store decision and E4
specifically.

## Confirmed blockers & majors

*(Deduped across tracks; no item survived at "blocker" severity — every claimed blocker was
refuted. The following are the confirmed/adjusted majors, hardest first. Severities use the
verifier's corrected value.)*

### 1. E4 bundles four independent hard subsystems; the security-load-bearing origin check is buried in the largest phase (major)
**What:** E4 (`live-prelude-evolution.md:758-774`) is a single flat bullet list — structurally
identical to E1-E6 — yet it loads four net-new, independently-riskable subsystems: (a)
`visibility: :private` on `%Tool{}` (no field today; `normalize_format` silently drops unknown
keys, `tool.ex:244-267`), (b) evaluator origin-threading to tool dispatch (the plan itself concedes
at line 467 "This requires evaluator support; it is not true in today's dispatch path"), (c)
per-call arg-signature validation + `lisp_trace`, and (d) the `prelude/` prelude over a new
`source-with-deps` projection.
**Why it matters:** The origin check (b) is the actual fail-open hazard: until it exists, a granted
private tool is directly callable by user code, and a typo'd/unenforced `visibility:` yields a
fully-callable tool. Hiding the one security-load-bearing slice inside an undifferentiated
mega-phase is a real planning hazard, not a sequencing one.
**Evidence:** plan E4 `:758-774`; `eval.ex:823` (`{:tool_call,...}` dispatch carries no origin
marker); `eval.ex:879-880` (`export_ctx = %{caller_ctx | user_ns: ns_env}` swaps only `user_ns`);
`context.ex:41-109` (no origin field).
**Fix:** Split E4. Promote evaluator origin-check + `visibility:` normalization/enforcement +
arg-validation into **E4a**, landing and tested before any `prelude_store` wiring; make the
`prelude/` prelude + `source-with-deps` a separate **E4b**; `SubAgent prelude_store:/preludes:`
acceptance is a third small slice. This is the highest-leverage change in the whole review.

### 2. Store handle ownership and supervision are unspecified (question, load-bearing for E2)
**What:** The plan recommends backing the store with a bare `{:ets, tid}` (line 290-292) and asserts
it is "owned by the long-lived host" (`:276-277`, `:287`) but never names *which process* calls
`:ets.new/2`, nor whether `named_table`/`heir` is needed.
**Why it matters:** The verifier correctly refuted the finding's headline framing — the plan
*deliberately* rejects Holder's session-coupled monitor-and-self-stop (lines 285-288), because the
store must outlive sessions, so inheriting that lifecycle would be a bug. But a bare table id
created by a transient process still vanishes on that process's exit, so "long-lived host
ownership" is not yet concretely real.
**Evidence:** plan `:276-296`; `holder.ex` `use GenServer` / `Process.monitor(owner)` /
self-stop-on-`:DOWN` is the *grant*-layer precedent only.
**Fix:** Before E2, name the concrete owner (a supervised GenServer/Agent that calls `:ets.new/2`,
optionally with `heir`/`named_table`) and document that the store does NOT inherit Holder's
recoverable-error-on-dead-source guarantee. Pairs naturally with #3.

### 3. Append-row + default-pointer-flip + monotonic-version-assign has no stated atomicity / read-your-writes contract (confirmed, question)
**What:** `write/4` appends a version row, may flip the per-id default (`:333-337`), and assigns a
monotonic version (E6, `:790`) — a read-modify-write across three pieces of state. Raw `:ets` is
atomic per single-key op only.
**Why it matters:** Two concurrent same-id `write/4` calls could interleave version assignment or
leave the default on a non-latest row. The plan states no read-your-writes guarantee (within-run vs
across-session). This decision *drives the ETS-vs-GenServer choice* and must be pinned before E2.
**Evidence:** plan `:290-296`, `:333-337`, `:790`; E2 `:740-743` covers compile-atomicity, not
store-row atomicity; Open Questions `:792-807` never touch it.
**Fix:** Serialize same-id writes — a single-owner GenServer (the Holder is already a GenServer)
makes append+flip+version-assign atomic for free, which is the cleanest resolution of #2
simultaneously. State the read-your-writes contract explicitly. Ties #2+#3 together.

### 4. Multi-prelude composition (E3) is unresolved and internally inconsistent; only concatenate-then-compile is viable (question, decide before E3)
**What:** The plan offers two composition mechanisms ("concatenate selected sources then compile
once, or merge compiled artifacts," `:341-345`) but Open Questions claims composition is "mostly
settled" (`:794-798`).
**Why it matters:** Merging two compiled `%Prelude{}` structs is non-viable — `source_hash` is
`@enforce_keys` and hashed over one source string (`compiler.ex:1481-1483`, `prelude.ex:70`), so a
merged struct has no recomputable hash, and `source_index`/`metadata` would have to be hand-unioned,
re-implementing compiler internals the plan forbids. Concatenate-then-compile is the only path to a
genuine single artifact — but it trips `reject_redeclared` (`compiler.ex:188-199`) if two selected
entries share a namespace, so dedup must happen *before* concatenation.
**Evidence:** plan `:341-345`, `:794-798`; the per-id-single-namespace rule resolves collision but
NOT the mechanism.
**Fix:** Commit E3 to concatenate-then-compile, state why merge is rejected, catch
same-namespace-id selection before concatenation (so the compiler doesn't surface a confusing
"declared more than once"), and reconcile the body vs Open Questions wording.

### 5. `source-with-deps` is a multi-structure join, not a one-map projection (minor)
**What:** The plan calls `source-with-deps` "a projection over the compiler's existing source index"
(`:559-566`), but the data lives in two structures: helper *bodies* in `source_index`
(`%{ref => header<>hint<>body}`, `compiler.ex:1248-1253`) and the declared `requires`/`tool_refs` on
`%Export{}` (`export.ex:67-69`, populated by `transitive_backing`, `compiler.ex:643-688`).
Assembling an export + transitive helpers also requires following the `;; depends-on:` hint chain
across multiple `source_index` entries.
**Why it matters:** The load-bearing directive — "do not reimplement a separate source walk in the
host" — *holds* (all three data sources exist, no new AST walk needed); only the word "projection"
understates a small join + chain-walk. The dependency chain is exposed only as a rendered string
hint, so the host must parse it or re-derive the graph.
**Fix:** Reword to a multi-source assembly (export entry + chain-walked helper entries +
`%Export{}.requires`); state E4 must parse the `(source ...)` hint or re-derive the dep graph. Note
`source_index` only holds privates reachable from some public export (`compiler.ex:1241`).

### 6. Store-tool wrappers lack a `guarded/1`-style rescue; a stopped-handle read would abort the program (minor)
**What:** The plan claims store errors surface "as a recoverable value rather than a host crash"
(`:401-406`). The wrapper examples (`:416-434`) normalize `{:ok}/{:error}` tuples but add no
rescue/catch.
**Why it matters:** The handle-backed `PreludeStore` can `:exit` on a stopped-handle read; the
evaluator catches that and re-raises `ToolExecutionError` (`eval.ex:1245-1250`), which **aborts**
the program — contradicting the line-404 no-crash claim.
**Fix:** Add a wrapper-level rescue mirroring `guarded/1` (`introspection.ex:159-164`) but
**returning** a reason-keyed `:prelude_store_error` map instead of raising, so an unexpected
substrate `:exit`/raise degrades to a recoverable value.

## Open decisions to settle before coding

**1. Multi-prelude composition mechanism (E3).** Options: (a) concatenate selected sources then
compile once; (b) merge compiled artifacts. **Recommendation: (a).** Merge is non-viable (no
recomputable `source_hash`, hand-unioned indices). Dedup same-namespace-id selections before
concatenation; fail closed on collisions. Precondition for E3 *and* E4 (both inject into the
singular `:prelude` slot).

**2. Default-selection policy.** The plan says a memory store "may make the new version the default
immediately" (`:335-337`). **Recommendation:** keep auto-default for *ordinary* ids in V1, but for
the reserved editor id `"prelude"`, do **not** auto-default a write — keep the host-shipped
bootstrap as default until an explicit `set_default`, so an untrusted self-rewrite cannot silently
become the standing disclosure/review surface.

**3. Version-history vs current+previous.** **Recommendation: keep full version history** — and it
is NOT the cost driver. The handle is mandated by the per-spawn deep-copy of the captured tools map
(`sandbox.ex:196-217`) regardless of version count, so "current + previous" would buy zero
simplification while losing reproducibility. Version *pinning/default policy* is correctly deferred
to E6; add one sentence in E2 so an implementer doesn't build the pinning resolver early.

**4. Canonical ref grammar.** Two pin syntaxes appear co-equal — `"paged@7"` (no checksum) and
`%{id, version, checksum}` (`:339`). **Recommendation:** declare the map form canonical; treat
`"paged@7"` as sugar that resolves version 7 (no checksum assertion); bare `"paged"` = default. For
a `{version, checksum}` ref, **version selects, checksum verifies against the resolved version's
`source_hash`, fail closed on mismatch**. Specify the `id_or_ref` parse rule for `read/2`. Settle in
E3.

**5. `write/4` return contract.** The dual shape (`{:ok, summary}` vs the test variant's
`{:ok, updated_store, summary}`, `:298-304`) is *not* a production breakage (the value variant is
test-only). But pick ONE return arity behind the public name so all backends (ETS handle, future
Memory/FileSystem) and the wrapper share it.

**6. Store write error taxonomy.** Decide whether `write/4` flattens all compiler `ValidationError`
reasons into `:prelude_compile_error` or passes them through verbatim. A reserved-namespace or
wrong-namespace write fails for *structural* reasons (un-repairable by editing the body), which an
LLM repair loop must distinguish from syntax errors. The documented one-reason envelope (`:200-208`)
under-specifies this.

## Minor findings & nits

- **MCP "only three tools" prose** (`:573-579`) silently omits the shipped
  `lisp_session_list/inspect/forget/close` lifecycle tools (`sessions.ex:30-38`). The E5 Phases
  block (`:776-782`) is already correctly additive — align line 573 to the additive wording and
  state the lifecycle tools are orthogonal and unchanged.
- The reserved namespace set is five names — `tool data budget mcp ptc.core`
  (`protected_namespaces.ex:30`).
- Decide whether `parent_checksum` is validated against the stored parent version's `source_hash` on
  write (recommend: validate, reject stale). `compiled.metadata` (atom-keyed namespace facts) and
  `candidate.metadata` (string-keyed provenance) are disjoint by construction, and `public_view`
  already excludes the compiled artifact (`:444-446`).
- In E1, the `version` provenance field has no producer until E2/E6 — scope E1's extension to
  `origin` only and defer `version`, else an implementer ships an always-nil `version` key. Origin
  must come from the session's frozen-bundle selection, not from `prelude_trace`
  (`turn_event.ex:120` carries only `source_hash` + namespaces); both emit sites (`session.ex:169`,
  `metrics.ex:257`) must merge bundle metadata.
- Foreground multi-prelude composition as THE new E3 work; demote "re-run attach validation per
  eval" to "preserve existing behavior" (it's already per-eval via inline attach today). The
  smallest valuable in-process slice is a selection-only, no-write `Session.new(prelude: ...)` A/B
  between E1 and E2.
- `Session.new`/`SubAgent.run` must **POP** the new `prelude_store:`/`preludes:` opts, not forward
  them — today both leak unknown opts downstream (`session.ex:95`). `Session.preludes/1` is a
  net-new accessor.
- The Motivation should match the turn-log doc's honesty and downgrade the 7-turn smoke to
  "motivating instance, not evidence"; when the formal A/B is written, extend the existing
  Wilson-interval ablation harness (`demo/`) rather than file-based `claude -p` subprocesses — but
  note the "Fresh model context matters" constraint means the demo harness isn't a drop-in. Extend
  the leakage rules to cover the same-instance editor→doc→verifier answer-leak surface.
- The precedent is `tools/2`, not `tools/1` (`introspection.ex:120`); the `opts`/`:max_bytes` arg is
  itself the host-side-bounds precedent the store needs.

## Refuted / dismissed

- **C1 (claimed blocker):** No internal contradiction — plan `:186-188` explicitly separates the
  store-level single-namespace invariant from the compiled struct's list-shaped `namespaces`. Only
  nit: state that a multi-ns *source file* must be split into N entries to be storable.
- **Handle-in-Session "breaks pure-value semantics":** false — `Session` already stores
  `upstream_runtime: pid()` as a struct field and calls it a "handle" (`session.ex:50, 71`).
- **`write/4` dual-shape prod breakage:** the value variant is test-only and never routed to the
  production wrapper; no broken call path exists (the API-cleanup decision survives as Open Decision
  #5).
- **Store tools collapse read/write authority:** `prelude_store_read`/`prelude_store_write` are
  *already* distinct named tools (`:416-438`), so the name-based `requires` check already carries the
  read/write distinction; the E3 strict-subset-grant test (`:755-756`) already covers fail-closed.
- **`log/` miscite for error-as-value:** the plan never claims `log/` demonstrates error-as-value;
  it cites it only for the two-layer architectural split. (The wrapper-hardening kernel survives as
  Major #6.)
- **"Re-run existing validation on every eval" overstated:** accurate, not overstated —
  `attach.ex:96-99` already validates a compiled `%Prelude{}` per call and `Lisp.run/2` invokes it
  every eval; the plan correctly labels it "existing." The genuinely-new work is bundle freezing,
  which E3 scopes.
- **`source-with-deps` second structure unaddressed:** the plan already says "projection over source
  index **and backing metadata**" (`:565-566`).
- **`visibility:` conflates execution and prompt/discovery visibility:** the plan already
  disambiguates (`:450-454`, `:500-503`); only a one-line cross-reference wanted.
- **Holder/Introspection precedent miscited:** accurately cited and self-aware, incl. the
  grant-vs-store lifetime split; no actionable item.
- **Concurrent-write test claim:** `MemorySink.record` is a `cast`, not a `call`
  (`memory_sink.ex:61`); the seam concern is real but subsumed by Major #3.

## Cross-cutting strategic assessment

**Is versioning the right primitive, or over-built for a "modest" goal?** The Motivation explicitly
calls the goal "modest" (`:22`). Versioning is the *right* primitive, but the near-term cost story is
correctly deflated: the handle-backed-ETS machinery is justified by the **per-spawn deep-copy of the
captured tools map** (`sandbox.ex:196-217`), *not* by version-history growth. So "current + previous"
would not simplify anything — the handle is mandatory regardless. The genuinely deferrable complexity
(monotonic assignment, pinning resolver, `set_default`/history, default policy) is already pushed to
E6 and Open Questions, which is correct discipline. Over-build risk is low **provided** E2 stays
minimal and the pinning resolver is not built early.

**Is the trust boundary coherent?** Largely yes, and it is the strongest part of the design. Three
layers are clean: (1) **editor/review TCB** — the `prelude/` prelude is itself the disclosure
surface; (2) **untrusted source** — recorded sessions and agent-authored docstrings are untrusted
instruction surfaces injected into future workers (`:76-79`); (3) **consumer-bound authority** —
`requires` validated against the *consuming* run's grants, with read/write modeled as distinct tool
names. The one coherence gap is **TCB recursion**: a meta-editor that reads untrusted logs can
rewrite the very `prelude` namespace whose source/docstrings later editors rely on, and in a memory
store that rewrite auto-defaults with no review gate. Gated (only host-granted derivation agents can
write), so a question not a blocker — but the fail-safe default (don't auto-default writes to the
reserved `"prelude"` id) should land in V1.

**Is E4 over-loaded?** Unambiguously yes — the single clearest finding. E4 carries the *only*
fail-open security mechanism in the plan (origin threading) flat-bundled with three other net-new
subsystems, presented as one of six co-equal phases. The non-obvious technical reason it can't be
shortcut: a prelude export can pass a private tool ref into a user-supplied HOF, so a static
`check_undefined_tools` pre-pass is insufficient and a **runtime** `EvalContext` origin field is
genuinely required.

## Recommended implementation sequence

**Smallest valuable first slice (de-risks everything, no PreludeStore):**
**E1 + E1.5.** Ship the already-cheap provenance extension (`origin` only; defer `version`). Then add
a thin **selection-only** `Session.new(prelude: ...)` in-process A/B helper over today's
single-artifact path. This proves two of the three Motivation goals (no restart latency, in-process
verification) with zero store, so E2's handle-backed-ETS investment is built against a *proven* need.

**Phase order and hidden risk:**
1. **E2 — Core PreludeStore.** First settle the three coupled decisions (owner/supervision,
   atomicity, return contract): use a **single-owner GenServer** that owns the table and serializes
   same-id writes, which resolves owner-lifetime + append/flip/version-assign atomicity together.
   Keep E2 minimal; state that pinning/default policy is E6.
2. **E3 — Session integration.** Commit to concatenate-then-compile; dedup same-namespace-id before
   concatenation; declare the canonical ref grammar and the fail-closed checksum-verify rule.
   Foreground composition as the new work; ensure `Session.new` *pops* the new opts.
3. **E4a — Authority kernel (HIGHEST HIDDEN RISK).** Land and test the runtime `EvalContext` origin
   field (set in `invoke_prelude_export`, cleared on return, fail-closed when `nil`), `visibility:`
   normalization that *rejects* unknown values fail-closed, and per-call arg-signature validation
   (`Signature.validate_input/2` already exists) returning recoverable `:invalid_tool_args`. Write
   deterministic `eval!`/stub-tool tests — top-level private-tool call fails closed; export call
   succeeds; cross-namespace `tool_refs`-mismatch fails closed. The only fail-open security seam;
   needs a net-new evaluator field with no existing thread; the HOF-leak vector means a static
   pre-pass cannot substitute.
4. **E4b — `prelude/` prelude + `source-with-deps`** (multi-structure assembly) + store-tool wrappers
   with `guarded/1`-style rescue. Add the fail-safe: no auto-default for the reserved `"prelude"` id.
5. **E4c — SubAgent `prelude_store:`/`preludes:` acceptance** + child-inheritance prevention.
6. **E5 — MCP projection** (additive; fix the "expose only" prose).
7. **E6 — Persistent defaults / policy** (deferred correctly).

**Hidden-risk ranking:** E4a > E2 (atomicity) > E3 (composition); everything else is mechanical.

## Codex second-opinion pass (folded in)

After folding the findings above into the plan, an independent `codex` review (read the
plan + this doc + the actual evaluator source: `eval.ex`, `apply.ex`, `eval/context.ex`,
`tool.ex`, `compiler.ex`, `protected_namespaces.ex`) confirmed the codebase claims hold
(sandbox per-spawn copy, attach-per-eval, compiler metadata/hash/source-index, `Tool`
fail-open unknown option, Holder lifecycle) and that single-owner-GenServer +
concatenate-then-compile are the right calls. It raised six refinements, all now folded
into the plan:

1. **E4a origin must be a stack, not a field (High).** Existing closure tags are
   namespace-only (`:prelude_ns`); private-tool authority must be by **export ref +
   `tool_refs`**, pushed on direct export entry, restored on `after`/catch unwind,
   inherited by in-export HOFs, and **dropped for closures that escape** the export.
   Fail closed on empty stack. (Folded into E4a + SubAgent prose.)
2. **Store-side bounded compile (High).** `Compiler.compile/1` runs parse/spec/index/hash
   in the caller and is not sandbox-bounded, so `write/4` must wrap the whole compile in
   its own timeout/heap/byte bound. (Folded into PreludeStore section + E2.)
3. **`"prelude"` no-auto-default contradiction (High).** The Context Refresh Workflow and
   Persistence sections still said a scratch memory store may default any new write;
   corrected to "ordinary ids only, never `prelude`."
4. **ETS owner/heir honesty (Medium).** A process cannot be its own ETS heir; a V1
   memory store loses data on server crash (durability is E6), and `write/4` is a
   synchronous `GenServer.call`. (Folded into Store Identity.)
5. **E2/E3/E6 ref-resolution terms (Medium).** E2 = store-level `id_or_ref` parse +
   checksum verify; E3 = bare-name/session bundle resolution; E6 = `set_default`/history.
6. **`source-with-deps` structured metadata (Medium).** Do not parse rendered
   `;; depends-on:` comments; add a compiler helper returning
   `{source, deps, requires, tool_refs}`.
