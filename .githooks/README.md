# Tracked git hooks

This directory holds the repo's git hooks as tracked files (rather than
the per-clone `.git/hooks/` directory). Today there is one:

- `pre-push` — runs `mix test --exclude clojure` and `mix dialyzer` for
  each top-level Mix project (`.`, `mcp_server`, `ptc_viewer`), with a
  docs-only short-circuit at the top that skips the gate when every
  pushed and dirty path matches the strict allow-list documented in
  `Plans/pre-push-perf.md` §"Phase 1".

> **Note:** The docs-only short-circuit requires Python 3 (`python3` on `PATH`). Without it the hook degrades gracefully to the full gate with no error, so contributors without Python 3 will simply never see the <0.5 s fast path.

## One-time setup per clone

After cloning (or in any existing clone), point git at this directory:

```bash
git config core.hooksPath .githooks
```

Verify with:

```bash
git config --get core.hooksPath
# → .githooks
```

This is per-clone (it lives in `.git/config`), so each contributor
runs it once. Linked worktrees inherit the parent clone's setting —
no extra step there.

## Override: skip the docs-only short-circuit

Set `FORCE_FULL_PRE_PUSH=1` to always run the full test/dialyzer gate,
even when the diff is docs-only:

```bash
FORCE_FULL_PRE_PUSH=1 git push
```

Useful when you've changed a docs file that's read at runtime or
doctested (the deny list catches the well-known cases, but the
override is the explicit lever when you want belt-and-suspenders).

## Gotcha: fresh clones need `mix deps.compile`

A freshly cloned worktree (or a clone that's never run `mix compile`)
will fail the mock-server tests during the gate with:

```
subprocess exited during handshake (status=1)
```

This is because `mcp_server`'s mock-server tests spawn helpers via
`mix run --no-start --no-compile`, which does **not** side-load
dependencies like `Jason`. The deps must be pre-compiled.

Fix once after cloning:

```bash
mix deps.get
mix deps.compile      # ← critical; `deps.get` alone is not enough
(cd mcp_server && mix deps.get && mix deps.compile)
(cd ptc_viewer && mix deps.get && mix deps.compile)
```

After that the hook (and `mix test`) work normally.

## Allow-list summary

Pushed/dirty paths matching these regexes are docs-only-eligible:

- `^Plans/.*\.md$`
- `^CHANGELOG\.md$`
- `^LICENSES/MIT\.txt$`
- `^\.gitignore$`
- `^\.githooks/README\.md$`

Everything else (including `README.md`, `docs/**.md`,
`priv/prompts/**.md`, `usage-rules*.md`, all source code, configs,
fixtures) falls through to the full gate. See
`Plans/pre-push-perf.md` §"Phase 1" for the verified list of
runtime-read / doctested markdown that the deny side protects.
