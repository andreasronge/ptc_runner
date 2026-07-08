defmodule PtcRunner.Kernel.Eval do
  @moduledoc false

  alias PtcRunner.Kernel, as: KernelRunner
  alias PtcRunner.LLM
  alias PtcRunner.LLM.Registry
  alias PtcRunner.LLM.ReqLLMAdapter

  @default_live_model "deepseek"

  @type result :: %{
          suite: String.t(),
          mode: :mock | :live,
          model: String.t() | nil,
          runs: pos_integer(),
          cases: [map()]
        }

  @spec resolve_model(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def resolve_model(model \\ nil) do
    requested = model || System.get_env("PTC_TEST_MODEL") || @default_live_model
    Registry.resolve(requested)
  end

  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    suite = Keyword.get(opts, :suite, "mini")
    mode = Keyword.get(opts, :mode, :mock)
    runs = Keyword.get(opts, :runs, 1)

    with :ok <- validate_suite(suite),
         :ok <- validate_runs(runs),
         {:ok, model} <- resolve_model(mode, Keyword.get(opts, :model)),
         {:ok, cases} <- select_cases(Keyword.get(opts, :case)) do
      results =
        for run_index <- 1..runs,
            eval_case <- cases do
          run_case(eval_case, run_index, mode, model, opts)
        end

      {:ok, %{suite: suite, mode: mode, model: model, runs: runs, cases: results}}
    end
  end

  @spec render_markdown(result()) :: String.t()
  def render_markdown(%{suite: suite, mode: mode, model: model, runs: runs, cases: cases}) do
    rows =
      Enum.map(cases, fn case_result ->
        "| #{case_result.run} | #{case_result.case} | #{case_result.status} | #{case_result.action_count} | #{case_result.eval_count} | #{case_result.failure_reason || ""} |"
      end)

    """
    # PTC Kernel Eval

    suite: #{suite}
    mode: #{mode}
    model: #{model || "mock"}
    runs: #{runs}

    | run | case | status | actions | evals | failure |
    | --- | --- | --- | ---: | ---: | --- |
    #{Enum.join(rows, "\n")}
    """
    |> String.trim()
  end

  @spec mini_cases() :: [map()]
  def mini_cases do
    [
      %{
        id: "arithmetic",
        task: "Return the integer result of 40 + 2.",
        context: %{},
        max_turns: 3,
        mock_programs: [~S|(return (+ 40 2))|]
      },
      %{
        id: "context_filter_count",
        task:
          ~S|Use context key items, available as data/items. Return the count of items where kind is "keep".|,
        context: %{
          "items" => [
            %{"kind" => "keep"},
            %{"kind" => "skip"},
            %{"kind" => "keep"}
          ]
        },
        max_turns: 5,
        mock_programs: [~S|(return (count (filter #(= (% "kind") "keep") data/items)))|]
      },
      %{
        id: "context_aggregation",
        task:
          "Use context key numbers, available as data/numbers. Return the sum of all numbers.",
        context: %{"numbers" => [2, 4, 6]},
        max_turns: 5,
        mock_programs: [~S|(return (reduce + data/numbers))|]
      },
      %{
        id: "domain_tool",
        task: ~S|Call the granted lookup tool for id "alpha" and return its score.|,
        context: %{},
        tools: %{
          "lookup" => fn %{"id" => "alpha"} -> %{"score" => 9} end
        },
        max_turns: 5,
        mock_programs: [~S|(return ((tool/lookup {"id" "alpha"}) "score"))|]
      },
      %{
        id: "eval_retry",
        task: "Return the integer 3. If a previous program did not return, retry with return.",
        context: %{},
        max_turns: 5,
        mock_programs: [~S|(+ 1 2)|, ~S|(return 3)|]
      }
    ]
  end

  defp validate_suite("mini"), do: :ok
  defp validate_suite(other), do: {:error, {:unknown_suite, other}}

  defp validate_runs(runs) when is_integer(runs) and runs > 0, do: :ok
  defp validate_runs(other), do: {:error, {:invalid_runs, other}}

  defp resolve_model(:mock, _model), do: {:ok, nil}

  defp resolve_model(:live, model) do
    PtcRunner.Dotenv.load()

    with {:ok, resolved} <- resolve_model(model),
         :ok <- ensure_key(resolved) do
      {:ok, resolved}
    end
  end

  defp resolve_model(other, _model), do: {:error, {:unknown_mode, other}}

  defp ensure_key(model) do
    if ReqLLMAdapter.requires_api_key?(model) and is_nil(System.get_env("OPENROUTER_API_KEY")) do
      {:error, {:missing_api_key, "OPENROUTER_API_KEY", model}}
    else
      :ok
    end
  end

  defp select_cases(nil), do: {:ok, mini_cases()}

  defp select_cases(case_id) do
    case Enum.filter(mini_cases(), &(&1.id == case_id)) do
      [] -> {:error, {:unknown_case, case_id}}
      cases -> {:ok, cases}
    end
  end

  defp run_case(eval_case, run_index, mode, model, opts) do
    started = System.monotonic_time()
    {:ok, events} = Agent.start_link(fn -> [] end)
    {llm, cleanup_llm} = llm_for(eval_case, mode, model, opts)

    try do
      result =
        KernelRunner.run(mission(eval_case),
          llm: llm,
          tools: Map.get(eval_case, :tools, %{}),
          max_turns: eval_case.max_turns,
          events: &Agent.update(events, fn current -> [sanitize_event(&1) | current] end)
        )

      sanitized_events = Agent.get(events, &Enum.reverse/1)

      build_case_result(eval_case, run_index, result, sanitized_events, started)
    after
      cleanup_llm.()
      stop_agent(events)
    end
  end

  defp mission(eval_case) do
    %{
      "task" => eval_case.task,
      "context" => eval_case.context
    }
  end

  defp llm_for(eval_case, :mock, _model, _opts) do
    {:ok, agent} = Agent.start_link(fn -> eval_case.mock_programs end)

    llm = fn _request ->
      if Process.alive?(agent) do
        Agent.get_and_update(agent, fn
          [program | rest] ->
            response = %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => program}}]}
            {{:ok, response}, rest}

          [] ->
            {{:ok, %{content: "no scripted response"}}, []}
        end)
      else
        {:error, :mock_llm_stopped}
      end
    end

    {llm, fn -> stop_agent(agent) end}
  end

  defp llm_for(%{id: "eval_retry"}, :live, model, opts) do
    real_llm = live_llm(model, opts)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    llm = fn request ->
      turn = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      with {:ok, response} <- real_llm.(request) do
        if turn == 0 do
          {:ok, rewrite_first_program(response, ~S|(+ 1 2)|)}
        else
          {:ok, response}
        end
      end
    end

    {llm, fn -> stop_agent(counter) end}
  end

  defp llm_for(_eval_case, :live, model, opts), do: {live_llm(model, opts), fn -> :ok end}

  defp live_llm(model, opts) do
    LLM.callback(model,
      receive_timeout: Keyword.get(opts, :receive_timeout, 60_000),
      req_http_options: Keyword.get(opts, :req_http_options, retry: :transient, max_retries: 3),
      max_tokens: Keyword.get(opts, :max_tokens, 512),
      temperature: Keyword.get(opts, :temperature, 0.0)
    )
  end

  defp rewrite_first_program(
         %{tool_calls: [%{args: %{"program" => _program}} = call | rest]} = response,
         program
       ) do
    %{response | tool_calls: [%{call | args: %{"program" => program}} | rest]}
  end

  defp rewrite_first_program(response, _program), do: response

  defp build_case_result(eval_case, run_index, result, events, started) do
    {status, value, failure_reason} =
      case result do
        {:ok, %{"value" => value}} -> {:pass, value, nil}
        {:ok, other} -> {:pass, other, nil}
        {:error, %{"reason" => reason}} -> {:fail, nil, reason}
        {:error, other} -> {:fail, nil, inspect(other, limit: 5)}
      end

    %{
      run: run_index,
      case: eval_case.id,
      status: status,
      value: value,
      failure_reason: failure_reason,
      action_count: Enum.count(events, &(&1.event == "action")),
      eval_count: Enum.count(events, &(&1.event == "eval")),
      duration_ms: duration_ms(started),
      trace: events
    }
  end

  defp sanitize_event(%{"event" => "action", "turn" => turn, "action" => action}) do
    %{
      event: "action",
      turn: turn,
      action_kind: Map.get(action, "kind") || Map.get(action, :kind),
      model: Map.get(action, "model") || Map.get(action, :model)
    }
  end

  defp sanitize_event(%{"event" => "eval", "turn" => turn, "result" => result}) do
    %{
      event: "eval",
      turn: turn,
      eval_status: Map.get(result, "status")
    }
  end

  defp sanitize_event(%{"event" => event, "turn" => turn}) do
    %{event: event, turn: turn}
  end

  defp duration_ms(started) do
    System.monotonic_time()
    |> Kernel.-(started)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp stop_agent(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
  end
end
