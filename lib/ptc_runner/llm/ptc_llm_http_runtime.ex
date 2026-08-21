defmodule PtcRunner.LLM.PtcLlmHttpRuntime do
  @moduledoc false

  # Owns the optional PtcLlmHttp Runtime as a PtcRunner application child.
  # Capacity is reserved and released by that runtime; this supervisor only
  # starts, restarts, and locates it. The Runtime process is started when
  # `ptc_llm_http` is compiled into the host, not per request. Tests may bind
  # an isolated runtime through `:ptc_llm_http_runtime` without replacing this
  # owner.

  use Supervisor

  @capacity_group "ptc-runner"
  @max_concurrency 8
  @cleanup_ms 1_000

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_opts), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  @spec capacity_group() :: String.t()
  def capacity_group, do: @capacity_group

  @spec runtime() :: {:ok, pid()} | {:error, :runtime_unavailable}
  def runtime do
    case Application.get_env(:ptc_runner, :ptc_llm_http_runtime) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :runtime_unavailable}

      _unbound ->
        supervised_runtime()
    end
  end

  defp supervised_runtime do
    case Supervisor.which_children(__MODULE__) do
      [{PtcLlmHttp.Runtime, pid, _type, _modules}] when is_pid(pid) -> {:ok, pid}
      _missing -> {:error, :runtime_unavailable}
    end
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  defp children do
    if Code.ensure_loaded?(PtcLlmHttp.Runtime) do
      [
        %{
          id: PtcLlmHttp.Runtime,
          start: {
            PtcLlmHttp.Runtime,
            :start_link,
            [[max_concurrency: @max_concurrency, groups: %{@capacity_group => @max_concurrency}]]
          },
          restart: :permanent,
          shutdown: @cleanup_ms,
          type: :supervisor
        }
      ]
    else
      []
    end
  end
end
