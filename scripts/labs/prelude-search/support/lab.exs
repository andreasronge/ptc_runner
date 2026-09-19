defmodule PtcRunner.Labs.PreludeSearch do
  @moduledoc false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.InspectionArtifact.Codec
  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ResultIdentity
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Labs.PreludeSearch.Inputs
  alias PtcRunner.Labs.PreludeSearch.Mutations

  @subjects ~w(intervals normaliser reconciliation)
  @entries %{
    "intervals" => "lab.intervals/merge-with-tolerance",
    "normaliser" => "lab.normaliser/normalise",
    "reconciliation" => "lab.reconciliation/reconcile"
  }

  def subjects, do: @subjects

  def instance(subject, seed) when subject in @subjects and is_integer(seed) do
    source = File.read!(Path.expand("../subjects/#{subject}.clj", __DIR__))
    {mutated, truth} = Mutations.apply(source, subject, seed)
    {:ok, registry} = ProviderRegistry.new()

    root =
      Path.join(System.tmp_dir!(), "ptc-search-instance-#{System.unique_integer([:positive])}")

    :ok = prepare_output(root)

    try do
      oracle = freeze(root, "oracle", subject, source, registry.installed_limits)
      observed = freeze(root, "observed", subject, mutated, registry.installed_limits)

      rows =
        Enum.map(Inputs.generate(subject, seed, 80), fn input ->
          expected = execute_value(oracle, input, registry)
          actual = execute_value(observed, input, registry)

          %{
            "input" => input,
            "oracle" => expected,
            "observed" => actual,
            "reached_mutation" => expected != actual
          }
        end)

      {visible, hidden} = Enum.split(rows, 40)
      [selection, final] = Enum.chunk_every(hidden, 20)

      input_sets =
        Enum.map([visible, selection, final], &MapSet.new(&1, fn row -> row["input"] end))

      [v, s, f] = input_sets

      unless MapSet.disjoint?(v, s) and MapSet.disjoint?(v, f) and MapSet.disjoint?(s, f),
        do: raise("overlapping input partitions for #{subject}/#{seed}")

      unless Enum.all?([selection, final], &Enum.any?(&1, fn row -> row["reached_mutation"] end)),
        do: raise("unobservable mutation for #{subject}/#{seed}")

      %{
        subject: subject,
        seed: seed,
        source: source,
        mutated_source: mutated,
        ground_truth: truth,
        visible: visible,
        selection: selection,
        final: final
      }
    after
      ProviderRegistry.close(registry)
      File.rm_rf!(root)
    end
  end

  def select_candidates(instance, sources, output) do
    :ok = prepare_output(output)
    {:ok, registry} = ProviderRegistry.new()

    {missions, candidates} =
      sources
      |> Enum.with_index()
      |> Enum.reduce({%{}, []}, fn {source, index}, {missions, candidates} ->
        name = "candidate-#{index}"
        valid = compilable?(instance.subject, source)

        missions =
          if valid do
            File.write!(Path.join(output, name <> ".clj"), source)

            Map.put(missions, name, %{
              "components" => [%{"id" => "lab." <> instance.subject, "path" => name <> ".clj"}]
            })
          else
            missions
          end

        {missions, candidates ++ [%{"index" => index, "mission" => name, "valid" => valid}]}
      end)

    input = %{
      "candidates" => candidates,
      "selection" => instance.selection,
      "final" => instance.final,
      "program" => "(" <> Map.fetch!(@entries, instance.subject) <> " data/params)"
    }

    File.write!(Path.join(output, "check.clj"), selection_workflow())

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [
          %{"id" => "lab.check", "path" => "check.clj", "dependencies" => ["kernel"]},
          %{"library" => "kernel"}
        ],
        "entry" => "lab.check/run"
      },
      "missions" => missions,
      "input" => %{"value" => %{}},
      "limits" => %{"subordinate_evaluations" => 128},
      "providers" => %{"workflow" => [], "mission" => []}
    }

    path = Path.join(output, "ptc.json")
    File.write!(path, pretty_json(manifest))

    try do
      {:ok, saved} =
        ApplicationPackage.request_directory(path, installed_limits: registry.installed_limits)

      {:ok, ref} = CommandRunRef.generate()
      {:ok, request} = request(saved.package, input, ref, true)

      {:ok, built} =
        RunBuilder.build(request, registry,
          trace_path: Path.join(output, "selection.jsonl"),
          inspect: Path.join(output, "selection.ptcins")
        )

      {:ok, result} = execute_and_publish(built)
      File.write!(Path.join(output, "result.json"), pretty_json(result))
      result
    after
      ProviderRegistry.close(registry)
    end
  end

  defp compilable?(subject, source) when is_binary(source) do
    with {:ok, component} <- PtcRunner.Kernel.Component.new(id: "lab." <> subject, source: source),
         {:ok, _bundle} <- PtcRunner.Kernel.compile_bundle([component]),
         do: true,
         else: (_ -> false)
  end

  defp compilable?(_subject, _source), do: false

  defp selection_workflow do
    ~S"""
    (ns lab.check "Recorded candidate selection and final evaluation.")
    (defn- check [candidate cases source]
      (if (get candidate "valid")
        (every? true?
          (mapv (fn [row]
            (let [result (kernel/eval-source-with (get candidate "mission") source (get row "input"))]
              (and (= :returned (get result :outcome)) (= (get row "oracle") (get result :value))))) cases))
        false))
    (defn run [input]
      (let [checked (mapv (fn [candidate]
                       (assoc candidate "passed" (check candidate (get input "selection") (get input "program"))))
                     (get input "candidates"))
            selected (first (filter #(get % "passed") checked))
            final-pass (if selected (check selected (get input "final") (get input "program")) false)]
        (return {"selection" checked "selected" (get selected "index") "final_pass" final-pass})))
    """
  end

  def run(opts) when is_list(opts) do
    output = opts |> Keyword.fetch!(:output) |> Path.expand()
    subjects = Keyword.get(opts, :subjects, @subjects)
    seed = Keyword.get(opts, :seed, 20_260_917)
    executions = Keyword.get(opts, :executions, 100)

    with :ok <- validate(subjects, executions),
         :ok <- prepare_output(output),
         {:ok, registry} <- ProviderRegistry.new() do
      results = Enum.map(subjects, &run_subject(&1, seed, executions, output, registry))
      {:ok, results}
    end
  end

  defp validate(subjects, executions) do
    cond do
      subjects == [] or Enum.any?(subjects, &(&1 not in @subjects)) ->
        {:error, :invalid_subject}

      not is_integer(executions) or executions < 2 or rem(executions, 2) != 0 ->
        {:error, :executions_must_be_a_positive_even_integer}

      true ->
        :ok
    end
  end

  defp prepare_output(output) do
    with :ok <- File.mkdir_p(output), do: File.chmod(output, 0o700)
  end

  defp run_subject(subject, seed, executions, output, registry) do
    subject_dir = Path.join(output, subject)
    :ok = File.mkdir!(subject_dir)
    :ok = File.chmod(subject_dir, 0o700)

    source_path = Path.expand("../subjects/#{subject}.clj", __DIR__)
    source = File.read!(source_path)
    {mutated, ground_truth} = Mutations.apply(source, subject, seed)
    File.write!(Path.join(subject_dir, "ground-truth.json"), pretty_json(ground_truth))

    oracle = freeze(subject_dir, "oracle", subject, source, registry.installed_limits)
    observed = freeze(subject_dir, "observed", subject, mutated, registry.installed_limits)
    input_count = div(executions, 2)
    visible_count = div(input_count * 4, 5)

    records =
      subject
      |> Inputs.generate(seed, input_count)
      |> Enum.with_index()
      |> Enum.flat_map(fn {input, index} ->
        split = if index < visible_count, do: "visible", else: "held-out"
        oracle_record = execute_recorded(oracle, input, subject_dir, split, "oracle", registry)

        observed_record =
          execute_recorded(observed, input, subject_dir, split, "observed", registry)

        reached = oracle_record.result_hash != observed_record.result_hash

        [
          Map.put(oracle_record, :reached_mutation, reached),
          Map.put(observed_record, :reached_mutation, reached)
        ]
      end)

    File.write!(Path.join(subject_dir, "executions.json"), pretty_json(records))

    replay_subject(subject_dir, registry)
  end

  def replay(output) do
    {:ok, registry} = ProviderRegistry.new()

    try do
      results = output |> Path.join("*/executions.json") |> Path.wildcard()
      if results == [], do: raise("no recorded executions under #{output}")
      {:ok, Enum.map(results, &replay_subject(Path.dirname(&1), registry))}
    after
      ProviderRegistry.close(registry)
    end
  end

  defp replay_subject(subject_dir, registry) do
    records = subject_dir |> Path.join("executions.json") |> File.read!() |> Jason.decode!()

    {equal, unequal, elapsed_us} =
      Enum.reduce(records, {0, [], 0}, fn record, {equal, unequal, elapsed} ->
        path = Path.join(subject_dir, record["inspection_path"])
        bytes = File.read!(path)

        if digest(bytes) != record["inspection_hash"],
          do: raise("inspection artifact changed: #{path}")

        captured = inspection_records(bytes)
        input = Enum.find(captured, &(&1["record_type"] == "run-input"))
        if is_nil(input), do: raise("inspection artifact has no run-input: #{path}")
        payload = input["payload"]
        {:ok, input_hash} = ResultIdentity.strict_json_hash(payload["value"])
        if input_hash != payload["input_hash"], do: raise("input identity changed: #{path}")
        result = Enum.find(captured, &(&1["record_type"] == "run-result"))
        expected = result["payload"]["result_hash"]
        manifest = Path.join([subject_dir, record["variant"] <> "-bundle", "ptc.json"])

        {:ok, saved} =
          ApplicationPackage.request_directory(manifest,
            installed_limits: registry.installed_limits
          )

        started = System.monotonic_time(:microsecond)

        replay_hash =
          execute_replay(
            %{package: saved.package},
            payload["value"],
            registry,
            record["bundle_hash"]
          )

        duration = System.monotonic_time(:microsecond) - started

        if replay_hash == expected do
          {equal + 1, unequal, elapsed + duration}
        else
          finding = %{
            run_ref: record["run_ref"],
            recorded_hash: expected,
            replay_hash: replay_hash
          }

          {equal, [finding | unequal], elapsed + duration}
        end
      end)

    %{
      subject: Path.basename(subject_dir),
      executions: length(records),
      equal: equal,
      unequal: Enum.reverse(unequal),
      milliseconds_per_reexecution: Float.round(elapsed_us / length(records) / 1_000, 3),
      output: subject_dir
    }
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp freeze(subject_dir, variant, subject, source, installed_limits) do
    directory = Path.join(subject_dir, variant <> "-bundle")
    :ok = File.mkdir!(directory)
    File.write!(Path.join(directory, "subject.clj"), source)
    File.write!(Path.join(directory, "input.json"), "{}\n")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "lab.#{subject}", "path" => "subject.clj"}],
        "entry" => Map.fetch!(@entries, subject)
      },
      "input" => %{"path" => "input.json"},
      "providers" => %{"workflow" => [], "mission" => []},
      "limits" => %{"evaluation_timeout_ms" => 5_000, "run_duration_ms" => 10_000},
      "labels" => %{"name" => "prelude-search-#{subject}-#{variant}"}
    }

    manifest_path = Path.join(directory, "ptc.json")
    File.write!(manifest_path, pretty_json(manifest))

    {:ok, request} =
      ApplicationPackage.request_directory(manifest_path, installed_limits: installed_limits)

    %{package: request.package}
  end

  defp execute_recorded(frozen, input, subject_dir, split, variant, registry) do
    {:ok, run_ref} = CommandRunRef.generate()
    artifacts = Path.join(subject_dir, "artifacts")
    trace_dir = private_child!(artifacts, "traces")
    inspection_dir = private_child!(artifacts, "inspection")
    trace = Path.join(trace_dir, run_ref <> ".jsonl")
    inspection = Path.join(inspection_dir, run_ref <> ".ptcins")

    {:ok, request} = request(frozen.package, input, run_ref, true)
    {:ok, built} = RunBuilder.build(request, registry, trace_path: trace, inspect: inspection)
    {:ok, _result} = execute_and_publish(built)
    result_hash = recorded_result_hash!(inspection)

    %{
      run_ref: run_ref,
      variant: variant,
      split: split,
      reached_mutation: false,
      result_hash: result_hash,
      bundle_hash: built.config.workflow_environment.bundle.hash,
      inspection_hash: digest(File.read!(inspection)),
      trace_path: Path.relative_to(trace, subject_dir),
      inspection_path: Path.relative_to(inspection, subject_dir)
    }
  end

  defp execute_replay(frozen, input, registry, expected_bundle_hash) do
    {:ok, run_ref} = CommandRunRef.generate()
    {:ok, request} = request(frozen.package, input, run_ref, false)
    {:ok, built} = RunBuilder.build(request, registry)

    if built.config.workflow_environment.bundle.hash != expected_bundle_hash do
      RunBuilder.close(built)
      raise "bundle identity changed"
    end

    {:ok, result} = execute_and_publish(built)
    {:ok, hash} = ResultIdentity.strict_json_hash(result)
    hash
  end

  defp execute_value(frozen, input, registry) do
    {:ok, run_ref} = CommandRunRef.generate()
    {:ok, request} = request(frozen.package, input, run_ref, false)
    {:ok, built} = RunBuilder.build(request, registry)
    {:ok, value} = execute_and_publish(built)
    value
  end

  defp request(package, input, run_ref, inspect?) do
    with {:ok, execution_input} <- ExecutionInput.new(input, :normal, package.contracts.input),
         {:ok, policy} <-
           ExecutionPolicy.new(
             event_policy: package.events.policy,
             run_id: run_ref,
             trace_id: run_ref,
             inspection_capture: inspect?,
             result_projection: :json
           ),
         do: RunRequest.new(package, execution_input, policy)
  end

  defp execute_and_publish(%{publication_authority: authority} = built) do
    case RunBuilder.execute_built(built) do
      {:ok, outcome} ->
        result =
          case RunBuilder.publish_execution_report(outcome, authority) do
            {:ok, %{result: {:ok, %Result{value: value}}}} -> {:ok, value}
            {:ok, %{result: {:error, reason}}} -> {:error, reason}
            {:error, report} -> {:error, report}
          end

        :ok = PublicationAuthority.close(authority)
        result

      {:error, reason} ->
        :ok = PublicationAuthority.abort(authority)
        {:error, reason}
    end
  end

  defp recorded_result_hash!(path) do
    path
    |> File.read!()
    |> inspection_records()
    |> Enum.find_value(fn
      %{"record_type" => "run-result", "payload" => %{"result_hash" => hash}} -> hash
      _record -> nil
    end)
    |> case do
      nil -> raise "inspection artifact has no run-result: #{path}"
      hash -> hash
    end
  end

  def read_records(path), do: path |> File.read!() |> inspection_records()

  defp inspection_records(bytes) do
    evidence_bytes = byte_size(bytes) - Format.header_size() - Format.footer_size()

    <<_header::binary-size(16), evidence::binary-size(^evidence_bytes),
      _footer::binary-size(192)>> = bytes

    decode_frames(evidence, [])
  end

  defp decode_frames(<<>>, records), do: Enum.reverse(records)

  defp decode_frames(
         <<length::unsigned-big-64, payload::binary-size(length), rest::binary>>,
         records
       ) do
    {:ok, record} = Codec.decode_record(payload)
    decode_frames(rest, [record | records])
  end

  defp private_child!(root, child) do
    :ok = File.mkdir_p(root)
    :ok = File.chmod(root, 0o700)
    path = Path.join(root, child)
    :ok = File.mkdir_p(path)
    :ok = File.chmod(path, 0o700)
    path
  end

  defp pretty_json(value), do: Jason.encode_to_iodata!(value, pretty: true)
end
