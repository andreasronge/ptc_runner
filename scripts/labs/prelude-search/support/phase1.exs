defmodule PtcRunner.Labs.PreludeSearch.Phase1 do
  @moduledoc false

  alias PtcRunner.Kernel.LLMFailureCatalog
  alias PtcRunner.Kernel.LLMReplay
  alias PtcRunner.Labs.PreludeSearch
  alias PtcRunner.Labs.PreludeSearch.Statistics

  @task """
  Repair the supplied component using its source, contract, and visible executions.
  Return diagnosis and candidate_source. The diagnosis names the function and exact
  faulty source fragment, and cites executions with their index and observed_json (the observed value encoded as JSON text).
  candidate_source is the complete component. Do not print or inspect data/params;
  its value is included below. Use run_ptc_lisp to return the requested object.
  """
  @experiments [
    {"E1 one-turn", 1, 1},
    {"E1 three-turn", 1, 3},
    {"E2 K=2", 2, 1},
    {"E2 K=4", 4, 1}
  ]
  @case_cap 100_000
  @wall_cap_ms 21_600_000

  def run(opts) do
    started = System.monotonic_time(:millisecond)
    output = opts |> Keyword.fetch!(:output) |> Path.expand()
    replay? = Keyword.get(opts, :replay, false)
    subjects = Keyword.get(opts, :subjects, PreludeSearch.subjects())
    instances = Keyword.get(opts, :instances, 20)
    budget = Keyword.get(opts, :budget_microusd, 5_000_000)
    seed = Keyword.get(opts, :seed, 20_260_930)

    request_ms = Keyword.get(opts, :request_timeout_ms, 120_000)
    if request_ms < 100 or request_ms > 500_000, do: raise("invalid request timeout")
    opts = Keyword.put(opts, :request_timeout_ms, request_ms)

    if instances < 1 or instances > 100 or budget < @case_cap,
      do: raise("invalid experiment limits")

    if File.exists?(output), do: raise("experiment output must be a new directory")
    :ok = prepare_output(output)

    protocol = %{
      request_timeout_ms: request_ms,
      wall_cap_ms: @wall_cap_ms,
      proposal_identity: "candidate-index-v1",
      seed: seed,
      instances: instances,
      subjects: subjects,
      case_cap_microusd: @case_cap,
      total_token_ceiling: 320_000,
      conditions: Enum.map(@experiments, &Tuple.to_list/1),
      budget_microusd: budget,
      model: "openrouter:deepseek/deepseek-v4-flash",
      final_tests: "never used for selection"
    }

    File.write!(Path.join(output, "protocol.json"), pretty_json(protocol))
    fixture_root = Keyword.get(opts, :fixtures, Path.join(output, "fixtures"))

    if replay? do
      saved_protocol =
        fixture_root
        |> Path.dirname()
        |> Path.join("protocol.json")
        |> File.read!()
        |> Jason.decode!()

      if saved_protocol != Jason.decode!(Jason.encode!(protocol)),
        do: raise("replay protocol differs from recorded experiment")
    end

    cases =
      for subject <- subjects,
          index <- 0..(instances - 1),
          condition <- @experiments,
          do: {subject, index, condition}

    cases = replay_cases(cases, fixture_root, opts)

    {results, spent, reason} =
      Enum.reduce_while(cases, {[], 0, nil}, fn {subject, index, {experiment, candidates, turns}},
                                                {rows, spent, _} ->
        remaining_ms = @wall_cap_ms - (System.monotonic_time(:millisecond) - started)
        # Reserve the longest case plus command startup/checking headroom before admission.
        stop_reason =
          cond do
            spent + @case_cap > budget -> "budget_reservation"
            remaining_ms < request_ms * 3 + 120_000 -> "wall_clock_reservation"
            true -> nil
          end

        if stop_reason do
          {:halt, {rows, spent, stop_reason}}
        else
          instance = PreludeSearch.instance(subject, seed + index)

          File.write!(
            Path.join(output, "reservation.json"),
            pretty_json(%{
              mode: if(replay?, do: "replay", else: "live"),
              spent_microusd: if(replay?, do: 0, else: spent),
              replayed_cost_microusd: if(replay?, do: spent, else: nil),
              reserved_microusd: if(replay?, do: 0, else: @case_cap),
              subject: subject,
              instance: index,
              condition: experiment
            })
          )

          case safely_run_case(
                 output,
                 instance,
                 index,
                 experiment,
                 candidates,
                 turns,
                 replay?,
                 fixture_root,
                 opts
               ) do
            {:ok, result} ->
              cost = get_in(result, ["usage", "llm_spend", "total_cost", "microunits"])
              next = [result | rows]
              File.write!(Path.join(output, "results.json"), pretty_json(Enum.reverse(next)))

              {:cont, {next, spent + cost, nil}}

            {:error, message} ->
              File.write!(
                Path.join(output, "stopped-case.json"),
                pretty_json(%{
                  subject: subject,
                  instance: index,
                  condition: experiment,
                  error: message,
                  reserved_microusd: @case_cap
                })
              )

              {:halt, {rows, spent + @case_cap, "case_failed_reserved_at_ceiling"}}
          end
        end
      end)

    results = Enum.reverse(results)
    File.write!(Path.join(output, "results.json"), pretty_json(results))

    if not replay? do
      fixtures =
        Enum.map(results, fn row ->
          Path.join(
            fixture_root,
            case_slug(row["subject"], row["instance"], row["experiment"]) <> ".jsonl"
          )
        end)

      index =
        Enum.map(fixtures, fn path ->
          %{
            file: Path.basename(path),
            sha256: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
          }
        end)

      File.mkdir_p!(fixture_root)
      File.write!(Path.join(fixture_root, "index.json"), pretty_json(index))
    end

    File.write!(
      Path.join(output, "summary.json"),
      pretty_json(%{
        rows: report(results),
        comparisons: Statistics.compare(results, "E1 three-turn", ["E2 K=2", "E2 K=4"]),
        mode: if(replay?, do: "replay", else: "live"),
        spent_or_reserved_microusd: if(replay?, do: 0, else: spent),
        replayed_cost_microusd: if(replay?, do: spent, else: nil),
        stop_reason: reason,
        completed_cases: length(results),
        planned_cases: length(cases),
        unstarted_cases:
          length(cases) - length(results) -
            if(reason == "case_failed_reserved_at_ceiling", do: 1, else: 0),
        conclusion: "pilot; no automatic hypothesis verdict"
      })
    )

    results
  end

  defp safely_run_case(
         output,
         instance,
         index,
         experiment,
         candidates,
         turns,
         replay?,
         fixtures,
         opts
       ) do
    {:ok,
     run_case(output, instance, index, experiment, candidates, turns, replay?, fixtures, opts)}
  rescue
    error ->
      if replay?, do: reraise(error, __STACKTRACE__), else: {:error, Exception.message(error)}
  end

  defp case_slug(subject, index, experiment),
    do: "#{subject}-#{index}-#{String.replace(experiment, ~r/[^A-Za-z0-9]+/, "-")}"

  defp replay_cases(cases, fixtures, opts) do
    if Keyword.get(opts, :partial_replay, false) do
      unless Keyword.get(opts, :replay, false), do: raise("partial replay requires --replay")
      index = fixtures |> Path.join("index.json") |> File.read!() |> Jason.decode!()
      prefix = Enum.take(cases, length(index))

      names =
        Enum.map(prefix, fn {subject, i, {experiment, _, _}} ->
          case_slug(subject, i, experiment) <> ".jsonl"
        end)

      unless names == Enum.map(index, & &1["file"]),
        do: raise("fixtures are not a completed prefix")

      prefix
    else
      cases
    end
  end

  def report(results) do
    groups = Enum.group_by(results, &{&1["experiment"], &1["subject"]})

    for {experiment, _, _} <- @experiments, subject <- PreludeSearch.subjects() ++ ["overall"] do
      rows =
        if subject == "overall" do
          Enum.filter(results, &(&1["experiment"] == experiment))
        else
          Map.get(groups, {experiment, subject}, [])
        end

      metric_row(experiment, subject, rows)
    end
  end

  def proposal_params(instance, candidates) do
    Enum.map(0..(candidates - 1), fn index ->
      %{
        "candidate_index" => index,
        "task" => @task,
        "source" => instance.mutated_source,
        "visible_executions" =>
          Enum.with_index(instance.visible, fn execution, index ->
            Map.take(execution, ["input", "observed"])
            |> Map.put("index", index)
          end)
      }
    end)
  end

  defp run_case(
         output,
         instance,
         instance_index,
         experiment,
         candidates,
         turns,
         replay?,
         fixture_root,
         opts
       ) do
    slug = case_slug(instance.subject, instance_index, experiment)

    app_dir = Path.join([output, "runs", slug])
    :ok = File.mkdir_p(app_dir)

    attempts = proposal_params(instance, candidates)

    input = %{
      "attempts" =>
        attempts
        |> Enum.with_index()
        |> Enum.map(fn {params, index} ->
          %{
            "mission" => "repair-#{index}",
            "task" => @task <> "\n\ndata/params:\n" <> Jason.encode!(params)
          }
        end),
      "entry" => entry(instance.subject)
    }

    write_application(app_dir, input, attempts, candidates, turns, replay?, fixture_root, opts)
    result_path = Path.join(app_dir, "result.json")
    envelope_path = Path.join(app_dir, "envelope.json")
    inspection_path = Path.join([app_dir, "inspection", "run.ptcins"])
    File.mkdir_p!(Path.dirname(inspection_path))
    trace_dir = Path.join(app_dir, "traces")
    File.mkdir_p!(trace_dir)

    started = System.monotonic_time(:millisecond)

    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    {console, status} =
      command_runner.(
        System.find_executable("mix"),
        [
          "ptc",
          "run",
          Path.join(app_dir, "ptc.json"),
          "--host-config",
          Path.join(app_dir, "ptc-host.json"),
          "--private-output",
          result_path,
          "--inspect",
          inspection_path,
          "--envelope",
          envelope_path,
          "--trace-dir",
          trace_dir
        ],
        stderr_to_stdout: true,
        env: [{"MIX_QUIET", "1"}]
      )

    wall_ms = System.monotonic_time(:millisecond) - started

    File.write!(Path.join(app_dir, "console.log"), console)

    File.write!(
      Path.join(app_dir, "command.json"),
      pretty_json(%{exit_status: status, wall_ms: wall_ms})
    )

    inspection_path = index_inspection(inspection_path, envelope_path)

    if status != 0 do
      raise "phase 1 run failed for #{slug}:\n#{console}"
    end

    envelope = envelope_path |> File.read!() |> Jason.decode!()
    spend = get_in(envelope, ["execution", "usage", "llm_spend"]) || %{}

    unless spend["state"] == "available" and
             is_integer(get_in(spend, ["total_cost", "microunits"])) do
      raise "model usage unavailable; retain artifacts and reservation"
    end

    if not replay?,
      do: write_replay_fixture(inspection_path, Path.join(fixture_root, slug <> ".jsonl"))

    case_result(
      result_path,
      envelope_path,
      instance,
      instance_index,
      experiment,
      wall_ms,
      console
    )
  end

  defp index_inspection(path, envelope_path) do
    if File.exists?(path) and File.exists?(envelope_path) do
      run_ref = envelope_path |> File.read!() |> Jason.decode!() |> Map.fetch!("run_ref")
      indexed = Path.join(Path.dirname(path), run_ref <> ".ptcins")
      File.rename!(path, indexed)
      indexed
    else
      path
    end
  end

  defp case_result(
         result_path,
         envelope_path,
         instance,
         instance_index,
         experiment,
         wall_ms,
         console
       ) do
    value = result_path |> File.read!() |> Jason.decode!()
    envelope = envelope_path |> File.read!() |> Jason.decode!()
    scored = score(value, instance)

    selection =
      PreludeSearch.select_candidates(
        instance,
        Enum.map(scored, & &1["candidate_source"]),
        Path.join(Path.dirname(result_path), "check")
      )

    usage = get_in(envelope, ["execution", "usage"]) || %{}
    wall_ms = if wall_ms == 0, do: 300_000 - (usage["remaining_ms"] || 300_000), else: wall_ms

    %{
      "experiment" => experiment,
      "subject" => instance.subject,
      "instance" => instance_index,
      "seed" => instance.seed,
      "ground_truth" => instance.ground_truth,
      "candidates" => scored,
      "solved" => selection["final_pass"],
      "winner" => selection["selected"],
      "selection" => selection,
      "usage" => usage,
      "run_ref" => envelope["run_ref"],
      "wall_ms" => wall_ms,
      "console" => String.trim(console)
    }
  end

  defp write_application(dir, input, attempts, candidates, turns, replay?, fixture_root, opts) do
    File.write!(Path.join(dir, "workflow.clj"), workflow_source(candidates, turns))
    File.write!(Path.join(dir, "input.json"), pretty_json(input))
    File.write!(Path.join(dir, "repair.schema.json"), pretty_json(repair_schema()))
    File.write!(Path.join(dir, "ptc.json"), pretty_json(manifest(attempts, opts)))
    fixture_name = Path.basename(dir)

    if replay? do
      fixture = Path.join(fixture_root, fixture_name <> ".jsonl")
      index = fixture_root |> Path.join("index.json") |> File.read!() |> Jason.decode!()
      expected = Enum.find(index, &(&1["file"] == Path.basename(fixture)))
      digest = :crypto.hash(:sha256, File.read!(fixture)) |> Base.encode16(case: :lower)

      if is_nil(expected) or expected["sha256"] != digest,
        do: raise("replay fixture identity changed")

      File.cp!(fixture, Path.join(dir, "replay.jsonl"))
    end

    File.write!(
      Path.join(dir, "ptc-host.json"),
      pretty_json(configure_host(host(replay?, fixture_name), replay?, opts))
    )
  end

  defp workflow_source(1, turns) do
    ~S"""
    (ns lab.search "Checked single-shot repair." {:visibility :prompt})
    (defn run
      "Run one repair candidate."
      [input]
      (return [(agent.core/run-outcome
                 (get-in input ["attempts" 0 "task"])
                 {"mission" (get-in input ["attempts" 0 "mission"])
                  "max_turns" 1
                  "retain_programs" 1
                  "return_contract" "repair"})]))
    """
    |> String.replace("\"max_turns\" 1", "\"max_turns\" #{turns}")
  end

  defp workflow_source(_candidates, _turns) do
    ~S"""
    (ns lab.search "Checked parallel repair." {:visibility :prompt})
    (defn- propose [attempt]
      (agent.core/run-outcome
        (get attempt "task")
        {"mission" (get attempt "mission") "max_turns" 1 "retain_programs" 1 "return_contract" "repair"}))
    (defn run
      "Generate candidates in parallel."
      [input]
      (return (pmap propose (get input "attempts"))))
    """
  end

  defp manifest(attempts, opts) do
    repair_missions =
      attempts
      |> Enum.with_index()
      |> Map.new(fn {params, index} ->
        {"repair-#{index}", %{"components" => [], "data" => %{"params" => params}}}
      end)

    request_ms = Keyword.fetch!(opts, :request_timeout_ms)

    limits = %{
      "llm_request_timeout_ms" => request_ms,
      "run_duration_ms" => request_ms * 3 + 60_000,
      "workflow_timeout_ms" => request_ms * 3 + 60_000,
      "parallel_timeout_ms" => request_ms + 30_000,
      "evaluation_timeout_ms" => 120_000,
      "subordinate_evaluations" => 16,
      "subordinate_source_checks" => 8,
      "llm_request_output_tokens" => 16_384,
      "llm_total_tokens" => 320_000,
      "llm_cost_microusd" => @case_cap
    }

    %{
      "version" => 1,
      "workflow" => %{
        "components" => [
          %{
            "id" => "lab.search",
            "path" => "workflow.clj",
            "dependencies" => ["agent.core"]
          },
          %{"library" => "agent.core"}
        ],
        "entry" => "lab.search/run"
      },
      "missions" => repair_missions,
      "contracts" => %{"phase_return_schemas" => %{"repair" => %{"path" => "repair.schema.json"}}},
      "input" => %{"path" => "input.json"},
      "providers" => %{"workflow" => [%{"name" => "deepseek"}], "mission" => []},
      "limits" => limits,
      "events" => %{"policy" => "private"},
      "labels" => %{"name" => "prelude-search-phase-1"}
    }
  end

  defp configure_host(host, replay?, opts) do
    request_ms = Keyword.fetch!(opts, :request_timeout_ms)

    limits =
      Map.merge(host["limits"], %{
        "llm_request_timeout_ms" => request_ms,
        "run_duration_ms" => request_ms * 3 + 60_000,
        "workflow_timeout_ms" => request_ms * 3 + 60_000,
        "parallel_timeout_ms" => request_ms + 30_000
      })

    host = Map.put(host, "limits", limits)

    if replay?,
      do: host,
      else:
        host
        |> put_in(["install", "deepseek", "ceilings"], %{"request_timeout_ms" => request_ms})
        |> put_in(
          ["install", "deepseek", "installation_revision"],
          "prelude-search-deepseek-v2-#{request_ms}"
        )
  end

  defp host(false, _fixture_name) do
    %{
      "credentials" => %{"openrouter_key" => %{"env" => "OPENROUTER_API_KEY"}},
      "limits" => %{
        "llm_cost_microusd" => @case_cap,
        "llm_total_tokens" => 320_000,
        "parallel_timeout_ms" => 180_000
      },
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "structured_output_mode" => "json_schema",
          "usage_guarantees" => %{"tokens" => true, "cost_currency" => "USD"},
          "reservation_tariff" => %{
            "currency" => "USD",
            "id" => "openrouter-model-pricing-v1"
          },
          "installation_revision" => "prelude-search-deepseek-v4-flash-v1",
          "model" => "openrouter:deepseek/deepseek-v4-flash",
          "credential" => "openrouter_key",
          "cache" => false,
          "params" => %{"max_tokens" => 16_384}
        }
      }
    }
  end

  defp host(true, _fixture_name) do
    %{
      "limits" => %{
        "llm_cost_microusd" => @case_cap,
        "llm_total_tokens" => 320_000,
        "parallel_timeout_ms" => 180_000
      },
      "install" => %{
        "deepseek" => %{
          "source" => "llm_replay",
          "installation_revision" => "prelude-search-deepseek-v4-flash-replay-v1",
          "fixtures" => "replay.jsonl",
          "ceilings" => %{"max_entries" => 1_000, "max_result_bytes" => 1_000_000}
        }
      }
    }
  end

  defp repair_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["diagnosis", "candidate_source"],
      "properties" => %{
        "diagnosis" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["function", "form", "cited_executions"],
          "properties" => %{
            "function" => %{"type" => "string"},
            "form" => %{"type" => "string"},
            "cited_executions" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "required" => ["index", "observed_json"],
                "additionalProperties" => false,
                "properties" => %{
                  "index" => %{"type" => "integer", "minimum" => 0},
                  "observed_json" => %{"type" => "string"}
                }
              }
            }
          }
        },
        "candidate_source" => %{"type" => "string"}
      }
    }
  end

  def score(value, instance) when is_list(value) do
    Enum.map(value, fn outcome ->
      diagnosis = get_in(outcome, ["value", "diagnosis"]) || %{}
      candidate_source = get_in(outcome, ["value", "candidate_source"])

      %{
        "diagnosis" => diagnosis,
        "candidate_source" => candidate_source,
        "status" => outcome["status"],
        "failure_kind" => get_in(outcome, ["error", "kind"]) || outcome["kind"],
        "failure_reason" => get_in(outcome, ["error", "reason"]),
        "function_correct" =>
          function_correct?(
            diagnosis["function"],
            instance.subject,
            instance.ground_truth["function"]
          ),
        "form_correct" => form_correct?(diagnosis["form"], instance.ground_truth["form"]),
        "citations_valid" => citations_valid?(diagnosis["cited_executions"], instance.visible)
      }
    end)
  end

  def score(_value, _instance), do: []

  defp metric_row(experiment, subject, rows) do
    candidates = Enum.flat_map(rows, & &1["candidates"])
    solved = Enum.filter(rows, & &1["solved"])

    checked =
      rows
      |> Enum.flat_map(& &1["selection"]["selection"])
      |> Enum.count(&(&1["valid"] == true))

    %{
      experiment: experiment,
      subject: subject,
      instances: length(rows),
      function_accuracy:
        ratio(Enum.count(candidates, & &1["function_correct"]), length(candidates)),
      form_accuracy: ratio(Enum.count(candidates, & &1["form_correct"]), length(candidates)),
      final_test_pass_rate: ratio(length(solved), length(rows)),
      citation_values_valid_rate:
        ratio(Enum.count(candidates, & &1["citations_valid"]), length(candidates)),
      wall_ms: Enum.sum(Enum.map(rows, & &1["wall_ms"])),
      tokens_in: sum_usage(rows, "input"),
      tokens_out: sum_usage(rows, "output"),
      cost_microusd: sum_cost(rows),
      cost_per_solved_microusd: cost_per_solved(rows, solved),
      candidates_generated: Enum.count(candidates, &(&1["candidate_source"] != nil)),
      candidates_checked: checked,
      generated_per_solved:
        ratio(Enum.count(candidates, &(&1["candidate_source"] != nil)), length(solved)),
      checked_per_solved: ratio(checked, length(solved))
    }
  end

  defp cost_per_solved(rows, solved) do
    case sum_cost(rows) do
      cost when is_integer(cost) and solved != [] -> cost / length(solved)
      _ -> nil
    end
  end

  defp ratio(_number, 0), do: nil
  defp ratio(number, denominator), do: Float.round(number / denominator, 4)

  defp sum_usage(rows, key), do: sum_known(rows, ["usage", "llm_spend", key])
  defp sum_cost(rows), do: sum_known(rows, ["usage", "llm_spend", "total_cost", "microunits"])

  defp sum_known(rows, path) do
    values = Enum.map(rows, &get_in(&1, path))
    if values != [] and Enum.all?(values, &is_integer/1), do: Enum.sum(values), else: nil
  end

  defp form_correct?(nil, _truth), do: false

  defp form_correct?(form, truth),
    do: is_binary(form) and String.trim(form) != "" and String.trim(form) == String.trim(truth)

  defp entry("intervals"), do: "lab.intervals/merge-with-tolerance"
  defp entry("normaliser"), do: "lab.normaliser/normalise"
  defp entry("reconciliation"), do: "lab.reconciliation/reconcile"

  defp prepare_output(output) do
    with :ok <- File.mkdir_p(output), do: File.chmod(output, 0o700)
  end

  defp pretty_json(value), do: Jason.encode_to_iodata!(value, pretty: true)

  defp function_correct?(name, subject, truth), do: name in [truth, "lab.#{subject}/#{truth}"]

  defp citations_valid?(citations, visible) when is_list(citations) and citations != [] do
    Enum.all?(citations, fn
      %{"index" => index, "observed_json" => observed} when is_integer(index) and index >= 0 ->
        case Enum.at(visible, index) do
          nil -> false
          row -> is_binary(observed) and Jason.decode(observed) == {:ok, row["observed"]}
        end

      _ ->
        false
    end)
  end

  defp citations_valid?(_, _), do: false

  defp write_replay_fixture(inspection_path, path) do
    :ok = File.mkdir_p(Path.dirname(path))

    lines =
      inspection_path
      |> model_exchanges()
      |> Enum.group_by(& &1.request_hash, & &1.response)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {hash, outcomes} ->
        Jason.encode!(%{"schema_version" => 2, "request_hash" => hash, "outcomes" => outcomes})
      end)

    File.write!(path, lines <> "\n")

    case LLMReplay.probe(Path.dirname(path), Path.basename(path),
           max_entries: 1_000,
           max_result_bytes: 1_000_000
         ) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        File.rm!(path)
        raise "unreplayable fixture: #{inspect(reason)}; retain artifacts and reservation"
    end
  end

  # Dispatcher failures after response admission can contain already-settled usage.
  # Only provider-originated errors can be faithfully re-injected at this boundary.
  def replay_outcome(%{"status" => "ok", "value" => value}),
    do: %{"response" => Map.drop(value, ["model"])}

  def replay_outcome(%{"status" => "error", "kind" => "provider_error"} = error) do
    if error["reason"] in Enum.map(LLMFailureCatalog.provider_kinds(), &Atom.to_string/1) do
      %{
        "error" => %{
          "kind" => error["reason"],
          "details" => error["details"],
          "retryable" => error["retryable?"] == true
        }
      }
    else
      unreplayable_outcome!(error)
    end
  end

  def replay_outcome(error), do: unreplayable_outcome!(error)

  defp unreplayable_outcome!(error) do
    raise "cannot replay dispatcher outcome #{inspect(error["reason"])}; retain artifacts and reservation"
  end

  defp model_exchanges(path) do
    records = PreludeSearch.read_records(path)

    outputs =
      records
      |> Enum.filter(&(&1["record_type"] == "capability-output"))
      |> Map.new(&{get_in(&1, ["correlation", "capability_id"]), &1})

    records
    |> Enum.filter(
      &(&1["record_type"] == "capability-input" and
          get_in(&1, ["payload", "name"]) == "llm-request")
    )
    |> Enum.map(fn input ->
      id = get_in(input, ["correlation", "capability_id"])
      output = Map.fetch!(outputs, id)
      result = get_in(output, ["payload", "result"])

      response = replay_outcome(result)

      %{
        request_hash: get_in(input, ["payload", "request_hash"]),
        response: response
      }
    end)
  end
end
