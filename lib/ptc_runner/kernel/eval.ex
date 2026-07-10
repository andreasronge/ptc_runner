defmodule PtcRunner.Kernel.Eval do
  @moduledoc false

  alias PtcRunner.Kernel, as: KernelRunner
  alias PtcRunner.Kernel.Action
  alias PtcRunner.Kernel.Eval.Dataset
  alias PtcRunner.Kernel.Eval.Oracle
  alias PtcRunner.Kernel.Eval.RunContext
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.LLM
  alias PtcRunner.LLM.Registry
  alias PtcRunner.LLM.ReqLLMAdapter
  alias PtcRunner.PreludeOrigin
  alias PtcRunner.SubAgent
  alias PtcRunner.TraceLog
  alias PtcRunner.TraceLog.Analyzer

  @default_live_model "deepseek"
  @incumbent_agent_name "kernel_eval_incumbent"
  @engineering_ids_program ~S|(def engineering-ids (set (map #(% "id") (filter #(= (% "department") "engineering") data/employees))))|
  @m2_dataset_seed 17
  @m2_dataset_hash "503d8233cce08aa825a00e14d49c6e13d2a9db931fa219a8cc3500866e8a0953"
  @m2_case_definition_hash "4b448ecc370db8260cc8b4537bd7ed61ae9c8c0c0bbec80203d754d362df4431"
  @m2_case_ids ~w(products_count delivered_orders total_revenue remote_employees engineering_expenses)
  @m1_smoke_case_definition_hash "c8f4d994cb474d1cc57bc6a2b0696e3d94f3d245ae825b53264d7584e710a299"

  @type result :: %{
          suite: String.t(),
          mode: :mock | :live,
          variant: String.t(),
          requested_model: String.t() | nil,
          model: String.t() | nil,
          provider: String.t() | nil,
          llm_source: String.t(),
          provenance_eligible: boolean(),
          evidence_eligible: boolean(),
          preregistered_config: boolean(),
          commit: String.t(),
          dataset_seed: integer(),
          dataset_hash: String.t() | nil,
          case_definition_hash: String.t(),
          aborted: boolean(),
          abort_reason: String.t() | nil,
          pass_count: non_neg_integer(),
          case_count: non_neg_integer(),
          pass_rate: float(),
          command_options: map(),
          runs: pos_integer(),
          cases: [map()]
        }

  @spec resolve_model(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def resolve_model(model \\ nil) do
    requested = model || System.get_env("PTC_TEST_MODEL") || @default_live_model
    Registry.resolve(requested)
  end

  @doc false
  @spec resolve_model_identity(String.t() | nil) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def resolve_model_identity(model) do
    PtcRunner.Dotenv.load()
    requested = model || System.get_env("PTC_TEST_MODEL") || @default_live_model

    case Registry.resolve(requested) do
      {:ok, resolved} -> {:ok, requested, resolved}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    suite = Keyword.get(opts, :suite, "mini")
    variant = Keyword.get(opts, :variant, "kernel")
    seed = Keyword.get(opts, :seed, 0)

    with :ok <- validate_suite(suite),
         :ok <- validate_seed(seed),
         :ok <- validate_variant(variant),
         {:ok, cases} <- select_cases(suite, Keyword.get(opts, :case), seed) do
      run_cases(
        cases,
        opts
        |> Keyword.put(:suite, suite)
        |> Keyword.put(:variant, variant)
        |> Keyword.put(:seed, seed)
      )
    end
  end

  @doc false
  @spec run_pair(keyword()) :: {:ok, map()} | {:error, term()}
  def run_pair(opts) do
    suite = Keyword.get(opts, :suite, "tier2")
    mode = Keyword.get(opts, :mode, :mock)
    seed = Keyword.get(opts, :seed, @m2_dataset_seed)
    report_path = Keyword.get(opts, :report)

    with :ok <- validate_pair_contract(suite, report_path),
         :ok <- validate_seed(seed),
         {:ok, cases} <- select_cases(suite, Keyword.get(opts, :case), seed),
         :ok <- validate_case_dataset_seed(suite, cases, Keyword.put(opts, :seed, seed)),
         :ok <- validate_tier2_preregistered_hashes(suite, cases, seed),
         {:ok, requested_model, model} <- resolve_model(mode, Keyword.get(opts, :model), opts) do
      run_pair_cases(cases, mode, seed, requested_model, model, report_path, opts)
    end
  end

  @doc false
  @spec run_cases([map()], keyword()) :: {:ok, result()} | {:error, term()}
  def run_cases(cases, opts \\ []) when is_list(cases) do
    suite = Keyword.get(opts, :suite, "custom")
    mode = Keyword.get(opts, :mode, :mock)
    runs = Keyword.get(opts, :runs, 1)
    variant = Keyword.get(opts, :variant, "kernel")

    with :ok <- validate_report_contract(suite, mode, Keyword.get(opts, :report)),
         :ok <- validate_runs(runs),
         :ok <- validate_seed(Keyword.get(opts, :seed, 0)),
         :ok <- validate_case_dataset_seed(suite, cases, opts),
         :ok <-
           validate_tier2_preregistered_hashes(
             suite,
             cases,
             Keyword.get(opts, :seed, 0)
           ),
         :ok <- validate_variant(variant),
         {:ok, report, run_context} <- execute_cases(cases, suite, mode, runs, variant, opts),
         :ok <- publish_report(report, Keyword.get(opts, :report), run_context) do
      {:ok, report}
    end
  end

  defp execute_cases(cases, suite, mode, runs, variant, opts) do
    with {:ok, requested_model, model} <- resolve_model(mode, Keyword.get(opts, :model), opts) do
      seed = Keyword.get(opts, :seed, 0)
      llm_source = llm_source(mode, opts)
      run_context = maybe_start_run_context(suite, mode, llm_source, variant, model, opts)
      initial_snapshot = initial_snapshot(run_context)

      {results, abort_reason} =
        execute_case_runs(cases, runs, mode, model, variant, opts, run_context)

      abort_reason = lifecycle_abort_reason(run_context, abort_reason)
      case_definition_hash = case_definition_hash(cases)

      provenance_eligible =
        provenance_eligible?(
          mode,
          llm_source,
          results,
          abort_reason,
          initial_snapshot.commit,
          lifecycle_eligible?(run_context, initial_snapshot)
        )

      preregistered_config =
        preregistered_config?(%{
          suite: suite,
          mode: mode,
          variant: variant,
          runs: runs,
          seed: seed,
          requested_model: requested_model,
          temperature: Keyword.get(opts, :temperature, 0.0),
          max_tokens: Keyword.get(opts, :max_tokens, 512),
          receive_timeout: Keyword.get(opts, :receive_timeout, 60_000),
          req_http_options:
            Keyword.get(opts, :req_http_options, retry: :transient, max_retries: 3),
          report: Keyword.get(opts, :report),
          trace_dir: Keyword.get(opts, :trace_dir),
          prelude_source_overrides: Keyword.get(opts, :prelude_source_overrides, %{}),
          role_policy: Keyword.get(opts, :role_policy),
          role: Keyword.get(opts, :role),
          prelude_store: Keyword.get(opts, :prelude_store),
          preludes: Keyword.get(opts, :preludes),
          inner_preludes: Keyword.get(opts, :inner_preludes),
          kernel_memory_byte_cap: Keyword.get(opts, :kernel_memory_byte_cap),
          unsafe_debug: Keyword.get(opts, :unsafe_debug, false),
          unsafe_debug_agent: Keyword.get(opts, :unsafe_debug_agent),
          paired_run: Keyword.get(opts, :paired_run, false),
          case_ids: Enum.map(cases, & &1.id),
          case_definition_hash: case_definition_hash
        })

      report = %{
        suite: suite,
        mode: mode,
        variant: variant,
        requested_model: requested_model,
        model: model,
        provider: provider(model),
        llm_source: llm_source,
        provenance_eligible: provenance_eligible,
        evidence_eligible: provenance_eligible and preregistered_config,
        preregistered_config: preregistered_config,
        commit: initial_snapshot.commit,
        dataset_seed: seed,
        dataset_hash: dataset_hash(suite, seed),
        case_definition_hash: case_definition_hash,
        aborted: not is_nil(abort_reason),
        abort_reason: abort_reason,
        command_options: command_options(opts, suite, mode, variant, requested_model),
        runs: runs,
        cases: results
      }

      {:ok, summarize_report(report), run_context}
    end
  end

  defp run_pair_cases(cases, mode, seed, requested_model, model, report_path, opts) do
    source = llm_source(mode, opts)

    context =
      maybe_start_run_context(
        "tier2",
        mode,
        source,
        "paired",
        model,
        Keyword.put(opts, :report, report_path)
      )

    try do
      paths = pair_paths(report_path)
      ensure_pair_artifacts_absent!(paths, context)

      shared_opts =
        opts
        |> Keyword.put(:suite, "tier2")
        |> Keyword.put(:seed, seed)
        |> Keyword.put(:runs, 1)
        |> Keyword.put(:paired_run, true)
        |> Keyword.put(:shared_run_context, context)

      {:ok, incumbent, _context} =
        execute_cases(
          cases,
          "tier2",
          mode,
          1,
          "incumbent",
          shared_opts
          |> Keyword.put(:report, paths.incumbent_report)
          |> Keyword.put(:trace_dir, paths.incumbent_traces)
        )

      kernel_result =
        if incumbent.aborted do
          nil
        else
          {:ok, kernel, _context} =
            execute_cases(
              cases,
              "tier2",
              mode,
              1,
              "kernel",
              shared_opts
              |> Keyword.put(:report, paths.kernel_report)
              |> Keyword.put(:trace_dir, paths.kernel_traces)
            )

          kernel
        end

      reports = Enum.reject([incumbent, kernel_result], &is_nil/1)
      abort_reason = Enum.find_value(reports, & &1.abort_reason)
      complete = length(reports) == 2 and is_nil(abort_reason)
      matching = pair_reports_match?(reports)

      pair = %{
        suite: "tier2",
        mode: mode,
        variant: "paired",
        requested_model: requested_model,
        model: model,
        commit: initial_snapshot(context).commit,
        dataset_seed: seed,
        dataset_hash: dataset_hash("tier2", seed),
        case_definition_hash: case_definition_hash(cases),
        configuration_hash: pair_configuration_hash(reports),
        complete: complete,
        aborted: not complete,
        abort_reason: abort_reason || if(not matching, do: "pair_identity_mismatch"),
        evidence_eligible:
          complete and matching and Enum.all?(reports, & &1.evidence_eligible) and
            validate_lifecycle(context) == :ok,
        reports: Enum.map(reports, &public_report/1)
      }

      write_report_files(incumbent, paths.incumbent_report, true)
      if kernel_result, do: write_report_files(kernel_result, paths.kernel_report, true)
      publish_pair_report(pair, report_path, context)
      {:ok, pair}
    rescue
      exception ->
        abort_run_context(context, exception)
        reraise exception, __STACKTRACE__
    end
  end

  defp validate_pair_contract("tier2", report) when is_binary(report) and report != "" do
    validate_report_contract("tier2", :live, report)
  end

  defp validate_pair_contract("tier2", _report), do: {:error, {:report_required, "tier2"}}
  defp validate_pair_contract(suite, _report), do: {:error, {:invalid_pair_suite, suite}}

  defp execute_case_runs(cases, runs, mode, model, variant, opts, run_context) do
    for(run_index <- 1..runs, eval_case <- cases, do: {run_index, eval_case})
    |> Enum.reduce_while({[], nil}, fn {run_index, eval_case}, {results, nil} ->
      case validate_lifecycle(run_context) do
        :ok ->
          result = safe_run_case(eval_case, run_index, mode, model, variant, opts)
          results = [result | results]

          case validate_lifecycle(run_context) do
            {:error, reason} ->
              {:halt, {Enum.reverse(results), reason}}

            :ok when result.status == :infrastructure_error ->
              {:halt, {Enum.reverse(results), result.failure_reason}}

            :ok ->
              {:cont, {results, nil}}
          end

        {:error, reason} ->
          {:halt, {Enum.reverse(results), reason}}
      end
    end)
    |> case do
      {results, nil} -> {Enum.reverse(results), nil}
      aborted -> aborted
    end
  end

  defp safe_run_case(eval_case, run_index, mode, model, variant, opts) do
    run_case(eval_case, run_index, mode, model, variant, opts)
  rescue
    exception -> exception_case_result(eval_case, run_index, exception)
  catch
    kind, _reason -> exception_case_result(eval_case, run_index, kind)
  end

  defp exception_case_result(eval_case, run_index, exception) do
    class = exception_class(exception)

    %{
      run: run_index,
      case: Map.get(eval_case, :id, "unknown"),
      status: :infrastructure_error,
      value: nil,
      expected_result: Oracle.expected_projection(eval_case),
      actual_result: project_result(nil),
      failure_reason: "case_exception:#{class}",
      failure_hash: nil,
      action_count: 0,
      eval_count: 0,
      persistence_verified: false,
      duration_ms: 0,
      trace: [],
      unsafe_trace: nil,
      trace_path: nil,
      write_errors: 0,
      prompt_hashes: [],
      action_hashes: [],
      expected_turns: 0,
      actual_turns: 0,
      dropped_turns: 0,
      unexpected_turns: 0
    }
  end

  defp exception_class(%{__struct__: module}) do
    module |> inspect() |> String.trim_leading("Elixir.")
  end

  defp exception_class(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp exception_class(_exception), do: "Exception"

  @spec render_markdown(map()) :: String.t()
  def render_markdown(%{variant: "paired"} = pair), do: render_pair_markdown(pair)

  def render_markdown(%{
        suite: suite,
        mode: mode,
        variant: variant,
        requested_model: requested_model,
        model: model,
        provider: provider,
        llm_source: llm_source,
        provenance_eligible: provenance_eligible,
        evidence_eligible: evidence_eligible,
        preregistered_config: preregistered_config,
        commit: commit,
        dataset_seed: dataset_seed,
        dataset_hash: dataset_hash,
        case_definition_hash: case_definition_hash,
        aborted: aborted,
        abort_reason: abort_reason,
        pass_count: pass_count,
        case_count: case_count,
        pass_rate: pass_rate,
        runs: runs,
        cases: cases
      }) do
    rows =
      Enum.map(cases, fn case_result ->
        "| #{case_result.run} | #{case_result.case} | #{case_result.status} | #{render_result(case_result.expected_result)} | #{render_result(case_result.actual_result)} | #{case_result.action_count} | #{case_result.eval_count} | #{case_result.expected_turns} | #{case_result.actual_turns} | #{case_result.dropped_turns} | #{case_result.unexpected_turns} | #{case_result.write_errors} | #{case_result.failure_reason || ""} | #{case_result.failure_hash || ""} |"
      end)

    """
    # PTC Kernel Eval

    suite: #{suite}
    mode: #{mode}
    variant: #{variant}
    requested_model: #{requested_model || "mock"}
    resolved_model: #{model || "mock"}
    provider: #{provider || "mock"}
    llm_source: #{llm_source}
    provenance_eligible: #{provenance_eligible}
    evidence_eligible: #{evidence_eligible}
    preregistered_config: #{preregistered_config}
    commit: #{commit}
    dataset_seed: #{dataset_seed}
    dataset_hash: #{dataset_hash || "none"}
    case_definition_hash: #{case_definition_hash}
    aborted: #{aborted}
    abort_reason: #{abort_reason || "none"}
    runs: #{runs}
    pass_rate: #{pass_count}/#{case_count} (#{Float.round(pass_rate * 100, 2)}%)

    | run | case | status | expected result | actual result | actions | evals | expected turns | actual turns | dropped | unexpected | write errors | failure | failure hash |
    | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
    #{Enum.join(rows, "\n")}
    """
    |> String.trim()
  end

  defp render_pair_markdown(pair) do
    """
    # PTC Kernel Tier-2 Paired Eval

    model: #{pair.model || "mock"}
    commit: #{pair.commit}
    dataset_hash: #{pair.dataset_hash}
    case_definition_hash: #{pair.case_definition_hash}
    configuration_hash: #{pair.configuration_hash}
    complete: #{pair.complete}
    aborted: #{pair.aborted}
    abort_reason: #{pair.abort_reason || "none"}
    evidence_eligible: #{pair.evidence_eligible}
    """
    |> String.trim()
  end

  @spec passed?(result()) :: boolean()
  def passed?(%{cases: cases}) when is_list(cases) do
    Enum.all?(cases, &case_passed?/1)
  end

  @spec failure_count(result()) :: non_neg_integer()
  def failure_count(%{cases: cases}) when is_list(cases) do
    Enum.count(cases, &(not case_passed?(&1)))
  end

  @spec mini_cases() :: [map()]
  def mini_cases do
    lookup_fixture = %{"alpha" => %{"score" => 9}}

    [
      %{
        id: "arithmetic",
        task: "Return the integer result of 40 + 2.",
        context: %{},
        expect: :integer,
        constraint: {:eq, 42},
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
        expect: :integer,
        constraint: {:eq, 2},
        max_turns: 5,
        mock_programs: [~S|(return (count (filter #(= (% "kind") "keep") data/items)))|]
      },
      %{
        id: "context_aggregation",
        task: "Return the sum of all numbers.",
        context: %{"numbers" => [2, 4, 6]},
        expect: :integer,
        constraint: {:eq, 12},
        max_turns: 5,
        mock_programs: [~S|(return (reduce + data/numbers))|]
      },
      %{
        id: "domain_tool",
        task: ~S|Call the granted lookup tool for id "alpha" and return its score.|,
        context: %{},
        tools: %{
          "lookup" => fn %{"id" => id} -> Map.fetch!(lookup_fixture, id) end
        },
        tool_fixtures: %{"lookup" => lookup_fixture},
        expect: :integer,
        constraint: {:eq, 9},
        max_turns: 5,
        mock_programs: [~S|(return ((tool/lookup {"id" "alpha"}) "score"))|]
      },
      %{
        id: "eval_retry",
        task: "Return the integer 3. If a previous program did not return, retry with return.",
        context: %{},
        expect: :integer,
        constraint: {:eq, 3},
        max_turns: 5,
        mock_programs: [~S|(+ 1 2)|, ~S|(return 3)|]
      },
      %{
        id: "memory_persistence",
        task:
          "Define an intermediate value in one program, then use that defined name in the next program.",
        context: %{},
        expect: :integer,
        constraint: {:eq, 41},
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
        expect: :integer,
        constraint: {:eq, 250},
        max_turns: 5,
        mock_programs: [~S|(return (count (filter #(= (% "included") true) data/records)))|]
      }
    ]
  end

  @spec tier2_cases(integer()) :: [map()]
  def tier2_cases(seed \\ 0) do
    context = Dataset.build(seed)
    delivered_count = Enum.count(context["orders"], &(&1["status"] == "delivered"))
    total_revenue = context["orders"] |> Enum.map(& &1["total"]) |> Enum.sum()
    remote_count = Enum.count(context["employees"], & &1["remote"])

    engineering_ids =
      context["employees"]
      |> Enum.filter(&(&1["department"] == "engineering"))
      |> MapSet.new(& &1["id"])

    engineering_expenses =
      context["expenses"]
      |> Enum.filter(&MapSet.member?(engineering_ids, &1["employee_id"]))
      |> Enum.map(& &1["amount"])
      |> Enum.sum()

    [
      %{
        id: "products_count",
        dataset_seed: seed,
        task: "Return the number of products.",
        context_ref: "products",
        context: %{"products" => context["products"]},
        expect: :integer,
        constraint: {:eq, 500},
        max_turns: 5,
        tags: ["filter", "level_1"],
        mock_programs: [~S|(return (count data/products))|]
      },
      %{
        id: "delivered_orders",
        dataset_seed: seed,
        task: ~S|Return the number of orders whose status is "delivered".|,
        context_ref: "orders",
        context: %{"orders" => context["orders"]},
        expect: :integer,
        constraint: {:eq, delivered_count},
        max_turns: 5,
        tags: ["filter", "level_1"],
        mock_programs: [
          ~S|(return (count (filter #(= (% "status") "delivered") data/orders)))|
        ]
      },
      %{
        id: "total_revenue",
        dataset_seed: seed,
        task: "Return the sum of the total field across all orders.",
        context_ref: "orders",
        context: %{"orders" => context["orders"]},
        expect: :number,
        constraint: {:between, total_revenue - 0.01, total_revenue + 0.01},
        max_turns: 5,
        tags: ["aggregation", "level_1"],
        mock_programs: [~S|(return (reduce + (map #(% "total") data/orders)))|]
      },
      %{
        id: "remote_employees",
        dataset_seed: seed,
        task: "Return the number of employees whose remote field is true.",
        context_ref: "employees",
        context: %{"employees" => context["employees"]},
        expect: :integer,
        constraint: {:eq, remote_count},
        max_turns: 5,
        tags: ["filter", "level_2"],
        mock_programs: [~S|(return (count (filter #(% "remote") data/employees)))|]
      },
      %{
        id: "engineering_expenses",
        dataset_seed: seed,
        task:
          "Use two PTC-Lisp programs. In the first, define engineering-ids from the " <>
            "engineering employees without returning. In the next program, return the total " <>
            "expense amount for matching employee IDs.",
        context_ref: "employees+expenses",
        context: Map.take(context, ["employees", "expenses"]),
        expect: :number,
        constraint: {:between, engineering_expenses - 0.01, engineering_expenses + 0.01},
        max_turns: 5,
        min_evals: 2,
        required_persistence: "engineering-ids",
        required_persistence_value: engineering_ids,
        tags: ["cross_dataset", "multi_turn", "level_3"],
        mock_programs: [
          @engineering_ids_program,
          ~S|(return (reduce + (map #(% "amount") (filter #(contains? engineering-ids (% "employee_id")) data/expenses))))|
        ]
      }
    ]
  end

  defp validate_suite("mini"), do: :ok
  defp validate_suite("smoke"), do: :ok
  defp validate_suite("tier2"), do: :ok
  defp validate_suite(other), do: {:error, {:unknown_suite, other}}

  defp validate_variant(variant) when variant in ["kernel", "incumbent"], do: :ok
  defp validate_variant(other), do: {:error, {:unsupported_variant, other}}

  defp validate_report_contract(suite, mode, report) do
    cond do
      (suite in ["smoke", "tier2"] or mode == :live) and
          not (is_binary(report) and report != "") ->
        {:error, {:report_required, suite}}

      is_binary(report) and String.downcase(Path.extname(report)) == ".json" ->
        {:error, {:invalid_report_path, report}}

      true ->
        :ok
    end
  end

  defp validate_runs(runs) when is_integer(runs) and runs > 0, do: :ok
  defp validate_runs(other), do: {:error, {:invalid_runs, other}}

  defp validate_seed(seed) when is_integer(seed), do: :ok
  defp validate_seed(other), do: {:error, {:invalid_seed, other}}

  defp validate_case_dataset_seed("tier2", cases, opts) do
    case Keyword.fetch(opts, :seed) do
      {:ok, seed} ->
        seeds = cases |> Enum.map(&Map.get(&1, :dataset_seed)) |> Enum.uniq()

        if seeds == [seed] do
          validate_tier2_case_contexts(cases, seed)
        else
          {:error, {:tier2_seed_mismatch, seed, seeds}}
        end

      :error ->
        {:error, :tier2_seed_required}
    end
  end

  defp validate_case_dataset_seed(_suite, _cases, _opts), do: :ok

  defp validate_tier2_preregistered_hashes("tier2", cases, @m2_dataset_seed) do
    case_ids = cases |> Enum.map(&Map.get(&1, :id)) |> Enum.sort()

    if case_ids == Enum.sort(@m2_case_ids) do
      actual_dataset_hash = dataset_hash("tier2", @m2_dataset_seed)
      actual_case_hash = case_definition_hash(cases)

      if actual_dataset_hash == @m2_dataset_hash and
           actual_case_hash == @m2_case_definition_hash do
        :ok
      else
        {:error,
         {:tier2_preregistration_hash_mismatch,
          %{
            dataset_hash: actual_dataset_hash,
            case_definition_hash: actual_case_hash,
            expected_dataset_hash: @m2_dataset_hash,
            expected_case_definition_hash: @m2_case_definition_hash
          }}}
      end
    else
      :ok
    end
  end

  defp validate_tier2_preregistered_hashes(_suite, _cases, _seed), do: :ok

  defp validate_tier2_case_contexts(cases, seed) do
    canonical = Map.new(tier2_cases(seed), &{&1.id, &1.context})

    mismatches =
      cases
      |> Enum.reject(fn eval_case ->
        Map.get(canonical, Map.get(eval_case, :id)) == Map.get(eval_case, :context)
      end)
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.uniq()
      |> Enum.sort()

    if mismatches == [], do: :ok, else: {:error, {:tier2_dataset_mismatch, mismatches}}
  end

  defp resolve_model(:mock, _model, _opts), do: {:ok, nil, nil}

  defp resolve_model(:live, model, opts) do
    with {:ok, requested, resolved} <- resolve_model_identity(model),
         :ok <- maybe_ensure_key(resolved, opts) do
      {:ok, requested, resolved}
    end
  end

  defp resolve_model(other, _model, _opts), do: {:error, {:unknown_mode, other}}

  defp maybe_ensure_key(model, opts) do
    if is_function(Keyword.get(opts, :live_llm), 1), do: :ok, else: ensure_key(model)
  end

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

  defp select_cases("mini", nil, _seed), do: {:ok, mini_cases()}
  defp select_cases("smoke", nil, _seed), do: {:ok, smoke_cases()}
  defp select_cases("tier2", nil, seed), do: {:ok, tier2_cases(seed)}

  defp select_cases(suite, case_id, seed) do
    cases =
      case suite do
        "smoke" -> smoke_cases()
        "tier2" -> tier2_cases(seed)
        "mini" -> mini_cases()
      end

    case Enum.filter(cases, &(&1.id == case_id)) do
      [] -> {:error, {:unknown_case, case_id}}
      cases -> {:ok, cases}
    end
  end

  defp run_case(eval_case, run_index, mode, model, "kernel", opts) do
    run_kernel_case(eval_case, run_index, mode, model, opts)
  end

  defp run_case(eval_case, run_index, mode, model, "incumbent", opts) do
    run_incumbent_case(eval_case, run_index, mode, model, opts)
  end

  defp run_kernel_case(eval_case, run_index, mode, model, opts) do
    started = System.monotonic_time()
    kernel_run_id = "kernel-eval-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, events} = Agent.start_link(fn -> [] end)
    {:ok, prompt_hashes} = Agent.start_link(fn -> [] end)

    try do
      {llm, cleanup_llm} = llm_for(eval_case, mode, model, opts)

      try do
        hashed_llm = fn request ->
          Agent.update(prompt_hashes, &[hash_term(request) | &1])
          llm.(request)
        end

        kernel_opts =
          [
            llm: hashed_llm,
            tools: Map.get(eval_case, :tools, %{}),
            max_turns: eval_case.max_turns,
            kernel_run_id: kernel_run_id,
            prelude_source_overrides: Keyword.get(opts, :prelude_source_overrides, %{}),
            unsafe_debug: Keyword.get(opts, :unsafe_debug, false)
          ]
          |> Keyword.merge(
            Keyword.take(opts, [
              :role_policy,
              :role,
              :prelude_store,
              :preludes,
              :inner_preludes,
              :kernel_memory_byte_cap
            ])
          )
          |> Keyword.put(
            :events,
            &record_event(events, Keyword.get(opts, :unsafe_debug_agent), &1)
          )

        trace_path = trace_path(eval_case, run_index, opts)
        raw_trace_dir = raw_trace_directory()
        raw_trace_path = Path.join(raw_trace_dir, "trace.jsonl")
        sanitized_trace_path = temporary_trace_path(trace_path, "sanitized")

        try do
          {:ok, result, %{write_errors: _} = trace_metadata} =
            TraceLog.with_trace(fn -> KernelRunner.run(mission(eval_case), kernel_opts) end,
              path: raw_trace_path,
              trace_kind: "kernel_eval",
              producer: "ptc.kernel_eval",
              trace_label: "#{eval_case.id}-#{run_index}",
              model: model,
              return_metadata: true
            )

          requirement_turns = raw_turns(raw_trace_path, "kernel", "agent_id", kernel_run_id)
          sanitize_persistent_trace!(raw_trace_path, sanitized_trace_path)
          :ok = File.rename(sanitized_trace_path, trace_path)

          trace_metadata =
            trace_metadata
            |> Map.put(:path, trace_path)
            |> Map.put(:kernel_run_id, kernel_run_id)
            |> Map.put(:requirement_turns, requirement_turns)

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
          File.rm(raw_trace_path)
          File.rm(sanitized_trace_path)
          File.rmdir(raw_trace_dir)
        end
      after
        cleanup_llm.()
      end
    after
      stop_agent(events)
      stop_agent(prompt_hashes)
    end
  end

  defp run_incumbent_case(eval_case, run_index, mode, model, opts) do
    started = System.monotonic_time()

    incumbent_name =
      "#{@incumbent_agent_name}-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, prompt_hashes} = Agent.start_link(fn -> [] end)

    try do
      {llm, cleanup_llm} = incumbent_llm_for(eval_case, mode, model, opts)

      try do
        hashed_llm = fn request ->
          Agent.update(prompt_hashes, &[hash_term(request) | &1])
          llm.(request)
        end

        trace_path = trace_path(eval_case, run_index, Keyword.put(opts, :variant, "incumbent"))
        raw_trace_dir = raw_trace_directory()
        raw_trace_path = Path.join(raw_trace_dir, "trace.jsonl")
        sanitized_trace_path = temporary_trace_path(trace_path, "sanitized")

        try do
          {:ok, result, %{write_errors: _} = trace_metadata} =
            TraceLog.with_trace(
              fn ->
                SubAgent.run(eval_case.task,
                  name: incumbent_name,
                  llm: hashed_llm,
                  context: eval_case.context,
                  tools: Map.get(eval_case, :tools, %{}),
                  max_turns: eval_case.max_turns,
                  completion_mode: :explicit
                )
              end,
              path: raw_trace_path,
              trace_kind: "kernel_eval",
              producer: "ptc.kernel_eval.incumbent",
              trace_label: "#{eval_case.id}-#{run_index}",
              model: model,
              return_metadata: true
            )

          incumbent_agent_id = agent_id_for_name(raw_trace_path, incumbent_name)

          requirement_turns =
            raw_turns(raw_trace_path, "sub_agent", "agent_id", incumbent_agent_id)

          sanitize_persistent_trace!(raw_trace_path, sanitized_trace_path)
          :ok = File.rename(sanitized_trace_path, trace_path)

          trace_metadata =
            trace_metadata
            |> Map.put(:path, trace_path)
            |> Map.put(:incumbent_agent_id, incumbent_agent_id)
            |> Map.put(:requirement_turns, requirement_turns)

          recorded_prompt_hashes = Agent.get(prompt_hashes, &Enum.reverse/1)

          build_incumbent_case_result(
            eval_case,
            run_index,
            result,
            trace_metadata,
            recorded_prompt_hashes,
            started
          )
        after
          File.rm(raw_trace_path)
          File.rm(sanitized_trace_path)
          File.rmdir(raw_trace_dir)
        end
      after
        cleanup_llm.()
      end
    after
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
    programs = Map.fetch!(eval_case, :mock_programs)
    {:ok, agent} = Agent.start_link(fn -> programs end)

    llm = fn _request ->
      if Process.alive?(agent) do
        Agent.get_and_update(agent, fn
          [program | rest] ->
            response = %{
              tool_calls: [%{name: Action.tool_name(), args: %{"program" => program}}]
            }

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

  defp llm_for(_eval_case, :live, model, opts), do: {live_llm(model, opts), fn -> :ok end}

  defp incumbent_llm_for(eval_case, :mock, _model, _opts) do
    responses =
      Map.get_lazy(eval_case, :mock_incumbent_responses, fn ->
        Enum.map(eval_case.mock_programs, &"```clojure\n#{&1}\n```")
      end)

    {:ok, agent} = Agent.start_link(fn -> responses end)

    llm = fn _request ->
      Agent.get_and_update(agent, fn
        [response | rest] -> {{:ok, response}, rest}
        [] -> {{:ok, "No program available."}, []}
      end)
    end

    {llm, fn -> stop_agent(agent) end}
  end

  defp incumbent_llm_for(_eval_case, :live, model, opts),
    do: {live_llm(model, opts), fn -> :ok end}

  defp live_llm(model, opts) do
    case Keyword.get(opts, :live_llm) do
      fun when is_function(fun, 1) ->
        fun

      nil ->
        LLM.callback(model,
          receive_timeout: Keyword.get(opts, :receive_timeout, 60_000),
          req_http_options:
            Keyword.get(opts, :req_http_options, retry: :transient, max_retries: 3),
          max_tokens: Keyword.get(opts, :max_tokens, 512),
          temperature: Keyword.get(opts, :temperature, 0.0)
        )
    end
  end

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
    {status, value, failure_reason, failure_hash} =
      case result do
        {:ok, %{"value" => value}} ->
          expected_result(eval_case, value)

        {:ok, other} ->
          expected_result(eval_case, other)

        {:error, %{"reason" => "llm_transport_error", "error" => error}} ->
          {:infrastructure_error, nil, "transport_failure", hash_term(error)}

        {:error, %{"reason" => reason}} ->
          {:fail, nil, "kernel_failure", hash_term(reason)}

        {:error, _other} ->
          {:fail, nil, "kernel_error", nil}
      end

    persisted_events = Analyzer.load(trace_metadata.path)

    kernel_turns =
      persisted_events
      |> Analyzer.turn_events()
      |> Enum.filter(fn turn ->
        turn["driver"] == "kernel" and turn["agent_id"] == trace_metadata.kernel_run_id
      end)

    expected_turns = expected_turns(events)
    actual_turns = length(kernel_turns)
    evidence = turn_evidence(kernel_turns)

    dropped_turns = max(expected_turns - actual_turns, 0)
    unexpected_turns = max(actual_turns - expected_turns, 0)

    eval_count = Enum.count(events, &(&1.event == "eval"))

    {persistence_verified, persistence_failure} =
      persistence_check(eval_case, trace_metadata.requirement_turns)

    {status, failure_reason, failure_hash} =
      enforce_trace_integrity(
        {status, failure_reason, failure_hash},
        trace_metadata.write_errors,
        dropped_turns,
        unexpected_turns
      )

    {status, failure_reason, failure_hash} =
      enforce_case_requirements(
        eval_case,
        eval_count,
        {persistence_verified, persistence_failure},
        status,
        failure_reason,
        failure_hash
      )

    Map.merge(evidence, %{
      run: run_index,
      case: eval_case.id,
      status: status,
      value: value,
      expected_result: Oracle.expected_projection(eval_case),
      actual_result: project_result(value),
      failure_reason: failure_reason,
      failure_hash: failure_hash,
      action_count: Enum.count(events, &(&1.event == "action")),
      eval_count: eval_count,
      persistence_verified: persistence_verified,
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
      dropped_turns: dropped_turns,
      unexpected_turns: unexpected_turns
    })
  end

  defp expected_result(eval_case, value) do
    case Oracle.verify(eval_case, value) do
      :ok -> {:pass, value, nil, nil}
      {:error, reason} -> {:fail, value, reason, nil}
    end
  end

  defp build_incumbent_case_result(
         eval_case,
         run_index,
         result,
         trace_metadata,
         prompt_hashes,
         started
       ) do
    {status, value, failure_reason, failure_hash} =
      case result do
        {:ok, %{return: value}} ->
          expected_result(eval_case, value)

        {:error, %{fail: %{reason: :llm_error} = fail}} ->
          {:infrastructure_error, nil, "transport_failure", hash_term(fail)}

        {:error, %{fail: fail}} ->
          {:fail, nil, "incumbent_failure", hash_term(fail)}

        {:error, reason} ->
          {:fail, nil, "incumbent_error", hash_term(reason)}
      end

    turns =
      trace_metadata.path
      |> Analyzer.load()
      |> Analyzer.turn_events()
      |> Enum.filter(fn turn ->
        turn["driver"] == "sub_agent" and
          turn["agent_id"] == trace_metadata.incumbent_agent_id
      end)

    actual_turns = length(turns)
    expected_turns = length(prompt_hashes)
    dropped_turns = max(expected_turns - actual_turns, 0)
    unexpected_turns = max(actual_turns - expected_turns, 0)
    eval_count = Enum.count(turns, &get_in(&1, ["data", "program_hash"]))

    {persistence_verified, persistence_failure} =
      persistence_check(eval_case, trace_metadata.requirement_turns)

    {status, failure_reason, failure_hash} =
      enforce_trace_integrity(
        {status, failure_reason, failure_hash},
        trace_metadata.write_errors,
        dropped_turns,
        unexpected_turns
      )

    {status, failure_reason, failure_hash} =
      enforce_case_requirements(
        eval_case,
        eval_count,
        {persistence_verified, persistence_failure},
        status,
        failure_reason,
        failure_hash
      )

    Map.merge(turn_evidence(turns), %{
      run: run_index,
      case: eval_case.id,
      status: status,
      value: value,
      expected_result: Oracle.expected_projection(eval_case),
      actual_result: project_result(value),
      failure_reason: failure_reason,
      failure_hash: failure_hash,
      action_count: actual_turns,
      eval_count: eval_count,
      persistence_verified: persistence_verified,
      duration_ms: duration_ms(started),
      trace: [],
      unsafe_trace: nil,
      trace_path: trace_metadata.path,
      write_errors: trace_metadata.write_errors,
      prompt_hashes: prompt_hashes,
      action_hashes:
        Enum.map(turns, &get_in(&1, ["data", "program_hash"])) |> Enum.reject(&is_nil/1),
      expected_turns: expected_turns,
      actual_turns: actual_turns,
      dropped_turns: dropped_turns,
      unexpected_turns: unexpected_turns
    })
  end

  defp enforce_case_requirements(
         eval_case,
         eval_count,
         {persistence_verified, persistence_failure},
         :pass,
         _reason,
         _hash
       ) do
    cond do
      eval_count < Map.get(eval_case, :min_evals, 1) ->
        {:fail, "minimum_eval_count_not_met", nil}

      persistence_verified == false ->
        {:fail, persistence_failure, nil}

      true ->
        {:pass, nil, nil}
    end
  end

  defp enforce_case_requirements(_eval_case, _eval_count, _persistence, status, reason, hash),
    do: {status, reason, hash}

  defp persistence_check(%{required_persistence: _name} = eval_case, turns) do
    case Enum.filter(turns, &(&1["committed"] == true)) do
      [definition | later] ->
        cond do
          not definition_matches_required_value?(definition, eval_case) ->
            {false, "required_persisted_value_not_defined"}

          later == [] ->
            {false, "required_persisted_name_not_reused"}

          not terminal_program_requires_persisted_value?(List.last(later), eval_case) ->
            {false, "required_persisted_name_not_reused"}

          true ->
            {true, nil}
        end

      _other ->
        {false, "required_persisted_value_not_defined"}
    end
  end

  defp persistence_check(_eval_case, _turns), do: {nil, nil}

  defp changed_keys(turn),
    do: get_in(turn, ["data", "memory_diff", "changed_keys"]) || []

  defp program_uses_symbol?(turn, name) do
    case Parser.parse(get_in(turn, ["data", "program"]) || "") do
      {:ok, ast} -> ast_reads_symbol?(ast, name, false)
      {:error, _reason} -> false
    end
  end

  defp definition_matches_required_value?(turn, eval_case) do
    name = eval_case.required_persistence
    program = get_in(turn, ["data", "program"]) || ""

    changed_keys(turn) == [name] and
      case Lisp.run(program, context: eval_case.context, timeout: 1_000) do
        {:ok, step} -> Map.get(step.memory, name) == eval_case.required_persistence_value
        _other -> false
      end
  end

  defp terminal_program_requires_persisted_value?(nil, _eval_case), do: false

  defp terminal_program_requires_persisted_value?(turn, eval_case) do
    name = eval_case.required_persistence
    program = get_in(turn, ["data", "program"]) || ""
    tools = Map.get(eval_case, :tools, %{})

    map_size(tools) == 0 and program_uses_symbol?(turn, name) and
      not program_reads_data_employees?(program) and
      counterfactuals_match_host_totals?(program, eval_case)
  end

  defp program_reads_data_employees?(program) do
    case Parser.parse(program) do
      {:ok, ast} -> ast_reads_ns_symbol?(ast, "data", "employees")
      {:error, _reason} -> false
    end
  end

  defp counterfactuals_match_host_totals?(program, eval_case) do
    eval_case
    |> persistence_counterfactuals(program)
    |> Enum.all?(fn ids ->
      expected = expense_total_for_ids(eval_case.context, ids)

      case Lisp.run(program,
             context: eval_case.context,
             tools: Map.get(eval_case, :tools, %{}),
             memory: %{eval_case.required_persistence => ids},
             timeout: 1_000
           ) do
        {:ok, step} -> counterfactual_matches?(counterfactual_value(step.return), expected)
        {:error, _step} -> false
      end
    end)
  end

  defp counterfactual_value({:__ptc_return__, value}), do: value
  defp counterfactual_value(value), do: value

  defp persistence_counterfactuals(%{required_persistence_value: %MapSet{}} = eval_case, program) do
    ids = eval_case.context["employees"] |> Enum.map(& &1["id"]) |> Enum.sort()
    offset = :erlang.phash2(program, max(length(ids) - 4, 1))
    selected = ids |> Enum.drop(offset) |> Enum.take(4)

    [
      selected |> Enum.take(1) |> MapSet.new(),
      selected |> Enum.take(2) |> MapSet.new(),
      selected |> Enum.take(3) |> MapSet.new(),
      selected |> Enum.take(4) |> MapSet.new()
    ]
    |> Enum.reject(&(&1 == eval_case.required_persistence_value))
  end

  defp persistence_counterfactuals(_eval_case, _program), do: []

  defp expense_total_for_ids(context, ids) do
    context["expenses"]
    |> Enum.filter(&MapSet.member?(ids, &1["employee_id"]))
    |> Enum.map(& &1["amount"])
    |> Enum.sum()
  end

  defp counterfactual_matches?(actual, expected) when is_number(actual),
    do: abs(actual - expected) <= 0.01

  defp counterfactual_matches?(_actual, _expected), do: false

  @doc false
  @spec enforce_trace_integrity(
          {atom(), String.t() | nil, String.t() | nil},
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {atom(), String.t() | nil, String.t() | nil}
  def enforce_trace_integrity(_status, write_errors, dropped_turns, unexpected_turns)
      when write_errors > 0 or dropped_turns > 0 or unexpected_turns > 0,
      do: {:infrastructure_error, "trace_integrity_failure", nil}

  def enforce_trace_integrity(status, _write_errors, _dropped_turns, _unexpected_turns),
    do: status

  defp ast_reads_symbol?({:symbol, symbol}, name, shadowed?),
    do: not shadowed? and to_string(symbol) == name

  defp ast_reads_symbol?({:list, [{:symbol, form} | args]}, name, shadowed?) do
    case to_string(form) do
      "quote" ->
        false

      "def" ->
        args |> Enum.drop(1) |> Enum.any?(&ast_reads_symbol?(&1, name, shadowed?))

      "defn" ->
        function_body_reads?(Enum.drop(args, 1), name, shadowed?)

      "fn" ->
        function_body_reads?(args, name, shadowed?)

      form when form in ["let", "loop"] ->
        binding_form_reads?(args, name, shadowed?)

      _other ->
        ast_reads_symbol?({:symbol, form}, name, shadowed?) or
          Enum.any?(args, &ast_reads_symbol?(&1, name, shadowed?))
    end
  end

  defp ast_reads_symbol?({:vector, values}, name, shadowed?),
    do: Enum.any?(values, &ast_reads_symbol?(&1, name, shadowed?))

  defp ast_reads_symbol?(tuple, name, shadowed?) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&ast_reads_symbol?(&1, name, shadowed?))

  defp ast_reads_symbol?(list, name, shadowed?) when is_list(list),
    do: Enum.any?(list, &ast_reads_symbol?(&1, name, shadowed?))

  defp ast_reads_symbol?(_ast, _name, _shadowed?), do: false

  defp function_body_reads?(args, name, shadowed?) do
    case Enum.split_while(args, &(not match?({:vector, _}, &1))) do
      {_prefix, [{:vector, params} | body]} ->
        body_shadowed? = shadowed? or Enum.any?(params, &binding_pattern_binds?(&1, name))
        Enum.any?(body, &ast_reads_symbol?(&1, name, body_shadowed?))

      {_prefix, []} ->
        false
    end
  end

  defp binding_form_reads?([{:vector, bindings} | body], name, shadowed?) do
    {binding_reads?, body_shadowed?} = binding_pairs_read?(bindings, name, shadowed?)
    binding_reads? or Enum.any?(body, &ast_reads_symbol?(&1, name, body_shadowed?))
  end

  defp binding_form_reads?(_args, _name, _shadowed?), do: false

  defp binding_pairs_read?([binding, value | rest], name, shadowed?) do
    if ast_reads_symbol?(value, name, shadowed?) do
      {true, shadowed?}
    else
      binding_pairs_read?(rest, name, shadowed? or binding_pattern_binds?(binding, name))
    end
  end

  defp binding_pairs_read?(_bindings, _name, shadowed?), do: {false, shadowed?}

  defp binding_pattern_binds?({:symbol, symbol}, name), do: to_string(symbol) == name

  defp binding_pattern_binds?({:vector, patterns}, name),
    do: Enum.any?(patterns, &binding_pattern_binds?(&1, name))

  defp binding_pattern_binds?({:map, pairs}, name) do
    Enum.any?(pairs, fn
      {{:keyword, key}, pattern} when key in [:keys, :strs, :syms, :as] ->
        binding_pattern_binds?(pattern, name)

      {{:keyword, :or}, {:map, defaults}} ->
        Enum.any?(defaults, fn {binding, _default} -> binding_pattern_binds?(binding, name) end)

      {binding, _source_key} ->
        binding_pattern_binds?(binding, name)
    end)
  end

  defp binding_pattern_binds?(_ast, _name), do: false

  defp ast_reads_ns_symbol?({:ns_symbol, namespace, symbol}, namespace_name, symbol_name),
    do: to_string(namespace) == namespace_name and to_string(symbol) == symbol_name

  defp ast_reads_ns_symbol?({:list, [{:symbol, form} | _args]}, _namespace, _symbol)
       when form in [:quote, "quote"],
       do: false

  defp ast_reads_ns_symbol?(tuple, namespace, symbol) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&ast_reads_ns_symbol?(&1, namespace, symbol))

  defp ast_reads_ns_symbol?(list, namespace, symbol) when is_list(list),
    do: Enum.any?(list, &ast_reads_ns_symbol?(&1, namespace, symbol))

  defp ast_reads_ns_symbol?(_ast, _namespace, _symbol), do: false

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
    first =
      Enum.find(turns, fn turn ->
        get_in(turn, ["data", "preludes"]) not in [nil, []] or
          get_in(turn, ["data", "inner_preludes"]) not in [nil, []]
      end) || hd(turns)

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

  defp raw_turns(path, driver, identity_key, identity_value) do
    path
    |> Analyzer.load()
    |> Analyzer.turn_events()
    |> Enum.filter(fn turn ->
      turn["driver"] == driver and turn[identity_key] == identity_value
    end)
  end

  defp agent_id_for_name(path, agent_name) do
    path
    |> Analyzer.load()
    |> Analyzer.turn_events()
    |> Enum.find_value(fn turn ->
      if turn["driver"] == "sub_agent" and turn["agent_name"] == agent_name,
        do: turn["agent_id"]
    end)
  end

  defp sanitize_persistent_trace!(source_path, destination_path) do
    sanitized =
      source_path
      |> Analyzer.load()
      |> Enum.map(&sanitize_persisted_event/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(&(Jason.encode!(&1) <> "\n"))

    File.write!(destination_path, sanitized)
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
      |> Map.update("catalog_ops", [], &sanitize_catalog_ops/1)
      |> Map.update("fail", nil, &sanitize_persisted_fail/1)

    event
    |> Map.put("projection", %{"name" => "m2_evidence_turn", "version" => 1})
    |> Map.put("data", sanitized_data)
  end

  defp sanitize_persisted_event(%{"event" => event_name} = event)
       when event_name in ["trace.start", "trace.stop"] do
    Map.take(event, [
      "schema_version",
      "event",
      "trace_id",
      "timestamp",
      "seq",
      "trace_kind",
      "producer",
      "trace_label",
      "model",
      "duration_ms"
    ])
  end

  defp sanitize_persisted_event(_event), do: nil

  defp maybe_put_hash(map, _key, nil), do: map
  defp maybe_put_hash(map, key, value), do: Map.put(map, key, hash_term(value))

  defp maybe_put_memory_count(map, memory_diff) when is_map(memory_diff) do
    changed = Map.get(memory_diff, "changed_keys", [])
    Map.put(map, "memory_changed_count", if(is_list(changed), do: length(changed), else: 0))
  end

  defp maybe_put_memory_count(map, _memory_diff), do: Map.put(map, "memory_changed_count", 0)

  defp sanitize_persisted_fail(nil), do: nil

  defp sanitize_persisted_fail(fail) when is_map(fail) do
    reason = Map.get(fail, "reason", Map.get(fail, :reason))

    %{"reason" => "kernel_failure"}
    |> maybe_put_hash("reason_hash", reason)
  end

  defp sanitize_persisted_fail(_fail), do: %{"reason" => "kernel_failure"}

  defp sanitize_catalog_ops(ops) when is_list(ops) do
    Enum.map(ops, fn op ->
      %{
        "operation" => Map.get(op, "operation"),
        "outcome" => Map.get(op, "outcome"),
        "duration_ms" => Map.get(op, "duration_ms")
      }
      |> maybe_put_hash("args_hash", Map.get(op, "args"))
      |> maybe_put_hash("reason_hash", Map.get(op, "reason"))
    end)
  end

  defp sanitize_catalog_ops(_ops), do: []

  defp hash_term(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(canonical_hash_term(term)))
    |> Base.encode16(case: :lower)
  end

  defp canonical_hash_term(%MapSet{} = set) do
    {:map_set, set |> Enum.map(&canonical_hash_term/1) |> Enum.sort()}
  end

  defp canonical_hash_term(%module{} = struct) do
    {:struct, module, struct |> Map.from_struct() |> canonical_hash_term()}
  end

  defp canonical_hash_term(map) when is_map(map) do
    entries =
      map
      |> Enum.map(fn {key, value} ->
        {canonical_hash_term(key), canonical_hash_term(value)}
      end)
      |> Enum.sort()

    {:map, entries}
  end

  defp canonical_hash_term([]), do: []

  defp canonical_hash_term([head | tail]),
    do: [canonical_hash_term(head) | canonical_hash_term(tail)]

  defp canonical_hash_term(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&canonical_hash_term/1)
    |> List.to_tuple()
  end

  defp canonical_hash_term(term), do: term

  defp trace_path(eval_case, run_index, opts) do
    trace_dir =
      Keyword.get(opts, :trace_dir) ||
        Path.join(Mix.Project.build_path(), "kernel_eval_traces")

    File.mkdir_p!(trace_dir)
    variant = Keyword.get(opts, :variant, "kernel")
    Path.join(trace_dir, "#{variant}-#{eval_case.id}-run-#{run_index}.jsonl")
  end

  defp temporary_trace_path(path, kind) do
    "#{path}.#{kind}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp raw_trace_directory do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc-kernel-eval-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp publish_report(_report, nil, nil), do: :ok

  defp publish_report(report, path, run_context) when is_binary(path) do
    write_report_files(report, path, not is_nil(run_context))
    finalize_run_context(run_context, report)
  rescue
    exception ->
      abort_run_context(run_context, exception)
      reraise exception, __STACKTRACE__
  end

  defp write_report_files(report, path, exclusive?) do
    File.mkdir_p!(Path.dirname(path))
    options = if exclusive?, do: [:exclusive], else: []
    File.write!(path, render_markdown(report) <> "\n", options)

    File.write!(
      Path.rootname(path) <> ".json",
      Jason.encode!(public_report(report), pretty: true) <> "\n",
      options
    )

    :ok
  end

  defp publish_pair_report(pair, path, context) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, render_pair_markdown(pair) <> "\n", [:exclusive])

    File.write!(Path.rootname(path) <> ".json", Jason.encode!(pair, pretty: true) <> "\n", [
      :exclusive
    ])

    state = if pair.aborted, do: "aborted", else: "completed"
    if context, do: RunContext.finish!(context, state, %{abort_reason: pair.abort_reason})
    :ok
  rescue
    exception ->
      abort_run_context(context, exception)
      reraise exception, __STACKTRACE__
  end

  defp maybe_start_run_context(suite, mode, source, variant, model, opts) do
    case Keyword.get(opts, :shared_run_context) do
      %RunContext{} = context -> context
      nil -> maybe_start_new_run_context(suite, mode, source, variant, model, opts)
    end
  end

  defp maybe_start_new_run_context(suite, :live, "registry", variant, model, opts)
       when suite in ["smoke", "tier2"] do
    report = Keyword.fetch!(opts, :report)

    RunContext.start!(
      report,
      %{suite: suite, variant: variant, model: model},
      opts
    )
  end

  defp maybe_start_new_run_context(_suite, _mode, _source, _variant, _model, _opts), do: nil

  defp initial_snapshot(%RunContext{initial_snapshot: snapshot}), do: snapshot
  defp initial_snapshot(nil), do: %{commit: commit(), clean: clean_worktree?()}

  defp validate_lifecycle(nil), do: :ok
  defp validate_lifecycle(context), do: RunContext.validate(context)

  defp lifecycle_abort_reason(nil, abort_reason), do: abort_reason

  defp lifecycle_abort_reason(context, abort_reason) do
    case RunContext.validate(context) do
      :ok -> abort_reason
      {:error, reason} -> reason
    end
  end

  defp lifecycle_eligible?(nil, snapshot), do: snapshot.clean
  defp lifecycle_eligible?(context, _snapshot), do: RunContext.validate(context) == :ok

  defp finalize_run_context(nil, _report), do: :ok

  defp finalize_run_context(context, report) do
    state = if report.aborted, do: "aborted", else: "completed"
    RunContext.finish!(context, state, %{abort_reason: report.abort_reason})
    :ok
  end

  defp abort_run_context(nil, _exception), do: :ok

  defp abort_run_context(context, exception) do
    RunContext.finish!(context, "aborted", %{abort_reason: exception_class(exception)})
    :ok
  end

  defp pair_paths(report_path) do
    root = Path.rootname(report_path)

    %{
      incumbent_report: root <> "-incumbent.md",
      kernel_report: root <> "-kernel.md",
      incumbent_traces: root <> "-incumbent-traces",
      kernel_traces: root <> "-kernel-traces"
    }
  end

  defp ensure_pair_artifacts_absent!(paths, context) do
    paths
    |> Map.take([:incumbent_report, :kernel_report])
    |> Map.values()
    |> Enum.flat_map(&[&1, Path.rootname(&1) <> ".json"])
    |> Enum.find(&File.exists?/1)
    |> case do
      nil ->
        :ok

      path ->
        abort_run_context(context, %ArgumentError{})
        raise ArgumentError, "canonical experiment artifact already exists: #{path}"
    end
  end

  defp pair_reports_match?([incumbent, kernel]) do
    fields = [:commit, :model, :dataset_hash, :case_definition_hash]

    Map.take(incumbent, fields) == Map.take(kernel, fields) and
      incumbent.command_options.report != kernel.command_options.report
  end

  defp pair_reports_match?(_reports), do: false

  defp pair_configuration_hash([incumbent, kernel]) do
    hash_term(%{
      incumbent: Map.drop(incumbent.command_options, [:report, :trace_dir, :variant]),
      kernel: Map.drop(kernel.command_options, [:report, :trace_dir, :variant])
    })
  end

  defp pair_configuration_hash(_reports), do: nil

  defp public_report(report) do
    Map.update!(report, :cases, fn cases ->
      Enum.map(cases, &Map.drop(&1, [:trace, :unsafe_trace, :value]))
    end)
  end

  defp provider(nil), do: nil
  defp provider(model), do: model |> Registry.provider_from_model() |> to_string()

  defp llm_source(:mock, _opts), do: "mock"

  defp llm_source(:live, opts) do
    if is_function(Keyword.get(opts, :live_llm), 1), do: "injected", else: "registry"
  end

  defp provenance_eligible?(mode, llm_source, results, abort_reason, commit, clean_worktree?) do
    mode == :live and llm_source == "registry" and results != [] and is_nil(abort_reason) and
      valid_commit?(commit) and clean_worktree?
  end

  @doc false
  @spec preregistered_config?(map()) :: boolean()
  def preregistered_config?(config) do
    common_preregistered_config?(config) and
      case config.suite do
        "tier2" -> tier2_preregistered_config?(config)
        "smoke" -> smoke_preregistered_config?(config)
        _other -> false
      end
  end

  defp common_preregistered_config?(config) do
    expected = %{
      mode: :live,
      requested_model: "deepseek",
      temperature: 0.0,
      max_tokens: 512,
      receive_timeout: 60_000,
      req_http_options: [retry: :transient, max_retries: 3],
      prelude_source_overrides: %{},
      role_policy: nil,
      role: nil,
      prelude_store: nil,
      preludes: nil,
      inner_preludes: nil,
      kernel_memory_byte_cap: nil,
      unsafe_debug: false,
      unsafe_debug_agent: nil
    }

    Map.take(config, Map.keys(expected)) == expected and valid_path?(config.report) and
      valid_path?(config.trace_dir)
  end

  defp tier2_preregistered_config?(config) do
    expected = %{
      runs: 1,
      seed: @m2_dataset_seed,
      case_definition_hash: @m2_case_definition_hash,
      paired_run: true
    }

    Map.take(config, Map.keys(expected)) == expected and
      config.variant in ["kernel", "incumbent"] and
      Enum.sort(config.case_ids) == Enum.sort(@m2_case_ids)
  end

  defp smoke_preregistered_config?(config) do
    expected = %{
      variant: "kernel",
      runs: 5,
      seed: 0,
      case_ids: ["record_count_500"],
      case_definition_hash: @m1_smoke_case_definition_hash
    }

    Map.take(config, Map.keys(expected)) == expected
  end

  defp valid_path?(path), do: is_binary(path) and path != ""

  defp valid_commit?(commit), do: Regex.match?(~r/\A[0-9a-f]{40}\z/, commit)

  defp commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: false) do
      {hash, 0} -> String.trim(hash)
      _ -> "unknown"
    end
  end

  defp clean_worktree? do
    case System.cmd("git", ["status", "--porcelain=v1"], stderr_to_stdout: false) do
      {"", 0} -> true
      {_output, _status} -> false
    end
  end

  defp command_options(opts, suite, mode, variant, requested_model) do
    %{
      suite: suite,
      mode: Atom.to_string(mode),
      variant: variant,
      requested_model: requested_model,
      llm_source: llm_source(mode, opts),
      runs: Keyword.get(opts, :runs, 1),
      seed: Keyword.get(opts, :seed, 0),
      case: Keyword.get(opts, :case),
      trace_dir: Keyword.get(opts, :trace_dir),
      report: Keyword.get(opts, :report)
    }
  end

  defp summarize_report(%{cases: cases} = report) do
    case_count = length(cases)
    pass_count = Enum.count(cases, &case_passed?/1)
    pass_rate = if case_count == 0, do: 0.0, else: pass_count / case_count

    Map.merge(report, %{case_count: case_count, pass_count: pass_count, pass_rate: pass_rate})
  end

  defp dataset_hash("tier2", seed), do: seed |> Dataset.build() |> hash_term()
  defp dataset_hash(_suite, _seed), do: nil

  @doc false
  @spec case_definition_hash([map()]) :: String.t()
  def case_definition_hash(cases) do
    cases
    |> Enum.map(fn eval_case ->
      %{
        id: eval_case.id,
        dataset_seed: Map.get(eval_case, :dataset_seed),
        task: eval_case.task,
        context: eval_case.context,
        tools: eval_case |> Map.get(:tools, %{}) |> Map.keys() |> Enum.sort(),
        tool_fixtures: Map.get(eval_case, :tool_fixtures, %{}),
        expect: Map.get(eval_case, :expect),
        constraint: Map.get(eval_case, :constraint),
        max_turns: eval_case.max_turns,
        min_evals: Map.get(eval_case, :min_evals, 1),
        required_persistence: Map.get(eval_case, :required_persistence),
        required_persistence_value_hash:
          eval_case |> Map.get(:required_persistence_value) |> hash_term(),
        tags: Map.get(eval_case, :tags, [])
      }
    end)
    |> hash_term()
  end

  defp case_passed?(case_result) do
    case_result.status == :pass and case_result.write_errors == 0 and
      case_result.expected_turns == case_result.actual_turns
  end

  @doc false
  @spec project_result(term()) :: map()
  def project_result(value) when is_integer(value), do: %{type: "integer", value: value}
  def project_result(value) when is_float(value), do: %{type: "float", value: value}
  def project_result(value) when is_boolean(value), do: %{type: "boolean", value: value}
  def project_result(nil), do: %{type: "nil", value: nil}

  def project_result(value) when is_binary(value),
    do: %{type: "string", bytes: byte_size(value), hash: hash_term(value)}

  def project_result(value) when is_list(value) do
    if proper_list?(value) do
      %{type: "list", count: length(value), hash: hash_term(value)}
    else
      %{type: "improper_list", hash: hash_term(value)}
    end
  end

  def project_result(value) when is_map(value),
    do: %{type: "map", count: map_size(value), hash: hash_term(value)}

  def project_result(value), do: %{type: value_type(value), hash: hash_term(value)}

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  defp value_type(value) when is_atom(value), do: "atom"
  defp value_type(value) when is_tuple(value), do: "tuple"
  defp value_type(_value), do: "other"

  defp render_result(projection), do: Jason.encode!(projection)

  defp duration_ms(started) do
    System.monotonic_time()
    |> Kernel.-(started)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp stop_agent(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
  end
end
