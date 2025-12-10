defmodule PtcRunner do
  @moduledoc """
  BEAM-native Programmatic Tool Calling (PTC) runner.

  ## Languages

  PtcRunner supports multiple DSL languages:

  - `PtcRunner.Json` - JSON-based DSL (stable)
  - `PtcRunner.Lisp` - Clojure-like DSL (experimental)

  ## Examples

  ### JSON DSL

      iex> program = ~s({"program": {"op": "literal", "value": 42}})
      iex> {:ok, result, _metrics} = PtcRunner.Json.run(program)
      iex> result
      42

  ### PTC-Lisp

      iex> {:ok, result, _delta, _memory} = PtcRunner.Lisp.run("(+ 1 2)")
      iex> result
      3
  """
end
