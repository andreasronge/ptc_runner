# PtcRunner Launcher

`ptc_runner_launcher` is the optional native POSIX companion for PtcRunner. Its
primary mode is the small packet-framed MCP stdio launcher, which starts a
host-authorized server with:

- an explicit compatibility environment plus configured bindings;
- a caller-frozen SHA-256 identity checked against the executable opened by
  the launcher before spawn;
- separate stdin, stdout, and bounded stderr streams;
- acknowledged backpressure;
- a new process group;
- bounded EOF, TERM, and KILL cleanup, including descendant reaping on Linux;
  and
- a lifeline watchdog that retires that group with a single `SIGKILL` when the
  launcher itself is destroyed before it can run any of that cleanup.

The package restores mandatory-checksum precompiled executables on
`aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-linux-gnu`, and
`x86_64-linux-gnu`. Installation on those targets does not require a C
compiler. Other macOS and Linux targets fall back to the included source and
require a POSIX C compiler and `make`; other operating systems are unsupported.

Release artifacts target macOS 15 or newer. x86-64 GNU/Linux artifacts target
the Ubuntu 22.04 glibc 2.35 baseline; ARM64 GNU/Linux artifacts target the
Ubuntu 24.04 ARM baseline. CI builds and executes each artifact on its pinned
native image rather than floating `*-latest` images.

The core package uses this companion through its internal owner-monitored stdio
transport. Data-driven stdio installation remains part of MCP source
unification.

The same executable also owns the initializer's single platform operation:
atomic no-replace directory publication. It calls
`renameat2(RENAME_NOREPLACE)` on Linux and `renamex_np(RENAME_EXCL)` on macOS,
and fails closed when the primitive is unavailable. Scaffold construction,
staging ownership, cleanup, and command outcomes remain in the core package.

The watchdog runs inside the server's own process group, forked by the server
process after it starts that group and before the identity hash. Membership is
the point: a process group's lifetime keeps its identifier out of the reuse
pool, so signalling the caller's own group can only ever reach the group it was
created for. Nothing holds or transmits a PID, which is what a launcher-side
observer could not avoid — by the time it noticed the launcher's death, the
leader could already have been reaped and its number reissued. It keeps only
the read end of a private pipe whose sole writer is the launcher, and the
launcher's own escalation retires it with the same `SIGKILL` that ends the
group.

This is process containment for trusted host-installed MCP servers, not a
hostile-code sandbox. A trusted child can deliberately leave its process group.
The trusted operator must not modify executable contents during startup.
Linux hashes and executes the same held readable descriptor, which prevents a
path replacement but not an in-place write. macOS cannot exec a descriptor at
all, so it re-reads the canonical path immediately before `execve` and refuses
to start unless that path still resolves to the device and inode it hashed. For
a native executable that leaves the interval between the re-read and the
kernel's own lookup, rather than the length of the hash, which scales with the
executable. An interpreted `#!` target is weaker still: macOS gives the
interpreter the script's path rather than a descriptor, so the interpreter opens
it a second time and no launcher check covers that lookup. A macOS host must
therefore keep the executable path hierarchy immutable for the whole of startup.

The Elixir API is intentionally small:

```elixir
{:ok, path} = PtcRunnerLauncher.executable_path()
1 = PtcRunnerLauncher.protocol_version()
:ok = PtcRunnerLauncher.publish_directory_noreplace(staging, target)
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
