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

    {equal, unequal, elapsed_us} =
      Enum.reduce(records, {0, [], 0}, fn record, {equal, unequal, elapsed} ->
        input = record.input_path |> File.read!() |> Jason.decode!()
        frozen = if record.variant == "oracle", do: oracle, else: observed
        started = System.monotonic_time(:microsecond)
        replay_hash = execute_replay(frozen, input, registry)
        duration = System.monotonic_time(:microsecond) - started

        if replay_hash == record.result_hash do
          {equal + 1, unequal, elapsed + duration}
        else
          finding = %{
            run_ref: record.run_ref,
            recorded_hash: record.result_hash,
            replay_hash: replay_hash
          }

          {equal, [finding | unequal], elapsed + duration}
        end
      end)

    %{
      subject: subject,
      executions: executions,
      equal: equal,
      unequal: Enum.reverse(unequal),
      milliseconds_per_reexecution: Float.round(elapsed_us / executions / 1_000, 3),
      output: subject_dir
    }
  end

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
    input_dir = private_child!(artifacts, "inputs")
    trace = Path.join(trace_dir, run_ref <> ".jsonl")
    inspection = Path.join(inspection_dir, run_ref <> ".ptcins")
    input_path = Path.join(input_dir, run_ref <> ".input.json")
    File.write!(input_path, pretty_json(input))

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
      input_path: input_path,
      trace_path: trace,
      inspection_path: inspection
    }
  end

  defp execute_replay(frozen, input, registry) do
    {:ok, run_ref} = CommandRunRef.generate()
    {:ok, request} = request(frozen.package, input, run_ref, false)
    {:ok, built} = RunBuilder.build(request, registry)
    {:ok, result} = execute_and_publish(built)
    {:ok, hash} = ResultIdentity.strict_json_hash(result)
    hash
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
