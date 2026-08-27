defmodule PtcViewer do
  @moduledoc """
  Local web UI for browsing canonical PTC traces, watching live Kernel runs,
  and, when explicitly enabled by the host, running one bounded run-analysis
  REPL profile or launching a fixed manifest target.

  The trace browser has no authentication. It binds loopback unless the host
  names the wildcard address, and every caller that does is choosing to publish
  whatever trace and inspection data the instance was granted. Live browser
  controls are available only when the page is opened through a local authority
  (`localhost`, `127.0.0.1`, or `::1`); non-loopback reporters require the
  separately configured `:live_token`.
  """

  alias PtcViewer.ReplAdapter
  alias PtcViewer.Server

  @doc """
  Starts one Viewer lifecycle.

  `:ip` selects the bind address from a closed pair: `{127, 0, 0, 1}`, the
  default, and `{0, 0, 0, 0}`, which serves this unauthenticated browser to
  every host that can reach the port. The port defaults to `0`, asking the
  operating system for a free one; `listener_info/1` returns the selected port.
  Any other address fails startup. In a container, bind the wildcard internally
  but publish only on host loopback:

      docker run -p 127.0.0.1:4123:4123 ... --listen 0.0.0.0

  In addition to the read-only trace and inspection options, a host may provide
  `:repl_adapter` and opaque `:repl_config`. Supplying an invalid or failed REPL
  adapter fails startup; omission preserves the Runs-only Viewer.

  Live options are:

  - `:launch` — a fixed `%{manifest: path, adapter: fun}` target with optional
    `:cwd` and `:label`. The two-arity host function receives a semantic launch
    request plus a direct live-frame sink. Browser data never chooses the
    adapter or manifest.
  - `:project_adapter` — a zero-arity function or module returning the project
    details displayed above the launch panel.
  - `:live_trace_refresh` — a one-arity host callback returning `:ok` or
    `{:error, reason}`. With a run id it atomically refreshes the pinned
    trace source and confirms the requested completed run exists. With
    `nil` it retains the new capture without naming a run, which is how
    the Runs list picks up work that finished after Viewer start.
  - `:live_token` — at least 32 bytes. External reporters send the same value in
    `PTC_VIEWER_TOKEN`; in-process host adapters use the direct sink instead.
    Without a token, only loopback reporter connections are accepted.

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
