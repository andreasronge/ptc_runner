defmodule PtcRunner.LivebookSmokeTest do
  @moduledoc """
  Cheap, deterministic guard for every published livebook: assert that each
  elixir cell still parses as valid Elixir. Catches syntax rot in the tutorials
  without running them (no LLM, no network). Semantic coverage of the
  deterministic playground lives in `PtcRunner.LivebookPlaygroundTest`.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Test.LivebookExtractor

  # Generate one test per notebook at compile time.
  for path <- LivebookExtractor.paths() do
    name = Path.basename(path)

    test "#{name}: every elixir cell parses" do
      cells = LivebookExtractor.elixir_cells(unquote(path))

      assert cells != [],
             "expected at least one elixir cell in #{unquote(name)} — did the format change?"

      for {code, idx} <- Enum.with_index(cells, 1) do
        case Code.string_to_quoted(code) do
          {:ok, _ast} ->
            :ok

          {:error, {meta, message, token}} ->
            flunk("""
            Syntax error in #{unquote(name)}, elixir cell ##{idx} (line #{meta[:line] || "?"}):
            #{message}#{inspect(token)}

            Cell source:
            #{code}
            """)
        end
      end
    end
  end
end
