# Handover: Checkpoint C, `doctor --connect`

Branch: `codex/stable-cli-checkpoint-c-doctor`
Head: `7bed8c86` — pushed, tree clean, 37 commits over `origin/main`
Gates: `mix precommit` green (5715 root, 72 viewer, 36 launcher); docs gate green
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

**Registrar lifecycle budgets** (`6878a4bc`..`7bed8c86`). Three deadline
classes, server-authoritative fences, budgets sealed into the handle, and commit
ownership decided by the reply channel rather than a scheduling grace. The
durable contract now lives in the `ProviderSession` moduledoc under "Scope
lifecycle budgets" — not in this plan directory. Two Fable review rounds, the
second cold, both clean of P1s.

## Remaining, in order

1. **#8 shared phase-8 credential resolution.** The agreed 7-point plan is in
   `stable-cli-contract.md` under the connect-settlement gaps. Not started — no
   code exists. Three facts from a read-only survey that shape it:
   - `ProviderAcquisition.credential_names/1` unions the names the *prepare
     callbacks reported*, not the sealed descriptors. `acquire_targets/6` guards
     this with `declarations_honored/2`; the ordinary `acquire/5` run path does
     not. Point 1 of the plan removes that.
   - Resolution currently sits *after* prepare and preflight, inside
     `complete_acquisition`. Point 5 (fail before any provider callback) is a
     genuine reordering of the shared run path, not a relocation.
   - `subject_occurrence_policy(:active_preflight, :credential_unavailable, _)`
     is `:forbidden`, so a credential diagnostic cannot carry an occurrence.
     Deterministic attribution can be per-alias but not per-occurrence; today it
     picks `Enum.find(providers, hd(providers), ...)`, which is order-dependent.
     Say so rather than silently delivering less than point 3 asks for.

   The user was explicit: do **not** take the "connect resolves the remainder"
   shortcut. It creates the second credential pipeline the shared architecture
   exists to eliminate.

2. **#7 raw acquisition-reason translation.** A builder/preflight/acquire
   callback returning `{:error, reason}` propagates as a bare term, and
   consumers collapse it to `internal_error` — an unreachable MCP server reads
   as an implementation defect. Fix where the occurrence is still in scope
   (`prepare_provider/7` and neighbours), because a `provider_acquisition` code
   requires a subject bearing one. Changes the shared run path. **Must land
   before CLI exposure**, but does not block #8.

3. **#3 connect-mode `DoctorPlan` settlement.** `DoctorPlan.new/3` gains the
   mode; connect leaves pending what default doctor settles as
   `requires_connect` / `active_check_required`. Also closes the OAuth gap:
   `active_preflight/authorization_required` is constructed *nowhere in the
   tree* today, so a selected OAuth occurrence currently walks into acquisition
   against an empty store. Connect must refuse it before any provider work, and
   `run` needs the same refusal.

4. **#4 MCP transport receive cap.** The plan says *prove* the bound first: the
   current active-mode Mint loop applies cumulative limits only after a socket
   message has already reached the command process. Either an authoritative
   per-message maximum via socket-buffer configuration, or Mint passive receive
   with an explicit byte cap. `MCPHTTPAdapter` stays the single shipped HTTP
   boundary. **Nothing enables the CLI before this lands.**

5. **#5 enable `doctor --connect` in `CommandEngine`**, then integration review,
   gates, cumulative `origin/main` review, PR.

## Distance to a PR

Four slices (#8, #7, #3, #4) plus the CLI enable. #8 and #4 are the large ones —
#8 reorders a shared authority model, #4 needs a proof before an implementation.
#7 and #3 are moderate. Do not shorten the order: #4 gates #5 for a real safety
reason, which is why the CLI has stayed off through 37 commits.

## Review discipline that has been working

- Base-guard every review to the new slice (`codex review --base <slice-base>`),
  not to `origin/main`. Do not re-review clean slices.
- A resumed reviewer session is never the gate — it carries context for code it
  already approved. Use it to verify a fix batch, then run a **fresh** cold
  reviewer for sign-off.
- Mutation-check every new regression. Three tests this session passed against
  the mutation they claimed to pin and had to be rewritten. Asserting an error
  value is usually not enough; assert the thing the change actually altered.
- Codex credits reset **Aug 8 05:32**. Codex found three [P1]s on the
  unverified-check slice that Fable did not, and Fable found a [P2] on the
  registrar slice; they find different classes. A codex round on
  `9c61b5fb..7bed8c86` is still worth having before calling #9 done.

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

## Two decisions already settled — do not relitigate

- **`connectivity_mode` governs only the connectivity row.** A review called
  active selection validation for a `:none` occurrence a defect; it is not.
  `CommandContract` decides this, and the reasoning is recorded.
- **Credential resolution moves to phase-8 step 5**, once per selected alias,
  before the operation branch — not a remainder pass inside connect.
