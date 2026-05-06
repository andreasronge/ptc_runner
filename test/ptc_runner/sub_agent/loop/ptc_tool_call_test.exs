defmodule PtcRunner.SubAgent.Loop.PtcToolCallTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop
  alias PtcRunner.SubAgent.Loop.PtcToolCall
  alias PtcRunner.SubAgent.Loop.State
  alias PtcRunner.SubAgent.SystemPrompt

  # Stable substring pulled from the canonical description string in the
  # plan (Plans/ptc-lisp-tool-call-transport.md, "Internal execution
  # tool"). Tests assert against substrings of the same constant so the
  # canonical text is the single source of truth (R7).
  @canonical_substring "Call app tools as `(tool/name ...)` from inside the program"

  describe "tool_schema/0 — native tool schema for ptc_lisp_execute (R7)" do
    test "schema name is ptc_lisp_execute" do
      schema = PtcToolCall.tool_schema()
      assert schema["function"]["name"] == "ptc_lisp_execute"
    end

    test "schema requires a non-empty `program` string argument" do
      schema = PtcToolCall.tool_schema()
      params = schema["function"]["parameters"]

      assert params["type"] == "object"
      assert params["required"] == ["program"]
      assert params["properties"]["program"]["type"] == "string"
    end

    test "description matches the canonical constant exactly" do
      schema = PtcToolCall.tool_schema()
      assert schema["function"]["description"] == PtcToolCall.tool_description()
    end

    test "description includes the canonical guidance about (tool/name ...)" do
      # Stable-substring assertion against the canonical description
      # string. R7: the description must explicitly tell the model to
      # call app tools as `(tool/name ...)` from inside the program,
      # not as native function calls.
      assert PtcToolCall.tool_description() =~ @canonical_substring
      assert PtcToolCall.tool_schema()["function"]["description"] =~ @canonical_substring
    end

    test "tool_name/0 returns the reserved name" do
      assert PtcToolCall.tool_name() == "ptc_lisp_execute"
    end
  end

  describe "request_tools/1 — provider-native tools list (R5)" do
    test ":tool_call mode returns exactly one entry — ptc_lisp_execute" do
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          tools: %{
            "search" => fn _ -> [] end,
            "fetch" => fn _ -> %{} end,
            "annotate" => fn _ -> "ok" end
          }
        )

      tools = PtcToolCall.request_tools(agent)

      assert is_list(tools)
      assert length(tools) == 1
      assert hd(tools)["function"]["name"] == "ptc_lisp_execute"
    end

    test ":tool_call mode never exposes app tools as provider-native tools" do
      # R5: regardless of how many app tools the agent declares, the
      # native `tools` array contains only `ptc_lisp_execute`. App-tool
      # names must not appear anywhere in the structure.
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          tools: %{
            "search_docs" => fn _ -> [] end,
            "lookup_user" => fn _ -> %{} end
          }
        )

      tools = PtcToolCall.request_tools(agent)
      flat = inspect(tools)

      refute flat =~ "search_docs"
      refute flat =~ "lookup_user"
    end

    test ":tool_call mode with zero app tools still yields one native entry" do
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          tools: %{}
        )

      assert [%{"function" => %{"name" => "ptc_lisp_execute"}}] =
               PtcToolCall.request_tools(agent)
    end

    test ":content mode returns nil (no native tools field)" do
      # In :content mode, app tools are not exposed as native provider
      # tools either — they are documented in the system prompt and
      # called from inside fenced PTC-Lisp. The request omits the
      # `tools` field entirely.
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :content,
          tools: %{"search" => fn _ -> [] end}
        )

      assert PtcToolCall.request_tools(agent) == nil
    end

    test "default agent is :content and returns nil" do
      agent = SubAgent.new(prompt: "Test", tools: %{"x" => fn _ -> :ok end})
      assert agent.ptc_transport == :content
      assert PtcToolCall.request_tools(agent) == nil
    end
  end

  describe "Loop.build_llm_input/5 — request shape (R5, R6)" do
    test ":tool_call request has tools=[ptc_lisp_execute] and one entry only" do
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          tools: %{
            "search" => fn _ -> [] end,
            "fetch" => fn _ -> %{} end
          },
          max_turns: 3
        )

      state = build_state(turn: 1, work_turns_remaining: 3)
      input = Loop.build_llm_input(agent, "system here", [], state, false)

      assert is_list(input.tools)
      assert length(input.tools) == 1
      assert hd(input.tools)["function"]["name"] == "ptc_lisp_execute"
    end

    test ":tool_call request never carries app-tool names in the tools field" do
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          tools: %{
            "secret_app_tool_alpha" => fn _ -> :ok end,
            "secret_app_tool_beta" => fn _ -> :ok end
          },
          max_turns: 3
        )

      state = build_state(turn: 1, work_turns_remaining: 3)
      input = Loop.build_llm_input(agent, "system", [], state, false)
      flat = inspect(input.tools)

      refute flat =~ "secret_app_tool_alpha"
      refute flat =~ "secret_app_tool_beta"
    end

    test ":content request has no :tools key (regression — match existing behavior)" do
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :content,
          tools: %{"search" => fn _ -> [] end},
          max_turns: 3
        )

      state = build_state(turn: 1, work_turns_remaining: 3)
      input = Loop.build_llm_input(agent, "system", [], state, false)

      refute Map.has_key?(input, :tools)
    end

    test ":content request preserves tool_names hint (existing behavior)" do
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :content,
          tools: %{"search" => fn _ -> [] end},
          max_turns: 3
        )

      state = build_state(turn: 1, work_turns_remaining: 3)
      input = Loop.build_llm_input(agent, "system", [], state, false)

      assert input.tool_names == ["search"]
    end

    test ":content request strips tool_names in must-return mode (existing behavior)" do
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :content,
          tools: %{"search" => fn _ -> [] end},
          max_turns: 1
        )

      state = build_state(turn: 1, work_turns_remaining: 1)
      input = Loop.build_llm_input(agent, "system", [], state, true)

      assert input.tool_names == []
    end
  end

  describe "system prompt — :tool_call output format (R6, R25, R26)" do
    test ":tool_call <output_format> block does not carry the :content fenced contract" do
      # R26: the tool-call output format must instruct the model not
      # to return fenced code blocks. The :content-mode contract phrase
      # ("Respond with EXACTLY ONE ```clojure code block") must not
      # appear in the <output_format> section. The language reference
      # (priv/prompts/) is unchanged and may still discuss fenced code
      # in its own examples — that's a separate concern (R6 says the
      # PTC-Lisp language reference stays).
      agent = SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)
      system = SystemPrompt.generate_system(agent)
      output_format_block = extract_output_format(system)

      refute output_format_block =~ "Respond with EXACTLY ONE ```clojure code block"
    end

    test ":tool_call prompt instructs the model to call ptc_lisp_execute" do
      # R26: instruct the model to call `ptc_lisp_execute` for
      # computation/orchestration.
      agent = SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)
      system = SystemPrompt.generate_system(agent)

      assert system =~ "ptc_lisp_execute"
    end

    test ":tool_call prompt instructs the model to return the final answer directly" do
      # R26: when ready, return the final answer in the requested
      # signature shape.
      agent = SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)
      system = SystemPrompt.generate_system(agent)

      assert system =~ ~r/return.*answer.*directly/i or system =~ ~r/Return the final answer/i
      assert system =~ "signature shape"
    end

    test ":tool_call prompt explicitly forbids fenced code blocks" do
      # R26: do not return fenced code blocks.
      agent = SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)
      system = SystemPrompt.generate_system(agent)

      assert system =~ ~r/(do\s+not|don't|never)/i
      assert system =~ "fenced"
    end

    test ":tool_call prompt forbids native app-tool calls" do
      # Reinforces R7 inside the prompt itself, not just on the tool
      # description: only `ptc_lisp_execute` is available natively.
      agent = SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)
      system = SystemPrompt.generate_system(agent)

      assert system =~ "only `ptc_lisp_execute`"
    end

    test ":tool_call thinking variant differs from non-thinking variant" do
      agent_plain = SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)

      agent_thinking =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, thinking: true, max_turns: 3)

      plain = SystemPrompt.generate_system(agent_plain)
      thinking = SystemPrompt.generate_system(agent_thinking)

      assert thinking =~ "thinking:"
      refute plain =~ "thinking:"
    end

    test ":content prompt is unchanged (regression — fenced contract preserved)" do
      agent = SubAgent.new(prompt: "Test", ptc_transport: :content, max_turns: 3)
      system = SystemPrompt.generate_system(agent)

      assert system =~ "Respond with EXACTLY ONE ```clojure code block"
    end
  end

  describe "system prompt — app-tool inventory still rendered in :tool_call mode (R6)" do
    test "tool inventory namespace section is present in :tool_call mode" do
      # R6: the system prompt continues to render the app-tool
      # inventory in `:tool_call` mode. App tools are still callable
      # via `(tool/name ...)` from inside the PTC-Lisp program — the
      # inventory documents what is available.
      agent =
        SubAgent.new(
          prompt: "Run the search",
          ptc_transport: :tool_call,
          tools: %{
            "search_widgets" => fn _ -> [] end,
            "rank" => fn _ -> [] end
          }
        )

      # generate/2 returns the full prompt (static + dynamic + mission)
      prompt = SystemPrompt.generate(agent, context: %{q: "hello"})

      assert prompt =~ ";; === tools ==="
      assert prompt =~ "tool/search_widgets"
      assert prompt =~ "tool/rank"
    end

    test "generate_context/2 in :tool_call mode renders app tools as namespaced lisp" do
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          tools: %{"search" => fn _ -> [] end}
        )

      ctx = SystemPrompt.generate_context(agent, context: %{q: 1})

      assert ctx =~ ";; === tools ==="
      assert ctx =~ "tool/search"
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp extract_output_format(prompt) do
    case Regex.run(~r/<output_format>(.*?)<\/output_format>/s, prompt) do
      [_, body] -> body
      _ -> ""
    end
  end

  defp build_state(opts) do
    %State{
      llm: nil,
      turn: Keyword.get(opts, :turn, 1),
      work_turns_remaining: Keyword.get(opts, :work_turns_remaining, 1),
      retry_turns_remaining: Keyword.get(opts, :retry_turns_remaining, 0),
      cache: Keyword.get(opts, :cache, false),
      messages: [],
      memory: %{},
      context: %{},
      start_time: System.monotonic_time(:millisecond)
    }
  end
end
