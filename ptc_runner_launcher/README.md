# PtcRunner Launcher

`ptc_runner_launcher` is the optional native companion for PtcRunner's MCP
stdio transport. It provides one small packet-framed executable that launches
a host-authorized server with:

- an explicit compatibility environment plus configured bindings;
- separate stdin, stdout, and bounded stderr streams;
- acknowledged backpressure;
- a new process group; and
- bounded EOF, TERM, and KILL cleanup, including descendant reaping on Linux.

This first package slice builds from source on macOS and Linux and is not yet
connected to the core transport. It requires a POSIX C compiler and `make`.
A following Slice 2 change adds checksummed precompiled executables before the
companion becomes the normal stdio installation path.

This is process containment for trusted host-installed MCP servers, not a
hostile-code sandbox. A trusted child can deliberately leave its process group.

The Elixir API is intentionally small:

```elixir
{:ok, path} = PtcRunnerLauncher.executable_path()
1 = PtcRunnerLauncher.protocol_version()
```

MCP protocol handling, request ownership, and transport policy remain in the
core `ptc_runner` package.
