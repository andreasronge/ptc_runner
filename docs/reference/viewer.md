# Viewer reference

The Viewer presents captured and live runs for one PtcRunner project. It is a
local inspection surface, not a general remote administration service.

## What it shows

The **Runs** tab lists the project's captured traces read-only. A run page shows
turns, tool calls, and effective prelude components. When the project records
`artifacts.inspection` and grants `viewer.private`, it also shows generated
programs, prelude sources, and model exchanges.

When the project enables `viewer.repl`, a run page can open a bounded analysis
REPL over an immutable capture of the selected run. The **Live** tab shows runs
that report through `PTC_VIEWER_URL`; it can also launch the project's workflow
or evaluate one expression in a declared mission's sandbox. The Live tab lists
newest first.

## Starting it

```console
ptc viewer PROJECT.json [--port PORT] [--listen ADDRESS] [--env-file FILE]
```

`--port` overrides the project's `viewer.port`; when neither selects a fixed
port, the default `0` asks the operating system for a free one. Startup prints
the selected address. When an explicitly selected port is occupied, the
command distinguishes another PTC Viewer, including its project path, from
another service and reports the conflict. It runs in the foreground until
`Ctrl+C`.

The Viewer never searches for `.env`. Environment-backed credentials come from
the inherited environment, the project's `host.env_file`, or the exact file
passed with `--env-file FILE`; that option overrides `host.env_file` for work
launched from the Live tab. Host-configured file and literal credential
bindings remain available.

The Viewer ships in the standalone release and container image. It is not part
of the published Hex package, where `ptc doctor` reports the optional Viewer as
unavailable.

The [project reference](project-files.md#viewer) documents the `viewer` block.

## Exposing it

The Viewer binds to `127.0.0.1` by default. `--listen 0.0.0.0` is the only
alternative; it accepts connections through every network interface and prints
a warning. Set a fresh `PTC_VIEWER_TOKEN` of at least 32 bytes before allowing
any non-loopback peer; for example, generate one with `openssl rand -hex 32`.

For a browser arriving through a non-loopback peer, keep the page authority at
`localhost`, `127.0.0.1`, or `::1` through a port forward, then open the Viewer
once with `?live_token=THE_TOKEN` to bootstrap Live access. The page removes
that query parameter after use. The token protects Live ingestion and controls;
it never authenticates the Runs trace browser, so exposing the Viewer can
disclose trace and private inspection data.

For container binding and host-port rules, see
[Docker installation](../installation/docker.md#open-the-viewer).

## Reporting a run

Set `PTC_VIEWER_URL` for `ptc run` to report progress to the Live tab. When the
Viewer requires a token, set the same `PTC_VIEWER_TOKEN` for the run. Reporting
is best-effort and never changes the run result. It sends the exact manifest
label, or the manifest filename when no label exists, and workflow entry to the
Viewer for display; trace metadata keeps its fingerprinted label.
