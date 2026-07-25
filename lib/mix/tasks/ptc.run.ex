defmodule Mix.Tasks.Ptc.Run do
  @shortdoc "Runs one strict PTC Kernel manifest"
  @moduledoc """
  Runs one V1 Kernel manifest through the shared run builder.

      mix ptc.run MANIFEST
      mix ptc.run MANIFEST --mission alternate-input.json
      mix ptc.run MANIFEST --trace traces/run.jsonl
      mix ptc.run MANIFEST --trace traces/run.jsonl --inspect traces/run.inspection.jsonl
      mix ptc.run MANIFEST --output results/answer.json
      mix ptc.run MANIFEST --private-output results/answer.private.json

  `--output` and `--private-output` write the result value as a standalone
  JSON artifact so a later run can consume it without scraping stdout. Both
  refuse to overwrite an existing destination and are mutually exclusive.

  A private-event run may not publish. It suppresses its value on stdout,
  rejects `--output`, and requires `--private-output` to keep the value at all.
  """
  use Mix.Task

  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder

  @usage "usage: mix ptc.run MANIFEST [--mission PATH] [--trace PATH] [--inspect PATH] " <>
           "[--output PATH | --private-output PATH]"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    with {opts, [manifest], []} <-
           OptionParser.parse(args,
             strict: [
               mission: :string,
               trace: :string,
               inspect: :string,
               output: :string,
               private_output: :string
             ],
             aliases: [m: :mission, t: :trace]
           ),
         :ok <- exclusive_destinations(opts),
         {:ok, registry} <- ProviderRegistry.new(),
         {:ok, result, class} <- run_with_class(manifest, registry, opts) do
      report(result, class, opts)
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
