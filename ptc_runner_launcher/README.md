# PtcRunner Launcher

`ptc_runner_launcher` is the optional native companion for PtcRunner's MCP
stdio transport. It provides one small packet-framed executable that launches
a host-authorized server with:

- an explicit compatibility environment plus configured bindings;
- separate stdin, stdout, and bounded stderr streams;
- acknowledged backpressure;
- a new process group; and
- bounded EOF, TERM, and KILL cleanup, including descendant reaping on Linux.

The package restores a mandatory-checksum precompiled executable on
`aarch64-apple-darwin` and `x86_64-linux-gnu`. Installation on those targets
does not require a C compiler. Other macOS and Linux targets fall back to the
included source and require a POSIX C compiler and `make`; other operating
systems are unsupported.

Release artifacts target macOS 15 or newer and GNU/Linux distributions
compatible with the Ubuntu 22.04 glibc 2.35 baseline. CI builds and executes
the artifacts on those pinned baseline images rather than floating
`*-latest` images.

The package is not yet connected to the core transport.

This is process containment for trusted host-installed MCP servers, not a
hostile-code sandbox. A trusted child can deliberately leave its process group.

The Elixir API is intentionally small:

```elixir
{:ok, path} = PtcRunnerLauncher.executable_path()
1 = PtcRunnerLauncher.protocol_version()
```

MCP protocol handling, request ownership, and transport policy remain in the
core `ptc_runner` package.

Maintainers can force the audited source path without attempting a download:

```elixir
config :elixir_make, :force_build, ptc_runner_launcher: true
```

Release tags use `ptc_runner_launcher-vX.Y.Z`, independently of root
`ptc_runner` releases. The tag workflow builds and executes each supported
artifact, verifies rejection of a checksum mismatch and source fallback,
assembles the mandatory checksum map, and attaches the verified Hex package to
an operator-published immutable GitHub release. It records build provenance for
the exact assets before creating the editable release draft.

The separately approved publication workflow verifies the immutable release
and package-asset attestations, plus the package's tag-workflow provenance,
then uploads that exact package tarball through the Hex package API instead of
rebuilding it.
