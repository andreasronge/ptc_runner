# Development setup

> **Audience:** people and coding agents preparing a source checkout to change
> PtcRunner itself.

One-time and per-worktree setup for working on PtcRunner itself. Day-to-day
rules live in `AGENTS.md`; this guide holds the parts you run once and then
forget.

## Toolchain and dependencies

Tool versions are pinned in `mise.toml`. `scripts/worktree.sh new` performs the
commands below automatically for a new worktree. From a new clone, or to repair
a partially initialized checkout, run `scripts/worktree.sh init`; its
equivalent manual sequence is:

```bash
mise install
mix deps.get
(cd ptc_viewer && mix deps.get)
(cd ptc_runner_launcher && mix deps.get)
mix compile
```

The nested projects are listed because `mix test` inside `ptc_viewer/` or
`ptc_runner_launcher/` needs them; no gate depends on your having run them.
`mix precommit` opens with `scripts/ci/preflight.sh`, which fetches both, and
each gate fetches the project it compiles — running
`mix deps.get --check-locked`, the command GitHub runs once per job.

### PtcLlmHttp compatibility coverage

Dev and test builds pin the published Hex package `ptc_llm_http` at exact
version `0.1.0`. Ordinary `mix test` runs the loopback, credential-free
streaming smoke in `test/ptc_runner/llm/ptc_llm_http_smoke_test.exs`. That
coverage is compatibility only: production still uses the ReqLLM adapter,
`ptc_llm_http` is not a production runtime dependency, and it is not selected
for ordinary requests.

```bash
mix test test/ptc_runner/llm/ptc_llm_http_smoke_test.exs
```

The focused tests use only a loopback raw HTTP fixture and no credentials.

## Worktree seeding

`scripts/worktree.sh new` seeds a fresh worktree with the main checkout's
`deps/`, `_build/`, and `priv/plts/` (root, Viewer, and launcher), then runs
`scripts/worktree.sh init` so the checkout is ready for tests. Initialization
installs the shared Git hooks, installs the pinned toolchain through `mise`,
fetches root/Viewer/launcher dependencies, compiles the root project, and
removes group-write permissions under a `0022` umask so Linux cloud agents do
not create directory trees that fail private-destination safety tests. Pass
`new --no-init` only when deliberately deferring that work, then run
`scripts/worktree.sh init <dir>` before editing or testing.

The seed is a cache, never an authority: Mix and dialyxir revalidate every
copied artifact, so a stale seed costs a rebuild rather than a wrong answer.
It prints one line per artifact saying whether it was seeded or why not, and
skips an artifact whose pinning files (`mise.toml` plus that project's own
`mix.lock`) differ from the main checkout. The one thing it takes on faith is
dependency fidelity: a locally edited dependency in the main checkout travels
with the seed, so do not seed from a checkout whose `deps/` you have edited.
The staging, atomic promotion, and PLT rules are documented in the seeding
section of `scripts/worktree.sh`.

To warm the cache, keep the main checkout built: `mix compile` and
`mix dialyzer` there make every subsequent worktree cheap. To fill gaps in an
existing worktree (artifacts already present are left untouched):

```bash
scripts/worktree.sh seed          # seed the current worktree
scripts/worktree.sh seed <dir>    # seed another worktree
```

## Git hooks

`scripts/worktree.sh new` and `scripts/worktree.sh init` run
`./scripts/install-hooks.sh` automatically. Linked worktrees share the clone's
installed hook wrappers, so this is idempotent and also repairs a clone whose
wrappers are absent. Run `./scripts/install-hooks.sh` directly only when
setting up a clone without using the worktree lifecycle script. The wrappers
set a `0022` umask and, when `mix` is absent from Git's non-interactive `PATH`,
run the tracked hooks through the same `mise` resolution used by worktree
initialization.

The script also registers the merge driver for
`priv/semantic_build_projection.json`. That projection is derived, its hashes
cannot be merged, and only the release gate checks it — so never regenerate it
on a feature branch and never hand-merge it. Run `mix regen` on `main` before
tagging. `.gitattributes` explains why.

## Local CI modes

GitHub Actions and the tracked hooks delegate deterministic gates to the
scripts in `scripts/ci/`. Run the core gate directly when diagnosing a test
failure:

```bash
scripts/ci/core-tests.sh
```

That command sets `CI=1`, including StreamData's 300-run setting, but retains
the machine's native scheduler count for higher local pressure. A complementary
four-scheduler run reproduces GitHub's current CPU shape:

```bash
scripts/ci/core-tests.sh --schedulers 4
```

The second command still runs on the local operating system. It is CPU-shape
parity, not an Ubuntu container; OS-level parity remains a separate concern.

## Dialyzer PLT

Outside CI the core PLT lives under `~/.cache/ptc_runner/` and is shared across
every worktree, so only the very first Dialyzer run on a machine builds it from
scratch. Each worktree still keeps its own project-specific
`priv/plts/project.plt`.

A toolchain bump leaves the project PLT stale, which surfaces as `mix dialyzer`
failing with "Old PLT file" while `--plt` reports it up to date. Remove
`priv/plts/*` and rebuild.

## Local MCP E2E server

The MCP E2E tests use the stateless harness in `test/support/mcp_go_stateless`.
Its `go.mod` pins the official Go SDK protocol implementation. Start it in one
terminal:

```bash
mcp_server_dir="$(mktemp -d)"
go -C test/support/mcp_go_stateless build \
  -o "$mcp_server_dir/ptc-mcp-http-server" .
"$mcp_server_dir/ptc-mcp-http-server" -host 127.0.0.1 -port 8000
```

This server speaks plain HTTP, so a host document reaching it needs
`"allow_insecure_loopback": true` on the transport. See
[reaching a local server over plain HTTP](../reference/mcp.md#reach-a-local-server-over-plain-http)
for the rule and a `doctor --connect` baseline.

The credential-free interoperability test runs as a dedicated PR check and can
be run from another terminal:

```bash
PTC_TEST_MCP_2026_ENDPOINT=http://127.0.0.1:8000 \
  mix test test/ptc_runner/kernel/mcp_remote_e2e_test.exs \
    --include e2e --trace
```

The OAuth authorization/interoperability test starts the same official SDK
server behind its deterministic OAuth harness and an ephemeral TLS certificate:

```bash
PTC_TEST_MCP_OAUTH=1 PTC_TEST_MCP_TLS=1 \
  bash test/support/mcp_go_stateless/with_server.sh \
    mix test test/ptc_runner/kernel/mcp_oauth_remote_e2e_test.exs \
      --include e2e --trace
```

The wrapper writes an ephemeral CA inside its exact temporary directory and
exports `PTC_TEST_MCP_CA_FILE`. The test loads that CA directly into the test VM;
this is test-only trust setup, not a host-document capability. One case drives
the lower-level authorization and refresh contract, and one writes a complete
host document and application before running `mix ptc run`'s command boundary
with `--authorize-mcp workspace`.

The scheduled/manual model-driven test uses the same server and additionally
loads `OPENROUTER_API_KEY` and the optional `PTC_TEST_MODEL` from the root
checkout's explicitly named `.env` test input.

### Aggregate E2E suite

`mix test --include e2e` runs the pull-request E2E tests and every optional MCP
test whose prerequisites are configured. The comparatively expensive live
tutorial probes are tagged `:scheduled_e2e`; the credentialed Integration
workflow adds `--include scheduled_e2e` on scheduled and manual runs, but not on
pull requests. Run those probes directly with:

```bash
mix test test/quickstart_guide_test.exs \
  test/ptc_runner/kernel/tutorial_examples_e2e_test.exs \
  --include scheduled_e2e
```

The quickstart's model-backed project is also an executable documentation
probe. It uses the source-checkout frontend while exercising the same project
document and command behavior shown to executable users:

These source-checkout probes are the maintainer equivalents of the standalone
`ptc` commands in the end-user guides:

<!-- ptc-guide-e2e: id=getting-started-orders project=examples/kernel-tutorial/01-orders.ptc-project.json -->
```console
mix ptc run examples/kernel-tutorial/01-orders.ptc-project.json
```
```json
{"order_count":3,"paid_count":2,"paid_total":335.75,"pending_ids":["A-101"]}
```

<!-- ptc-guide-e2e: id=replay-frozen-answer project=examples/llm-replay/ptc-project.json -->
```console
mix ptc run examples/llm-replay/ptc-project.json
```
```json
{"content":"Frozen answer","model":"frozen-model"}
```

<!-- ptc-guide-e2e: id=quickstart-live-agent project=examples/kernel-tutorial/04-multi-turn-agent.ptc-project.json requires=OPENROUTER_API_KEY assert=two-turn-agent -->
```console
mix ptc run examples/kernel-tutorial/04-multi-turn-agent.ptc-project.json
```
```json
{"ok":true,"value":42}
```

Missing MCP prerequisites are reported as skips, so a checkout configured only
with `OPENROUTER_API_KEY` remains a valid way to run model-backed coverage. Once
a prerequisite is configured, an invalid binary, unreachable endpoint,
authentication error, or protocol error still fails its test.

The remote MCP tests require `PTC_TEST_MCP_2026_ENDPOINT`. The GitHub MCP test
requires both:

- `PTC_TEST_GITHUB_MCP_BINARY` — an absolute path to the pinned GitHub MCP
  Server executable used by CI.
- `PTC_TEST_GITHUB_TOKEN` — a GitHub token that can read this repository.

The filesystem MCP tests run when a `node` executable is available on `PATH`;
otherwise they skip with the other unavailable optional integrations.

With the GitHub MCP prerequisites exported, the repository harness supplies a
temporary remote endpoint while the aggregate suite runs:

```bash
export PTC_TEST_GITHUB_MCP_BINARY=/absolute/path/to/github-mcp-server
export PTC_TEST_GITHUB_TOKEN=replace-with-repository-read-token
bash test/support/mcp_go_stateless/with_server.sh \
  mix test --include e2e --trace
```

## Headless Linux VMs

Notes for Cursor Cloud and similar agents that run in a fresh Linux VM. The
toolchain, hooks, and standard commands above apply unchanged.

- **The toolchain lives under `mise`.** Erlang/Elixir/Java are pinned in
  `mise.toml` and installed at `~/.local/bin/mise`. Interactive shells activate
  it through `~/.bashrc`; in a non-interactive script prefix commands with
  `~/.local/bin/mise exec -- …` so the pinned tools resolve.
- **Cloud shells default to a group-writable umask.** `scripts/worktree.sh init`
  repairs existing checkout directories but cannot change its caller's umask,
  so prefix later build and test commands with `umask 0022;`.
- **Reinstalling dependencies does not rebuild.** A startup script that only
  runs `mix deps.get` leaves the build stale; run `mix compile` yourself after
  pulling changes. The launcher's C binary is rebuilt by `mix compile` through
  `elixir_make` and needs a C compiler.
- **Smoke test offline.** `mix ptc run
  examples/kernel-tutorial/01-orders.ptc-project.json` and `mix ptc run
  examples/llm-replay/ptc-project.json` need no network or credential.
- **Maintainer labs live in `scripts/labs/`.** `scripts/labs/viewer-demo/run.sh`
  produces varied Viewer traces against a live model, and
  `mix run scripts/labs/inspection-lab/run.exs` produces trace and inspection
  pairs without a credential. Neither is a shipped example.
- **The Viewer must be started explicitly.** `mix ptc viewer <project.json>`
  binds `127.0.0.1` on a free port and tries to open a browser; in a headless
  VM pass `--port <PORT> --listen 127.0.0.1` and open the printed URL. It shows
  only runs that already produced a trace.
- **The latin1 locale warning is harmless.** Export `LANG=C.UTF-8` (or
  `ELIXIR_ERL_OPTIONS="+fnu"`) to silence the BEAM's encoding warning.
