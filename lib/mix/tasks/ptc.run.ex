defmodule Mix.Tasks.Ptc.Run do
  @shortdoc "Runs one strict PTC Kernel manifest"
  @moduledoc """
  Runs one V1 Kernel manifest through the shared run builder.

      mix ptc.run MANIFEST
      mix ptc.run MANIFEST --mission alternate-input.json
      mix ptc.run MANIFEST --trace traces/run.jsonl
      mix ptc.run MANIFEST --trace traces/run.jsonl --inspect traces/run.inspection.jsonl
  """
  use Mix.Task

  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    with {opts, [manifest], []} <-
           OptionParser.parse(args,
             strict: [mission: :string, trace: :string, inspect: :string],
             aliases: [m: :mission, t: :trace]
           ),
         {:ok, registry} <- ProviderRegistry.new(),
         {:ok, result} <- RunBuilder.run(manifest, registry, opts) do
      Mix.shell().info(Jason.encode!(public(result)))
    else
      {_opts, _arguments, invalid} when invalid != [] ->
        Mix.raise("invalid ptc.run options: #{inspect(invalid)}")

      {_opts, _arguments, _invalid} ->
        Mix.raise("usage: mix ptc.run MANIFEST [--mission PATH] [--trace PATH] [--inspect PATH]")

      {:error, error} ->
        Mix.raise("ptc.run failed: #{inspect(error, limit: 10, printable_limit: 1_024)}")
    end
  end

  defp public(struct) when is_struct(struct), do: struct |> Map.from_struct() |> public()
  defp public(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, public(value)} end)
  defp public(list) when is_list(list), do: Enum.map(list, &public/1)
  defp public(value), do: value
end
