defmodule CodeScout.Tools do
  @moduledoc """
  Tools for the Code Scout agent to explore the codebase.

  These tools use Elixir `@spec` annotations that are automatically extracted
  to PTC-Lisp signatures by `PtcRunner.SubAgent.TypeExtractor`.
  """

  @typedoc "Grep result entry with file location and matched snippet"
  @type grep_result :: %{file: String.t(), line: integer(), snippet: String.t()}

  @doc """
  Search for a pattern in lib/ptc_runner. Returns matches with file, line, and snippet.
  """
  @spec grep(%{pattern: String.t()}) :: [
          %{file: String.t(), line: integer(), snippet: String.t()}
        ]
  def grep(%{pattern: pattern}) when is_binary(pattern) do
    # Restrict search to lib/ptc_runner
    # lib/code_scout/tools.ex -> lib/code_scout -> lib -> examples -> root
    root = Path.expand("../../../../", __DIR__)
    search_path = Path.join(root, "lib/ptc_runner")

    # Use -m to limit matches per file, preventing heap exhaustion with broad patterns
    case System.cmd("grep", ["-rnI", "--context=0", "-m", "20", pattern, search_path],
           stderr_to_stdout: true
         ) do
      {output, status} when status in [0, 1] ->
        output
        |> String.split("\n", trim: true)
        |> Stream.map(fn line ->
          case String.split(line, ":", parts: 3) do
            [file, line_num, snippet] ->
              %{
                file: String.replace(file, root <> "/", ""),
                line:
                  try do
                    String.to_integer(line_num)
                  rescue
                    _ -> 0
                  end,
                snippet: String.trim(snippet)
              }

            _ ->
              nil
          end
        end)
        |> Stream.reject(&is_nil/1)
        |> Enum.take(50)

      {_output, _status} ->
        []
    end
  end

  @doc """
  Read an entire file. Returns content with line numbers.
  """
  @spec read_file(%{path: String.t()}) :: String.t()
  def read_file(%{path: path}) do
    root = Path.expand("../../../../", __DIR__)
    full_path = if Path.type(path) == :absolute, do: path, else: Path.join(root, path)

    if File.exists?(full_path) do
      lines = File.stream!(full_path) |> Enum.to_list()
      total_lines = length(lines)

      if total_lines == 0 do
        "File is empty."
      else
        # Calculate padding width based on total line count
        width = total_lines |> Integer.to_string() |> String.length()

        lines
        |> Enum.with_index(1)
        |> Enum.map(fn {line, index} ->
          line_num = String.pad_leading(Integer.to_string(index), width)
          "#{line_num}: #{line}"
        end)
        |> Enum.join("")
      end
    else
      "File not found: #{path}"
    end
  end
end
