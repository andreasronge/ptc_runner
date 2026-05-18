defmodule PtcRunner.PromptFilesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.PromptLoader

  @start_marker "<!-- PTC_PROMPT_START -->"
  @end_marker "<!-- PTC_PROMPT_END -->"
  @required_fields ~w(version date prompt-guidelines audience budget)
  @forbidden_runtime_patterns [
    "docs/",
    "Plans/",
    "priv/prompts/README.md",
    "hexdocs.pm/ptc_runner",
    "Full reference:",
    "see docs"
  ]

  test "maintained prompt files have metadata, markers, extracted content, and budgets" do
    Enum.each(maintained_prompt_files(), fn path ->
      body = File.read!(path)
      assert body =~ @start_marker, "#{relative(path)} missing start marker"
      assert body =~ @end_marker, "#{relative(path)} missing end marker"

      {header, content} = PromptLoader.extract_with_header(body)
      metadata = parse_metadata(header)

      Enum.each(@required_fields, fn field ->
        assert Map.has_key?(metadata, field), "#{relative(path)} missing #{field} metadata"
      end)

      assert metadata["prompt-guidelines"] == "priv/prompts/README.md"
      assert byte_size(content) <= hard_budget!(metadata, path)
      refute content =~ @start_marker
      refute content =~ @end_marker
      refute content =~ "<!--"

      Enum.each(@forbidden_runtime_patterns, fn pattern ->
        refute String.contains?(content, pattern),
               "#{relative(path)} extracted content contains authoring reference #{inspect(pattern)}"
      end)
    end)
  end

  defp maintained_prompt_files do
    root = Path.expand("../..", __DIR__)

    root
    |> Path.join("priv/prompts/*.md")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "README.md"))
    |> Enum.sort()
  end

  defp parse_metadata(header) do
    ~r/<!--\s*([a-z-]+):\s*(.*?)\s*-->/
    |> Regex.scan(header)
    |> Map.new(fn [_full, key, value] -> {key, value} end)
  end

  defp hard_budget!(metadata, path) do
    case Regex.run(~r/hard<=([0-9]+)\s+bytes/, metadata["budget"] || "") do
      [_full, bytes] -> String.to_integer(bytes)
      _ -> flunk("#{relative(path)} has invalid budget metadata")
    end
  end

  defp relative(path) do
    root = Path.expand("../..", __DIR__)
    Path.relative_to(path, root)
  end
end
