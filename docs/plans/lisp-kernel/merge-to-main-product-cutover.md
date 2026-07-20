# Meta-agentic product cutover to `main`

Status: merge preparation complete; awaiting commit, pull request, and merge,
2026-07-20.

This plan makes the Lisp Kernel branch the canonical PtcRunner product without
waiting for every standalone-distribution milestone. It separates the work
required to merge safely from the work required to publish the first Kernel-era
0.x release.

The product direction is:

> PtcRunner is a bounded meta-agentic harness. Agent orchestration, policy,
> prompts, retries, delegation, memory, and task logic are written in PTC-Lisp.
> The Kernel supplies confinement, capabilities, limits, execution, and
> observability.

PTC-Lisp is the product language. Elixir/BEAM remains the trusted Kernel
implementation and an optional embedding surface, not a prerequisite for the
ordinary macOS or container user.

## Verified starting point

- `main` is an ancestor of the current branch, so the cutover does not require
  reconciling two competing product histories.
- The branch has replaced the legacy SubAgent, MCP-server, upstream, mutable
  prelude, and trace products with the owner-based Kernel.
- Strict manifests, immutable workflow and mission bundles, bounded execution,
  explicit capabilities, canonical traces, private inspection, a REPL, and the
  local Viewer exist from a repository checkout.
- The current published version remains `0.13.0`; the changelog already records
  the branch as a clean 0.x replacement with no compatibility facades.
- The current user journey still assumes Elixir, Mix, and a source checkout.
  The Viewer is a development/test path dependency rather than a published
  product artifact. The README and guides state this explicitly.
- The load-sensitive receive failures, ExDoc warnings, and fixture whitespace
  error found during preparation are resolved. The current uncommitted cutover
  passes the complete merge gate recorded below.

## Product boundary

One concept must have one owner across all three installation channels.

| Concern | Authoritative owner | Product rule |
| --- | --- | --- |
| Agent behavior | PTC-Lisp libraries and workflow components | Planning, model interaction, retries, delegation, memory policy, tool choice, and task logic do not move into channel-specific Elixir code. |
| Authority request | Declarative manifest | A project declares components, providers, data, and requested limits without executing host code. |
| Authority grant | Installed Kernel configuration | PTC-Lisp and manifests cannot grant themselves credentials, callbacks, filesystem roots, commands, or network destinations. |
| Execution and accounting | Owner-based BEAM Kernel | Time, heap, result, event, provider, and lifecycle bounds remain native and fail closed. |
| Command behavior | One shared command layer | Mix tasks, the macOS command, and the container entrypoint are adapters over the same validation and execution path. |
| Public diagnostics | Stable command result schema | All channels use the same JSON success/error envelopes, exit statuses, and stdout/stderr rules. |
| Observability | Kernel event and inspection contracts | Distribution adapters do not create parallel trace formats or relax private-data boundaries. |

“No Elixir required” means that a normal user authors PTC-Lisp and a small
manifest, then invokes `ptc`. It does not mean moving host security, transport,
credentials, process ownership, or resource enforcement into PTC-Lisp.

## Supported installation channels

The first Kernel-era release should support three ways to obtain the same
runtime:

| Channel | Audience | Installation shape | Command surface |
| --- | --- | --- | --- |
| Hex/Mix | Elixir applications and embedders | Add the `ptc_runner` dependency | Existing `mix ptc.*` adapters plus the direct `PtcRunner.Kernel` API |
| macOS | PTC-Lisp authors who do not use Elixir | Versioned self-contained archive, exposed through Homebrew once release hosting is stable | `ptc ...` |
| Docker | CI, reproducible jobs, and non-macOS users | Versioned OCI image with the runtime as its entrypoint | `docker run ... ptc ...` or an image entrypoint equivalent |

All three channels must consume the same manifests and PTC-Lisp files and
produce semantically equivalent results, errors, exit statuses, traces, and
inspection artifacts. Packaging must not fork command or runtime behavior.

The minimum channel-parity command set for the first standalone release is:

```text
ptc init
ptc validate ptc.json
ptc run ptc.json
ptc repl --manifest ptc.json
ptc doctor
ptc version
```

`ptc viewer`, model discovery, and additional operational commands may join the
first release only if they are packaged and tested consistently. Until then,
documentation must label the Viewer as a repository-development tool.

## Merge scope

The merge establishes the new product as the truth on `main`. It does not claim
that the macOS archive, Homebrew formula, or Docker image already exists.

### Slice M1: freeze the product identity

1. Replace the README opening with the bounded meta-agentic-harness definition.
2. State that PTC-Lisp is the user-facing language and Elixir is the Kernel
   implementation and optional embedding API.
3. Keep the explicit 0.x breaking-change notice.
4. Document the three intended installation channels in a status table that
   distinguishes available from planned channels.
5. Remove the public README link to disposable plans. Put implemented status
   and current limitations in durable user documentation.

Gate:

- A newcomer can say what PtcRunner is, what they author, and where authority
  comes from after reading the first screen of the README.
- The README does not imply that standalone artifacts already exist.

### Slice M2: create the short user journey

Restructure the current long tutorial into a small guide set:

1. `getting-started.md`: one credential-free PTC-Lisp workflow from manifest to
   result and trace.
2. `building-agents.md`: workflow/mission separation, shipped agent libraries,
   model interaction, retries, delegation, and capability use.
3. `manifests-and-capabilities.md`: declarative authority requests, installed
   grants, limits, provider configuration, and security boundaries.
4. `running-and-debugging.md`: run, REPL, canonical traces, private inspection,
   and the current Viewer availability.
5. `embedding-in-elixir.md`: the direct Kernel API as an advanced integration
   path rather than the primary product tutorial.

Keep the language specification, generated function reference, conformance
report, trace contract, and maintainer guide as advanced references. Move useful
content out of the existing tutorial before deleting or replacing it.

Gate:

- The first credential-free example is copied from a checked-in fixture and is
  executed in normal tests.
- A user can complete it without reading Elixir code or obtaining an LLM key.
- Model/provider-specific examples are optional follow-on material.

### Slice M3: remove old-product drift

Sweep the repository outside historical changelog entries and clearly marked
retained plans for obsolete SubAgent, deleted MCP-server, upstream-platform,
mutable-prelude, and removed-directory language.

At minimum, inspect:

- public module documentation and types;
- README files under `bench/`, `test/`, `examples/`, and the Viewer;
- CI and assistant workflows that link deleted documentation paths;
- release instructions, `.gitignore`, and package metadata;
- generated documentation sources and examples.

Delete obsolete material instead of preserving compatibility explanations.
When a surviving mechanism is generic Kernel behavior, rename its documentation
to the current concept rather than deleting working code by name alone.

Gate:

- Repository-wide searches find old product names only in the changelog,
  intentionally retained history, or tests explicitly proving removal.
- Code documentation contains no links to `docs/plans/` or deleted paths.

### Slice M4: restore deterministic merge gates

1. Replace scheduling-sensitive receive assertions with explicit barriers,
   monitors, or appropriately bounded synchronization. Do not add sleeps.
2. Fix all ExDoc warnings, including references to intentionally hidden
   internal modules.
3. Fix whitespace and generated-file drift.
4. Decide where `mix docs --warnings-as-errors` belongs and make the release
   path enforce it.
5. Make release documentation truthful: either implement publication in the
   tag workflow or state that publication remains a manual, confirmed action.

Gate:

```text
mix precommit
mix prepush
mix docs --warnings-as-errors
git diff --check main...HEAD
```

All commands pass from a clean worktree. Deadline-sensitive tests also pass in
a repetition run chosen to exercise scheduler load without relying on sleeps.

### Slice M5: whole-range review and merge

1. Review the complete `main...HEAD` range for competing owners, stale parallel
   paths, privacy leaks, cleanup races, and documentation claims that exceed
   implemented behavior.
2. Run one deterministic manifest through `ptc.run`, `ptc.repl`, trace loading,
   and the documented inspection path.
3. Confirm the changelog describes the clean replacement and names deleted
   public products without promising compatibility.
4. Merge by fast-forward or a normal PR merge that preserves the branch's
   coherent history. Do not squash the complete product rewrite into one
   commit.
5. Delete the experiment branch only after the merged `main` and remote refs
   are verified.

Merge exit gate:

- `main` builds and passes every repository gate.
- Public documentation describes the meta-agentic Kernel product, not the
  deleted product and not an unshipped standalone release.
- The deterministic newcomer path works from the repository checkout.
- No required migration shim or dual implementation remains.

## Post-merge standalone release slices

These slices should proceed on `main` after the product cutover. They block the
first standalone release, not the merge itself.

### Slice R1: canonical `ptc` command contract

- Extract command behavior from Mix presentation concerns into one shared
  command layer used by all frontends.
- Define stable JSON envelopes, exit statuses, stdout/stderr rules, and bounded
  diagnostics for `init`, `validate`, `run`, `repl`, `doctor`, and `version`.
- Keep Mix tasks as thin adapters with semantic parity tests.
- Rename obsolete 0.x options instead of adding compatibility aliases.

### Slice R2: macOS artifact

- Choose and document a supported CPU/OS matrix.
- Build a self-contained, versioned `ptc` artifact that does not require an
  existing Erlang or Elixir installation.
- Publish checksums and provenance; add signing/notarization before describing
  the artifact as a normal macOS install.
- Add a Homebrew formula backed by the versioned artifact.
- Smoke-test install, deterministic run, trace creation, version reporting, and
  uninstall on a clean macOS runner.

The packaging implementation may be a release with bundled ERTS or a proven
single-artifact packager. Choose it through a short spike; do not let packaging
technology define a second runtime architecture.

### Slice R3: Docker artifact

- Publish a versioned OCI image with `ptc` as its entrypoint and an explicit
  working directory.
- Run without root privileges and support read-only project mounts plus a
  separate writable output/trace mount.
- Inject credentials through deployment configuration; never copy them into
  images, manifests, PTC-Lisp data, traces, or inspection output.
- Document signal handling, exit statuses, resource limits, architecture
  support, and image retention.
- Smoke-test the same deterministic fixture used by Mix and macOS.

Do not expose the Viewer from the first container merely by widening its
current loopback binding. Container Viewer access needs its own explicit bind,
origin, and private-inspection security contract.

### Slice R4: distribution parity and Viewer decision

- Run one fixture corpus against Mix, macOS, and Docker artifacts and compare
  normalized outcomes, error codes, usage, and trace contracts.
- Test success, manifest failure, Lisp failure, capability denial, timeout,
  cancellation, and credential redaction.
- Package the Viewer as an intentional artifact or keep it clearly outside the
  supported release. Do not advertise development-only wiring as installed
  functionality.
- Verify that each artifact can be installed, exercised, and removed using only
  published instructions.

### Slice R5: first Kernel-era 0.x release

1. Bump `0.13.0` to `0.14.0` unless intervening releases require another
   version.
2. Convert the changelog's Unreleased replacement section into the versioned
   release entry.
3. Build and verify the Hex package, macOS artifact, Homebrew formula, Docker
   image, and generated documentation from the same commit and tag.
4. Publish only after explicit confirmation and a green release workflow.
5. Verify downloads, checksums, image digest, HexDocs, examples, and clean
   installation after publication.

Release exit gate:

- A non-Elixir user can install PtcRunner on macOS or through Docker, author
  only PTC-Lisp plus a manifest, run the getting-started agent, and inspect its
  bounded result and trace.
- An Elixir user can obtain the same runtime through Hex/Mix and optionally
  embed the Kernel.
- All channels implement one command and runtime contract.

## Explicit non-goals for the merge

- General connector catalogs, databases, arbitrary shell execution, or
  unrestricted network capabilities.
- Restoring deleted SubAgent or MCP-server APIs.
- Compatibility shims for the 0.13 product.
- Multi-model routing, a hosted service, shared IAM, or remote private Viewer
  access.
- Completing every Clojure conformance gap.
- Publishing artifacts before their installation and removal paths are tested.

## Risks and controls

| Risk | Control |
| --- | --- |
| “Everything in Lisp” weakens the host boundary | Keep authority grants, credentials, transports, ownership, and hard limits native; test that Lisp cannot manufacture them. |
| Three installs become three products | One shared command layer, one manifest loader, one Kernel path, and cross-artifact semantic parity tests. |
| Merge waits indefinitely for packaging | Merge on documentation truth and green repository gates; make artifacts release gates. |
| Standalone claims get ahead of implementation | Use explicit availability tables and test install/uninstall before changing status. |
| Docker weakens Viewer privacy | Do not widen binding by default; design container access as a separate security slice. |
| The long tutorial is deleted before content is retained | Split and verify guides before removing the old entry point. |

## Completion record

Merge preparation completed on `exp/minimal-kernel` on 2026-07-20. The work is
intentionally uncommitted and has not been merged, tagged, or published.

- M1: `README.md` now owns the meta-agentic product definition, PTC-Lisp/Kernel
  boundary, 0.x warning, and truthful installation status.
- M2: the short user journey is split across `getting-started.md`,
  `building-agents.md`, `manifests-and-capabilities.md`,
  `running-and-debugging.md`, and `embedding-in-elixir.md`; checked-in tutorial
  fixtures exercise the credential-free path in normal tests.
- M3: obsolete product documentation, automation references, and package drift
  were removed or rewritten around the Kernel product.
- M4: scheduler-sensitive tests, documentation warnings, generated/doc links,
  and whitespace drift were repaired. Release instructions and automation now
  require a commit contained in `main`; the tag workflow verifies but never
  publishes.
- M5 review: two independent whole-range reviews found and drove regression
  coverage for file-grant replacement, REPL commit/event failure ordering,
  concurrent and hard-link trace appends, event normalization/accounting,
  malformed event boundaries, MCP remote-error classification, advisory-lock
  cleanup, and retained-contract workflow labeling.

Verified after the final fixes:

```text
mix precommit
  396 specification examples
  125 doctests, 3 properties, 4,169 root tests
  67 Viewer tests
  0 failures
mix prepush
  Dialyzer: 0 errors
  unused dependency check: passed
MIX_ENV=dev mix docs --warnings-as-errors
git diff --check main
```

The only unfinished M5 actions are the git operations themselves: create the
intentional commit set, open/review the pull request, merge to `main`, rerun the
same gates on `main`, and then remove the experiment branch after remote
verification. R1–R5 remain post-merge work on `main`; no version bump, release
tag, Hex publication, macOS artifact, or Docker publication belongs in this
merge.

After the branch is merged, remove this plan once any still-useful product
contract has been moved into the README, user guides, release guide, and owning
module documentation. Git history remains the migration record.
