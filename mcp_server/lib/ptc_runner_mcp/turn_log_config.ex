defmodule PtcRunnerMcp.TurnLogConfig do
  @moduledoc """
  Process-wide MCP turn-log configuration.

  This is deliberately separate from `PtcRunnerMcp.TraceConfig`: `--trace-dir`
  writes one debug/envelope trace per request, while `--turn-log-dir` writes one
  canonical session turn record spanning all stateful MCP evals.
  """

  @config_key {__MODULE__, :config}
  @collector_key {__MODULE__, :collector}

  @type t :: %{turn_log_dir: String.t() | nil}

  @doc "Default config — MCP turn logging disabled."
  @spec defaults() :: t()
  def defaults, do: %{turn_log_dir: nil}

  @doc "Set process-wide turn-log config."
  @spec set(map()) :: :ok
  def set(overrides) when is_map(overrides) do
    dir =
      case Map.get(overrides, :turn_log_dir, defaults().turn_log_dir) do
        nil -> nil
        "" -> nil
        value when is_binary(value) -> value
      end

    :persistent_term.put(@config_key, %{turn_log_dir: dir})
    :ok
  end

  @doc "Read process-wide turn-log config."
  @spec get() :: t()
  def get, do: :persistent_term.get(@config_key, defaults())

  @doc "Configured destination directory, or nil when disabled."
  @spec turn_log_dir() :: String.t() | nil
  def turn_log_dir, do: get().turn_log_dir

  @doc "True when MCP turn logging is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(turn_log_dir())

  @doc false
  @spec put_collector(pid() | nil) :: :ok
  def put_collector(nil) do
    :persistent_term.erase(@collector_key)
    :ok
  end

  def put_collector(pid) when is_pid(pid) do
    :persistent_term.put(@collector_key, pid)
    :ok
  end

  @doc "The active MCP turn-log collector pid, if one is running."
  @spec collector() :: pid() | nil
  def collector, do: :persistent_term.get(@collector_key, nil)
end
