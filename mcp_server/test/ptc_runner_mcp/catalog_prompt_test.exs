defmodule PtcRunnerMcp.CatalogPromptTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.CatalogPrompt

  @forbidden_runtime_patterns [
    "<!--",
    "PTC_PROMPT_START",
    "PTC_PROMPT_END",
    "docs/",
    "Plans/"
  ]

  test "every catalog builtin prompt file is extracted before rendering" do
    for key <- [
          :summary,
          :list_servers,
          :search_tools,
          :list_tools,
          :describe_tool
        ] do
      text = CatalogPrompt.builtin_text(key)

      assert is_binary(text)
      assert text != ""

      Enum.each(@forbidden_runtime_patterns, fn pattern ->
        refute String.contains?(text, pattern),
               "#{key} contains forbidden runtime prompt pattern #{inspect(pattern)}"
      end)
    end
  end

  test "every catalog builtin has a prompt file" do
    prompt_dir = Path.expand("../../priv/prompts/catalog", __DIR__)

    for file <- [
          "summary.md",
          "list_servers.md",
          "search_tools.md",
          "list_tools.md",
          "describe_tool.md"
        ] do
      path = Path.join(prompt_dir, file)
      assert File.exists?(path), "missing catalog prompt file #{path}"
      assert File.read!(path) =~ "<!-- PTC_PROMPT_START -->"
    end
  end

  test "discovery block is built from catalog builtin prompts" do
    block = CatalogPrompt.discovery_block()

    assert block =~ ~s|`(catalog/search-tools "query" {:limit 8})`|
    assert block =~ ~s|`(catalog/list-tools "server-name" {:limit 20})`|
    assert block =~ ~s|`(catalog/describe-tool "server-name" "tool-name")`|
    assert block =~ ~s|`(tool/mcp-call {:server "server-name" :tool "tool-name" :args {...}})`|

    Enum.each(@forbidden_runtime_patterns, fn pattern ->
      refute String.contains?(block, pattern)
    end)
  end

  test "agentic discovery block includes server listing and quota guidance" do
    block = CatalogPrompt.agentic_discovery_block()

    assert block =~ ~s|`(catalog/list-servers)`|
    assert block =~ ~s|`(catalog/search-tools "query" {:limit 8})`|
    assert block =~ "catalog/* ops have their own budget"
  end
end
