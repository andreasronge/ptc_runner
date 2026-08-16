defmodule PtcViewer do
  @moduledoc """
  Local web UI for browsing canonical PTC traces and, when explicitly enabled
  by the host, running one bounded run-analysis REPL profile.

  There is no authentication. It binds loopback unless the host names the
  wildcard address, and every caller that does is choosing to publish whatever
  trace and inspection data the instance was granted.
  """

  alias PtcViewer.ReplAdapter
  alias PtcViewer.Server

  @doc """
  Starts one Viewer lifecycle.

  `:ip` selects the bind address from a closed pair: `{127, 0, 0, 1}`, the
  default, and `{0, 0, 0, 0}`, which serves this unauthenticated browser to
  every host that can reach the port. Any other value fails startup.

  In addition to the read-only trace and inspection options, a host may provide
  `:repl_adapter` and opaque `:repl_config`. Supplying an invalid or failed REPL
  adapter fails startup; omission preserves the Runs-only Viewer.

  The Viewer's own applications are started here rather than left to the host,
  because `ptc_runner` carries this companion as a load-only release
  dependency: nothing has started `bandit` by the time a caller arrives.
  """
  def start(opts \\ [])

  def start(opts) when is_list(opts) do
    kernel_adapter = Keyword.get(opts, :kernel_trace_adapter)
    repl_adapter = Keyword.get(opts, :repl_adapter)

    with :ok <- started(),
         :ok <- valid_kernel_adapter(kernel_adapter),
         :ok <- ReplAdapter.validate(repl_adapter) do
      Server.start(opts)
    end
  end

  def start(_opts), do: {:error, :invalid_viewer_config}

  @doc "Stops traffic, drains accepted REPL work, and terminates the Viewer."
  def stop(pid), do: Server.stop(pid)

  @doc "Returns the bound listener address and actual bound port."
  def listener_info(pid), do: Server.listener_info(pid)

  defp started do
    case Application.ensure_all_started(:ptc_viewer) do
      {:ok, _started} -> :ok
      {:error, _reason} -> {:error, :viewer_start_failed}
    end
  end

  defp valid_kernel_adapter(nil), do: :ok
  defp valid_kernel_adapter(adapter) when is_function(adapter, 3), do: :ok

  defp valid_kernel_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :query, 3),
      do: :ok,
      else: {:error, :invalid_kernel_trace_adapter}
  end

  defp valid_kernel_adapter(_adapter), do: {:error, :invalid_kernel_trace_adapter}
end
