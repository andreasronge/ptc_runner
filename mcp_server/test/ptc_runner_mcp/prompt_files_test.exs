defmodule PtcRunnerMcp.PromptFilesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.PromptLoader

  # Mirrors `PtcRunner.PromptFilesTest` for the MCP prompt tree. The metadata
  # policy in `priv/prompts/README.md` declares `mcp_server/priv/prompts/**/*.md`
  # as maintained prompt files, but the root test only globs the root tree — so
  # this guards the MCP cards.
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

  test "maintained MCP prompt files have metadata, markers, extracted content, and budgets" do
    files = maintained_prompt_files()
    refute files == [], "expected MCP prompt files under priv/prompts/ but found none"

    Enum.each(files, fn path ->
      body = File.read!(path)
      assert body =~ @start_marker, "#{relative(path)} missing start marker"
      assert body =~ @end_marker, "#{relative(path)} missing end marker"

      {header, content} = PromptLoader.extract_with_header(body)
      metadata = parse_metadata(header)

      Enum.each(@required_fields, fn field ->
        assert Map.has_key?(metadata, field), "#{relative(path)} missing #{field} metadata"
      end)

      assert metadata["prompt-guidelines"] == "priv/prompts/README.md",
             "#{relative(path)} prompt-guidelines must point at priv/prompts/README.md"

      assert byte_size(content) <= hard_budget!(metadata, path),
             "#{relative(path)} extracted content exceeds its hard budget"

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

    [
      Path.join(root, "priv/prompts/*.md"),
      Path.join(root, "priv/prompts/**/*.md")
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
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
