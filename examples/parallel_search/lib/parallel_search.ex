defmodule ParallelSearch do
  @moduledoc """
  Demonstrates parallel tool execution in PTC-Lisp using `pcalls`.

  This is a single-shot example - no multi-turn loop, just one PTC-Lisp
  expression that runs multiple searches concurrently.
  """

  alias PtcRunner.Lisp

  @doc """
  Search for multiple patterns in parallel and combine results.

  Uses `pcalls` to run grep searches concurrently, then merges and
  deduplicates the results.

  ## Example

      ParallelSearch.search(["defmodule", "defstruct"])
      # => {:ok, [%{file: "...", line: 42, snippet: "..."}]}

  """
  def search(patterns) when is_list(patterns) do
    # Build tools map
    tools = %{"grep" => &do_grep/1}

    # Build parallel search expression using pcalls
    # (let [results (pcalls #(tool/grep {:pattern "p1"})
    #                       #(tool/grep {:pattern "p2"}))]
    #   (distinct-by :snippet (apply concat results)))
    thunks =
      patterns
      |> Enum.map(fn pattern -> ~s|#(tool/grep {:pattern "#{pattern}"})| end)
      |> Enum.join(" ")

    code = "(let [results (pcalls #{thunks})] (apply concat results))"

    case Lisp.run(code, tools: tools) do
      {:ok, step} -> {:ok, step.return}
      {:error, step} -> {:error, step.fail}
    end
  end

  @doc """
  Search for a single pattern.

  ## Example

      ParallelSearch.grep("defmodule")

  """
  def grep(pattern) when is_binary(pattern) do
    case search([pattern]) do
      {:ok, results} -> results
      {:error, _} -> []
    end
  end

  # Tool implementation (private, called by PTC-Lisp via tools map)
  # PTC-Lisp passes string keys: %{"pattern" => "..."}
  defp do_grep(%{"pattern" => pattern}) do
    root = Path.expand("../../..", __DIR__)
    search_path = Path.join(root, "lib/ptc_runner")

    case System.cmd("grep", ["-rnI", "--context=0", pattern, search_path]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_grep_line(&1, root))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(30)

      {_output, _status} ->
        []
    end
  end

  defp parse_grep_line(line, root) do
    case String.split(line, ":", parts: 3) do
      [file, line_num, snippet] ->
        %{
          file: String.replace(file, root <> "/", ""),
          line: String.to_integer(line_num),
          snippet: String.trim(snippet)
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
