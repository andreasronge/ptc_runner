# AGENTS.md

This project runs on the `ptc` executable. Ask the installed binary for the
exact contract instead of guessing; its answers always match its own version
and need no network.

## Find the exact contract

- `ptc help` lists every command; `ptc help COMMAND` gives its switches.
- `ptc docs` lists every shipped document; read `ptc docs agent-guide` first.
- `ptc repl --project ptc-project.json -e '(doc "name")'` documents one function, and
  `ptc repl --project ptc-project.json -e '(apropos "term")'` searches the available language surface.

## Files here

- `ptc.json` — the application: workflow, input, providers, missions, limits.
- `main.clj` — the PTC-Lisp component the workflow entry calls.
- `ptc-project.json` — local paths and artifact settings. Pass this document
  to commands so they do not depend on the current directory.

## Working loop

```console
ptc validate ptc-project.json
ptc repl --project ptc-project.json -e '(main/run {"name" "world"})'
ptc run ptc-project.json --envelope out.json
```

Parse `out.json` rather than scraping stdout. Keep credentials in an exact
environment file passed with `--env-file`; never place a secret in
`ptc.json`, in a component, or in a prompt.
