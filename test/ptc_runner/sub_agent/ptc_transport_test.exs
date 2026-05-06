defmodule PtcRunner.SubAgent.PtcTransportTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "ptc_transport validation (Phase 1, R1–R3)" do
    test "defaults to :content when not specified" do
      agent = SubAgent.new(prompt: "Test")
      assert agent.ptc_transport == :content
    end

    test "accepts :content explicitly" do
      agent = SubAgent.new(prompt: "Test", ptc_transport: :content)
      assert agent.ptc_transport == :content
    end

    test "accepts :tool_call with default output (:ptc_lisp)" do
      agent = SubAgent.new(prompt: "Test", ptc_transport: :tool_call)
      assert agent.ptc_transport == :tool_call
      assert agent.output == :ptc_lisp
    end

    test "accepts :tool_call with explicit output: :ptc_lisp" do
      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, output: :ptc_lisp)

      assert agent.ptc_transport == :tool_call
    end

    test "rejects invalid ptc_transport value with accepted values listed" do
      assert_raise ArgumentError,
                   ~r/ptc_transport must be :content or :tool_call, got :foo/,
                   fn ->
                     SubAgent.new(prompt: "Test", ptc_transport: :foo)
                   end
    end

    test "rejects ptc_transport with output: :text (R2 — names both keys)" do
      assert_raise ArgumentError,
                   ~r/ptc_transport.*output: :text/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :text,
                       ptc_transport: :tool_call
                     )
                   end
    end

    test "rejects ptc_transport: :content with output: :text as well" do
      # The combination is rejected regardless of which valid transport is chosen,
      # because ptc_transport applies only to PTC-Lisp output.
      assert_raise ArgumentError,
                   ~r/ptc_transport.*output: :text/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :text,
                       ptc_transport: :content
                     )
                   end
    end
  end

  describe "reserved tool name `ptc_lisp_execute` (Phase 1, R4)" do
    test "rejects atom-keyed user tool named :ptc_lisp_execute with default transport" do
      assert_raise ArgumentError, ~r/"ptc_lisp_execute" is reserved/, fn ->
        SubAgent.new(
          prompt: "Test",
          tools: %{ptc_lisp_execute: fn _ -> :ok end}
        )
      end
    end

    test "rejects string-keyed user tool named \"ptc_lisp_execute\" with default transport" do
      assert_raise ArgumentError, ~r/"ptc_lisp_execute" is reserved/, fn ->
        SubAgent.new(
          prompt: "Test",
          tools: %{"ptc_lisp_execute" => fn _ -> :ok end}
        )
      end
    end

    test "rejects user tool named ptc_lisp_execute with ptc_transport: :tool_call" do
      assert_raise ArgumentError, ~r/"ptc_lisp_execute" is reserved/, fn ->
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          tools: %{ptc_lisp_execute: fn _ -> :ok end}
        )
      end
    end

    test "rejects user tool named ptc_lisp_execute alongside other valid tools" do
      assert_raise ArgumentError, ~r/"ptc_lisp_execute" is reserved/, fn ->
        SubAgent.new(
          prompt: "Test",
          tools: %{
            other_tool: fn _ -> :ok end,
            ptc_lisp_execute: fn _ -> :ok end
          }
        )
      end
    end

    test "still allows other user tool names" do
      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{my_tool: fn _ -> :ok end}
        )

      assert Map.has_key?(agent.tools, :my_tool)
    end
  end

  describe "Phase 1 runtime guard (loop.ex)" do
    test "constructing a :tool_call agent succeeds" do
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 2
        )

      assert agent.ptc_transport == :tool_call
    end

    test "executing a :tool_call agent raises before LLM is called" do
      test_pid = self()

      # llm callback fails the test if invoked, proving the guard fires first.
      llm = fn _input ->
        send(test_pid, :llm_invoked)
        {:ok, "should not be reached"}
      end

      # max_turns: 2 forces routing through Loop.run/2 (not the single-shot
      # fast path in SubAgent.run/2 which bypasses Loop).
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 2
        )

      assert_raise ArgumentError,
                   "ptc_transport: :tool_call not yet implemented",
                   fn ->
                     SubAgent.run(agent, llm: llm)
                   end

      refute_received :llm_invoked
    end

    test "executing a :tool_call agent on the single-shot fast path also raises" do
      test_pid = self()

      # llm callback fails the test if invoked, proving the guard fires first.
      llm = fn _input ->
        send(test_pid, :llm_invoked)
        {:ok, "should not be reached"}
      end

      # max_turns: 1, no tools, retry_turns: 0 routes through SubAgent.run/2's
      # single-shot fast path (run_single_shot), bypassing Loop.run/2. The
      # single-shot guard must mirror the Loop guard.
      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 1,
          retry_turns: 0,
          tools: %{}
        )

      assert_raise ArgumentError,
                   "ptc_transport: :tool_call not yet implemented",
                   fn ->
                     SubAgent.run(agent, llm: llm)
                   end

      refute_received :llm_invoked
    end

    test ":content transport executes through Loop without the guard firing" do
      # Sanity check that the guard is gated on :tool_call only.
      llm = fn _input ->
        {:ok, "```clojure\n(return \"hi\")\n```"}
      end

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :content,
          max_turns: 2
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == "hi"
    end
  end
end
