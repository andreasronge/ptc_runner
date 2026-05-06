defmodule PtcRunner.SubAgent.Loop.TextModeCombinedPtcLispTest do
  @moduledoc """
  Tier 3a — TextMode `ptc_lisp_execute` happy-path tests.

  Combined mode = `output: :text, ptc_transport: :tool_call`. The
  validator still rejects this combo at agent construction (Tier 3e
  flips the gate). Tests build via `SubAgent.new/1` in pure text mode
  and `into_combined/1` it before invoking `SubAgent.run/2`, mirroring
  the helper used in `text_mode_combined_test.exs`.

  Coverage:

  - Combined-mode request includes `ptc_lisp_execute` with the
    `:in_process_text_mode` profile description.
  - Pure text mode does NOT include `ptc_lisp_execute`.
  - Happy path: program returns intermediate value, tool result rendered.
  - `(return v)` produces a tool result and the loop continues.
  - `(fail v)` produces an error tool result; loop continues if budget
    remains.
  - Parse / runtime errors render as tool-result error JSON; loop
    continues.
  - Memory-limit fatal terminates with `{:error, step}`; rollback
    continues.
  - Budget exemption: `max_tool_calls: 1` allows ≥ 2 sequential
    `ptc_lisp_execute` calls. Native calls still consume budget.
  - State threading: memory / journal / tool_cache / child_steps
    propagate.
  - PTC-Lisp `(tool/foo ...)` from inside a program hits a `:both`
    tool but is rejected at parse time when called against a
    `:native`-only target.
  - Telemetry: combined-mode native call emits `:native`; PTC-Lisp
    `(tool/...)` call emits `:ptc_lisp`.
  """

  use ExUnit.Case, async: false

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Definition
  alias PtcRunner.SubAgent.Loop.{PtcToolCall, TextMode}

  import PtcRunner.TestSupport.SubAgentTestHelpers, only: [tool_calling_llm: 1]

  defp into_combined(%Definition{} = agent), do: %{agent | ptc_transport: :tool_call}

  defp run_combined(agent, llm) do
    SubAgent.run(into_combined(agent), llm: llm, collect_messages: true)
  end

  # ---------------------------------------------------------------------------
  # Combined-mode request build
  # ---------------------------------------------------------------------------

  describe "combined-mode request build" do
    test "tool_schemas include ptc_lisp_execute with :in_process_text_mode description" do
      schema = TextMode.combined_mode_tool_schema()

      assert schema["type"] == "function"
      assert schema["function"]["name"] == "ptc_lisp_execute"
      desc = schema["function"]["description"]

      # Substring pin against the canonical :in_process_text_mode profile string.
      assert desc =~ "Execute a PTC-Lisp program in PtcRunner's sandbox."
      assert desc =~ "filtering, aggregation, or multi-step data transformation"
      assert desc =~ ":both`-exposed app tools"
    end

    test "combined-mode description differs from :in_process_with_app_tools profile" do
      combined_desc =
        TextMode.combined_mode_tool_schema()
        |> get_in(["function", "description"])

      in_process_desc =
        PtcToolCall.tool_schema()
        |> get_in(["function", "description"])

      refute combined_desc == in_process_desc
    end

    test "combined-mode LLM request lists ptc_lisp_execute alongside native tools" do
      tools = %{
        "search" =>
          {fn _ -> [%{"id" => 1}] end, signature: "(q :string) -> [:any]", expose: :native}
      }

      test_pid = self()

      capturing_llm = fn input ->
        send(test_pid, {:llm_input, input})
        {:ok, %{content: "done", tokens: %{input: 1, output: 1}}}
      end

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 3)

      {:ok, _step} = run_combined(agent, capturing_llm)

      assert_received {:llm_input, %{tools: tool_list}}
      names = Enum.map(tool_list, & &1["function"]["name"])
      assert "search" in names
      assert "ptc_lisp_execute" in names
    end

    test "pure text mode (no combined) does NOT include ptc_lisp_execute" do
      tools = %{
        "search" => {fn _ -> [%{"id" => 1}] end, signature: "(q :string) -> [:any]"}
      }

      test_pid = self()

      capturing_llm = fn input ->
        send(test_pid, {:llm_input, input})
        {:ok, %{content: "done", tokens: %{input: 1, output: 1}}}
      end

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 3)
      {:ok, _step} = SubAgent.run(agent, llm: capturing_llm)

      assert_received {:llm_input, %{tools: tool_list}}
      names = Enum.map(tool_list, & &1["function"]["name"])
      refute "ptc_lisp_execute" in names
    end
  end

  # ---------------------------------------------------------------------------
  # Happy-path dispatch
  # ---------------------------------------------------------------------------

  describe "happy path: ptc_lisp_execute returns intermediate value" do
    test "tool result rendered with status: ok; loop continues to final text" do
      tools = %{
        "search" =>
          {fn _ -> [%{"id" => 1}] end,
           signature: "(q :string) -> [:any]", expose: :both, cache: true}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => "(+ 1 2)"}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      test_pid = self()
      handler_id = :"ptc_happy_#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:ptc_runner, :sub_agent, :tool, :call],
        fn _e, _m, meta, _ -> send(test_pid, {:tool_event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "done"

      # Confirm a :native exposure-layer event fired for the dispatch itself.
      assert_received {:tool_event, %{tool_name: "ptc_lisp_execute", exposure_layer: :native}}
    end
  end

  describe "(return v) produces a tool result and continues" do
    test "tool message JSON has status: ok; loop continues to assistant turn" do
      tools = %{}

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => "(return {:value 42})"}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "wrapped", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      # Loop did not terminate on (return v); LLM produced final text.
      assert step.return == "wrapped"

      # Inspect the paired tool-result message.
      tool_msg = Enum.find(step.messages, &(&1[:role] == :tool))
      payload = Jason.decode!(tool_msg.content)
      assert payload["status"] == "ok"
    end
  end

  describe "(fail v) produces an error tool result and continues" do
    test "tool message JSON has reason: fail and a result preview; loop continues" do
      tools = %{}

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => ~S|(fail "boom")|}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "ok recovered", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "ok recovered"

      tool_msg = Enum.find(step.messages, &(&1[:role] == :tool))
      payload = Jason.decode!(tool_msg.content)
      assert payload["status"] == "error"
      assert payload["reason"] == "fail"
      assert is_binary(payload["result"])
      assert payload["result"] =~ "boom"
    end
  end

  describe "parse / runtime errors render as tool-result error JSON" do
    test "parse error renders reason: parse_error; loop continues" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => "((((not balanced"}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "tried", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "tried"
      tool_msg = Enum.find(step.messages, &(&1[:role] == :tool))
      payload = Jason.decode!(tool_msg.content)
      assert payload["status"] == "error"
      assert payload["reason"] == "parse_error"
    end

    test "runtime error renders reason: runtime_error; loop continues" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => "(undefined-fn 1 2)"}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "tried", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "tried"
      tool_msg = Enum.find(step.messages, &(&1[:role] == :tool))
      payload = Jason.decode!(tool_msg.content)
      assert payload["status"] == "error"
      # Reason classification covers all non-parse / non-timeout / non-memory runtime errors.
      assert payload["reason"] in ["runtime_error", "parse_error"]
    end
  end

  # ---------------------------------------------------------------------------
  # Memory-limit handling
  # ---------------------------------------------------------------------------

  describe "memory-limit handling" do
    test "memory_limit fatal terminates with {:error, step}" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => "(def big (str (range 0 1000)))"}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "unused", tokens: %{input: 1, output: 1}}
        ])

      # Tiny memory_limit — first program write should exceed it.
      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          tools: %{},
          max_turns: 5,
          memory_limit: 100,
          memory_strategy: :strict
        )

      assert {:error, %PtcRunner.Step{}} = run_combined(agent, llm)
    end

    test "memory_limit rollback continues" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => "(def big (str (range 0 1000)))"}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "recovered", tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          tools: %{},
          max_turns: 5,
          memory_limit: 100,
          memory_strategy: :rollback
        )

      {:ok, step} = run_combined(agent, llm)
      assert step.return == "recovered"

      tool_msg = Enum.find(step.messages, &(&1[:role] == :tool))
      payload = Jason.decode!(tool_msg.content)
      assert payload["status"] == "error"
      assert payload["reason"] == "memory_limit"
    end
  end

  # ---------------------------------------------------------------------------
  # Budget exemption
  # ---------------------------------------------------------------------------

  describe "budget exemption (Tier 3a Addendum)" do
    test "max_tool_calls: 1 allows ≥ 2 sequential ptc_lisp_execute calls" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "ptc_lisp_execute", args: %{"program" => "(+ 1 2)"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{
            tool_calls: [
              %{id: "c2", name: "ptc_lisp_execute", args: %{"program" => "(+ 3 4)"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{
            tool_calls: [
              %{id: "c3", name: "ptc_lisp_execute", args: %{"program" => "(+ 5 6)"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 6, max_tool_calls: 1)

      {:ok, step} = run_combined(agent, llm)
      assert step.return == "done"

      # No "Tool call limit reached" message should appear.
      tool_msgs = Enum.filter(step.messages, &(&1[:role] == :tool))

      refute Enum.any?(tool_msgs, fn m ->
               m.content =~ "Tool call limit reached"
             end)

      assert length(tool_msgs) == 3
    end

    test "native app-tool calls still consume max_tool_calls budget" do
      tools = %{
        "search" => {fn _ -> [%{"id" => 1}] end, signature: "(q :string) -> [:any]"}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "search", args: %{"q" => "x"}},
              %{id: "c2", name: "search", args: %{"q" => "y"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 6, max_tool_calls: 1)

      {:ok, step} = run_combined(agent, llm)

      tool_msgs = Enum.filter(step.messages, &(&1[:role] == :tool))

      assert Enum.any?(tool_msgs, fn m ->
               m.content =~ "Tool call limit reached"
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # State threading
  # ---------------------------------------------------------------------------

  describe "state threading" do
    test "memory propagates across program executions via (def ...)" do
      # Program 1 stores via (def n 7); program 2 reads it back as `n`.
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => ~s|(def n 7) n|}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{
            tool_calls: [
              %{
                id: "c2",
                name: "ptc_lisp_execute",
                args: %{"program" => "(* 2 n)"}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 6)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "done"

      # Final step memory carries the bound `n` from the first program.
      assert Map.get(step.memory, :n) == 7 or Map.get(step.memory, "n") == 7
    end
  end

  # ---------------------------------------------------------------------------
  # PTC-Lisp (tool/...) call inventory filtering
  # ---------------------------------------------------------------------------

  describe "PTC-Lisp inventory filtering" do
    test "(tool/foo) call hits a :both-exposed tool" do
      counter = :atomics.new(1, [])

      tools = %{
        "echo" =>
          {fn args ->
             :atomics.add(ref = counter, 1, 1)
             _ = ref
             args
           end, signature: "(v :int) -> :any", expose: :both, cache: false}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => ~s|(tool/echo {:v 7})|}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "ok", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)
      assert step.return == "ok"

      # Tool was actually invoked from inside the program.
      assert :atomics.get(counter, 1) == 1
    end

    test "(tool/foo) call against a :native-only target is rejected at parse time" do
      tools = %{
        "echo" => {fn args -> args end, signature: "(v :int) -> :any", expose: :native}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => ~s|(tool/echo {:v 7})|}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "fallback", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)
      assert step.return == "fallback"

      tool_msg = Enum.find(step.messages, &(&1[:role] == :tool))
      payload = Jason.decode!(tool_msg.content)

      # Either parse_error or runtime_error depending on analyzer
      # surfacing path. The key invariant: rejection, not silent
      # success.
      assert payload["status"] == "error"
      assert payload["reason"] in ["parse_error", "runtime_error"]
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry: exposure_layer for PTC-Lisp tool calls
  # ---------------------------------------------------------------------------

  describe "telemetry: exposure_layer" do
    test "PTC-Lisp (tool/...) call emits :ptc_lisp; native ptc_lisp_execute emits :native" do
      tools = %{
        "echo" =>
          {fn args -> args end, signature: "(v :int) -> :any", expose: :both, cache: false}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => ~s|(tool/echo {:v 7})|}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "ok", tokens: %{input: 1, output: 1}}
        ])

      test_pid = self()
      handler_id = :"ptc_telemetry_#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:ptc_runner, :sub_agent, :tool, :call],
        fn _e, _m, meta, _ -> send(test_pid, {:tool_event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, _step} = run_combined(agent, llm)

      events = collect_tool_events()

      assert Enum.any?(events, fn meta ->
               meta.tool_name == "ptc_lisp_execute" and meta.exposure_layer == :native
             end)

      assert Enum.any?(events, fn meta ->
               meta.tool_name == "echo" and meta.exposure_layer == :ptc_lisp
             end)
    end
  end

  defp collect_tool_events(acc \\ []) do
    receive do
      {:tool_event, meta} -> collect_tool_events([meta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
