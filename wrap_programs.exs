#!/usr/bin/env elixir

defmodule ProgramWrapper do
  @moduledoc """
  Script to wrap program definitions with {"program": ...} wrapper format.
  """

  def find_matching_paren(text, start_pos) do
    find_matching_paren(text, start_pos + 1, 1)
  end

  defp find_matching_paren(_text, pos, 0), do: pos - 1

  defp find_matching_paren(text, pos, depth) when pos >= byte_size(text) do
    -1
  end

  defp find_matching_paren(text, pos, depth) do
    case :binary.at(text, pos) do
      ?( -> find_matching_paren(text, pos + 1, depth + 1)
      ?) -> find_matching_paren(text, pos + 1, depth - 1)
      _ -> find_matching_paren(text, pos + 1, depth)
    end
  end

  def wrap_program_json(json_content) do
    stripped = String.trim(json_content)

    cond do
      String.starts_with?(stripped, ~s({"program":)) -> json_content
      String.starts_with?(stripped, ~s({ "program":)) -> json_content
      true -> ~s({"program": ) <> json_content <> "}"
    end
  end

  def find_program_assignments(content) do
    # Find all positions where "program = ~s(" appears
    regex = ~r/program\s*=\s*~s\(/

    Regex.scan(regex, content, return: :index)
    |> Enum.map(fn [{start, length}] ->
      # Find position of '(' after ~s
      paren_pos = start + length - 1
      end_pos = find_matching_paren(content, paren_pos)

      if end_pos == -1 do
        IO.puts("WARNING: Could not find matching ')' at position #{paren_pos}")
        nil
      else
        json_start = paren_pos + 1
        json_content = String.slice(content, json_start, end_pos - json_start)

        %{
          start: json_start,
          end: end_pos,
          original: json_content,
          wrapped: wrap_program_json(json_content)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def process_file(file_path) do
    unless File.exists?(file_path) do
      IO.puts("ERROR: File not found: #{file_path}")
      {0, 0}
    else
      content = File.read!(file_path)
      matches = find_program_assignments(content)

      # Process matches in reverse order to preserve positions
      {modified_content, modifications} =
        matches
        |> Enum.reverse()
        |> Enum.reduce({content, 0}, fn match, {acc_content, count} ->
          if match.original != match.wrapped do
            new_content =
              String.slice(acc_content, 0, match.start) <>
                match.wrapped <>
                String.slice(acc_content, match.end, String.length(acc_content))

            {new_content, count + 1}
          else
            {acc_content, count}
          end
        end)

      if modifications > 0 do
        File.write!(file_path, modified_content)
        IO.puts("✓ #{file_path}")
        IO.puts("  - Found: #{length(matches)} program definitions")
        IO.puts("  - Wrapped: #{modifications} programs")
      else
        IO.puts("✓ #{file_path}")
        IO.puts("  - Found: #{length(matches)} program definitions")
        IO.puts("  - Already wrapped: all programs already have wrapper")
      end

      {length(matches), modifications}
    end
  end

  def run do
    base_dir = "/home/runner/work/ptc_runner/ptc_runner"

    files = [
      Path.join([base_dir, "test", "ptc_runner_test.exs"]),
      Path.join([base_dir, "test", "ptc_runner", "e2e_test.exs"])
    ]

    IO.puts(String.duplicate("=", 70))
    IO.puts(~s(Wrapping program definitions with {"program": ...}))
    IO.puts(String.duplicate("=", 70))
    IO.puts("")

    results =
      Enum.map(files, fn file_path ->
        {found, wrapped} = process_file(file_path)
        IO.puts("")
        {found, wrapped}
      end)

    total_found = Enum.sum(Enum.map(results, fn {found, _} -> found end))
    total_wrapped = Enum.sum(Enum.map(results, fn {_, wrapped} -> wrapped end))

    IO.puts(String.duplicate("=", 70))
    IO.puts("TOTAL: Found #{total_found} programs, wrapped #{total_wrapped} programs")
    IO.puts(String.duplicate("=", 70))
  end
end

ProgramWrapper.run()
