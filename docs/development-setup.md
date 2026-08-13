# Development setup

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

## Worktree seeding

`scripts/worktree.sh new` seeds a fresh worktree with the main checkout's
`deps/`, `_build/`, and `priv/plts/` (root, Viewer, and launcher) so the
commands above become incremental instead of cold. It prints one line per
artifact saying whether it was seeded or why not — copy skipped, source not
built, or already present — and skips seeding entirely when `mise.toml` or any
lockfile differs from the main checkout's copy.

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

The credential-free interoperability test runs as a dedicated PR check and can
be run from another terminal:

```bash
PTC_TEST_MCP_2026_ENDPOINT=http://127.0.0.1:8000 \
  mix test test/ptc_runner/kernel/mcp_remote_e2e_test.exs \
    --include e2e --trace
```

The credential-free OAuth authorization/interoperability test starts the same
official SDK server behind its deterministic OAuth harness:

```bash
PTC_TEST_MCP_OAUTH=1 \
  bash test/support/mcp_go_stateless/with_server.sh \
    mix test test/ptc_runner/kernel/mcp_oauth_remote_e2e_test.exs \
      --include e2e --trace
```

The scheduled/manual model-driven test uses the same server and additionally
loads `OPENROUTER_API_KEY` and the optional `PTC_TEST_MODEL` from the root
checkout's explicitly named `.env` test input.

### Aggregate E2E suite

`mix test --include e2e` runs the live-model tests and every optional MCP test
whose prerequisites are configured. Missing MCP prerequisites are reported as
skips, so a checkout configured only with `OPENROUTER_API_KEY` remains a valid
way to run the model-backed coverage. Once a prerequisite is configured, an
invalid binary, unreachable endpoint, authentication error, or protocol error
still fails its test.

The remote MCP tests require `PTC_TEST_MCP_2026_ENDPOINT`. The GitHub MCP test
requires both:

- `PTC_TEST_GITHUB_MCP_BINARY` — an absolute path to the pinned GitHub MCP
  Server executable used by CI.
- `PTC_TEST_GITHUB_TOKEN` — a GitHub token that can read this repository.

With the GitHub MCP prerequisites exported, the repository harness supplies a
temporary remote endpoint while the aggregate suite runs:

```bash
export PTC_TEST_GITHUB_MCP_BINARY=/absolute/path/to/github-mcp-server
export PTC_TEST_GITHUB_TOKEN=replace-with-repository-read-token
bash test/support/mcp_go_stateless/with_server.sh \
  mix test --include e2e --trace
```
