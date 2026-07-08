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

    assert {:ok, %{"value" => 42, "trace" => %{"turns" => 1, "actions" => [_]}}} =
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

    assert {:ok, %{"value" => "ok", "trace" => %{"turns" => 2, "actions" => [_, _]}}} =
             Kernel.run(%{"task" => "compute"}, llm: llm)

    assert_received {:llm_request, %{system: system_prompt, messages: first_messages}}
    assert_received {:llm_request, %{messages: retry_messages}}

    assert system_prompt == Kernel.render_system_prompt()
    assert first_messages == [%{role: :user, content: "compute"}]
    assert [%{role: :user, content: feedback}] = Enum.drop(retry_messages, 1)
    assert feedback =~ "Protocol error"
    assert feedback =~ "run_ptc_lisp"
  end

  test "caller-supplied system prompt is sent once through the request system channel" do
    parent = self()

    llm =
      scripted_llm(
        [
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(return 1)"}}]}
        ],
        parent
      )

    assert {:ok, %{"value" => 1}} =
             Kernel.run(%{"task" => "compute"}, llm: llm, system_prompt: "custom system")

    assert_received {:llm_request, %{system: "custom system", messages: messages}}
    assert [%{role: :user, content: "compute"}] = messages
    refute Enum.any?(messages, &(&1.role == :system))
  end

  test "transport errors surface as kernel errors instead of model protocol feedback" do
    llm = fn _request -> {:error, :econnrefused} end

    assert {:error, %{"reason" => "llm_transport_error", "error" => error}} =
             Kernel.run(%{"task" => "compute"}, llm: llm)

    assert error.kind == "transport_error"
    assert error.reason == ":econnrefused"
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
    parent = self()

    llm =
      scripted_llm(
        [
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(+ 1 2)"}}]},
          %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => "(return 7)"}}]}
        ],
        parent
      )

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

    assert_received {:llm_request, %{messages: [%{role: :user}]}}

    assert_received {:llm_request,
                     %{
                       messages: [
                         %{role: :user},
                         %{
                           role: :assistant,
                           tool_calls: [
                             %{
                               id: tool_call_id,
                               type: "function",
                               function: %{name: "run_ptc_lisp", arguments: arguments}
                             }
                           ]
                         },
                         %{role: :tool, tool_call_id: tool_call_id, content: feedback}
                       ]
                     }}

    assert is_binary(tool_call_id)
    assert Jason.decode!(arguments)["program"] == "(+ 1 2)"
    assert feedback =~ "Program did not return successfully"
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
