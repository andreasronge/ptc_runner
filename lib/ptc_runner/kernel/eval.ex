defmodule PtcRunner.Kernel.Eval do
  @moduledoc false

  alias PtcRunner.Kernel, as: KernelRunner
  alias PtcRunner.LLM
  alias PtcRunner.LLM.Registry
  alias PtcRunner.LLM.ReqLLMAdapter
  alias PtcRunner.PreludeOrigin
  alias PtcRunner.TraceLog
  alias PtcRunner.TraceLog.Analyzer

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
    variant = Keyword.get(opts, :variant, "kernel")

    with :ok <- validate_suite(suite),
         :ok <- validate_variant(variant),
         :ok <- validate_report_contract(suite, mode, Keyword.get(opts, :report)),
         {:ok, cases} <- select_cases(suite, Keyword.get(opts, :case)),
         {:ok, report} <-
           run_cases(
             cases,
             opts
             |> Keyword.put(:suite, suite)
             |> Keyword.put(:variant, variant)
           ),
         :ok <- maybe_write_report(report, Keyword.get(opts, :report)) do
      {:ok, report}
    end
  end

  @doc false
  @spec run_cases([map()], keyword()) :: {:ok, result()} | {:error, term()}
  def run_cases(cases, opts \\ []) when is_list(cases) do
    suite = Keyword.get(opts, :suite, "custom")
    mode = Keyword.get(opts, :mode, :mock)
    runs = Keyword.get(opts, :runs, 1)
    variant = Keyword.get(opts, :variant, "kernel")
    requested_model = requested_model(mode, Keyword.get(opts, :model))

    with :ok <- validate_runs(runs),
         :ok <- validate_variant(variant),
         {:ok, model} <- resolve_model(mode, Keyword.get(opts, :model)) do
      results =
        for run_index <- 1..runs,
            eval_case <- cases do
          run_case(eval_case, run_index, mode, model, opts)
        end

      {:ok,
       %{
         suite: suite,
         mode: mode,
         variant: variant,
         requested_model: requested_model,
         model: model,
         provider: provider(model),
         commit: commit(),
         command_options: command_options(opts, suite, mode, variant, requested_model),
         runs: runs,
         cases: results
       }}
    end
  end

  @spec render_markdown(result()) :: String.t()
  def render_markdown(%{
        suite: suite,
        mode: mode,
        variant: variant,
        requested_model: requested_model,
        model: model,
        provider: provider,
        commit: commit,
        runs: runs,
        cases: cases
      }) do
    rows =
      Enum.map(cases, fn case_result ->
        "| #{case_result.run} | #{case_result.case} | #{case_result.status} | #{case_result.action_count} | #{case_result.eval_count} | #{case_result.expected_turns} | #{case_result.actual_turns} | #{case_result.dropped_turns} | #{case_result.unexpected_turns} | #{case_result.write_errors} | #{case_result.failure_reason || ""} |"
      end)

    """
    # PTC Kernel Eval

    suite: #{suite}
    mode: #{mode}
    variant: #{variant}
    requested_model: #{requested_model || "mock"}
    resolved_model: #{model || "mock"}
    provider: #{provider || "mock"}
    commit: #{commit}
    runs: #{runs}

    | run | case | status | actions | evals | expected turns | actual turns | dropped | unexpected | write errors | failure |
    | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
    #{Enum.join(rows, "\n")}
    """
    |> String.trim()
  end

  @spec passed?(result()) :: boolean()
  def passed?(%{cases: cases}) when is_list(cases) do
    Enum.all?(cases, &(&1.status == :pass))
  end

  @spec failure_count(result()) :: non_neg_integer()
  def failure_count(%{cases: cases}) when is_list(cases) do
    Enum.count(cases, &(&1.status != :pass))
  end

  @spec mini_cases() :: [map()]
  def mini_cases do
    [
      %{
        id: "arithmetic",
        task: "Return the integer result of 40 + 2.",
        context: %{},
        expected: 42,
        max_turns: 3,
        mock_programs: [~S|(return (+ 40 2))|]
      },
      %{
        id: "context_filter_count",
        task: ~S|Return the count of items where kind is "keep".|,
        context: %{
          "items" => [
            %{"kind" => "keep"},
            %{"kind" => "skip"},
            %{"kind" => "keep"}
          ]
        },
        expected: 2,
        max_turns: 5,
        mock_programs: [~S|(return (count (filter #(= (% "kind") "keep") data/items)))|]
      },
      %{
        id: "context_aggregation",
        task: "Return the sum of all numbers.",
        context: %{"numbers" => [2, 4, 6]},
        expected: 12,
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
        expected: 9,
        max_turns: 5,
        mock_programs: [~S|(return ((tool/lookup {"id" "alpha"}) "score"))|]
      },
      %{
        id: "eval_retry",
        task: "Return the integer 3. If a previous program did not return, retry with return.",
        context: %{},
        expected: 3,
        max_turns: 5,
        mock_programs: [~S|(+ 1 2)|, ~S|(return 3)|]
      },
      %{
        id: "memory_persistence",
        task:
          "Define an intermediate value in one program, then use that defined name in the next program.",
        context: %{},
        expected: 41,
        max_turns: 5,
        mock_programs: [~S|(def x 41)|, ~S|(return x)|]
      }
    ]
  end

  @spec smoke_cases() :: [map()]
  def smoke_cases do
    records =
      for id <- 1..500 do
        %{"id" => id, "included" => rem(id, 2) == 0}
      end

    [
      %{
        id: "record_count_500",
        task: "Return the count of records whose included field is true.",
        context: %{"records" => records},
        expected: 250,
        max_turns: 5,
        mock_programs: [~S|(return (count (filter #(= (% "included") true) data/records)))|]
      }
    ]
  end

  defp validate_suite("mini"), do: :ok
  defp validate_suite("smoke"), do: :ok
  defp validate_suite(other), do: {:error, {:unknown_suite, other}}

  defp validate_variant("kernel"), do: :ok
  defp validate_variant(other), do: {:error, {:unsupported_variant, other}}

  defp validate_report_contract(suite, mode, report) do
    if (suite == "smoke" or mode == :live) and not (is_binary(report) and report != "") do
      {:error, {:report_required, suite}}
    else
      :ok
    end
  end

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
    if ReqLLMAdapter.requires_api_key?(model) do
      ensure_provider_key(model)
    else
      :ok
    end
  end

  defp ensure_provider_key(model) do
    provider = Registry.provider_from_model(model)

    cond do
      provider in [:amazon_bedrock, :bedrock] ->
        ensure_bedrock_credentials(model)

      is_atom(provider) ->
        case ReqLLM.Keys.get(provider, []) do
          {:ok, _key, _source} ->
            :ok

          {:error, _reason} ->
            {:error, {:missing_api_key, ReqLLM.Keys.env_var_name(provider), model}}
        end

      true ->
        :ok
    end
  end

  defp ensure_bedrock_credentials(model) do
    cond do
      present_env?("AWS_BEARER_TOKEN_BEDROCK") ->
        :ok

      present_env?("AWS_ACCESS_KEY_ID") and present_env?("AWS_SECRET_ACCESS_KEY") ->
        :ok

      true ->
        {:error,
         {:missing_api_key,
          "AWS_BEARER_TOKEN_BEDROCK or AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY", model}}
    end
  end

  defp present_env?(key), do: System.get_env(key) not in [nil, ""]

  defp select_cases("mini", nil), do: {:ok, mini_cases()}
  defp select_cases("smoke", nil), do: {:ok, smoke_cases()}

  defp select_cases(suite, case_id) do
    cases = if suite == "smoke", do: smoke_cases(), else: mini_cases()

    case Enum.filter(cases, &(&1.id == case_id)) do
      [] -> {:error, {:unknown_case, case_id}}
      cases -> {:ok, cases}
    end
  end

  defp run_case(eval_case, run_index, mode, model, opts) do
    started = System.monotonic_time()
    {:ok, events} = Agent.start_link(fn -> [] end)
    {:ok, prompt_hashes} = Agent.start_link(fn -> [] end)
    {llm, cleanup_llm} = llm_for(eval_case, mode, model, opts)

    hashed_llm = fn request ->
      Agent.update(prompt_hashes, &[hash_term(request) | &1])
      llm.(request)
    end

    try do
      kernel_opts =
        [
          llm: hashed_llm,
          tools: Map.get(eval_case, :tools, %{}),
          max_turns: eval_case.max_turns,
          prelude_source_overrides: Keyword.get(opts, :prelude_source_overrides, %{}),
          unsafe_debug: Keyword.get(opts, :unsafe_debug, false)
        ]
        |> Keyword.merge(
          Keyword.take(opts, [
            :role_policy,
            :role,
            :prelude_store,
            :preludes,
            :inner_preludes
          ])
        )
        |> Keyword.put(:events, &record_event(events, Keyword.get(opts, :unsafe_debug_agent), &1))

      trace_path = trace_path(eval_case, run_index, opts)

      {:ok, result, trace_metadata} =
        TraceLog.with_trace(fn -> KernelRunner.run(mission(eval_case), kernel_opts) end,
          path: trace_path,
          trace_kind: "kernel_eval",
          producer: "ptc.kernel_eval",
          trace_label: "#{eval_case.id}-#{run_index}",
          model: model,
          return_metadata: true
        )

      sanitized_events = Agent.get(events, &Enum.reverse/1)
      recorded_prompt_hashes = Agent.get(prompt_hashes, &Enum.reverse/1)

      unsafe_trace = unsafe_trace(Keyword.get(opts, :unsafe_debug_agent))

      build_case_result(
        eval_case,
        run_index,
        result,
        sanitized_events,
        unsafe_trace,
        trace_metadata,
        recorded_prompt_hashes,
        started
      )
    after
      cleanup_llm.()
      stop_agent(events)
      stop_agent(prompt_hashes)
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
    live_llm_with_rewritten_first_program(model, opts, ~S|(+ 1 2)|)
  end

  defp llm_for(%{id: "memory_persistence"}, :live, model, opts) do
    live_llm_with_rewritten_first_program(model, opts, ~S|(def x 41)|)
  end

  defp llm_for(_eval_case, :live, model, opts), do: {live_llm(model, opts), fn -> :ok end}

  defp live_llm_with_rewritten_first_program(model, opts, program) do
    real_llm = live_llm(model, opts)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    llm = fn request ->
      turn = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      with {:ok, response} <- real_llm.(request) do
        if turn == 0 do
          {:ok, rewrite_first_program(response, program)}
        else
          {:ok, response}
        end
      end
    end

    {llm, fn -> stop_agent(counter) end}
  end

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

  defp record_event(events, unsafe_debug_agent, event) do
    Agent.update(events, fn current -> [sanitize_event(event) | current] end)

    if is_pid(unsafe_debug_agent) and Process.alive?(unsafe_debug_agent) do
      Agent.update(unsafe_debug_agent, fn current -> [unsafe_event(event) | current] end)
    end
  end

  defp unsafe_trace(nil), do: nil

  defp unsafe_trace(agent) when is_pid(agent) do
    if Process.alive?(agent), do: Agent.get(agent, &Enum.reverse/1)
  end

  defp build_case_result(
         eval_case,
         run_index,
         result,
         events,
         unsafe_trace,
         trace_metadata,
         prompt_hashes,
         started
       ) do
    {status, value, failure_reason} =
      case result do
        {:ok, %{"value" => value}} -> verify_expected(eval_case, value)
        {:ok, other} -> verify_expected(eval_case, other)
        {:error, %{"reason" => reason}} -> {:fail, nil, reason}
        {:error, _other} -> {:fail, nil, "kernel_error"}
      end

    sanitize_persistent_trace!(trace_metadata.path)
    persisted_events = Analyzer.load(trace_metadata.path)

    kernel_turns =
      persisted_events
      |> Analyzer.turn_events()
      |> Enum.filter(&(&1["driver"] == "kernel"))

    expected_turns = expected_turns(events)
    actual_turns = length(kernel_turns)
    evidence = turn_evidence(kernel_turns)

    Map.merge(evidence, %{
      run: run_index,
      case: eval_case.id,
      status: status,
      value: value,
      failure_reason: failure_reason,
      action_count: Enum.count(events, &(&1.event == "action")),
      eval_count: Enum.count(events, &(&1.event == "eval")),
      duration_ms: duration_ms(started),
      trace: events,
      unsafe_trace: unsafe_trace,
      trace_path: trace_metadata.path,
      write_errors: trace_metadata.write_errors,
      prompt_hashes: prompt_hashes,
      action_hashes:
        Enum.map(kernel_turns, &get_in(&1, ["data", "program_hash"])) |> Enum.reject(&is_nil/1),
      expected_turns: expected_turns,
      actual_turns: actual_turns,
      dropped_turns: max(expected_turns - actual_turns, 0),
      unexpected_turns: max(actual_turns - expected_turns, 0)
    })
  end

  defp verify_expected(eval_case, value) do
    case Map.fetch(eval_case, :expected) do
      {:ok, ^value} ->
        {:pass, value, nil}

      {:ok, _expected} ->
        {:fail, value, "expected_mismatch"}

      :error ->
        {:fail, value, "missing_expected"}
    end
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

  defp sanitize_event(%{"event" => "memory"} = event) do
    %{
      event: "memory",
      memory_bytes: Map.get(event, "memory_bytes"),
      defined_count: Map.get(event, "defined_count"),
      changed_count: Map.get(event, "changed_count")
    }
  end

  defp sanitize_event(%{"event" => "prelude", "prelude" => prelude} = event)
       when is_map(prelude) do
    %{
      event: "prelude",
      slot: Map.get(event, "slot"),
      prelude: %{
        source_hash: Map.get(prelude, :source_hash),
        artifact_hash: Map.get(prelude, :artifact_hash),
        protected_namespaces: Map.get(prelude, :protected_namespaces, []),
        components:
          prelude
          |> Map.get(:components, [])
          |> Enum.map(&sanitize_prelude_component/1)
      }
    }
  end

  defp sanitize_event(%{"event" => event, "turn" => turn}) do
    %{event: event, turn: turn}
  end

  defp unsafe_event(%{"event" => "unsafe_llm_request"} = event) do
    %{
      event: "unsafe_llm_request",
      turn: Map.get(event, "turn"),
      system: Map.get(event, "system"),
      messages: Map.get(event, "messages")
    }
  end

  defp unsafe_event(%{"event" => "action", "turn" => turn, "action" => action}) do
    %{
      event: "action",
      turn: turn,
      kind: Map.get(action, "kind") || Map.get(action, :kind),
      program: Map.get(action, "program") || Map.get(action, :program),
      reason: Map.get(action, "reason") || Map.get(action, :reason),
      content: Map.get(action, "content") || Map.get(action, :content),
      model: Map.get(action, "model") || Map.get(action, :model),
      provider: Map.get(action, "provider") || Map.get(action, :provider)
    }
  end

  defp unsafe_event(%{"event" => "eval", "turn" => turn, "result" => result}) do
    %{
      event: "eval",
      turn: turn,
      result: result
    }
  end

  defp unsafe_event(%{"event" => "memory"} = event), do: event
  defp unsafe_event(%{"event" => "prelude"} = event), do: sanitize_event(event)
  defp unsafe_event(%{"event" => event, "turn" => turn}), do: %{event: event, turn: turn}
  defp unsafe_event(event), do: %{event: "unknown", value: inspect(event, limit: 20)}

  defp sanitize_prelude_component(component) when is_map(component) do
    %{
      id: Map.get(component, :id),
      checksum: Map.get(component, :checksum),
      source_hash: Map.get(component, :source_hash),
      namespaces: Map.get(component, :namespaces, []),
      origin: PreludeOrigin.sanitize(Map.get(component, :origin))
    }
  end

  defp expected_turns(events) do
    completed_evals = Enum.count(events, &(&1.event == "eval"))

    terminal_actions =
      Enum.count(events, fn event ->
        event.event == "action" and
          event.action_kind in ["protocol_error", "transport_error", "budget_exhausted"]
      end)

    completed_evals + terminal_actions
  end

  defp turn_evidence([]) do
    %{
      preludes: [],
      inner_preludes: [],
      inner_prelude_projection: nil,
      inner_prelude_call_counts: %{}
    }
  end

  defp turn_evidence(turns) do
    first = hd(turns)

    %{
      preludes: get_in(first, ["data", "preludes"]) || [],
      inner_preludes: get_in(first, ["data", "inner_preludes"]) || [],
      inner_prelude_projection: get_in(first, ["data", "inner_prelude_projection"]),
      inner_prelude_call_counts: aggregate_inner_call_counts(turns)
    }
  end

  defp aggregate_inner_call_counts(turns) do
    Enum.reduce(turns, %{}, fn turn, acc ->
      counts = get_in(turn, ["data", "inner_prelude_call_counts"]) || %{}
      Map.merge(acc, counts, fn _ref, left, right -> left + right end)
    end)
  end

  defp sanitize_persistent_trace!(path) do
    sanitized =
      path
      |> Analyzer.load()
      |> Enum.map(&sanitize_persisted_event/1)
      |> Enum.map_join(&(Jason.encode!(&1) <> "\n"))

    File.write!(path, sanitized)
  end

  defp sanitize_persisted_event(%{"event" => "turn", "data" => data} = event)
       when is_map(data) do
    program = Map.get(data, "program")
    result_preview = Map.get(data, "result_preview")
    prints = Map.get(data, "prints", [])
    memory_diff = Map.get(data, "memory_diff")

    sanitized_data =
      data
      |> Map.drop(["program", "raw_response", "result_preview", "prints", "memory_diff"])
      |> maybe_put_hash("program_hash", program)
      |> maybe_put_hash("result_hash", result_preview)
      |> Map.put("prints_count", if(is_list(prints), do: length(prints), else: 0))
      |> maybe_put_memory_count(memory_diff)
      |> Map.update("fail", nil, &sanitize_persisted_fail/1)

    Map.put(event, "data", sanitized_data)
  end

  defp sanitize_persisted_event(event), do: event

  defp maybe_put_hash(map, _key, nil), do: map
  defp maybe_put_hash(map, key, value), do: Map.put(map, key, hash_term(value))

  defp maybe_put_memory_count(map, memory_diff) when is_map(memory_diff) do
    changed = Map.get(memory_diff, "changed_keys", [])
    Map.put(map, "memory_changed_count", if(is_list(changed), do: length(changed), else: 0))
  end

  defp maybe_put_memory_count(map, _memory_diff), do: Map.put(map, "memory_changed_count", 0)

  defp sanitize_persisted_fail(nil), do: nil

  defp sanitize_persisted_fail(fail) when is_map(fail) do
    %{"reason" => Map.get(fail, "reason", Map.get(fail, :reason, "kernel_failure"))}
  end

  defp sanitize_persisted_fail(_fail), do: %{"reason" => "kernel_failure"}

  defp hash_term(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
  end

  defp trace_path(eval_case, run_index, opts) do
    trace_dir =
      Keyword.get(opts, :trace_dir) ||
        Path.join(Mix.Project.build_path(), "kernel_eval_traces")

    File.mkdir_p!(trace_dir)
    Path.join(trace_dir, "#{eval_case.id}-run-#{run_index}.jsonl")
  end

  defp maybe_write_report(_report, nil), do: :ok

  defp maybe_write_report(report, path) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, render_markdown(report) <> "\n")

    File.write!(
      Path.rootname(path) <> ".json",
      Jason.encode!(public_report(report), pretty: true) <> "\n"
    )

    :ok
  end

  defp public_report(report) do
    Map.update!(report, :cases, fn cases ->
      Enum.map(cases, &Map.drop(&1, [:trace, :unsafe_trace, :value]))
    end)
  end

  defp requested_model(:mock, _model), do: nil

  defp requested_model(:live, model),
    do: model || System.get_env("PTC_TEST_MODEL") || @default_live_model

  defp requested_model(_mode, model), do: model

  defp provider(nil), do: nil
  defp provider(model), do: model |> Registry.provider_from_model() |> to_string()

  defp commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {hash, 0} -> String.trim(hash)
      _ -> "unknown"
    end
  end

  defp command_options(opts, suite, mode, variant, requested_model) do
    %{
      suite: suite,
      mode: Atom.to_string(mode),
      variant: variant,
      requested_model: requested_model,
      runs: Keyword.get(opts, :runs, 1),
      case: Keyword.get(opts, :case),
      trace_dir: Keyword.get(opts, :trace_dir)
    }
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
