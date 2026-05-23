defmodule PtcRunnerMcp.PromptRegistryTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.PromptRegistry

  @forbidden_runtime_patterns [
    "<!--",
    "PTC_PROMPT_START",
    "PTC_PROMPT_END",
    "docs/",
    "Plans/",
    "priv/prompts/README.md",
    "hexdocs.pm/ptc_runner",
    "Full reference:",
    "see docs"
  ]

  @dynamic_boundaries MapSet.new([
                        :before_dynamic_catalog,
                        :dynamic_catalog,
                        :operator_text,
                        :static_card,
                        :terminal_authoritative_card
                      ])

  @trust_levels MapSet.new([
                  :authoritative,
                  :operator_text,
                  :untrusted_data
                ])

  test "all cards expose only the metadata used by prompt assembly" do
    Enum.each(PromptRegistry.card_keys(), fn key ->
      metadata = PromptRegistry.card_metadata(key)

      assert metadata.id == key
      assert Map.keys(metadata) |> Enum.sort() == [:dynamic_boundary, :id, :trust]
      assert MapSet.member?(@dynamic_boundaries, metadata.dynamic_boundary)
      assert MapSet.member?(@trust_levels, metadata.trust)
    end)
  end

  test "MCP language reference is file-backed" do
    text = PromptRegistry.card_text(:mcp_language_reference)

    assert text =~ "PTC-Lisp reference"
    assert text =~ "No `lambda`, `let*`"
    refute text =~ "<java_interop>"
    refute text =~ "<restrictions>"
  end

  test "all profiles reference registered cards and expose metadata in render order" do
    cards = MapSet.new(PromptRegistry.card_keys())

    Enum.each(PromptRegistry.profile_keys(), fn profile ->
      parts = PromptRegistry.profile_parts!(profile)

      assert parts != []
      assert MapSet.subset?(MapSet.new(parts), cards)
      assert Enum.map(PromptRegistry.profile_metadata(profile), & &1.id) == parts
    end)
  end

  test "prompt keys include every profile and card key" do
    expected =
      PromptRegistry.profile_keys()
      |> Kernel.++(PromptRegistry.card_keys())
      |> MapSet.new()

    assert MapSet.new(PromptRegistry.prompt_keys()) == expected
  end

  test "rendered MCP tool descriptions exclude metadata, markers, and authoring references" do
    for key <- [
          :mcp_no_tools_description,
          :mcp_aggregator_description,
          :mcp_session_start_description,
          :mcp_session_eval_description,
          :mcp_session_eval_with_upstreams_description,
          :lisp_debug_description,
          :lisp_task_description
        ] do
      rendered = PromptRegistry.render(key, catalog: nil)

      assert is_binary(rendered)
      assert byte_size(rendered) <= 2_000

      Enum.each(@forbidden_runtime_patterns, fn pattern ->
        refute String.contains?(rendered, pattern),
               "#{key} contains forbidden runtime prompt pattern #{inspect(pattern)}"
      end)
    end
  end

  test "rendered MCP tool descriptions do not repeat prompt lines" do
    for key <- [
          :mcp_no_tools_description,
          :mcp_aggregator_description,
          :mcp_session_start_description,
          :mcp_session_eval_description,
          :mcp_session_eval_with_upstreams_description,
          :lisp_debug_description,
          :lisp_task_description
        ] do
      duplicates =
        key
        |> PromptRegistry.render(catalog: nil)
        |> repeated_prompt_lines()

      assert duplicates == [],
             "#{key} repeats prompt line(s): #{inspect(duplicates)}"
    end
  end

  test "file-backed MCP cards are extracted before rendering" do
    for key <- [
          :lisp_eval_description,
          :lisp_eval_with_upstreams_description,
          :mcp_language_reference,
          :lisp_session_start_description,
          :lisp_session_eval_description,
          :lisp_session_eval_with_upstreams_description,
          :mcp_session_list_description,
          :mcp_session_inspect_description,
          :mcp_session_forget_description,
          :mcp_session_close_description,
          :lisp_debug_description,
          :lisp_task_description
        ] do
      text = PromptRegistry.card_text(key)

      assert is_binary(text)
      assert text != ""
      refute text =~ "<!--"
      refute text =~ "PTC_PROMPT_START"
      refute text =~ "PTC_PROMPT_END"
    end
  end

  test "every advertised MCP tool has a prompt file" do
    prompt_dir = Path.expand("../../priv/prompts/tools", __DIR__)

    for file <- [
          "lisp_eval.md",
          "lisp_eval.with_upstreams.md",
          "lisp_session_start.md",
          "lisp_session_eval.md",
          "lisp_session_eval.with_upstreams.md",
          "lisp_session_list.md",
          "lisp_session_inspect.md",
          "lisp_session_forget.md",
          "lisp_session_close.md",
          "lisp_debug.md",
          "lisp_task.md"
        ] do
      path = Path.join(prompt_dir, file)
      assert File.exists?(path), "missing MCP tool prompt file #{path}"
      assert File.read!(path) =~ "<!-- PTC_PROMPT_START -->"
    end
  end

  test "one-shot lisp_eval prompt does not mention unavailable session tools" do
    description = PromptRegistry.render(:mcp_no_tools_description, [])

    refute description =~ "ptc_session"
    refute description =~ "session tools"
    assert description =~ "No persistence across calls."
  end

  test "execute and session eval descriptions include the shared MCP language reference" do
    for key <- [
          :mcp_no_tools_description,
          :mcp_aggregator_description,
          :mcp_session_eval_description,
          :mcp_session_eval_with_upstreams_description
        ] do
      description = PromptRegistry.render(key, catalog: nil)

      assert description =~ "PTC-Lisp reference"
      assert description =~ "No `lambda`, `let*`"
      refute description =~ "<java_interop>"
      refute description =~ "<restrictions>"
    end
  end

  test "session eval upstream guidance is isolated to the upstream-enabled profile" do
    regular = PromptRegistry.render(:mcp_session_eval_description, [])

    with_upstreams =
      PromptRegistry.render(:mcp_session_eval_with_upstreams_description,
        catalog: "apropos"
      )

    refute regular =~ "tool/mcp-call"
    refute regular =~ "apropos"

    assert with_upstreams =~ "tool/mcp-call"
    assert with_upstreams =~ "apropos"
  end

  defp repeated_prompt_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&normalize_prompt_line/1)
    |> Enum.reject(&ignore_dup_line?/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_line, count} -> count > 1 end)
    |> Enum.map(fn {line, _count} -> line end)
    |> Enum.sort()
  end

  defp normalize_prompt_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp ignore_dup_line?(""), do: true
  defp ignore_dup_line?("```"), do: true
  defp ignore_dup_line?(_line), do: false
end
