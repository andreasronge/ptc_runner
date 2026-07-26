# Filesystem MCP sample server

**Non-production sample.** It exists so PtcRunner tutorials and integration
tests have a deterministic MCP server in another language, demonstrating that a
new capability arrives through host configuration rather than Elixir. Do not
deploy it.

## What it does

Captures one host-supplied root into an immutable in-memory snapshot at
startup, then answers five read-only tools from that snapshot. The filesystem
is never read again, so a file that changes, appears, or disappears after
capture cannot alter a result.

| Tool | Returns |
| --- | --- |
| `list_directory` | Sorted, paginated entries directly under a relative prefix |
| `search_files` | Sorted, paginated paths containing a literal substring |
| `search_text` | Literal matches with path and line evidence |
| `read_text_file` | A bounded UTF-8 line range with stable line numbers and explicit end-of-file |
| `snapshot_info` | Content hash and inventory statistics, never the host root |

Every data-bearing result carries the same `snapshot_hash`, so a citation binds
to the exact bytes queried.

## Running

```console
node dist/server.js --root ./workspace --include 'lib/**' --include 'docs/**' --exclude '**/secrets/**'
```

`--include` is mandatory and repeatable; the default is **no files**, so a
server started without it exposes nothing. `--exclude` may only narrow what the
includes selected. Excluded paths are skipped before any stat or open, so they
are never inventoried.

## Confinement

- Relative paths only. Absolute paths, `.`/`..` segments, NUL bytes, and
  Windows separators are rejected rather than resolved.
- Symbolic links are skipped, not followed, so a link inside the root cannot
  reach bytes outside it.
- Non-regular files and files that are not valid UTF-8 are not captured.
- File count, per-file bytes, aggregate bytes, and directory depth are bounded
  at startup; results are bounded per page, per match set, and per byte budget.
- Errors are short actionable text — no stacktraces, no host paths.
- Nothing is written, no subprocess or network is used, and no Roots, Sampling,
  Logging, MRTR, or Tasks capability is advertised.
- stdout carries protocol messages only; diagnostics go to stderr.

## Building and testing

```console
npm install      # maintainers only; the tutorial runs the committed bundle
npm run build    # regenerates dist/server.js
npm run typecheck
npm test
```

`dist/server.js` is committed so a clean checkout or a release-installed
tutorial can run the server without installing or downloading anything. CI
regenerates the bundle and fails on a diff.

## Licensing

The sample's own source is MIT, matching the repository. `dist/server.js` is a
bundle that inlines its dependencies, so `NOTICE` reproduces their upstream
license texts and travels with the artifact. `REUSE.toml` annotates the bundle
as a combined work.

## Dependency pin

`@modelcontextprotocol/server` is pinned to an exact version, and the lockfile
is committed. The capability platform plan requires the official TypeScript SDK
v2 after a stable release supporting `2026-07-28`, and permits a pinned beta
only on an experimental branch until then. No stable release exists yet, so
this pins `2.0.0-beta.5`. Re-pin when the stable release lands.
