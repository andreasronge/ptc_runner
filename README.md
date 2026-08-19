# PtcRunner

**Build AI agents that are bounded in what they can do, easy to change,
observable in operation, and designed to improve from evidence.**

## The loop is a library, not the runtime

A system that improves itself has to be able to change itself. In most
frameworks the agent loop is host code, so changing the agent means editing
privileged code, and self-modification and privilege escalation become the same
act.

Here the loop is an ordinary library, written in the same bounded language the
model writes its own programs in. Everything about the agent is replaceable,
and nothing replaceable carries authority. You can change what the agent does
without expanding what it may do.

That language is also how tools get called: the model writes one small program
instead of taking twenty turns, the part usually called code mode. Every run
leaves a structured trace. Replay holds the model fixed, so a change can be
measured against its baseline instead of guessed at. A candidate arrives with
evidence, and a human decides whether it ships.

One executable, with its own runtime inside. No language to install, no sandbox
to stand up.

> PtcRunner is a 0.x project under active development. Breaking changes are
> expected.

## Try it

The public one-command installer and published container image are not
available yet. The command interface is stable enough to try today through a
locally built standalone executable or the verified local container. See
[Installation](docs/installation/standalone.md) for where each route stands.

Once `ptc` is installed, create and run a credential-free project:

```console
ptc init hello-ptc
ptc run hello-ptc/ptc-project.json
```

```json
{"greeting":"hello world"}
```

This verifies the executable and creates a structured trace without contacting
a model. The same `ptc run` command drives agentic projects.

The executable documents itself: `ptc help` lists every command, and `ptc docs`
lists the language specification, references, and JSON Schemas embedded for
that exact version. Coding agents should start at `ptc docs agent-guide`.

## Documentation

Everything is published at **[ptc-runner.dev](https://ptc-runner.dev/)**:
installation routes, guides, references, and the language specification.

## In this repository

Changing PtcRunner itself starts at the
[maintainer documentation](https://github.com/andreasronge/ptc_runner/blob/main/docs/maintainers/README.md):
development setup, kernel architecture, host embedding, documentation
guidelines, and the repository gates.

## License

See [LICENSE](LICENSE).
