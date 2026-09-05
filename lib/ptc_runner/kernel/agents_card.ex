defmodule PtcRunner.Kernel.AgentsCard do
  @moduledoc """
  The `AGENTS.md` routing card that `ptc init` writes into a new directory.

  Deliberately a routing card, not a manual: every pointer is a command served
  by the installed executable, so the card cannot describe another version.
  The scaffold's card names its own files. An embedded example tree that ships
  no card of its own gets the layout-neutral variant, because its `README.md`
  already says which project document to run first.
  """

  @doc "The card for the built-in scaffold, which names its own files."
  @spec scaffold() :: binary()
  def scaffold do
    contract("ptc-project.json") <>
      """
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

      """ <> credentials()
  end

  @doc "The card for an embedded example tree that ships none of its own."
  @spec example() :: binary()
  def example do
    contract("PROJECT.json") <>
      """
      ## Files here

      - `README.md` — which project document to run first, and which need a
        credential.
      - `ptc-project.json`, or `STEP.ptc-project.json` in a tree with several
        steps — one runnable project each: local paths and artifact settings.
        Pass the document to commands so they do not depend on the current
        directory; it names the application manifest, the host document, and
        the environment file.
      - `ptc-host.json` — the installed providers the projects select.

      ## Working loop

      ```console
      ptc validate PROJECT.json
      ptc run PROJECT.json --envelope out.json
      ```

      """ <> credentials()
  end

  defp contract(project) do
    """
    # AGENTS.md

    This project runs on the `ptc` executable. Ask the installed binary for the
    exact contract instead of guessing; its answers always match its own version
    and need no network.

    ## Find the exact contract

    - `ptc help` lists every command; `ptc help COMMAND` gives its switches.
    - `ptc docs` lists every shipped document; read `ptc docs agent-guide` first.
    - `ptc repl --project #{project} -e '(doc "name")'` documents one function, and
      `ptc repl --project #{project} -e '(apropos "term")'` searches the available language surface.

    """
  end

  defp credentials do
    """
    Parse `out.json` rather than scraping stdout. Keep credentials in an exact
    environment file passed with `--env-file`; never place a secret in
    `ptc.json`, in a component, or in a prompt.
    """
  end
end
