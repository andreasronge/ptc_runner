defmodule PtcRunnerMcp.CatalogPromptTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.{CatalogPrompt, PromptRegistry}

  @forbidden_runtime_patterns [
    "<!--",
    "PTC_PROMPT_START",
    "PTC_PROMPT_END",
    "docs/",
    "Plans/"
  ]

  test "every catalog builtin prompt file is extracted before rendering" do
    for key <- [:discovery, :agentic_discovery] do
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

    for file <- ["discovery.md", "agentic_discovery.md"] do
      path = Path.join(prompt_dir, file)
      assert File.exists?(path), "missing catalog prompt file #{path}"
      assert File.read!(path) =~ "<!-- PTC_PROMPT_START -->"
    end
  end

  test "discovery block is built from catalog builtin prompts" do
    block = CatalogPrompt.discovery_block()

    assert block =~ ~s|`(catalog/search-tools "query" {:limit 8})`|
    assert block =~ ~s|`(catalog/list-tools "server" {:limit 20})`|
    assert block =~ ~s|`(catalog/describe-tool "server" "tool")`|
    assert block =~ ~s|`(tool/mcp-call {:server "server" :tool "tool" :args {...}})`|

    Enum.each(@forbidden_runtime_patterns, fn pattern ->
      refute String.contains?(block, pattern)
    end)
  end

  test "agentic discovery block includes discovery and quota guidance" do
    block = CatalogPrompt.agentic_discovery_block()

    assert block =~ ~s|`(catalog/search-tools "query" {:limit 8})`|
    assert block =~ "catalog/* ops have their own budget"
  end

  test "upstream-capable eval tool cards start with discovery guidance" do
    for key <- [
          :lisp_eval_with_upstreams_description,
          :lisp_session_eval_with_upstreams_description
        ] do
      text = PromptRegistry.card_text(key)

      assert String.starts_with?(text, "Tools below. For details:")
      assert text =~ ~s|`(catalog/describe-tool "server" "tool")`|
      assert text =~ ~s|`(tool/mcp-call {:server "server" :tool "tool" :args {...}})`|
    end
  end
end
