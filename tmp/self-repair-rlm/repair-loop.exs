defmodule SelfRepairExperiment.OneShotLoop do
  @moduledoc false

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.MixCommandAdapter

  @max_artifact_bytes 1_048_576

  def run(config_path) do
    with {:ok, config} <- read_config(config_path),
         {:ok, resolved} <- resolve_config(config_path, config),
         :ok <- PrivateDirectory.create(resolved.out),
         {:ok, correction} <- run_correction(resolved),
         {:ok, report} <- finish(resolved, correction),
         :ok <- write_private_json(Path.join(resolved.out, "report.json"), report) do
      IO.puts(
        "repair loop finished: #{report["state"]}; private report: #{resolved.out}/report.json"
      )
    else
      {:error, reason} -> Mix.raise("repair loop failed: #{inspect(reason)}")
    end
  end

  defp read_config(path) do
    with {:ok, raw} <- read_bounded(path),
         {:ok, config} when is_map(config) <- StrictJSON.decode(raw),
         :ok <- validate_config(config) do
      {:ok, config}
    else
      _invalid -> {:error, :invalid_config}
    end
  end

  defp validate_config(
         %{
           "version" => 1,
           "feedback" => feedback,
           "out" => out,
           "correction" => correction,
           "repair" => repair
         } = config
       ) do
    valid? =
      exact_keys?(config, ~w(version feedback out correction repair)) and
        present_string?(feedback) and present_string?(out) and
        valid_command_config?(correction) and valid_repair_config?(repair)

    if valid?, do: :ok, else: {:error, :invalid_config}
  end

  defp validate_config(_config), do: {:error, :invalid_config}

  defp valid_command_config?(%{"manifest" => manifest} = config) do
    optional_paths = ~w(host_config env_file)

    exact_keys?(config, ["manifest" | optional_paths]) and present_string?(manifest) and
      Enum.all?(optional_paths, fn key ->
        not Map.has_key?(config, key) or present_string?(config[key])
      end)
  end

  defp valid_command_config?(_config), do: false

  defp valid_repair_config?(%{"manifest" => manifest, "validation_suite" => suite} = config) do
    optional_paths = ~w(host_config env_file)

    exact_keys?(config, ["manifest", "validation_suite" | optional_paths]) and
      present_string?(manifest) and present_string?(suite) and
      Enum.all?(optional_paths, fn key ->
        not Map.has_key?(config, key) or present_string?(config[key])
      end)
  end

  defp valid_repair_config?(_config), do: false

  defp exact_keys?(map, allowed), do: Map.keys(map) -- allowed == []

  defp present_string?(value), do: is_binary(value) and byte_size(value) > 0

  defp resolve_config(config_path, config) do
    base = config_path |> Path.expand() |> Path.dirname()

    resolved = %{
      feedback: resolve_path(base, config["feedback"]),
      out: resolve_path(base, config["out"]),
      correction: resolve_paths(base, config["correction"]),
      repair: resolve_paths(base, config["repair"])
    }

    if File.regular?(resolved.feedback) and File.regular?(resolved.correction.manifest) and
         File.regular?(resolved.repair.manifest) and
         File.regular?(resolved.repair.validation_suite) do
      {:ok, resolved}
    else
      {:error, :configured_artifact_unavailable}
    end
  end

  defp resolve_paths(base, values) do
    values
    |> Enum.map(fn {key, value} -> {String.to_atom(key), resolve_path(base, value)} end)
    |> Map.new()
  end

  defp resolve_path(base, path), do: Path.expand(path, base)

  defp run_correction(config) do
    correction_root = Path.join(config.out, "correction")
    inspection_root = Path.join(correction_root, "inspection")
    traces = Path.join(correction_root, "traces")
    output = Path.join(correction_root, "result.private.json")
    envelope = Path.join(correction_root, "envelope.private.json")

    with :ok <- PrivateDirectory.create(correction_root),
         :ok <- PrivateDirectory.create(inspection_root),
         :ok <- PrivateDirectory.create(traces) do
      with_staged_feedback(config.feedback, config.correction.manifest, fn staged ->
        args =
          [
            "run",
            config.correction.manifest,
            "--private-input",
            Path.relative_to(staged, Path.dirname(config.correction.manifest)),
            "--private-output",
            output,
            "--trace-dir",
            traces,
            "--inspect",
            Path.join(inspection_root, "run.inspection.jsonl"),
            "--envelope",
            envelope
          ] ++ host_args(config.correction)

        presentation = MixCommandAdapter.execute(args)
        result = read_json_value(output)
        run_id = read_run_id(envelope)

        {:ok,
         %{
           exit_status: presentation.exit_status,
           result: result,
           run_id: run_id,
           artifacts: %{
             "envelope" => "correction/envelope.private.json",
             "inspection" => "correction/inspection/run.inspection.jsonl",
             "result" => "correction/result.private.json",
             "traces" => "correction/traces"
           }
         }}
      end)
    else
      {:error, _reason} -> {:error, :correction_artifact_directory_unavailable}
    end
  end

  defp with_staged_feedback(feedback, manifest, callback) do
    # Application references intentionally exclude dot-prefixed paths, so this
    # owner-only run input cannot use PrivateDirectory.temporary_sibling/2.
    directory =
      Path.join(
        Path.dirname(manifest),
        "repair-feedback-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    staged = Path.join(directory, "feedback.json")

    with {:ok, content} <- read_bounded(feedback),
         :ok <- PrivateDirectory.create(directory),
         :ok <- write_private(staged, content) do
      try do
        callback.(staged)
      after
        _ = File.rm(staged)
        _ = File.rmdir(directory)
      end
    else
      _failure -> {:error, :feedback_staging_failed}
    end
  end

  defp finish(_config, %{exit_status: status} = correction) when status != 0 do
    {:ok, lifecycle_report("correction-failed", correction, "exit_status_#{status}")}
  end

  defp finish(
         _config,
         %{result: {:ok, %{"decision" => "insufficient-evidence"} = decision}} = correction
       ) do
    if valid_abstention?(decision) do
      {:ok, lifecycle_report("correction-abstained", correction, nil)}
    else
      {:ok, lifecycle_report("correction-failed", correction, "invalid_correction_decision")}
    end
  end

  defp finish(
         config,
         %{result: {:ok, %{"decision" => "propose-change"} = candidate}} = correction
       ) do
    candidate_report = Path.join(config.out, "candidate-report.private.json")

    with :ok <- write_private_json(candidate_report, candidate) do
      outcome = run_repair(config, correction, candidate_report)

      case outcome do
        :validated ->
          {:ok, lifecycle_report("candidate-validated", correction, nil, repair_artifacts())}

        {:rejected, reason} ->
          {:ok, lifecycle_report("candidate-rejected", correction, reason, repair_artifacts())}

        {:error, reason} ->
          {:ok, lifecycle_report("repair-failed", correction, reason, repair_artifacts())}
      end
    end
  end

  defp finish(_config, correction) do
    reason =
      case correction.result do
        {:error, _reason} -> "result_unavailable"
        {:ok, _value} -> "invalid_correction_decision"
      end

    {:ok, lifecycle_report("correction-failed", correction, reason)}
  end

  defp valid_abstention?(decision) do
    exact_keys?(decision, ~w(decision run_id cause evidence missing_evidence)) and
      present_string?(decision["run_id"]) and present_string?(decision["cause"]) and
      string_list?(decision["evidence"]) and string_list?(decision["missing_evidence"])
  end

  defp string_list?(values) when is_list(values) and values != [],
    do: Enum.all?(values, &present_string?/1)

  defp string_list?(_values), do: false

  defp run_repair(config, correction, candidate_report) do
    candidate_out = Path.join(config.out, "candidate")
    validation_out = Path.join(config.out, "validation")

    args =
      [
        config.repair.manifest,
        "--report",
        candidate_report,
        "--out",
        candidate_out,
        "--validation-suite",
        config.repair.validation_suite,
        "--validation-out",
        validation_out,
        "--allow-live-validation"
      ] ++ origin_args(correction.run_id) ++ host_args(config.repair)

    try do
      Mix.Task.reenable("ptc.repair")
      :ok = Mix.Tasks.Ptc.Repair.run(args)
      :validated
    rescue
      error in Mix.Error -> classify_repair_failure(validation_out, error.message)
    end
  end

  defp classify_repair_failure(validation_out, message) do
    case read_json_value(Path.join(validation_out, "feedback.json")) do
      {:ok, %{"state" => "candidate-rejected"}} -> {:rejected, "host_validation_failed"}
      _other -> {:error, "ptc_repair_failed: " <> message}
    end
  end

  defp lifecycle_report(state, correction, reason, repair_artifacts \\ nil) do
    report = %{
      "version" => 1,
      "kind" => "one-shot-repair-loop",
      "state" => state,
      "authority" => "host-authored",
      "reason" => reason,
      "correction" => %{
        "exit_status" => correction.exit_status,
        "run_id" => correction.run_id,
        "artifacts" => correction.artifacts
      }
    }

    if repair_artifacts,
      do: Map.put(report, "repair", %{"artifacts" => repair_artifacts}),
      else: report
  end

  defp repair_artifacts do
    %{
      "candidate_report" => "candidate-report.private.json",
      "candidate" => "candidate",
      "validation_feedback" => "validation/feedback.json",
      "validation_report" => "validation/report.json"
    }
  end

  defp origin_args(run_id) when is_binary(run_id) and byte_size(run_id) > 0,
    do: ["--origin-run-id", run_id]

  defp origin_args(_run_id), do: []

  defp host_args(config) do
    Enum.flat_map([:host_config, :env_file], fn key ->
      case Map.get(config, key) do
        nil -> []
        value -> ["--" <> String.replace(Atom.to_string(key), "_", "-"), value]
      end
    end)
  end

  defp read_run_id(envelope) do
    case read_json_value(envelope) do
      {:ok, %{"run_ref" => run_id}} when is_binary(run_id) -> run_id
      _other -> nil
    end
  end

  defp read_json_value(path) do
    with {:ok, raw} <- read_bounded(path), do: StrictJSON.decode(raw)
  end

  defp read_bounded(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          case IO.binread(device, @max_artifact_bytes + 1) do
            data when is_binary(data) and byte_size(data) <= @max_artifact_bytes -> {:ok, data}
            _other -> {:error, :artifact_too_large_or_unreadable}
          end
        after
          File.close(device)
        end

      {:error, _reason} ->
        {:error, :artifact_too_large_or_unreadable}
    end
  end

  defp write_private_json(path, value) do
    with {:ok, encoded} <- DeterministicJSON.encode(value), do: write_private(path, encoded)
  end

  defp write_private(path, content) do
    result =
      File.open(path, [:write, :binary, :exclusive], fn device ->
        with :ok <- File.chmod(path, 0o600), do: IO.binwrite(device, content)
      end)

    case result do
      {:ok, :ok} -> :ok
      _other -> {:error, :private_artifact_publication_failed}
    end
  end
end

case System.argv() do
  ["--", config_path] -> SelfRepairExperiment.OneShotLoop.run(config_path)
  [config_path] when config_path != "--" -> SelfRepairExperiment.OneShotLoop.run(config_path)
  _other -> Mix.raise("usage: mix run tmp/self-repair-rlm/repair-loop.exs -- CONFIG.json")
end
