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

## How do I browse completed runs?

Browse completed runs locally:

```console
ptc viewer hello-ptc/ptc-project.json
```

The Runs list uses a matching project `labels.name` as its readable headline,
keeps the command run ID underneath, and shows finite label tags. When every
successful model call reported a metric, the row also shows full-run input and
output tokens and provider-reported cost; missing prices or usage stay absent.
Refresh includes runs that finished after this captured snapshot.

When the Live tab launches provider-backed work, pass an exact dotenv file
with `--env-file FILE` or declare `host.env_file` in the project. The Viewer
does not search implicitly for `.env`.

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

Use the [CLI reference](../reference/cli.md) for the complete command grammar,
exit statuses, envelopes, artifact publication, diagnostics, transcripts,
Viewer behavior, and process contract. Continue with [Debug a failed
run](debugging-a-failed-run.md) when a trace needs deeper investigation.
