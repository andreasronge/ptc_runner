# Handover: Checkpoint C, `doctor --connect`

Branch: `codex/stable-cli-checkpoint-c-doctor`
Head: the tip of this branch — pushed, tree clean, rebased onto `origin/main`
(`0b3273c5`) on 2026-08-07 and 0 behind it. Do not trust a SHA written here for
where the work stands; derive it:

```text
git log --oneline origin/main..HEAD | head -3          # where the branch is
git log --oneline origin/main..HEAD -- lib/ | head -1  # last commit carrying code
```

A handover that names its own head is stale the moment it is committed, and this
one was already wrong twice from trying.
Gates: `mix precommit` green (5780 root, 72 viewer, 36 launcher); docs gate
green; `mix dialyzer` and `MIX_ENV=test mix dialyzer` both at 0 errors
PR: not opened
CLI safety: `doctor --connect` is reachable from `CommandEngine` as of slice
#5. The whole connect build order is complete; what is left is step 6.

The authoritative plan is `docs/plans/lisp-kernel/stable-cli-contract.md`. This
file is disposable and only describes where the work stands.

## Start here

1. Read "Connect build order" step 6 in `stable-cli-contract.md`. That is the
   contract; this file only says how far along it is. Steps 1–5 are all
   complete, including the CLI enable.
2. Read "Settled decisions" at the bottom of this file before designing
   anything. Two of the three were re-derived the hard way by someone who had
   not read them.
3. Run `mix dialyzer` before believing the branch is clean. `mix precommit` does
   not run it — see below.

## Repo hazard — read before your first commit

This working directory is shared with a concurrent automation that edits files
and switches branches under you. **Never `git add -A` / `git add .` /
`git commit -a` here.** Stage explicit paths, and run `git show --stat <sha>`
before every push.

This was not hypothetical: the commit now on the branch as `f3e9d62b` first
shipped a README diagram and a `mix.exs` ExDoc change written by that process,
including a CDN `<script>` injected into generated HexDocs. A reviewer caught
it, not the fourteen `git add -A` calls that produced it. It was amended out
after confirming both changes were already on `origin/main`.

## Facts that cost time to rediscover

**`mix precommit` does not run Dialyzer; `mix prepush` does.** The registrar
lifecycle-budget slice pushed a 16-error Dialyzer regression that survived
several commits behind a green per-commit gate, and only surfaced when a push
was attempted. Bisect: `c6fa661e~1` = 0, `c6fa661e` = 6, `a4709f1e` = 16. Run
`mix dialyzer` yourself before believing a branch is clean. CI uses
`MIX_ENV=test`, which analyses `test/support` too; run both.

**The 2026-08-07 rebase orphaned every commit id before `238a112a`.** The
SHAs above have been remapped once already; if one does not resolve, find the
commit by subject with `git log --oneline origin/main..HEAD --grep=...` rather
than trusting the id. This matters because the review discipline below tells
you to base-guard a review to a slice base.

**Rebasing this branch costs more than `git merge-tree` suggests.** Most of its
commits regenerate `priv/semantic_build_projection.json` — 35 of 52 at the last
rebase — so a rebase conflicts on that path once per commit even though
`merge-tree` reports a single net conflict. That check models a merge, not a
commit-by-commit replay. The working recipe is to script the rebase, resolving
only that path by running `mix compile && mix ptc.gen_semantic_revision` at each
stop and aborting if any other path conflicts. About 8.5s per conflict. Doing it
this way keeps every replayed commit's projection matching its own tree instead
of deferring to one fixup at the end. Verify afterwards with
`git diff <old-head> HEAD --stat`: it must list only files the upstream changed,
never your own.

**Coverage on this repo has false negatives — do not read it literally.**
`mix test --cover` reports single-line `defp f(...), do: expr` clause bodies as
uncovered even when they are heavily exercised. It flagged
`ProviderCredentials`'s no-credentials-declared path, which is an ordinary case
rather than a defensive one; putting a `raise` in that clause failed 14 of 34
connectivity tests. Verify a suspicious "uncovered" line with a probe before
writing a test for it. Three tests also fail under `--cover` and pass without it
— `HostConfigTest`, `RunCoordinatorExecutionTest`, `SemanticRevisionTest` — so
instrumentation artifacts, not regressions. Coverage output lands in a gitignored
`cover/` with several hundred files; delete it afterwards. Total sits at ~84%,
and most genuinely uncovered lines are fail-closed clauses reachable only with
values callers cannot construct, which is deliberate.

**Dialyzer and Credo do not see an unreferenced *public* function.** Dialyzer
reports unused private ones — that is how a dead `unreleased_diagnostic/0`
surfaced — but a public function with no caller needs its own audit. One was
found this way (`ProviderCredentials.required_names/2`, since made private).
When auditing, match function names as fixed strings: a `?` suffix breaks a
regex scan and will report live code as dead.

**`InspectionAnalysisProfileTest` fails under load.** The
"PTC-Lisp reaches exact evidence" case reports `:memory_exceeded` when the
machine is busy and passes when it is quiet. Verified pre-existing: it fails at
`HEAD` in a clean worktree with no local changes, at load average ~4.6. Do not
attribute it to your slice. `PTC_PRE_PUSH_MAX_CASES=2` reduces the pressure.

## Completed, in the order it landed

The `(complete)` markers in `stable-cli-contract.md` are the full record; this
list starts partway through the branch, at the point where notes were first
kept. The earlier entries it omits — the abort-ordering repair (`1379e7a2`),
the default doctor applicability matrix, phase-7 audited-local execution, the
shared coordinator boundary, and the audited-local trust rule — all landed on
this branch too, and are marked complete in the plan.

**Connectivity modes** (`02bf7741`, `eb8e1ebd`, `af01b229`). Resolved the
inherited semantic question: `connectivity_mode` governs only the connectivity
row, so a `:none` occurrence declaring `selection_validation: :active` still
runs its validator. `CommandContract` is the deciding evidence — connect admits
a success only when every provider row is `pass`, and the rows come from three
independent sealed declarations. Then implemented `:probe` and `:acquisition`:
acquisition barrier first in dependency order, probes in declaration order,
entries projected in manifest order only on success.

**Unverified local checks** (`e1800ed8`..`ec00d0fa`). `LocalPreflight.run_unverified/4`
is the only entry to an `:unverified` callback, reached from the shared
operation prefix so run, check, and connect all cross it; default doctor still
reports `active_check_required`. It runs *after* active selection validation —
that order is a contract, not a preference, because an unverified callback is
unrestricted active work and must not be paid for on a selection the validator
then rejects. Seven review rounds.

**Registrar lifecycle budgets** (`c6fa661e`..`675bf51e`). Three
deadline classes, server-authoritative fences, budgets sealed into the handle,
and commit ownership decided by the reply channel rather than a scheduling
grace. The durable contract now lives in the `ProviderSession` moduledoc under
"Scope lifecycle budgets" — not in this plan directory. Two Fable review rounds,
the second cold, both clean of P1s. It also shipped the Dialyzer regression
described above, which neither round caught because neither ran Dialyzer.

**Shared phase-8 credential resolution** (`238a112a`). Slice #8, built to the
seven-point plan. `ProviderCredentials` is the single authority;
`ProviderExecution.complete/7` resolves once, reached by both the ordinary and
post-authorization branches, after registry and OAuth setup and before the
operation branch. The union comes from the sealed descriptor of every selected
declaration, which is what lets connect answer for a `connectivity_mode: :none`
occurrence that declares a credential. Acquisition and `ConnectivityProbe`
consume the map; the shipped LLM probe no longer resolves its own. One cold
Fable review, no P1; its P2 corrected an over-claimed per-occurrence guarantee.
Six new regressions and three retargeted, each mutation-checked.

**Registrar handle type contract** (`e1ad00f6`). Repairs the Dialyzer regression
above. `ResourceRegistrar.commit/2`'s spec omitted
`{:error, :provider_cleanup_failed}`, which `ProviderSession.settle_commit/2`
returns, so three ownership branches and `unreleased_diagnostic/0` read as dead
code to the type checker. The twelve opacity violations were closed by
completing the `@doc false` accessor set the module had already started, not by
dropping `@opaque` — no *compiled* module outside `ProviderSession` reads a
registrar field, so the fence still earns its keep for the ~10 that hold a
`t()`. Two cold Fable reviews: the first rejected an earlier draft that dropped
`@opaque` outright and caught a half-false claim that callers cannot *construct*
a handle (they can — `new/8` attests whatever it is given; what contains a
minted handle is the session's server-side authority). The second reviewed the
replacement cold and was clean, having checked each of the eleven rewritten call
sites for a `token`/`scope` swap — both are `reference()`, so neither the
compiler nor Dialyzer would catch one.

**Acquisition reason translation** (`4a011766`). Slice #7. `AcquisitionReason`
classifies a callback's bare reason at the three sites in `ProviderAcquisition`
that still hold the occurrence, so an unreachable MCP server stops reading as an
implementation defect. One cold Fable review found a [P1] — the table missed
`:mcp_invalid_snapshot_identity`, which any build of a host installing
`snapshot_identity` produces — plus six dead entries the stdio and discovery
paths normalize away before a builder can return them, and three producers
inside `ProviderAcquisition` itself that were bypassing the very code they
should mint. Two drafts were needed to honour "translations are added with their
producers", so the table now has a test pinning every branch against the catalog
and the contract.

**Up-front OAuth refusal** (`8b7546ed`). The first half of slice #3.
`ProviderExecution` refuses the first selected alias, in manifest order, that
declares `authorization_mode: :oauth` and is not an explicit `--authorize-mcp`
target. Run, `--check`, and connect share it. It sits before both execution
branches, so the interactive one never opens a browser round trip for one alias
before discovering another can never be served, and the ordinary one never
spends a selection validator or an unverified check on a selection already
refused — the same argument the validator/unverified ordering rests on. It is
still past the phase-8 marker, which `active_preflight` pins.

It does not collide with `AcquisitionReason`'s mid-acquisition variant of the
same code: attribution here is per alias with no occurrence, because a grant, an
authority, and a store are all per alias, and reaching acquisition at all means
this refusal found nothing. One cold review, no P1; its P2 was that the
manifest-order tie-break was unpinned, so the regression now separates manifest
order from alphabetical order *and* from a minimum over the names.

**`doctor --connect` in `CommandEngine`** (slice #5). The CLI enable. The
engine derives the plan with `:connect` while the preparation is still claimed,
runs one `RunCoordinator.connect/3`, settles with `settle_connect/4` against the
seal, and projects with `checks/1`; anything failing renders one catalogued
diagnostic and no rows. Three decisions the step did not name are recorded in
the plan: a selection with no providers is answered without an operation,
`provider_activity` follows whether the operation ran, and the engine performs
no frontend VM setup because it cannot prove it owns the VM.

Three cold codex rounds, each finding the same `provider_activity` question
from a different side, and none reachable from a gate. Round one: a raise after
the operation reported `false` for a command that had contacted a provider.
Round two, against the fix: a bare reason from `connect/3` can arrive having
contacted nothing, so treating every bare reason as post-marker invents a cost
(reproduce with a manifest narrowing `normal_event_bytes` to 1, which fails sink
opening in `ExecutionSessionOwner.init`). Round three: the invariant the fix
rested on — post-marker answers are always diagnostics — was itself false,
because `with_registry/8` runs after the marker and forwards an unclassified
reason. `ProviderExecution.classify_marked_failure/1` now enforces it.

Do not "simplify" the classification back to a default in either direction, and
do not try to ask the marker: the execution owner closes the preparation it was
handed on every exit, so `ProviderActivity.value/1` answers `:unknown` by the
time the caller sees the error. That was the first fix attempted and it does not
work.

**Connect-mode `DoctorPlan`** (`f4a59c82`). The second half. `new/4` takes the
mode with no default; `settle_connect/4` settles from `ConnectivityResult`.

The acceptance check from the previous handover is discharged.
`ConnectivityResult.bound_to?/3` and `entries/1` now have their production
consumer, and `valid?/1` follows through `bound_to?/3`. `outcomes/0` had no
consumer even after this and is deleted. `DoctorPlan.pending/1` is private, and
the three test assertions that used it were redundant with `checks/1` refusing
before settlement and succeeding after.

Two cold rounds plus one resumed verification. The first found a *partial*
cross-mode refusal — a deferred credentials row has no connectivity row to be
caught by, so it settled into a list that failed only at the closed result
contract — and an untested `:audited_local`-under-connect mapping, which needed
the test fixture to learn that a host-bound catalog registers `:host_runtime`
rather than an inline authority. The second found a false uniqueness claim in a
test comment about which shipped sources admit an audited-local declaration
without connectivity. Neither round's finding was reachable from any gate.

**MCP transport receive cap** (slice #4). Socket-buffer configuration turned out
to be authoritative, so neither Mint's passive receive loop nor a native helper
was needed and `MCPHTTPAdapter` is still the only HTTP boundary. The full proof
is in `stable-cli-contract.md` at the end of the slice-7 section; the two facts
worth carrying are that `Mint.Core.Util.inet_opts/2` *raises* `buffer` to
`max(buffer, sndbuf, recbuf)` on every `initiate/5` — which is why passing it
through `:transport_opts` had no effect and the bound looked unreachable — and
that applying it after an active-mode connect is too late, because the socket is
already armed under the old buffer.

Measuring it turned up a second, larger hole that the slice also closes: Mint
buffers *unparsed* input with no ceiling, so a peer that never completes a
status line, a chunk-size line, or a chunk extension emits no Mint response, no
declared limit ever runs, and 64 MiB from the peer became 80–134 MiB resident.
The adapter now counts raw socket payloads before parsing them, and **resets the
count whenever Mint returns a response**. The reset is load-bearing, not an
optimisation: the first draft used a cumulative wire ceiling, and a cold review
demonstrated it would refuse a legitimate 2 MiB SSE response sent as 100-byte
events, because chunked framing scales with the chunk count rather than with one
message. The reasoning is in the plan; do not "simplify" it back to a running
total.

Nine mutations were checked and all fail. One property is not pinned by a test
— that `mode: :passive` closes the arm-before-cap window — because it cannot be
forced deterministically. It is covered instead by a canary on the two Mint
behaviours the ordering depends on, which is what will fail on a Mint bump. That
same review showed the window is materially wider over TLS than over TCP, so the
ceiling is applied before the caller-supplied peer verifier rather than after.

Three cold rounds, two Fable and one codex. The first rejected the cumulative
wire ceiling described above. The second found the pending ceiling short by one
TLS record — enough to refuse a single legitimate https message — and, twice
over, prose asserting a peak memory bound the code does not provide. The third
(codex, base-guarded to the slice) found the post-handshake TLS window as a
[P1]: with a 30 ms deschedule between Mint's connect and the ceiling being
reapplied, `ssl` delivers a whole 409600-byte operating-system buffer under a
16 KiB ceiling, 10/10. Round two had seen the same phenomenon and rated it [P2]
after failing to reproduce it on the real sequence; codex was right that it is
reachable. It cannot be prevented — both candidate fixes were measured and fail
— so the receive loop now enforces the per-message bound rather than trusting
the socket option. A fourth round, codex again and cold against the same slice
base, was clean. All three finding rounds found things no gate did.
The residual it recorded rather than closed: total bytes *read* is unbounded,
because bare `1xx` responses reset the counter and advance no ceiling. That is
bandwidth, not memory, and the deadline ends it; closing it means the cumulative
ceiling the first round rejected.

## Remaining, in order

1. **The cumulative `codex review` over `origin/main..HEAD`**, then the PR.
   Everything else in the build order has landed. Note that per-slice reviews
   have covered each change as it went in; the cumulative pass is for what only
   shows up across them.

## Distance to a PR

The cumulative review. Every slice is done and every gate is green.

## Review discipline that has been working

- Base-guard every review to the new slice (`codex review --base <slice-base>`),
  not to `origin/main`. Do not re-review clean slices.
- A resumed reviewer session is never the gate — it carries context for code it
  already approved. Use it to verify a fix batch, then run a **fresh** cold
  reviewer for sign-off.
- Mutation-check every new regression. Several tests on this branch passed
  against the mutation they claimed to pin and had to be rewritten. Asserting an
  error value is usually not enough; assert the thing the change actually
  altered.
- **Reviews have repeatedly found what the gates could not.** A [P1] table gap,
  a false security claim, a non-minimal opacity change, and three bare-reason
  producers all passed a green `mix precommit`. Budget for a cold review per
  slice rather than treating it as optional.
- Codex credits came back on 2026-08-08 and the outstanding cumulative pass is
  still worth doing before the PR. Note the CLI form: this version rejects a
  `[PROMPT]` alongside `--base`, `--commit`, or `--uncommitted`, so a
  base-guarded review has to run bare and a focused one has to go through
  `codex exec`.
- Codex found three [P1]s on the unverified-check slice that Fable did not, and
  Fable found substantive findings on the registrar slice, slice #8, the type
  contract, slice #7, and both halves of #3; they find different classes.
  Everything from `238a112a` onward has had Fable only, because codex credits
  were exhausted — `codex review` was attempted for #3 and refused with a usage
  limit resetting 2026-08-08 05:32. Worth one codex pass over
  `500e5523..<head>` before the PR.
- A review's own claims need checking too. The round that verified #3's fix
  batch retracted a sentence it had let through cold the first time, and the
  fresh round after it found a factual claim about the shipped recipes that both
  earlier passes had accepted. Verify a reviewer's premise before acting on it,
  the same way you would the author's.
- Neither review round on the registrar slice ran Dialyzer, which is how a
  16-error regression reached `origin`. A reviewer reads a diff; it will not
  notice a type contract that silently deleted three branches from the checker's
  view. Run the gate yourself.

## Residuals recorded, not fixed

All are in `stable-cli-contract.md` with reasoning:

- `register_root/2`'s 50 ms mutation reserve is now the only load-bearing timing
  margin in `ProviderSession`, after the commit fence stopped being one. Left
  deliberately — one mechanism per change — but it will read as inconsistent.
- Three reasoned-but-untested branches: the post-`ProviderScopeOwner.start/2`
  recheck, a setup call live at precheck that expires while waiting, and
  `settle_commit/2` finding a committed reply (unreachable while the fence
  holds; kept as the correct answer to a future regression).
- `test "an abort spends its own cleanup budget"` passes at the slice base — it
  guards the invariant but is not evidence for the slice. Labelled as such.
- `ResourceRegistrar.commit/2` and `activate/1` can each return
  `{:error, :provider_session_unavailable}` — the session's fallback
  `handle_call` reply, passed through verbatim — which neither spec admits.
  Reachable only out of contract, because it needs a handle whose token does not
  match the session's, and `new/8` minting such a handle is exactly the forgery
  the `ResourceRegistrar` moduledoc now says is possible. Dialyzer cannot see it
  (a `gen_server` reply is `term()`), and every production caller has an
  `{:error, _}` fallback. Same class as the spec bug `e1ad00f6` fixed, so it is
  named here rather than left to be rediscovered.
- `e1ad00f6`'s message says "no module outside `ProviderSession` reads a
  registrar field". True of compiled code only: three `.exs` test files read
  fields — `provider_session_test`, `mcp_request_context_test`, and
  `mcp_oauth/token_manager_test` — including `scope_controller`, which the
  accessor set deliberately does not cover. (`root_owner` is the other
  uncovered field, and no test reads it.) Scripts are not compiled, so the
  Dialyzer fence holds and the decision stands, but the sentence overstates.
- The phase-8 credential union bounds the *selection*, not the occurrence. On
  the ordinary `acquire/6` run path a preparation can still report a credential
  another selected provider declared and be handed it; `acquire_targets/7` and
  `ConnectivityProbe` are per-occurrence tight. Closing it means giving the
  ordinary path sealed per-occurrence declarations, which is the
  `acquire/6`–`acquire_targets/7` unification rather than a third check.
- `settle_connect/4` trusts that its rows came from `DoctorPlan.new/4` with the
  same trio, because a plan carries no seal of its own — the same assumption
  `settle_pending/1` already makes. It checks the result's binding, the alias
  set, the connectivity cover, and every row's outcome vocabulary, so a plan
  from another application, catalog, or mode is refused; what it cannot see is a
  plan whose aliases and connectivity modes coincide while some other
  declaration differs. Sealing the plan would close it. Recorded rather than
  built: its only production caller is `CommandEngine`, which derives the plan
  and settles it against one catalog and one preparation inside a single
  command, so the gap needs a second caller to be reachable at all.
- The up-front OAuth refusal makes `execute_ordinary`'s memory-runtime branch
  unreachable in practice: with `authorizations == []`, any selected OAuth alias
  is now refused first, so `oauth_authorities/2` always answers `%{}` on that
  branch. Harmless as defense in depth, and left alone under one-mechanism-per-
  change, but it is a candidate for the next simplification pass rather than
  something to discover as a surprise.

## Settled decisions — do not relitigate

- **`connectivity_mode` governs only the connectivity row.** A review called
  active selection validation for a `:none` occurrence a defect; it is not.
  `CommandContract` decides this, and the reasoning is recorded.
- **Credential resolution happens at phase-8 step 5**, once per selected alias,
  before the operation branch — not a remainder pass inside connect. Delivered
  in `238a112a`; the remaining limit is recorded as a residual above.
- **An active command and a direct embedding are different boundaries, and the
  discriminator is whether the session carries an operation deadline**
  (`ProviderSession.execution_deadline/1` returning `{:ok, nil}` versus
  `{:ok, deadline}`). This has now been drawn twice, and both times it was the
  right answer rather than a second pipeline:
  - credentials — an embedding has no sealed declarations to derive a union from
    before preparation, so it keeps the registry's synchronous resolution; and
  - acquisition reasons — an embedding has no envelope to render a diagnostic
    into, and its ~20 distinct MCP and replay reasons are richer than three
    closed codes can carry, so it keeps the bare reason.

  Both are fenced so the distinction cannot decay into a real second pipeline:
  an active command reaching the embedding branch is refused rather than served.
  Before adding a third, check whether the difference is *forced* by what each
  caller has, as it is in both cases above. If it is only a preference, it is
  the second weaker pipeline the acquisition subset was rejected for.
