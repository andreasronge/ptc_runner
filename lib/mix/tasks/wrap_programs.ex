defmodule Mix.Tasks.WrapPrograms do
  use Mix.Task

  @moduledoc """
  Wraps all test programs with {"program": ...} format.
  Uses a simple regex-based approach.
  """

  @impl Mix.Task
  def run(_args) do
    IO.puts("Wrapping test programs...")
    process_file("test/ptc_runner_test.exs")
    process_file("test/ptc_runner/e2e_test.exs")
    IO.puts("Done!")
  end

  defp process_file(file_path) do
    IO.puts("Processing #{file_path}...")

    case File.read(file_path) do
      {:ok, content} ->
        original_count = Regex.scan(~r/program\s*=\s*~s\(/, content) |> length()

        # Use a very simple approach: replace the opening with the wrapped version
        # For single-line JSON: {"op": ...} becomes {"program": {"op": ...}}
        wrapped = simple_wrap(content)

        File.write!(file_path, wrapped)
        IO.puts("  ✓ Found #{original_count} program definitions")

      {:error, reason} ->
        IO.puts("  ✗ Error: #{reason}")
    end
  end

  # Simple wrapping: match program = ~s({...}) with non-nested braces
  # This handles most single-line cases
  defp simple_wrap(content) do
    # First pass: handle single-line programs like ~s({"op": "literal", "value": 42})
    # Match: program = ~s( followed by {NOT containing top-level } then })
    step1 =
      Regex.replace(
        ~r/program = ~s\((\{(?:[^{}]|"[^"]*")*\})\)/,
        content,
        "program = ~s({\"program\": \\1})"
      )

    # Second pass: handle multi-line programs
    # We'll use a different approach for these - match from ~s({ to the closing })
    step2 = wrap_multiline(step1)

    step2
  end

  # For multi-line programs, we need a stateful approach
  defp wrap_multiline(content) do
    lines = String.split(content, "\n")
    {wrapped_lines, _} = process_all_lines(lines, [], false)
    Enum.join(Enum.reverse(wrapped_lines), "\n")
  end

  defp process_all_lines([], acc, _), do: {acc, false}

  defp process_all_lines([line | rest], acc, in_program) do
    cond do
      # Start of a multi-line program
      String.match?(line, ~r/program\s*=\s*~s\(\{/) and not String.match?(line, ~r/\}\s*\)/) ->
        # Found start of multi-line program
        # Modify the line to have {"program": {
        modified_line =
          Regex.replace(
            ~r/(program\s*=\s*~s\()(\{)/,
            line,
            "\\1{\"program\": {"
          )

        process_all_lines(rest, [modified_line | acc], true)

      # End of multi-line program
      in_program and String.match?(line, ~r/\}\s*\)/) ->
        # Close the wrapper: }} instead of }
        modified_line = Regex.replace(~r/(\}\s*\))/, line, "}})")
        process_all_lines(rest, [modified_line | acc], false)

      # Already wrapped (protection against double-wrapping)
      String.match?(line, ~r/\{"program"/) ->
        process_all_lines(rest, [line | acc], in_program)

      true ->
        process_all_lines(rest, [line | acc], in_program)
    end
  end
end
