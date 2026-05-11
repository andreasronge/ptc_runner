defmodule PtcRunnerMcp.AgenticPromptTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Agentic.Prompt
  alias PtcRunnerMcp.Upstream.Catalog

  setup do
    Catalog.clear_frozen()

    on_exit(fn ->
      Catalog.clear_frozen()
    end)

    :ok
  end

  test "assembles ordered MCP sections with operator prefix suffix and final recap last" do
    Catalog.freeze("alpha:\n  ping()")

    prompt =
      Prompt.system_prompt(
        prefix: "operator prefix",
        suffix: "operator suffix",
        max_turns: 2,
        allow_writes: true
      )

    assert_order(prompt, [
      "You are an agent that writes PTC-Lisp programs",
      "operator prefix",
      "PTC-Lisp dialect authoring:",
      "ptc_task MCP-call contract:",
      "Upstream catalog:\nalpha:",
      "operator suffix",
      "Final MCP recap:"
    ])

    assert String.ends_with?(
             prompt,
             "- Return a human-readable text answer that addresses the task."
           )

    assert prompt =~ "Check the value before returning it"
    assert prompt =~ "You may continue across turns"
    assert prompt =~ "Write-capable upstream calls may have side effects"
  end

  test "prompt contains exactly one ptc_task MCP-call contract" do
    prompt = Prompt.system_prompt(catalog: "docs:\n  search()")

    assert count(prompt, "ptc_task MCP-call contract:") == 1
    assert count(prompt, "In `ptc_task`, `tool/mcp-call` returns a tagged map") == 1
    assert prompt =~ "Prefer `(mcp/text ...)` for human-readable upstream text"
    assert prompt =~ "unexpected shape, inspect `(mcp/text ...)`"
    assert prompt =~ "inspect `:ok`"
    refute prompt =~ ":tag"
    refute prompt =~ "returns `nil`"
    refute prompt =~ "tool/mcp-call returns nil"
  end

  test "assemble returns user message and generic tool-rendering suppression data" do
    assembled =
      Prompt.assemble(%{
        task: "find the issue",
        context: %{"repo" => "ptc_runner"},
        constraints: %{"max_items" => 3}
      })

    assert assembled.user_message =~ "Task:\nfind the issue"
    assert assembled.user_message =~ ~S|"repo":"ptc_runner"|
    assert assembled.user_message =~ ~S|"max_items":3|

    assert assembled.tool_rendering == %{
             "suppress_generic_tools" => ["mcp-call"],
             "authoritative_tool_contracts" => ["mcp-call"]
           }
  end

  defp assert_order(text, markers) do
    {_last, _text} =
      Enum.reduce(markers, {-1, text}, fn marker, {previous, whole} ->
        index =
          case :binary.match(whole, marker) do
            {idx, _len} -> idx
            :nomatch -> flunk("missing marker #{inspect(marker)}")
          end

        assert index > previous
        {index, whole}
      end)
  end

  defp count(text, pattern) do
    text
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end
end
