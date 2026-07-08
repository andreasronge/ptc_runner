defmodule PtcRunner.KernelTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude.Compiler

  test "happy path: mock LLM tool call is evaluated by strict inner Lisp and returned" do
    llm =
      scripted_llm([
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(return (+ 40 2))"}}]}
      ])

    assert {:ok, %{"value" => 42, "trace" => %{"turns" => 1}}} =
             Kernel.run(%{"task" => "compute"}, llm: llm)
  end

  test "protocol error retries with feedback, then accepts a valid action" do
    parent = self()

    llm =
      scripted_llm(
        [
          %{content: "I would write (return 1)."},
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(return :ok)"}}]}
        ],
        parent
      )

    assert {:ok, %{"value" => "ok", "trace" => %{"turns" => 2}}} =
             Kernel.run(%{"task" => "compute"}, llm: llm)

    assert_received {:llm_request, %{messages: first_messages}}
    assert_received {:llm_request, %{messages: retry_messages}}

    assert length(first_messages) == 2
    assert [%{"role" => "user", "content" => feedback}] = Enum.drop(retry_messages, 2)
    assert feedback =~ "Protocol error"
    assert feedback =~ "run_ptc_lisp"
  end

  test "model program fail path returns a kernel error without another eval" do
    llm =
      scripted_llm([
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(fail {:reason :bad})"}}]}
      ])

    assert {:error, %{"reason" => "model_program_failed", "eval" => %{"status" => "fail"}}} =
             Kernel.run(%{"task" => "compute"}, llm: llm)
  end

  test "continue projection is bounded and does not expose raw Step" do
    llm =
      scripted_llm([
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(+ 1 2)"}}]},
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(return 7)"}}]}
      ])

    {:ok, events} = Agent.start(fn -> [] end)
    on_exit(fn -> if Process.alive?(events), do: Agent.stop(events) end)

    assert {:ok, %{"value" => 7}} =
             Kernel.run(%{"task" => "compute"},
               llm: llm,
               events: &Agent.update(events, fn xs -> [&1 | xs] end)
             )

    eval_events =
      events
      |> Agent.get(& &1)
      |> Enum.filter(&(Map.get(&1, "event") == "eval"))

    assert [
             %{"result" => %{"status" => "return"}},
             %{"result" => %{"status" => "continue", "prints" => []}}
           ] =
             eval_events
  end

  test "private kernel capabilities are denied to model programs" do
    llm =
      scripted_llm([
        %{
          tool_calls: [
            %{name: "run_ptc_lisp", args: %{"program" => ~S|(tool/llm-complete {"messages" []})|}}
          ]
        },
        %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(return :recovered)"}}]}
      ])

    assert {:ok, %{"value" => "recovered", "trace" => %{"turns" => 2}}} =
             Kernel.run(%{"task" => "compute"}, llm: llm)
  end

  test "prelude export can call private kernel tools but user code cannot" do
    {:ok, prelude} = Compiler.compile(Kernel.prelude_source())

    assert {:error, step} =
             Lisp.run(~S|(tool/log {"event" "forged"})|,
               prelude: prelude,
               tools: %{
                 "log" => {fn _ -> %{"ok" => true} end, [visibility: :private]},
                 "llm-complete" => {fn _ -> %{} end, [visibility: :private]},
                 "eval-program" => {fn _ -> %{} end, [visibility: :private]}
               }
             )

    assert step.fail.reason == :private_tool_unauthorized
  end

  test "rendered prompt hygiene is native-tool-call only and domain blind" do
    prompt = Kernel.render_system_prompt()

    assert prompt =~ "run_ptc_lisp"
    refute prompt =~ "lisp_eval"
    refute prompt =~ "```"
    refute prompt =~ "final answer"

    for forbidden <- ["product", "customer", "wire", "email", "invoice"] do
      refute String.contains?(String.downcase(prompt), forbidden)
    end
  end

  defp scripted_llm(responses, notify \\ nil) do
    {:ok, agent} = Agent.start(fn -> responses end)

    fn request ->
      if notify, do: send(notify, {:llm_request, request})

      Agent.get_and_update(agent, fn
        [next | rest] -> {{:ok, next}, rest}
        [] -> {{:ok, %{content: "no scripted response"}}, []}
      end)
    end
  end
end
