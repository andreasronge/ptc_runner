defmodule PtcRunner do
  @moduledoc """
  BEAM-native Programmatic Tool Calling (PTC) runner.

  ## Languages

  PtcRunner supports multiple DSL languages:

  - `PtcRunner.Json` - JSON-based DSL (stable)
  - `PtcRunner.Lisp` - Clojure-like DSL (experimental)

  ## Migration

  The top-level `run/2` function is deprecated. Use language-specific modules:

      # Before (deprecated)
      PtcRunner.run(json_program, opts)

      # After
      PtcRunner.Json.run(json_program, opts)

  ## Examples

      iex> program = ~s({"program": {"op": "literal", "value": 42}})
      iex> {:ok, result, _metrics} = PtcRunner.Json.run(program)
      iex> result
      42
  """

  @deprecated "Use PtcRunner.Json.run/2 instead"
  defdelegate run(program, opts \\ []), to: PtcRunner.Json

  @deprecated "Use PtcRunner.Json.run!/2 instead"
  defdelegate run!(program, opts \\ []), to: PtcRunner.Json

  @deprecated "Use PtcRunner.Json.format_error/1 instead"
  defdelegate format_error(error), to: PtcRunner.Json
end
