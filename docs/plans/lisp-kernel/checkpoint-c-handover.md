# Handover: Checkpoint C, `doctor --connect`

Branch: `codex/stable-cli-checkpoint-c-doctor`
Head: the tip of this branch — pushed, tree clean, rebased onto `origin/main`
(`0b3273c5`) on 2026-08-07 and 0 behind it. The last commit carrying code is
`4a011766`; anything after it is plan documentation. Confirm with
`git log --oneline -3` rather than trusting a SHA written here — a handover that
names its own head is stale the moment it is committed.
Gates: `mix precommit` green (5750 root, 72 viewer, 36 launcher); docs gate
green; `mix dialyzer` and `MIX_ENV=test mix dialyzer` both at 0 errors
PR: not opened
CLI safety: `doctor --connect` is still unreachable from `CommandEngine`, which
is correct — see the ordering constraint below.

The authoritative plan is `docs/plans/lisp-kernel/stable-cli-contract.md`. This
file is disposable and only describes where the work stands.

## Start here

1. Read the connect-settlement gaps in `stable-cli-contract.md`. That is the
   contract; this file only says how far along it is.
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

This was not hypothetical: commit `37413ae8` shipped a README diagram and a
`mix.exs` ExDoc change written by that process, including a CDN `<script>`
injected into generated HexDocs. A reviewer caught it, not the fourteen
`git add -A` calls that produced it. It has since been amended out
(`1b53ea23`) after confirming both changes were already on `origin/main`.

## Facts that cost time to rediscover

**`mix precommit` does not run Dialyzer; `mix prepush` does.** The registrar
lifecycle-budget slice pushed a 16-error Dialyzer regression that survived
several commits behind a green per-commit gate, and only surfaced when a push
was attempted. Bisect: `6878a4bc~1` = 0, `6878a4bc` = 6, `d7fd0ffc` = 16. Run
`mix dialyzer` yourself before believing a branch is clean. CI uses
`MIX_ENV=test`, which analyses `test/support` too; run both.

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

**`InspectionAnalysisProfileTest` fails under load.** The
"PTC-Lisp reaches exact evidence" case reports `:memory_exceeded` when the
machine is busy and passes when it is quiet. Verified pre-existing: it fails at
`HEAD` in a clean worktree with no local changes, at load average ~4.6. Do not
attribute it to your slice. `PTC_PRE_PUSH_MAX_CASES=2` reduces the pressure.

## Completed, in the order it landed

**Connectivity modes** (`b3d34845`, `74f64a28`, `4443c136`). Resolved the
inherited semantic question: `connectivity_mode` governs only the connectivity
row, so a `:none` occurrence declaring `selection_validation: :active` still
runs its validator. `CommandContract` is the deciding evidence — connect admits
a success only when every provider row is `pass`, and the rows come from three
independent sealed declarations. Then implemented `:probe` and `:acquisition`:
acquisition barrier first in dependency order, probes in declaration order,
entries projected in manifest order only on success.

**Unverified local checks** (`9a5f52e8`..`9c61b5fb`). `LocalPreflight.run_unverified/4`
is the only entry to an `:unverified` callback, reached from the shared
operation prefix so run, check, and connect all cross it; default doctor still
reports `active_check_required`. It runs *after* active selection validation —
that order is a contract, not a preference, because an unverified callback is
unrestricted active work and must not be paid for on a selection the validator
then rejects. Seven review rounds.

**Registrar lifecycle budgets** (`6878a4bc`..`7bed8c86`, now rebased). Three
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

## Remaining, in order

1. **#3 connect-mode `DoctorPlan` settlement.** `DoctorPlan.new/3` gains the
   mode; connect leaves pending what default doctor settles as
   `requires_connect` / `active_check_required`. Also closes the OAuth gap: a
   selected OAuth occurrence currently walks into acquisition against an empty
   store, and connect must refuse it before any provider work, with `run`
   getting the same refusal. Note that `active_preflight/authorization_required`
   *is* now constructed — `AcquisitionReason` mints it for an authorization
   failure discovered mid-acquisition. #3 owns the different question of
   refusing a selected OAuth occurrence up front; the two must not collide.

2. **#4 MCP transport receive cap.** The plan says *prove* the bound first: the
   current active-mode Mint loop applies cumulative limits only after a socket
   message has already reached the command process. Either an authoritative
   per-message maximum via socket-buffer configuration, or Mint passive receive
   with an explicit byte cap. `MCPHTTPAdapter` stays the single shipped HTTP
   boundary. **Nothing enables the CLI before this lands.** Nothing learned in
   the slices above transfers to it — it is a different subsystem and a natural
   place to start with a fresh context.

3. **#5 enable `doctor --connect` in `CommandEngine`**, then integration review,
   gates, cumulative `origin/main` review, PR.

## Distance to a PR

Two slices (#3, #4) plus the CLI enable. #4 is the large one and needs a proof
before an implementation; #3 is moderate. Do not shorten the order: #4 gates #5
for a real safety reason, which is why the CLI has stayed off this long.

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
- Codex found three [P1]s on the unverified-check slice that Fable did not, and
  Fable found substantive findings on the registrar slice, slice #8, the type
  contract, and slice #7; they find different classes. Everything from
  `238a112a` onward has had Fable only, because codex credits were exhausted.
  Worth one codex pass over `500e5523..4a011766` before the PR.
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
  registrar field". True of compiled code only: four `.exs` test files read
  fields, including `scope_controller` and `root_owner`, which the accessor set
  deliberately does not cover. Scripts are not compiled, so the Dialyzer fence
  holds and the decision stands, but the sentence overstates.
- The phase-8 credential union bounds the *selection*, not the occurrence. On
  the ordinary `acquire/6` run path a preparation can still report a credential
  another selected provider declared and be handed it; `acquire_targets/7` and
  `ConnectivityProbe` are per-occurrence tight. Closing it means giving the
  ordinary path sealed per-occurrence declarations, which is the
  `acquire/6`–`acquire_targets/7` unification rather than a third check.

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
