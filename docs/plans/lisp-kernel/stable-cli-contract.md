# Standalone CLI distribution

**Status:** active; macOS ARM64 packaging and the Linux AMD64/ARM64 publication
machinery are complete. This plan retains the first container publication and
macOS x86_64 evidence that have not landed.

Implemented architecture belongs in the
[Kernel maintainer guide](../../maintainers/kernel.md), current behavior in
[Running and debugging](../../guides/running-and-debugging.md), and the machine
contract in
[`ptc-command-envelope-v2.schema.json`](../../../priv/schemas/ptc-command-envelope-v2.schema.json).
Git history retains the completed CLI checkpoint designs.

## Goal

Distribute the existing standalone `ptc` release for the supported macOS and
container targets, then reconcile the release evidence and user documentation.
This work does not change command grammar, envelopes, diagnostics, application
acquisition, provider ownership, or REPL semantics.

## Build targets

The release includes its Erlang runtime and cannot be cross-compiled. Each
target builds and verifies its own artifact:

- macOS arm64;
- macOS x86_64;
- Linux amd64 for the container image; and
- Linux arm64 for the container image.

Reuse the existing standalone release verification and launcher conformance
checks. macOS artifacts remain unsigned until a concrete signing/notarization
workflow is funded; documentation must state that limitation precisely.

## Runtime library closure

`include_erts: true` copies the Erlang runtime, not the libraries that runtime
links against. The assembled macOS release therefore is not yet portable: its
`crypto` NIF records an absolute install name under the build host's Homebrew
prefix, and the release directory contains no OpenSSL of its own. On a machine
without that prefix — every Intel Mac, and any Mac without Homebrew — the NIF
cannot load, and `:crypto` is an `extra_applications` entry used on ordinary
command paths.

An artifact is therefore publishable only once packaging closes that gap, and
closure is a property of the whole artifact rather than of the one library
that exposed the problem. The packaging step must:

- walk every Mach-O file in the assembled release — executables, NIFs, and
  bundled libraries alike — rather than a known list;
- classify each recorded dependency as system-provided or foreign, where
  system means the paths macOS itself guarantees;
- vendor every foreign dependency, transitively, into the release, rewrite
  each dependent reference and each vendored library's own identity to a
  loader-relative path, and re-sign in dependency order, because rewriting a
  Mach-O invalidates its signature and an unsigned arm64 library will not
  load;
- carry the vendored libraries' licenses; and
- fail the build on any remaining foreign reference, so a new dependency
  cannot appear silently in a later runtime bump.

The result is ad-hoc signed. It is not Developer ID signed and not notarized,
and the installation documentation must use those words rather than
"unsigned". State the minimum supported macOS version and verify the packaged
artifact on a host that has never had Homebrew, since a build host cannot
observe its own missing dependency.

Linux images inherit the same rule and answer it differently: the runtime
library set is pinned by the image, so the constraint is the base image
digest, not the host distribution.

## Container image

The image must:

- contain the assembled release and launcher companion built for its
  architecture;
- run as a non-root user;
- keep the same command grammar and exit statuses as the local release;
- accept application, host-config, input, and artifact directories only through
  explicit mounts; and
- disable interactive OAuth authorization while retaining already-authorized
  non-interactive execution supported by the standalone runtime.

The image is packaging, not an extra security or compatibility layer. It must
not introduce wrapper-only option aliases, environment inference, or alternate
machine output.

## Remaining distribution work

The next root release tag must execute the container publication workflow,
make the linked GHCR package public, and prove an unauthenticated pull plus
signed-provenance verification for the published multi-platform digest. The
workflow already builds the launcher-bearing finished image on native Linux
AMD64 and ARM64 runners before it publishes that manifest.

macOS x86_64 remains a separate target. It still needs its own packaging run,
runtime-library closure evidence, standalone verification, and release asset.
Publishing it without that target evidence is out of contract.

## Distribution evidence

For every target, build from a clean checkout and run the existing packaged
verification paths plus a provider-bearing fixture. Prove at least:

- `help`, `version`, `init`, `validate`, `run`, `doctor`, `models`, `repl`,
  and `viewer`;
- successful and failed envelope publication;
- normal and private artifact policy;
- launcher discovery and one local provider operation;
- detached private-REPL refusal; and
- byte-identical human fixtures where the platform does not intentionally
  affect a diagnostic.

The gate is complete only when CI names and verifies all four architectures.
Do not describe a multi-architecture image without per-architecture evidence.

## Final acceptance

After target evidence is green:

1. reconcile the root README and installation/running guides with the shipped
   targets and unsigned macOS limitation;
2. verify the packaged command schema and generated docs are current;
3. run the full root, Viewer, launcher, package, and standalone gates; and
4. delete this plan once no distribution work remains.

## Non-goals

- signed downloads or package-manager formulas before their publishing
  infrastructure exists;
- Windows or musl targets;
- a single-file executable;
- authenticated remote Viewer hosting;
- interactive OAuth authorization in detached/container execution; and
- any compatibility alias for removed commands or switches.
