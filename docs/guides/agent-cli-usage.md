# Drive ptc as an agent

> **Audience:** LLMs and coding agents that run the `ptc` executable directly,
> and the people configuring them.

You do not need network access or a remembered API to use PtcRunner. The
executable you are running carries its own command grammar and documentation,
so both always describe the version you actually invoke.

## Ask the binary instead of guessing

| Question | Command |
| --- | --- |
| Which commands and switches exist? | `ptc help`, then `ptc help COMMAND` |
| Which documentation ships here? | `ptc docs` |
| How does the language or a contract work? | `ptc docs PAGE` |
| What does one function do? | `ptc repl -e '(doc "name")'` |

Help output is generated from the same declarations as the strict parser, and
`ptc docs` prints pages embedded at build time. Neither can drift from the
running executable. Prefer both over any remembered flag, built-in, or manifest
field, and over any page you fetched from the web for a different version.

Start with `ptc docs agent-guide` (this page), `ptc docs manifest` for the
application document, and `ptc docs functions` for the built-in library.

## Follow the loop

Each step fails early and cheaply, so run them in order rather than jumping
straight to a credentialed run.

```console
ptc init hello-ptc                       # generate a working application
ptc validate hello-ptc/ptc-project.json  # compile without executing
ptc repl --project hello-ptc/ptc-project.json -e '(main/run {"name" "world"})'
ptc doctor hello-ptc/ptc-project.json    # check provider readiness locally
ptc run hello-ptc/ptc-project.json --envelope out.json
```

`ptc init` writes a complete project, including an `AGENTS.md` that points a
later agent back at these commands. Edit `main.clj` for behavior and `ptc.json`
for input, providers, missions, and limits.

## Experiment before committing to a file

`ptc repl` is the cheapest place to check a language question, and its
discovery functions work in every input context — not only at a terminal, so a
detached agent gets the same answers:

```console
ptc repl -e '(apropos "json")'            # search built-ins and prelude exports
ptc repl -e '(doc "reduce")'              # print one function's documentation
ptc repl -e '(dir)'                       # list the attached prelude API
```

Repeat `-e` to build up a session in order. Add `--project PROJECT.json` to
evaluate against the real workflow environment, capabilities, and model routes
instead of a bare scratchpad. This answers "does this expression work" without
editing a component, revalidating, or spending a provider call.

## Read outcomes as data

`run`, `validate`, `doctor`, `models`, and `init` accept `--envelope FILE`,
which atomically publishes one JSON document describing the outcome: status,
run reference, result or classified error, and artifact state. Parse that file
rather than scraping stdout, which is a human presentation channel that may
also carry application output.

Exit status is part of the contract: `0` on success, the diagnostic catalog's
status for a classified failure, `70` for a caught internal failure, and `74`
when envelope publication itself fails. `ptc docs cli` has the complete process
contract.

## Expect a bounded failure report

A failed run reports a closed phase and code pair. Deliberate `fail` values are
deliberately not copied into the command diagnostic, and private detail never
reaches public evidence, so do not expect a stack trace or a model transcript
in normal output. To debug, read the canonical trace the run recorded, then
`ptc docs debug` for the query surface and `ptc docs traces` for the record
contract. `ptc viewer PROJECT.json` browses the same evidence when a human is
present.

When you need the exact private records — model exchanges, generated source,
capability payloads — they require explicit private authorization; see
`ptc docs repl` and `ptc docs cli`.

## Respect the authority boundary

An application document selects only what the operator already installed. It
cannot add credentials, endpoints, commands, or wider limits, and no prompt or
generated program can escalate that. If a provider or tool is missing, the fix
belongs in the host configuration a person controls (`ptc docs host`), not in
the manifest or in a retry. Report the gap instead of working around it.

Keep credentials in the exact environment file passed with `--env-file`; never
inline a secret into a manifest, a component, or a prompt.
