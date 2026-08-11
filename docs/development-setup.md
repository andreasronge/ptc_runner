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

The seed is an optimization, never an authority: Mix revalidates `deps/` and
`_build/` against `mix.lock` and source digests, and dialyxir revalidates the
project PLT against the module set, so a stale seed costs a rebuild rather
than a wrong answer. (The seeded PLT's dialyxir hash file is deliberately not
copied, so the first `mix dialyzer` run always re-checks the PLT instead of
trusting the hash.) Copies are staged and promoted with an atomic rename —
an interrupted seed leaves nothing half-copied — and each worktree owns its
copies, so concurrent gates never share a writable artifact. Copies use
copy-on-write clones where the filesystem supports it (APFS/btrfs).

One deliberate trust boundary: seeding copies the main checkout's `deps/`
trees as they are. If you have locally edited a dependency there, the edit
travels with the seed — the same trust you accept when running gates in the
main checkout itself. CI always builds from pristine dependencies and is
unaffected.

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
loads `OPENROUTER_API_KEY` and the optional `PTC_TEST_MODEL` from `.env`.
