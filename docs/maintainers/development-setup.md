# Development setup

> **Audience:** people and coding agents preparing a source checkout to change
> PtcRunner itself.

One-time and per-worktree setup for working on PtcRunner itself. Day-to-day
rules live in `AGENTS.md`; this guide holds the parts you run once and then
forget.

## Toolchain and dependencies

Tool versions are pinned in `mise.toml`. From a new clone or worktree, install
the toolchain and dependencies before running tests:

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
`deps/`, `_build/`, and `priv/plts/` (root, Viewer, and launcher) so the
commands above become incremental instead of cold. It prints one line per
artifact saying whether it was seeded or why not — copy skipped, source not
built, already present, or pinned by a file that differs from the main
checkout's copy.

That last key is per artifact, not per seed: every artifact is pinned by
`mise.toml`, and each project's artifacts additionally by that project's own
lockfile. A branch that bumps the root `mix.lock` therefore keeps seeding
`ptc_viewer/` and `ptc_runner_launcher/` — projects it never touched — while a
diverged `ptc_viewer/mix.lock` skips only the Viewer's two artifacts. The root
lockfile covers the nested projects' Hex dependencies as well, because Mix
converges a path dependency's requirements into the parent lock.

For build staleness the seed is never an authority: Mix revalidates `deps/`
and `_build/` against `mix.lock` and source digests, and dialyxir revalidates
the project PLT against the module set, so a stale seed costs a rebuild
rather than a wrong answer. The launcher's native executable is covered by
this rule only because repository checkouts force elixir_make's build path
(`force_build?/0` in `ptc_runner_launcher/mix.exs`): the precompiler flow
otherwise trusts any artifact already present in priv, which once let a
seeded pre-change binary answer `--publish-directory-noreplace` with a usage
error through every warm build. Forced make runs honor `MIX_QUIET=1`, keeping
machine-readable command stdout free of make's up-to-date chatter. The seeded
PLT's dialyxir hash file is
deliberately not copied (the first `mix dialyzer` run must re-check the PLT
instead of trusting the hash), and each copied PLT must fully decode as an
external term before promotion, so a torn copy taken while a concurrent
dialyzer run was rewriting the source is discarded rather than promoted.
The decode proves the copy is whole, not that the PLT is current: a project
PLT left stale by a toolchain bump seeds as-is and fails in the worktree
exactly as it would have in the main checkout — the remedy in the section
above applies unchanged.
Copies are staged under a per-process gitignored directory and promoted with
atomic no-replace renames — neither an interrupted seed nor two concurrent
ones can leave a half-copied artifact that later runs mistake for a built
one — and each worktree owns its copies, so concurrent gates never share a
writable artifact. Copies use copy-on-write clones where the filesystem
supports it (APFS/btrfs).

The one thing the seed takes on faith is dependency *fidelity*: it copies the
main checkout's `deps/` trees as they are, so a locally edited dependency
travels with the seed. This is a deliberate trust boundary — it is the same
trust you accept when running gates in the main checkout itself, no tool
rescans dependency sources against compiled artifacts anyway, and CI always
builds from pristine dependencies. If you have edited a dependency in the
main checkout, do not seed from it.

To warm the cache, keep the main checkout built: `mix compile` and
`mix dialyzer` there make every subsequent worktree cheap. To fill gaps in an
existing worktree (artifacts already present are left untouched):

```bash
scripts/worktree.sh seed          # seed the current worktree
scripts/worktree.sh seed <dir>    # seed another worktree
```

## Git hooks

Run `./scripts/install-hooks.sh` once per clone. Linked worktrees share the
clone's installed hook wrappers, so they do not need to reinstall them.

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
