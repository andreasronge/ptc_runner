# Handover: Checkpoint C, `doctor --connect`

Branch: `codex/stable-cli-checkpoint-c-doctor`
Head: `e1ad00f6` — pushed, tree clean, 52 commits over `origin/main`, rebased
onto `origin/main` (`0b3273c5`) on 2026-08-07 and currently 0 behind
Gates: `mix precommit` green (5741 root, 72 viewer, 36 launcher); docs gate
green; `mix dialyzer` and `MIX_ENV=test mix dialyzer` both at 0 errors
PR: not opened
CLI safety: `doctor --connect` is still unreachable from `CommandEngine`, which
is correct — see the ordering constraint below.

The authoritative plan is `docs/plans/lisp-kernel/stable-cli-contract.md`. This
file is disposable and only describes where the work stands.

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

## Two gate facts that cost time to rediscover

**`mix precommit` does not run Dialyzer; `mix prepush` does.** The registrar
lifecycle-budget slice pushed a 16-error Dialyzer regression that survived
several commits behind a green per-commit gate, and only surfaced when a push
was attempted. Bisect: `6878a4bc~1` = 0, `6878a4bc` = 6, `d7fd0ffc` = 16. Run
`mix dialyzer` yourself before believing a branch is clean. CI uses
`MIX_ENV=test`, which analyses `test/support` too; run both.

**Rebasing this branch costs more than `git merge-tree` suggests.** 35 of its
52 commits regenerate `priv/semantic_build_projection.json`, so a rebase
conflicts on that path once per commit even though `merge-tree` reports a
single net conflict — that check models a merge, not a commit-by-commit replay.
The working recipe is to script the rebase, resolving only that path by running
`mix compile && mix ptc.gen_semantic_revision` at each stop and aborting if any
other path conflicts. About 8.5s per conflict. Doing it this way keeps every
replayed commit's projection matching its own tree instead of deferring to one
fixup at the end. Verify afterwards with `git diff <old-head> HEAD --stat`: it
must list only files the upstream changed, never your own.

## Completed

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
dropping `@opaque` — no module outside `ProviderSession` reads a registrar
field, so the fence still earns its keep for the ~10 that hold a `t()`. One cold
Fable review; its two P2s produced that approach and corrected the moduledoc's
half-false claim that callers cannot *construct* a handle (they can — `new/8`
attests whatever it is given; what contains a minted handle is the session's
server-side authority).

## Remaining, in order

1. **#7 raw acquisition-reason translation.** A builder/preflight/acquire
   callback returning `{:error, reason}` propagates as a bare term, and
   consumers collapse it to `internal_error` — an unreachable MCP server reads
   as an implementation defect. Fix where the occurrence is still in scope
   (`prepare_provider/7` and neighbours), because a `provider_acquisition` code
   requires a subject bearing one. Changes the shared run path. **Must land
   before CLI exposure**, but does not block #8.

2. **#3 connect-mode `DoctorPlan` settlement.** `DoctorPlan.new/3` gains the
   mode; connect leaves pending what default doctor settles as
   `requires_connect` / `active_check_required`. Also closes the OAuth gap:
   `active_preflight/authorization_required` is constructed *nowhere in the
   tree* today, so a selected OAuth occurrence currently walks into acquisition
   against an empty store. Connect must refuse it before any provider work, and
   `run` needs the same refusal.

3. **#4 MCP transport receive cap.** The plan says *prove* the bound first: the
   current active-mode Mint loop applies cumulative limits only after a socket
   message has already reached the command process. Either an authoritative
   per-message maximum via socket-buffer configuration, or Mint passive receive
   with an explicit byte cap. `MCPHTTPAdapter` stays the single shipped HTTP
   boundary. **Nothing enables the CLI before this lands.**

4. **#5 enable `doctor --connect` in `CommandEngine`**, then integration review,
   gates, cumulative `origin/main` review, PR.

## Distance to a PR

Three slices (#7, #3, #4) plus the CLI enable. #4 is the large one and needs a
proof before an implementation; #7 and #3 are moderate. Do not shorten the
order: #4 gates #5 for a real safety reason, which is why the CLI has stayed off
through 52 commits.

## Review discipline that has been working

- Base-guard every review to the new slice (`codex review --base <slice-base>`),
  not to `origin/main`. Do not re-review clean slices.
- A resumed reviewer session is never the gate — it carries context for code it
  already approved. Use it to verify a fix batch, then run a **fresh** cold
  reviewer for sign-off.
- Mutation-check every new regression. Three tests this session passed against
  the mutation they claimed to pin and had to be rewritten. Asserting an error
  value is usually not enough; assert the thing the change actually altered.
- Codex found three [P1]s on the unverified-check slice that Fable did not, and
  Fable found a [P2] on both the registrar slice and slice #8; they find
  different classes. Slice #8 and the type-contract repair have had Fable only —
  codex credits were exhausted when they landed, and the user chose not to wait
  for a round. Worth one codex pass over `500e5523..e1ad00f6` before the PR.
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
- The phase-8 credential union bounds the *selection*, not the occurrence. On
  the ordinary `acquire/6` run path a preparation can still report a credential
  another selected provider declared and be handed it; `acquire_targets/7` and
  `ConnectivityProbe` are per-occurrence tight. Closing it means giving the
  ordinary path sealed per-occurrence declarations, which is the
  `acquire/6`–`acquire_targets/7` unification rather than a third check.

## Two decisions already settled — do not relitigate

- **`connectivity_mode` governs only the connectivity row.** A review called
  active selection validation for a `:none` occurrence a defect; it is not.
  `CommandContract` decides this, and the reasoning is recorded.
- **Credential resolution moves to phase-8 step 5**, once per selected alias,
  before the operation branch — not a remainder pass inside connect. Delivered
  in `238a112a`; the remaining limit is recorded as a residual below.
