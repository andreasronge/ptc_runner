defmodule Mix.Tasks.Ptc.Viewer do
  @moduledoc "Launch the PTC Trace Viewer web UI"
  @shortdoc "Launch PTC Trace Viewer"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          port: :integer,
          trace_dir: :string,
          inspection_file: :string,
          no_open: :boolean
        ]
      )

    Mix.Task.run("app.start")

    viewer_opts =
      []
      |> maybe_add(:port, opts[:port])
      |> maybe_add(:trace_dir, opts[:trace_dir])
      |> maybe_add(:inspection_file, opts[:inspection_file])
      |> maybe_add(:open, if(opts[:no_open], do: false, else: true))
      |> maybe_add(:kernel_trace_adapter, default_kernel_adapter())
      |> maybe_add(:inspection_adapter, inspection_adapter(opts[:inspection_file]))
      |> maybe_add(:repl_adapter, default_repl_adapter())
      |> maybe_add(:repl_config, repl_config(opts[:trace_dir]))

    case PtcViewer.start(viewer_opts) do
      {:ok, _pid} ->
        port = opts[:port] || 4123
        Mix.shell().info("PTC Viewer running at http://localhost:#{port}")
        Mix.shell().info("Press Ctrl+C to stop")

        receive do
          :stop -> :ok
        end

      {:error, reason} ->
        Mix.shell().error("Failed to start viewer: #{inspect(reason)}")
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp default_kernel_adapter do
    adapter = Module.concat([PtcRunner, Kernel, ViewerAdapter])
    if Code.ensure_loaded?(adapter), do: adapter, else: nil
  end

  defp inspection_adapter(nil), do: nil
  defp inspection_adapter(_path), do: default_kernel_adapter()

  defp default_repl_adapter do
    adapter = Module.concat([PtcRunner, Kernel, ViewerReplAdapter])
    if Code.ensure_loaded?(adapter), do: adapter, else: nil
  end

  defp repl_config(trace_dir) do
    %{trace_dir: Path.expand(trace_dir || "traces"), profile_id: "run-analysis-v1"}
  end
end
