# Run and inspect a project

Run, validate, and inspect a PtcRunner project through the `ptc` executable.

## How do I run a project?

Start with a project that needs no API key:

```console
ptc init hello-ptc
ptc validate hello-ptc/ptc-project.json
ptc run hello-ptc/ptc-project.json
```

The result is written to standard output. The project document remembers its
artifact root, so traces and optional envelopes or results stay beside the
project rather than depending on the caller's current directory.

## How do I check a model-backed project?

Materialize the tutorial projects, then check the multi-turn agent without
network activity:

```console
ptc init kernel-tutorial --example kernel-tutorial
ptc doctor kernel-tutorial/04-multi-turn-agent.ptc-project.json
ptc models kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

Use `--connect` only when an active provider probe is intended:

```console
ptc doctor kernel-tutorial/04-multi-turn-agent.ptc-project.json --connect
```

## How do I watch a run while it is running?

Start the Viewer on the fan-out step, which runs long enough to watch:

```console
ptc viewer kernel-tutorial/07-parallel-fan-out.ptc-project.json --port 4123
```

In a second terminal, set the URL the Viewer printed:

```console
export OPENROUTER_API_KEY=...
PTC_VIEWER_URL=http://127.0.0.1:4123 ptc run kernel-tutorial/07-parallel-fan-out.ptc-project.json
```

Status appears in the Live tab. If the Viewer requires a token, set the same
`PTC_VIEWER_TOKEN` for the run.

## How do I browse completed runs?

Browse completed runs locally:

```console
ptc viewer hello-ptc/ptc-project.json
```

The Viewer binds to loopback by default, where Live controls need no token.
Do not expose it to a network without setting `PTC_VIEWER_TOKEN`, especially
when a project grants access to private inspection records.

In Docker, publish the port on host loopback, bind the Viewer to the container
wildcard, and set `PTC_VIEWER_TOKEN`. Open
`http://localhost:4123/?live_token=THE_TOKEN#/live` to authorize the Live
controls; the token does not authenticate the Runs trace browser.

## How do I consume results from automation?

For automation, request a command envelope instead of parsing human-readable
diagnostics:

```console
ptc run hello-ptc/ptc-project.json --envelope command-envelope.json
```

The [CLI reference](../reference/cli.md) has the complete command grammar,
exit statuses, envelopes, and Viewer contract. Continue with [Debug a failed
run](debugging-a-failed-run.md) when a trace needs deeper investigation.
