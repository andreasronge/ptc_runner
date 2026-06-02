defmodule PtcRunner.Lisp.Analyze.Placeholder do
  @moduledoc false

  # Detects short-function placeholders: %, %1..%N, %&.
  # Leaf helper with no dependencies, so both Analyze and ShortFn can use it
  # without forming a compile-time cycle.
  def placeholder?(name) do
    case to_string(name) do
      "%" -> true
      "%" <> rest -> String.match?(rest, ~r/^(\d+|&)$/)
      _ -> false
    end
  end
end
