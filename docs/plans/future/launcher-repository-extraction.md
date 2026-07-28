# Extract the launcher into a separate Git repository

**Status:** future, trigger-gated; no approved work. Written 2026-07-28.

`ptc_runner_launcher` is already an independently versioned and released Hex
package, but its source, native release workflows, and integration tests live
in the `ptc_runner` Git repository. This plan records what must be true before
moving that subproject into its own repository and how to perform the move
without weakening protocol compatibility, release provenance, or the normal
core development gate.

The default remains the current monorepo. During 0.x development, one commit
can change the core transport, native implementation, conformance client, and
integration tests together. A repository split is justified only when the
launcher has a genuinely independent maintenance or release boundary and its
wire protocol is stable enough to replace atomic commits with an explicit
cross-repository compatibility contract.

## Goals

- Give the native launcher a focused source, review, issue, CI, and release
  boundary when independent ownership or release cadence warrants it.
- Preserve the launcher's optional Hex-package relationship to `ptc_runner`.
- Preserve or strengthen native artifact checksums, GitHub attestations,
  immutable-release verification, and protected Hex publication.
- Make the private core/launcher protocol a durable, versioned contract with
  executable conformance coverage.
- Preserve integration confidence after core and launcher can no longer change
  in the same commit.
- Retain relevant Git history and leave existing immutable releases verifiable
  at their original repository and tags.

## Non-goals

- Do not generalize the launcher into a public process-management framework.
  It remains the native companion for PtcRunner's MCP stdio transport.
- Do not make the launcher mandatory for HTTP-only consumers.
- Do not change the launcher wire protocol as part of the repository move.
- Do not rewrite the C implementation or change its supported operating-system
  and architecture matrix merely to justify extraction.
- Do not turn process containment for trusted host-installed servers into a
  hostile-code sandbox claim.
- Do not couple launcher and core package versions. Compatibility remains an
  explicit version range and protocol version, not matching release numbers.
- Do not recreate, retag, or replace historical immutable launcher releases in
  the new repository.

## Current state

Established by reading the repository on 2026-07-28.

The launcher is already a separate distributable:

| Boundary | Current implementation |
| --- | --- |
| Mix application | `ptc_runner_launcher/mix.exs` |
| Version and target matrix | `ptc_runner_launcher/release_config.exs` |
| Package API | `PtcRunnerLauncher.executable_path/0` and `protocol_version/0` |
| Package dependency | optional `{:ptc_runner_launcher, "~> 0.1.0"}` in root `mix.exs` |
| Development dependency | nested path dependency when the subproject directory exists |
| Native implementation | `ptc_runner_launcher/c_src/ptc_runner_launcher.c` |
| Package gate | launcher `mix precommit` plus archive and precompiled verification |
| Release tag | independent `ptc_runner_launcher-vX.Y.Z` namespace |
| Publication | launcher-specific release and protected Hex workflows |

The source boundary is clean: launcher production code does not import the
root `ptc_runner` application. The important remaining coupling is the private
packet protocol. Its version, limits, bootstrap fields, frame types,
acknowledgement rules, and shutdown reasons are implemented independently in:

- `lib/ptc_runner/kernel/mcp_stdio_transport.ex`;
- `ptc_runner_launcher/c_src/ptc_runner_launcher.c`; and
- `ptc_runner_launcher/test/support/launcher_port.ex`.

The test client contains the most complete prose explanation, but it is
test-only rather than a retained protocol specification. Root `mix precommit`
also enters the nested subproject directly, and root CI builds the launcher
matrix and release archive from the same checkout. Those properties currently
provide same-commit compatibility and must be replaced before extraction.

## Extraction triggers

Approve this plan only when at least one primary trigger and all readiness gates
hold.

Primary triggers:

- another maintained project needs to consume the launcher or its protocol;
- native code has distinct maintainers, review policy, or security ownership;
- launcher releases regularly need to proceed independently of unrelated core
  state;
- the native build and release surface creates sustained repository or
  permissions friction that path-filtered monorepo CI cannot solve.

Readiness gates:

- the wire protocol has a canonical retained specification;
- core declares an explicit supported launcher package range and protocol
  version;
- shared conformance vectors cover every bootstrap field, frame, limit,
  transition, and terminal reason;
- both repositories can test compatibility without unpublished local path
  dependencies;
- the new repository has approved branch protection, release immutability,
  attestation permissions, publication environments, and maintainers;
- a published launcher release from the new repository exists before the root
  subtree is removed.

CI duration by itself is not a trigger. Before extraction, reduce monorepo cost
with path-aware jobs that run the native matrix for launcher sources, core
launcher-protocol code, release scripts, or relevant workflow changes.

## 1. Specify the launcher protocol

Create a retained, versioned protocol document before moving any source. It
must define, at byte level:

- the initial packet framing and protocol version;
- bootstrap field order, integer widths, string encodings, and limits;
- executable and working-directory identity rules;
- every core-to-launcher control and data frame;
- every launcher-to-core event frame;
- stdin and stdout acknowledgement/backpressure behavior;
- bounded stderr and truncation signaling;
- startup success and failure behavior;
- EOF, TERM, KILL, owner-death, signal, and timeout transitions;
- terminal reason and exit-status encoding;
- invalid, duplicate, late, oversized, and out-of-order frame behavior;
- compatibility rules for additive and breaking protocol revisions.

The extracted launcher repository will own this protocol document and its
conformance fixtures. PtcRunner core will own which protocol version it
requires and how received events map into Kernel transport outcomes.

Acceptance:

- no protocol behavior needed for an independent implementation is left only
  in C, Elixir, or a test comment;
- the native launcher and core transport both pass the same versioned
  conformance corpus;
- a breaking protocol change requires a new protocol version rather than
  relying only on package SemVer.

## 2. Decouple compatibility testing while still in the monorepo

Prove the future boundary before moving it:

1. Keep launcher unit, process-containment, package, precompiled-download,
   checksum-mismatch, and source-fallback tests inside the launcher project.
2. Keep core transport state-machine and failure-normalization tests inside
   `ptc_runner`.
3. Add an integration gate that installs a built launcher package or release
   artifact rather than resolving the nested source path.
4. Test core against the minimum and newest launcher versions admitted by its
   dependency range.
5. Retain an explicit opt-in path or Git checkout override for coordinated
   development of an unreleased protocol version.

The gate must execute the real native artifact on every supported native
platform; checking only `PtcRunnerLauncher.protocol_version/0` or resolving an
executable path is insufficient.

Acceptance:

- deleting or temporarily hiding `ptc_runner_launcher/` does not prevent core
  compatibility CI from resolving a published compatible package;
- a protocol-incompatible launcher fails before spawning a server;
- a launcher implementation defect is caught by both its conformance suite and
  at least one core integration path.

## 3. Define cross-repository compatibility CI

The split repositories need complementary gates:

### Launcher repository

- Run formatting, compilation, unit, conformance, process-containment, package,
  source-fallback, and precompiled verification on launcher changes.
- Test the candidate launcher against the latest supported released
  `ptc_runner`.
- Optionally test against core `main` as a non-release signal; failure must not
  silently widen the declared compatibility range.

### Core repository

- Test the minimum and latest compatible published launcher packages.
- Allow a trusted workflow input for a candidate launcher package or immutable
  release asset during coordinated protocol work.
- Run the full native matrix only when the launcher dependency, protocol
  consumer, stdio transport, staging, host installation, or related workflow
  changes.

### Coordination

- A published launcher release may dispatch or open a dependency-update change
  in core, but it may not mutate core compatibility automatically.
- A core change requiring a new protocol lands only after a compatible launcher
  release is immutable and verifiable.
- Scheduled compatibility runs detect ecosystem or toolchain drift without
  making either repository depend on the other's mutable default branch.

## 4. Create the new repository

Create the approved repository under the intended owner and preserve launcher
path history, for example with a reviewed `git filter-repo` extraction of
`ptc_runner_launcher/`. Record the exact source commit used for extraction.

Move into the new repository:

- launcher production and test sources;
- package metadata, lockfile, changelog, license, and README;
- release configuration and packaging scripts;
- launcher unit, native matrix, release, attestation, and Hex-publication
  workflows;
- the canonical protocol specification and conformance corpus.

Do not migrate root-only files or secrets. Configure from scratch:

- protected default branch and required reviews;
- native-code ownership;
- pinned action permissions;
- protected Hex publication environment and narrowly scoped key;
- release immutability;
- artifact attestations and verification;
- Dependabot or equivalent dependency maintenance.

Historical launcher tags and immutable releases remain in the original
`ptc_runner` repository. The new README and the old release documentation must
state the boundary between historical and new release locations.

## 5. Re-home package and release metadata

Update launcher metadata so:

- `source_url`, package links, issue links, and release asset URLs name the new
  repository;
- precompiled download URLs resolve only immutable assets for the matching
  launcher tag;
- attestation verification names the new repository and exact signer workflow;
- release tags no longer require an unrelated root commit or root release
  gate;
- the verified Hex tarball is still built once, attached, attested, made
  immutable, downloaded, verified, and published as those exact bytes.

Publish and verify one launcher release from the new repository before changing
core's development dependency. Do not remove the monorepo copy while core would
have to resolve an unpublished package.

## 6. Cut core over to the external package

In one core change:

- remove the nested path default and resolve the supported optional Hex package;
- retain an explicit developer override for an external launcher checkout or
  immutable candidate package;
- remove the root alias that changes directory into the nested subproject;
- remove launcher-native build, package, release, and publication workflows
  from the core repository;
- retain core transport and installed-package integration tests;
- update package verification to assert that launcher source is not bundled;
- replace relative launcher documentation links with the new canonical URL;
- update `AGENTS.md`, release documentation, host configuration guidance, and
  contributor commands;
- remove the tracked `ptc_runner_launcher/` subtree only after all preceding
  checks pass.

Core continues to own:

- stdio transport state and request correlation;
- MCP protocol behavior above the process launcher;
- trusted host installation and executable staging;
- the required launcher protocol version and supported package range;
- mapping launcher outcomes into Kernel provider errors and cleanup results.

## 7. Verify the migration

Before declaring extraction complete:

- run launcher conformance and native artifact verification on all supported
  platforms in the new repository;
- build and inspect the launcher Hex package and every precompiled archive;
- verify checksum rejection and source fallback;
- verify GitHub release and asset attestations against the new repository;
- publish only through the protected exact-byte workflow;
- run core tests against minimum and latest compatible launcher releases;
- run a credential-free real MCP stdio flow through the installed package;
- build the core Hex archive under `MIX_ENV=prod`;
- run root `mix precommit`, the tracked pre-push hook, and release-package
  verification;
- confirm unrelated core changes no longer build native launcher artifacts;
- search for stale relative paths, old source URLs, workflow names, tag
  assumptions, and release instructions.

## Rollback

Before the core subtree removal merges, rollback is simply abandoning the new
repository and continuing the monorepo release path.

After core cuts over, rollback must not overwrite or recreate immutable
releases. Pin core back to the last verified compatible launcher package while
fixing the external repository. Restoring a nested development checkout is
permitted as a temporary explicit override, but do not reintroduce two
authoritative release locations.

## Completion and durable documentation

The extraction is complete only when:

- launcher source and native release automation have one authoritative external
  repository;
- core consumes a published compatible package in normal development and
  release builds;
- the protocol specification and conformance corpus are retained and versioned;
- cross-repository compatibility failures are blocking in the appropriate
  repository;
- existing historical releases remain verifiable at their original location;
- current documentation points to exactly one release and source authority.

After completion, retain protocol and release contracts in the launcher
repository, retain core compatibility and operator behavior in
`PtcRunner.Kernel.MCPSource`, `PtcRunner.Kernel.HostConfig`, and the host
configuration guide, update the root release guide, and delete this plan.
