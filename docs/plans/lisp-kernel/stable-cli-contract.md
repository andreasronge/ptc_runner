# Standalone CLI distribution

**Status:** active; the shared command engine, Mix frontend, assembled release,
standalone REPL, envelope publication, human rendering, and package verification
are complete. This plan retains only distribution work that has not landed.

Implemented architecture belongs in the
[Kernel maintainer guide](../../guides/kernel-maintainer.md), current behavior in
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

## Distribution evidence

For every target, build from a clean checkout and run the existing packaged
verification paths plus a provider-bearing fixture. Prove at least:

- `help`, `version`, `init`, `validate`, `run`, `doctor`, `models`, and `repl`;
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
