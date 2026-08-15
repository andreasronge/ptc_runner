defmodule Mix.Tasks.Ptc.Repair do
  @shortdoc "Materializes and validates one structured generated repair"
  @moduledoc """
  Consumes a structured `propose-change` result, materializes its complete
  replacement source through the normal G1-G4 gate, verifies that the captured
  base hash still names the selected component, and executes one fresh run with
  the resulting override:

      mix ptc.repair MANIFEST --report repair.json --out candidate \\
        --origin-run-id debugger-run-id \\
        --host-config ptc-host.json --env-file .env \\
        --trace-dir validation-traces --inspect validation.inspection.jsonl

  The report supplies `target_environment`, `target_mission`, `component_id`,
  `base_source_hash`, `candidate_source`, and the diagnosed `run_id`. It does
  not supply paths, authoring provenance, host configuration, credentials,
  validation inputs, output destinations, or promotion authority; those remain
  host-owned arguments. Pass the debugger's run id separately with
  `--origin-run-id` when it should be recorded as provenance.

  A successful validation leaves the private candidate directory ready for an
  operator to review. Nothing is installed or promoted automatically. A stale
  base is discarded. A candidate that passes the static gate but fails its
  fresh run is retained for diagnosis and the task exits with the validation
  command's failure status.
  """

  use Mix.Task

  alias Mix.Tasks.Ptc.Materialize
  alias PtcRunner.Kernel.CandidateArtifact
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.MixCommandAdapter

  @max_report_bytes 1_048_576
  @max_descriptor_bytes 65_536

  @switches [
    report: :string,
    out: :string,
    origin_run_id: :string,
    host_config: :string,
    input: :string,
    private_input: :string,
    trace_dir: :string,
    output: :string,
    private_output: :string,
    inspect: :string,
    env_file: :string,
    envelope: :string
  ]

  @forwarded ~w(
    host_config
    input
    private_input
    trace_dir
    output
    private_output
    inspect
    env_file
    envelope
  )a

  @usage "usage: mix ptc.repair MANIFEST --report REPORT.json --out DIR " <>
           "[--origin-run-id ID] " <>
           "[--host-config HOST.json] [--input INPUT.json | --private-input INPUT.json] " <>
           "[--trace-dir DIR] [--output RESULT.json | --private-output RESULT.json] " <>
           "[--inspect INSPECTION.jsonl] [--env-file FILE] [--envelope ENVELOPE.json]"

  @impl Mix.Task
  def run(argv) do
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
         {:ok, report} <- read_report(report_path),
         {:ok, materialize_args} <-
           materialize_args(manifest, report_path, out, report, opts) do
      materialize!(materialize_args)
      verify_published!(out, report)
      validate!(manifest, out, opts)
    else
      {:error, reason} -> Mix.raise("ptc.repair failed: #{inspect(reason)}")
    end
  end

  defp materialize!(args) do
    Mix.Task.reenable("ptc.materialize")
    Materialize.run(args)
  end

  defp materialize_args(manifest, report_path, out, report, opts) do
    with :ok <- validate_report(report),
         {:ok, target} <- target_args(report) do
      {:ok,
       [
         manifest,
         "--component",
         report["component_id"],
         "--out",
         out,
         "--from-result",
         report_path,
         "--result-pointer",
         "/candidate_source"
       ] ++ provenance_args(opts) ++ target}
    end
  end

  defp validate_report(%{"decision" => "propose-change"} = report) do
    required = ~w(run_id target_environment component_id base_source_hash candidate_source)

    if Enum.all?(required, &present_string?(report[&1])) do
      :ok
    else
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

  defp verify_published!(out, report) do
    descriptor_path = Path.join(out, CandidateArtifact.descriptor_name())

    with {:ok, raw} <- read_bounded(descriptor_path, @max_descriptor_bytes),
         {:ok, descriptor} <- StrictJSON.decode(raw) do
      cond do
        descriptor["base_source_hash"] != report["base_source_hash"] ->
          CandidateArtifact.discard(out)

          Mix.raise(
            "ptc.repair failed: captured base hash does not match the currently selected component"
          )

        descriptor["source_hash"] == descriptor["base_source_hash"] ->
          CandidateArtifact.discard(out)
          Mix.raise("ptc.repair failed: generated candidate is a no-op")

        true ->
          :ok
      end
    else
      {:error, reason} ->
        CandidateArtifact.discard(out)
        Mix.raise("ptc.repair failed: invalid candidate descriptor: #{inspect(reason)}")
    end
  end

  defp validate!(manifest, out, opts) do
    descriptor = Path.join(out, CandidateArtifact.descriptor_name())

    args =
      ["run", manifest, "--component-override-descriptor", descriptor] ++
        forwarded_args(opts)

    presentation = MixCommandAdapter.execute(args)
    write_output(presentation.stdout, presentation.stderr)

    if presentation.exit_status == 0 do
      Mix.shell().info("candidate validated in a fresh run: #{descriptor}")
    else
      Mix.raise(
        "candidate passed materialization but fresh validation failed; candidate retained at #{out}",
        exit_status: presentation.exit_status
      )
    end
  end

  defp forwarded_args(opts) do
    Enum.flat_map(@forwarded, fn key ->
      case Keyword.get(opts, key) do
        nil -> []
        value -> ["--" <> String.replace(Atom.to_string(key), "_", "-"), value]
      end
    end)
  end

  defp read_report(path) do
    with {:ok, raw} <- read_bounded(path, @max_report_bytes),
         {:ok, report} when is_map(report) <- StrictJSON.decode(raw) do
      {:ok, report}
    else
      _other -> {:error, :invalid_repair_report}
    end
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

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_option, key}}
      value -> {:ok, value}
    end
  end

  defp present_string?(value),
    do: is_binary(value) and byte_size(String.trim(value)) > 0

  defp write_output(stdout, stderr) do
    if stdout != "", do: IO.write(stdout)
    if stderr != "", do: IO.write(:stderr, stderr)
  end
end
