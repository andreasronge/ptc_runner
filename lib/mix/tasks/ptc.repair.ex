defmodule Mix.Tasks.Ptc.Repair do
  @shortdoc "Materializes a generated repair and optionally runs a host-owned trial suite"
  @moduledoc """
  Consumes one structured `propose-change` result and materializes its complete
  replacement source through the normal G1-G4 candidate gate.

      mix ptc.repair MANIFEST --report repair.json --out candidate

  Materialization does not execute the candidate. A host may explicitly opt in
  to a live trial using a bounded validation suite:

      mix ptc.repair MANIFEST --report repair.json --out candidate \\
        --validation-suite private/suite.json \\
        --validation-out private/trial \\
        --allow-live-validation

  A suite contains one to 32 host-owned cases. Each case supplies `name`,
  exactly one JSON `input` or `private_input`, and an exact JSON `expected`
  result. Use `input` for non-secret regression vectors so the provider data
  class remains normal; `private_input` requires every selected provider to
  admit private input. Test inputs are staged owner-only and removed after the
  suite. Results, traces, inspection, envelopes, and the aggregate report are
  written beneath the new private trial directory. Result values are never
  printed. The directory also receives `feedback.json`, an owner-only handoff
  that separates the model-authored candidate from host-authored comparisons
  and retains each input, expected value, and available actual value. A later
  correction run can consume that file as private input without reconstructing
  validation facts in prose.

  `--allow-live-validation` is deliberately explicit: the application is run
  with its installed providers and can exercise their existing effects. The
  static candidate gate prevents authority widening; it cannot make a live
  application run transactional. Passing cases prove only the named inputs and
  providers. Promotion remains a separate human decision.
  """

  use Mix.Task

  alias Mix.Tasks.Ptc.Materialize
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CandidateArtifact
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.MixCommandAdapter

  @max_report_bytes 1_048_576
  @max_descriptor_bytes 65_536
  @max_source_bytes 1_048_576
  @max_suite_bytes 1_048_576
  @max_host_input_bytes 1_048_576
  @max_cases 32
  @case_name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

  @switches [
    report: :string,
    out: :string,
    origin_run_id: :string,
    host_config: :string,
    env_file: :string,
    validation_suite: :string,
    validation_out: :string,
    allow_live_validation: :boolean
  ]

  @usage "usage: mix ptc.repair MANIFEST --report REPORT.json --out DIR " <>
           "[--origin-run-id DEBUGGER_RUN_ID] [--host-config HOST.json] [--env-file FILE] " <>
           "[--validation-suite SUITE.json --validation-out PRIVATE_DIR " <>
           "--allow-live-validation]"

  @impl Mix.Task
  def run(argv) do
    start_core_application!()

    case OptionParser.parse(argv, strict: @switches) do
      {opts, [manifest], []} ->
        repair(manifest, opts)

      {_opts, _arguments, invalid} when invalid != [] ->
        Mix.raise("invalid ptc.repair options: #{inspect(invalid)}")

      _other ->
        Mix.raise(@usage)
    end
  end

  defp repair(manifest, opts) do
    with {:ok, report_path} <- required(opts, :report),
         {:ok, out} <- required(opts, :out),
         {:ok, report} <- read_json_map(report_path, @max_report_bytes, :invalid_repair_report),
         :ok <- validate_report(report),
         {:ok, validation} <- validation_config(opts),
         {:ok, base_digest} <- application_digest(manifest),
         :ok <- materialize(manifest, out, report, opts),
         :ok <- verify_published(out, report),
         :ok <- maybe_validate(manifest, out, report, base_digest, validation, opts) do
      :ok
    else
      {:error, :validation_requires_allow_live_validation} ->
        Mix.raise(
          "ptc.repair failed: --allow-live-validation is required because installed providers may have effects"
        )

      {:error, reason} ->
        Mix.raise("ptc.repair failed: #{inspect(reason)}")
    end
  end

  defp materialize(manifest, out, report, opts) do
    with {:ok, target} <- target_args(report) do
      with_private_source(out, report["candidate_source"], fn source_path ->
        args =
          [
            manifest,
            "--component",
            report["component_id"],
            "--out",
            out,
            "--source",
            source_path
          ] ++ provenance_args(opts) ++ target

        Mix.Task.reenable("ptc.materialize")
        Materialize.run(args)
      end)
    end
  end

  defp with_private_source(out, source, callback) do
    {directory, path} = PrivateDirectory.temporary_sibling(out, "candidate.clj")

    case PrivateDirectory.create(directory) do
      :ok ->
        outcome =
          case write_private(path, source) do
            :ok ->
              try do
                callback.(path)
                :ok
              rescue
                exception -> {:raised, exception, __STACKTRACE__}
              end

            {:error, _reason} ->
              {:error, :private_candidate_staging_failed}
          end

        # Every exit path sweeps and verifies: the staged file holds
        # model-authored source that was supposed to be gone, so residue is
        # a failure, not a footnote.
        _ = File.rm(path)
        _ = File.rmdir(directory)
        residue? = File.exists?(path) or File.exists?(directory)

        case outcome do
          {:raised, exception, stacktrace} ->
            if residue? do
              Mix.shell().error("candidate staging residue retained at #{directory}")
            end

            reraise exception, stacktrace

          _outcome when residue? ->
            {:error, :private_candidate_cleanup_failed}

          outcome ->
            outcome
        end

      {:error, _reason} ->
        {:error, :private_candidate_staging_failed}
    end
  end

  defp validate_report(%{"decision" => "propose-change"} = report) do
    required = ~w(run_id target_environment component_id base_source_hash candidate_source)

    cond do
      Map.keys(report) --
        ~w(decision run_id target_environment target_mission component_id function_id
             base_source_hash candidate_source cause invariant evidence validation_plan) != [] ->
        {:error, :invalid_repair_report}

      Enum.all?(required, &present_string?(report[&1])) ->
        :ok

      true ->
        {:error, :invalid_repair_report}
    end
  end

  defp validate_report(_report), do: {:error, :repair_not_proposed}

  defp target_args(%{"target_environment" => "workflow"}), do: {:ok, ["--workflow"]}

  defp target_args(%{"target_environment" => "mission", "target_mission" => mission})
       when is_binary(mission) and byte_size(mission) > 0,
       do: {:ok, ["--target-mission", mission]}

  defp target_args(_report), do: {:error, :invalid_repair_target}

  defp provenance_args(opts) do
    case Keyword.get(opts, :origin_run_id) do
      nil -> []
      run_id -> ["--origin-run-id", run_id]
    end
  end

  defp verify_published(out, report) do
    descriptor_path = Path.join(out, CandidateArtifact.descriptor_name())
    expected_source_hash = ComponentOverride.hash(report["candidate_source"])

    with {:ok, raw} <- read_bounded(descriptor_path, @max_descriptor_bytes),
         {:ok, descriptor} when is_map(descriptor) <- StrictJSON.decode(raw),
         {:ok, candidate} <-
           read_bounded(Path.join(out, CandidateArtifact.candidate_name()), @max_source_bytes) do
      cond do
        descriptor["base_source_hash"] != report["base_source_hash"] ->
          discard_or_raise!(out)

          Mix.raise(
            "ptc.repair failed: captured base hash does not match the currently selected component"
          )

        descriptor["source_hash"] != expected_source_hash or
            ComponentOverride.hash(candidate) != expected_source_hash ->
          discard_or_raise!(out)
          Mix.raise("ptc.repair failed: published candidate does not match the captured report")

        descriptor["source_hash"] == descriptor["base_source_hash"] ->
          discard_or_raise!(out)
          Mix.raise("ptc.repair failed: generated candidate is a no-op")

        true ->
          :ok
      end
    else
      _invalid ->
        discard_or_raise!(out)
        Mix.raise("ptc.repair failed: invalid candidate descriptor")
    end
  end

  defp validation_config(opts) do
    case {
      Keyword.get(opts, :validation_suite),
      Keyword.get(opts, :validation_out),
      Keyword.get(opts, :allow_live_validation, false)
    } do
      {nil, nil, false} ->
        {:ok, nil}

      {suite_path, out, true} when is_binary(suite_path) and is_binary(out) ->
        with {:ok, suite} <-
               read_json_map(suite_path, @max_suite_bytes, :invalid_validation_suite),
             :ok <- validate_suite(suite) do
          {:ok, %{suite: suite, out: out}}
        end

      {_suite, _out, false} ->
        {:error, :validation_requires_allow_live_validation}

      _other ->
        {:error, :incomplete_validation_options}
    end
  end

  defp validate_suite(%{"version" => 1, "cases" => cases} = suite)
       when is_list(cases) and length(cases) in 1..@max_cases do
    # Shape before names: a case that is not a map must be refused, not
    # crash name extraction.
    valid? =
      Map.keys(suite) -- ~w(version cases) == [] and
        Enum.all?(cases, &valid_case?/1) and
        unique_names?(cases)

    if valid?, do: :ok, else: {:error, :invalid_validation_suite}
  end

  defp validate_suite(_suite), do: {:error, :invalid_validation_suite}

  defp unique_names?(cases) do
    names = Enum.map(cases, & &1["name"])
    names == Enum.uniq(names)
  end

  defp valid_case?(%{"name" => name} = validation_case) do
    keys = Map.keys(validation_case) |> Enum.sort()

    keys in [~w(expected input name), ~w(expected name private_input)] and
      is_binary(name) and Regex.match?(@case_name, name)
  end

  defp valid_case?(_case), do: false

  defp maybe_validate(_manifest, _out, _report, _base_digest, nil, _opts) do
    Mix.shell().info("candidate materialized; no validation cases were run")
    :ok
  end

  defp maybe_validate(manifest, out, report, base_digest, validation, opts) do
    # The digest is rechecked on both sides of the suite: before, so trials
    # and their installed-provider effects never run against an application
    # that changed after the report was bound; after, so a mid-suite change
    # cannot certify results the final application never produced.
    host_inputs = host_input_digests(opts)

    with :ok <- create_validation_directory(validation.out),
         {:ok, pre_suite_digest} <- application_digest(manifest),
         :ok <- same_application(base_digest, pre_suite_digest),
         {:ok, results} <-
           run_cases(
             manifest,
             out,
             report,
             validation.out,
             validation.suite["cases"],
             host_inputs,
             opts
           ),
         :ok <- verify_published(out, report),
         :ok <- verify_host_inputs(opts, host_inputs),
         {:ok, final_digest} <- application_digest(manifest),
         :ok <- same_application(base_digest, final_digest),
         aggregate <- validation_report(report, opts, base_digest, results),
         feedback <- validation_feedback(report, opts, base_digest, results),
         :ok <- write_validation_report(validation.out, aggregate),
         :ok <- write_validation_feedback(validation.out, feedback) do
      failed = Enum.count(results, &(&1["status"] == "fail"))

      if failed == 0 do
        Mix.shell().info("candidate passed #{length(results)} host-owned validation cases")
        :ok
      else
        Mix.raise(
          "#{failed} of #{length(results)} host-owned validation cases failed; " <>
            "candidate and private evidence retained at #{validation.out}"
        )
      end
    end
  end

  defp run_cases(manifest, out, report, root, cases, host_inputs, opts) do
    input_root =
      Path.join(
        Path.dirname(Path.expand(manifest)),
        "validation-inputs-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    case PrivateDirectory.create(input_root) do
      :ok ->
        outcome =
          try do
            staged_descriptor = stage_candidate!(out, report, input_root)

            {:ok,
             cases
             |> Enum.with_index(1)
             |> Enum.map(fn {validation_case, index} ->
               verify_host_inputs!(opts, host_inputs)

               run_case(
                 manifest,
                 staged_descriptor,
                 root,
                 input_root,
                 validation_case,
                 index,
                 opts
               )
             end)}
          rescue
            exception -> {:raised, exception, __STACKTRACE__}
          end

        sweep_input_root(input_root)

        # Staged inputs can carry private values; residue the sweep could
        # not remove must fail the task rather than certify a passing suite.
        residue? = File.exists?(input_root)

        case outcome do
          {:raised, exception, stacktrace} ->
            if residue? do
              Mix.shell().error("private validation input residue retained at #{input_root}")
            end

            reraise exception, stacktrace

          _outcome when residue? ->
            {:error, :private_input_cleanup_failed}

          outcome ->
            outcome
        end

      {:error, _reason} ->
        Mix.raise("could not create private validation input staging")
    end
  end

  # The application digest guards the code under trial; these guard the
  # host-owned inputs every fresh case command rereads. A host configuration
  # or credential file that changes mid-suite would otherwise let one passing
  # report certify cases run under different installations.
  defp host_input_digests(opts) do
    Map.new([:host_config, :env_file], fn key ->
      {key, host_input_digest(Keyword.get(opts, key))}
    end)
  end

  defp host_input_digest(nil), do: nil

  # Bounded, regular-file reads only, like the canonical host-config and
  # env-file loaders: an oversized file or a FIFO must not hang or exhaust
  # the hash step before the run's own loader rejects it.
  defp host_input_digest(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, bytes} <- read_bounded(path, @max_host_input_bytes) do
      :crypto.hash(:sha256, bytes)
    else
      _other -> {:unreadable, path}
    end
  end

  defp verify_host_inputs(opts, reference) do
    if host_input_digests(opts) == reference do
      :ok
    else
      {:error, :validation_inputs_changed}
    end
  end

  defp verify_host_inputs!(opts, reference) do
    case verify_host_inputs(opts, reference) do
      :ok ->
        :ok

      {:error, _reason} ->
        Mix.raise("ptc.repair failed: a host configuration input changed during validation")
    end
  end

  # Every case executes the exact candidate the report named: the published
  # pair is copied into the owner-only staging root and re-verified there,
  # so a concurrent replacement of the published artifact cannot put ungated
  # source under a passing report.
  defp stage_candidate!(out, report, input_root) do
    for name <- [CandidateArtifact.descriptor_name(), CandidateArtifact.candidate_name()] do
      with {:ok, bytes} <- read_bounded(Path.join(out, name), @max_source_bytes),
           :ok <- write_private(Path.join(input_root, name), bytes) do
        :ok
      else
        _failure -> Mix.raise("ptc.repair failed: candidate staging for validation failed")
      end
    end

    :ok = verify_published(input_root, report)
    Path.join(input_root, CandidateArtifact.descriptor_name())
  end

  defp sweep_input_root(input_root) do
    case File.ls(input_root) do
      {:ok, names} -> Enum.each(names, &File.rm(Path.join(input_root, &1)))
      {:error, _reason} -> :ok
    end

    _ = File.rmdir(input_root)
  end

  defp run_case(manifest, descriptor, root, input_root, validation_case, index, opts) do
    prefix = index |> Integer.to_string() |> String.pad_leading(2, "0")
    {input_switch, input_class, input_value} = validation_input(validation_case)
    input = Path.join(input_root, "#{prefix}.input.json")
    input_argument = Path.relative_to(input, Path.dirname(Path.expand(manifest)))
    case_root = Path.join(root, prefix)
    inspection_root = Path.join(case_root, "inspection")
    output = Path.join(case_root, "result.private.json")
    inspection = Path.join(inspection_root, "run.inspection.jsonl")
    envelope = Path.join(case_root, "envelope.private.json")
    traces = Path.join(case_root, "traces")

    :ok = write_private_json(input, input_value)
    :ok = create_private_child(case_root)
    :ok = create_private_child(inspection_root)
    :ok = create_private_child(traces)

    args =
      [
        "run",
        manifest,
        "--component-override-descriptor",
        descriptor,
        input_switch,
        input_argument,
        "--private-output",
        output,
        "--trace-dir",
        traces,
        "--inspect",
        inspection,
        "--envelope",
        envelope
      ] ++ host_args(opts)

    presentation = MixCommandAdapter.execute(args)
    expected = validation_case["expected"]

    result = read_json_value(output)

    # Strict equality: 42 and 42.0 are different JSON values, and an exact
    # expected result must not certify a different representation.
    {status, reason} =
      case {presentation.exit_status, result} do
        {0, {:ok, value}} when value === expected -> {"pass", nil}
        {0, {:ok, _value}} -> {"fail", "result_mismatch"}
        {0, {:error, _reason}} -> {"fail", "result_unavailable"}
        {exit_status, _result} -> {"fail", "exit_status_#{exit_status}"}
      end

    summary = %{
      "name" => validation_case["name"],
      "input_class" => input_class,
      "status" => status,
      "reason" => reason,
      "artifacts" => %{
        "envelope" => Path.relative_to(envelope, root),
        "inspection" => Path.relative_to(inspection, root),
        "result" => Path.relative_to(output, root),
        "traces" => Path.relative_to(traces, root)
      }
    }

    Map.put(summary, :feedback, %{
      "input" => input_value,
      "expected" => expected,
      "actual" => feedback_actual(result)
    })
  end

  defp validation_input(%{"input" => input}), do: {"--input", "normal", input}

  defp validation_input(%{"private_input" => input}),
    do: {"--private-input", "private", input}

  defp validation_report(report, opts, base_digest, results) do
    failed? = Enum.any?(results, &(&1["status"] == "fail"))

    %{
      "version" => 1,
      "outcome" => if(failed?, do: "fail", else: "pass"),
      "diagnosed_run_id" => report["run_id"],
      "authoring_run_id" => Keyword.get(opts, :origin_run_id),
      "base_application_content_digest" => base_digest,
      "candidate_source_hash" => ComponentOverride.hash(report["candidate_source"]),
      "cases" => Enum.map(results, &Map.delete(&1, :feedback))
    }
  end

  defp validation_feedback(report, opts, base_digest, results) do
    failed? = Enum.any?(results, &(&1["status"] == "fail"))
    outcome = if(failed?, do: "fail", else: "pass")

    %{
      "version" => 1,
      "kind" => "repair-validation-feedback",
      "state" => if(failed?, do: "candidate-rejected", else: "candidate-validated"),
      "candidate" => %{
        "authority" => "model-authored-untrusted",
        "value" => report
      },
      "validation" => %{
        "authority" => "host-authored",
        "outcome" => outcome,
        "diagnosed_run_id" => report["run_id"],
        "authoring_run_id" => Keyword.get(opts, :origin_run_id),
        "base_application_content_digest" => base_digest,
        "candidate_source_hash" => ComponentOverride.hash(report["candidate_source"]),
        "cases" => Enum.map(results, &validation_feedback_case/1)
      }
    }
  end

  defp validation_feedback_case(%{:feedback => comparison} = result) do
    result
    |> Map.delete(:feedback)
    |> Map.merge(comparison)
  end

  defp feedback_actual({:ok, value}), do: %{"state" => "available", "value" => value}
  defp feedback_actual({:error, _reason}), do: %{"state" => "unavailable"}

  defp write_validation_report(root, report) do
    with {:ok, encoded} <- DeterministicJSON.encode(report),
         do: write_private(Path.join(root, "report.json"), encoded)
  end

  defp write_validation_feedback(root, feedback) do
    with {:ok, encoded} <- DeterministicJSON.encode(feedback),
         do: write_private(Path.join(root, "feedback.json"), encoded)
  end

  defp host_args(opts) do
    Enum.flat_map([:host_config, :env_file], fn key ->
      case Keyword.get(opts, key) do
        nil -> []
        value -> ["--" <> String.replace(Atom.to_string(key), "_", "-"), value]
      end
    end)
  end

  defp application_digest(manifest) do
    case ApplicationPackage.request_directory(manifest, result_projection: :native) do
      {:ok, request} -> {:ok, "sha256:" <> request.package.application_content_digest}
      {:error, reason} -> {:error, {:application_unavailable, reason}}
    end
  end

  defp same_application(digest, digest), do: :ok
  defp same_application(_before, _after), do: {:error, :application_changed_during_validation}

  defp create_validation_directory(path) do
    case PrivateDirectory.create(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :validation_destination_unavailable}
    end
  end

  defp create_private_child(path) do
    with :ok <- File.mkdir(path), do: File.chmod(path, 0o700)
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

  defp read_json_map(path, limit, reason) do
    with {:ok, raw} <- read_bounded(path, limit),
         {:ok, decoded} when is_map(decoded) <- StrictJSON.decode(raw) do
      {:ok, decoded}
    else
      _other -> {:error, reason}
    end
  end

  defp read_json_value(path) do
    with {:ok, raw} <- read_bounded(path, @max_report_bytes), do: StrictJSON.decode(raw)
  end

  defp read_bounded(path, limit) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          case IO.binread(device, limit + 1) do
            data when is_binary(data) and byte_size(data) <= limit -> {:ok, data}
            _other -> {:error, :artifact_too_large_or_unreadable}
          end
        after
          File.close(device)
        end

      {:error, _reason} ->
        {:error, :artifact_too_large_or_unreadable}
    end
  end

  defp discard_or_raise!(out) do
    case CandidateArtifact.discard(out) do
      :ok ->
        :ok

      {:error, :candidate_cleanup_failed} ->
        Mix.raise("candidate cleanup failed; residue retained")
    end
  end

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_option, key}}
      value -> {:ok, value}
    end
  end

  defp present_string?(value),
    do: is_binary(value) and byte_size(String.trim(value)) > 0

  defp start_core_application! do
    case Application.ensure_all_started(:ptc_runner) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("could not start PtcRunner: #{inspect(reason)}")
    end
  end
end
