defmodule Mix.Tasks.Ptc.Viewer do
  @moduledoc "Launch the PTC Trace Viewer web UI"
  @shortdoc "Launch PTC Trace Viewer"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [port: :integer, trace_dir: :string, plan_dir: :string, no_open: :boolean]
      )

    Mix.Task.run("app.start")

    viewer_opts =
      []
      |> maybe_add(:port, opts[:port])
      |> maybe_add(:trace_dir, opts[:trace_dir])
      |> maybe_add(:plan_dir, opts[:plan_dir])
      |> maybe_add(:open, if(opts[:no_open], do: false, else: true))

    case PtcViewer.start(viewer_opts) do
      {:ok, _pid} ->
        port = opts[:port] || 4123
        Mix.shell().info("PTC Viewer running at http://localhost:#{port}")
        Mix.shell().info("Press Ctrl+C to stop")
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.shell().error("Failed to start viewer: #{inspect(reason)}")
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
