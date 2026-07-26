defmodule Mix.Tasks.Ptc.Run do
  @shortdoc "Runs one strict PTC Kernel manifest"
  @moduledoc """
  Runs one V1 Kernel manifest through the shared run builder.

      mix ptc.run MANIFEST
      mix ptc.run MANIFEST --mission alternate-input.json
      mix ptc.run MANIFEST --private-mission private-input.json --private-output result.json
      mix ptc.run MANIFEST --trace traces/run.jsonl
      mix ptc.run MANIFEST --trace traces/run.jsonl --inspect traces/run.inspection.jsonl
      mix ptc.run MANIFEST --output results/answer.json
      mix ptc.run MANIFEST --private-output results/answer.private.json
      mix ptc.run MANIFEST --host-config ptc-host.json
      mix ptc.run MANIFEST --host-config ptc-host.json --check

  `--output` and `--private-output` write the result value as a standalone
  JSON artifact so a later run can consume it without scraping stdout. Both
  refuse to overwrite an existing destination and are mutually exclusive.
  `--private-mission` is mutually exclusive with `--mission`, loads the same
  manifest-confined JSON shape, and classifies the entire run before provider
  activity.

  A private-event run may not publish. It suppresses its value on stdout,
  rejects `--output`, and requires `--private-output` to keep the value at all.

  `--host-config` installs the exact provider aliases declared by one strict,
  bounded host document. `--check` assembles and discovers those providers,
  prints a safe resolved view, and closes every resource without invoking the
  workflow or a model. A provider-bearing manifest requires `--host-config`;
  provider-free manifests continue to run without one.
  """
  use Mix.Task

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder

  @usage "usage: mix ptc.run MANIFEST [--mission PATH | --private-mission PATH] " <>
           "[--trace PATH] [--inspect PATH] " <>
           "[--output PATH | --private-output PATH] [--host-config PATH] [--check]"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    with {opts, [manifest], []} <-
           OptionParser.parse(args,
             strict: [
               mission: :string,
               private_mission: :string,
               trace: :string,
               inspect: :string,
               output: :string,
               private_output: :string,
               host_config: :string,
               check: :boolean
             ],
             aliases: [m: :mission, t: :trace]
           ),
         :ok <- exclusive_destinations(opts),
         :ok <- exclusive_mission_inputs(opts),
         :ok <- check_options(opts),
         {:ok, registry, host} <- registry(opts) do
      result =
        if Keyword.get(opts, :check, false) do
          with {:ok, view} <- check(manifest, registry, host, run_options(opts)) do
            report_check(view)
          end
        else
          with {:ok, result, class} <-
                 run_with_class(manifest, registry, run_options(opts)) do
            report(result, class, opts)
          end
        end

      case result do
        {:error, error} ->
          Mix.raise("ptc.run failed: #{inspect(error, limit: 10, printable_limit: 1_024)}")

        completed ->
          completed
      end
    else
      {_opts, _arguments, invalid} when invalid != [] ->
        Mix.raise("invalid ptc.run options: #{inspect(invalid)}")

      {_opts, _arguments, _invalid} ->
        Mix.raise(@usage)

      {:error, error} ->
        Mix.raise("ptc.run failed: #{inspect(error, limit: 10, printable_limit: 1_024)}")
    end
  end

  defp exclusive_destinations(opts) do
    if Keyword.has_key?(opts, :output) and Keyword.has_key?(opts, :private_output) do
      {:error, :conflicting_result_destinations}
    else
      :ok
    end
  end

  defp exclusive_mission_inputs(opts) do
    if Keyword.has_key?(opts, :mission) and Keyword.has_key?(opts, :private_mission) do
      {:error, :conflicting_mission_inputs}
    else
      :ok
    end
  end

  defp check_options(opts) do
    if Keyword.get(opts, :check, false) and
         Enum.any?([:output, :private_output, :trace, :inspect], &Keyword.has_key?(opts, &1)) do
      {:error, :check_has_output_options}
    else
      :ok
    end
  end

  defp registry(opts) do
    case Keyword.get(opts, :host_config) do
      nil ->
        with {:ok, registry} <- ProviderRegistry.new(),
             do: {:ok, registry, nil}

      path ->
        with {:ok, host} <- HostConfig.load(path),
             {:ok, registry} <- HostInstallation.registry(host),
             do: {:ok, registry, host}
    end
  end

  defp run_options(opts), do: Keyword.drop(opts, [:host_config, :check])

  defp check(manifest, registry, host, opts) do
    with {:ok, built} <- RunBuilder.load_and_build(manifest, registry, opts) do
      view = resolved_view(built, host)

      case RunBuilder.close(built.config) do
        :ok -> {:ok, view}
        {:error, _reason} = error -> error
      end
    end
  end

  defp resolved_view(built, host) do
    built.config.connector_snapshots
    |> Enum.map(fn snapshot ->
      installation = if host, do: host.install[snapshot["provider"]]
      resolved_provider(snapshot, installation)
    end)
    |> Enum.sort_by(&{&1["environment"], &1["name"]})
  end

  defp resolved_provider(snapshot, %{source: :mcp} = installation) do
    %{
      "environment" => "mission",
      "name" => snapshot["provider"],
      "summary" => "mcp/#{snapshot["transport"]}  #{length(snapshot["tools"])} tools",
      "accepts_data" => Enum.map(installation.accepts_data, &Atom.to_string/1),
      "snapshot_hash" => snapshot["snapshot_hash"]
    }
  end

  defp resolved_provider(snapshot, %{source: :llm} = installation) do
    %{
      "environment" => "workflow",
      "name" => snapshot["provider"],
      "summary" => "llm  model #{snapshot["model"]}",
      "accepts_data" => Enum.map(installation.accepts_data, &Atom.to_string/1),
      "snapshot_hash" => snapshot["snapshot_hash"]
    }
  end

  defp resolved_provider(snapshot, _installation) do
    %{
      "environment" => "mission",
      "name" => snapshot["provider"],
      "summary" => "provider  1 capabilities",
      "accepts_data" => ["normal"],
      "snapshot_hash" => snapshot["snapshot_hash"]
    }
  end

  defp report_check([]), do: Mix.shell().info("check ok: no providers")

  defp report_check(view) do
    Enum.each(view, fn provider ->
      Mix.shell().info(
        "#{provider["environment"]}  #{provider["name"]}  " <>
          "#{provider["summary"]}  " <>
          "accepts: #{Enum.join(provider["accepts_data"], ", ")}  " <>
          "snapshot #{provider["snapshot_hash"]}"
      )
    end)
  end

  defp run_with_class(manifest, registry, opts),
    do: RunBuilder.run_with_class(manifest, registry, opts)

  # A private value never reaches the terminal. Publishing it there would
  # declassify it just as surely as writing it to a normal artifact.
  defp report(result, :private, opts) do
    unless Keyword.has_key?(opts, :private_output) do
      Mix.raise(
        "ptc.run failed: a private run requires --private-output; its value is not published"
      )
    end

    Mix.shell().info(Jason.encode!(%{"class" => "private", "usage" => public(result.usage)}))
  end

  defp report(result, :normal, _opts),
    do: Mix.shell().info(Jason.encode!(public(result)))

  defp public(struct) when is_struct(struct), do: struct |> Map.from_struct() |> public()
  defp public(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, public(value)} end)
  defp public(list) when is_list(list), do: Enum.map(list, &public/1)
  defp public(value), do: value
end
