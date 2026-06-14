defmodule PtcRunnerMcp.Sessions.Config do
  @moduledoc """
  Runtime configuration for opt-in PTC-Lisp MCP sessions.

  This module is intentionally independent of `PtcRunnerMcp.Application`
  plumbing so Phase 1 routing can call it before the collision-prone boot
  files are wired. Values may be installed with `set/1`; until then `get/0`
  resolves CLI-shaped args from an empty map plus environment variables.
  """

  alias PtcRunner.Lisp.Prelude.Compiler, as: PreludeCompiler

  @default_max_sessions 64
  @default_max_sessions_per_owner 16
  @default_session_ttl_ms 30 * 60 * 1000
  @default_session_idle_timeout_ms 15 * 60 * 1000
  @default_max_session_memory_bytes 1 * 1024 * 1024
  @default_max_session_binding_bytes 256 * 1024
  @default_max_session_bindings 200
  @default_max_session_history_entry_bytes 64 * 1024
  @default_max_session_print_entries 50
  @default_max_session_print_bytes 64 * 1024
  @default_max_session_tool_call_entries 50
  @default_max_session_tool_call_bytes 128 * 1024
  @default_max_session_upstream_call_entries 50
  @default_max_session_upstream_call_bytes 128 * 1024
  @default_max_session_preview_chars 512
  @default_collection_hint false
  @default_prelude_path nil
  @default_prelude_source nil
  @default_runtime_prelude nil

  @typedoc "Process-wide sessions configuration."
  @type t :: %{
          enabled: boolean(),
          max_sessions: pos_integer(),
          max_sessions_per_owner: pos_integer(),
          session_ttl_ms: pos_integer(),
          session_idle_timeout_ms: pos_integer(),
          max_session_memory_bytes: pos_integer(),
          max_session_binding_bytes: pos_integer(),
          max_session_bindings: pos_integer(),
          max_session_history_entry_bytes: pos_integer(),
          max_session_print_entries: pos_integer(),
          max_session_print_bytes: pos_integer(),
          max_session_tool_call_entries: pos_integer(),
          max_session_tool_call_bytes: pos_integer(),
          max_session_upstream_call_entries: pos_integer(),
          max_session_upstream_call_bytes: pos_integer(),
          max_session_preview_chars: pos_integer(),
          collection_hint: boolean(),
          prelude_path: String.t() | nil,
          prelude_source: String.t() | nil,
          runtime_prelude: PtcRunner.Lisp.Prelude.t() | nil
        }

  @doc "Default session config. Sessions are disabled by default."
  @spec defaults() :: t()
  def defaults do
    %{
      enabled: false,
      max_sessions: @default_max_sessions,
      max_sessions_per_owner: @default_max_sessions_per_owner,
      session_ttl_ms: @default_session_ttl_ms,
      session_idle_timeout_ms: @default_session_idle_timeout_ms,
      max_session_memory_bytes: @default_max_session_memory_bytes,
      max_session_binding_bytes: @default_max_session_binding_bytes,
      max_session_bindings: @default_max_session_bindings,
      max_session_history_entry_bytes: @default_max_session_history_entry_bytes,
      max_session_print_entries: @default_max_session_print_entries,
      max_session_print_bytes: @default_max_session_print_bytes,
      max_session_tool_call_entries: @default_max_session_tool_call_entries,
      max_session_tool_call_bytes: @default_max_session_tool_call_bytes,
      max_session_upstream_call_entries: @default_max_session_upstream_call_entries,
      max_session_upstream_call_bytes: @default_max_session_upstream_call_bytes,
      max_session_preview_chars: @default_max_session_preview_chars,
      collection_hint: @default_collection_hint,
      prelude_path: @default_prelude_path,
      prelude_source: @default_prelude_source,
      runtime_prelude: @default_runtime_prelude
    }
  end

  @doc """
  Resolve config from a CLI-shaped args map and environment variables.

  Precedence is CLI map key, then environment variable, then default. This
  mirrors the existing MCP config modules without requiring the Application
  module to own Phase 1 session wiring yet.
  """
  @spec resolve(map()) :: {:ok, t()} | {:error, String.t()}
  def resolve(args) when is_map(args) do
    defaults = defaults()

    with {:ok, max_sessions} <-
           read_int(args, :max_sessions, "PTC_RUNNER_MCP_MAX_SESSIONS", defaults.max_sessions),
         {:ok, max_sessions_per_owner} <-
           read_int(
             args,
             :max_sessions_per_owner,
             "PTC_RUNNER_MCP_MAX_SESSIONS_PER_OWNER",
             defaults.max_sessions_per_owner
           ),
         {:ok, session_ttl_ms} <-
           read_int(
             args,
             :session_ttl_ms,
             "PTC_RUNNER_MCP_SESSION_TTL_MS",
             defaults.session_ttl_ms
           ),
         {:ok, session_idle_timeout_ms} <-
           read_int(
             args,
             :session_idle_timeout_ms,
             "PTC_RUNNER_MCP_SESSION_IDLE_TIMEOUT_MS",
             defaults.session_idle_timeout_ms
           ),
         {:ok, max_session_memory_bytes} <-
           read_int(
             args,
             :max_session_memory_bytes,
             "PTC_RUNNER_MCP_MAX_SESSION_MEMORY_BYTES",
             defaults.max_session_memory_bytes
           ),
         {:ok, max_session_binding_bytes} <-
           read_int(
             args,
             :max_session_binding_bytes,
             "PTC_RUNNER_MCP_MAX_SESSION_BINDING_BYTES",
             defaults.max_session_binding_bytes
           ),
         {:ok, max_session_bindings} <-
           read_int(
             args,
             :max_session_bindings,
             "PTC_RUNNER_MCP_MAX_SESSION_BINDINGS",
             defaults.max_session_bindings
           ),
         {:ok, max_session_history_entry_bytes} <-
           read_int(
             args,
             :max_session_history_entry_bytes,
             "PTC_RUNNER_MCP_MAX_SESSION_HISTORY_ENTRY_BYTES",
             defaults.max_session_history_entry_bytes
           ),
         {:ok, max_session_print_entries} <-
           read_int(
             args,
             :max_session_print_entries,
             "PTC_RUNNER_MCP_MAX_SESSION_PRINT_ENTRIES",
             defaults.max_session_print_entries
           ),
         {:ok, max_session_print_bytes} <-
           read_int(
             args,
             :max_session_print_bytes,
             "PTC_RUNNER_MCP_MAX_SESSION_PRINT_BYTES",
             defaults.max_session_print_bytes
           ),
         {:ok, max_session_tool_call_entries} <-
           read_int(
             args,
             :max_session_tool_call_entries,
             "PTC_RUNNER_MCP_MAX_SESSION_TOOL_CALL_ENTRIES",
             defaults.max_session_tool_call_entries
           ),
         {:ok, max_session_tool_call_bytes} <-
           read_int(
             args,
             :max_session_tool_call_bytes,
             "PTC_RUNNER_MCP_MAX_SESSION_TOOL_CALL_BYTES",
             defaults.max_session_tool_call_bytes
           ),
         {:ok, max_session_upstream_call_entries} <-
           read_int(
             args,
             :max_session_upstream_call_entries,
             "PTC_RUNNER_MCP_MAX_SESSION_UPSTREAM_CALL_ENTRIES",
             defaults.max_session_upstream_call_entries
           ),
         {:ok, max_session_upstream_call_bytes} <-
           read_int(
             args,
             :max_session_upstream_call_bytes,
             "PTC_RUNNER_MCP_MAX_SESSION_UPSTREAM_CALL_BYTES",
             defaults.max_session_upstream_call_bytes
           ),
         {:ok, max_session_preview_chars} <-
           read_int(
             args,
             :max_session_preview_chars,
             "PTC_RUNNER_MCP_MAX_SESSION_PREVIEW_CHARS",
             defaults.max_session_preview_chars
           ),
         {:ok, prelude_path, prelude_source, runtime_prelude} <- read_prelude(args, defaults) do
      {:ok,
       %{
         enabled: read_bool(args, :sessions, "PTC_RUNNER_MCP_SESSIONS", defaults.enabled),
         max_sessions: max_sessions,
         max_sessions_per_owner: max_sessions_per_owner,
         session_ttl_ms: session_ttl_ms,
         session_idle_timeout_ms: session_idle_timeout_ms,
         max_session_memory_bytes: max_session_memory_bytes,
         max_session_binding_bytes: max_session_binding_bytes,
         max_session_bindings: max_session_bindings,
         max_session_history_entry_bytes: max_session_history_entry_bytes,
         max_session_print_entries: max_session_print_entries,
         max_session_print_bytes: max_session_print_bytes,
         max_session_tool_call_entries: max_session_tool_call_entries,
         max_session_tool_call_bytes: max_session_tool_call_bytes,
         max_session_upstream_call_entries: max_session_upstream_call_entries,
         max_session_upstream_call_bytes: max_session_upstream_call_bytes,
         max_session_preview_chars: max_session_preview_chars,
         collection_hint:
           read_bool(
             args,
             :collection_hint,
             "PTC_RUNNER_MCP_COLLECTION_HINT",
             defaults.collection_hint
           ),
         prelude_path: prelude_path,
         prelude_source: prelude_source,
         runtime_prelude: runtime_prelude
       }}
    end
  end

  @doc "Install process-wide session config."
  @spec set(map()) :: :ok
  def set(overrides) when is_map(overrides) do
    config =
      defaults()
      |> Map.merge(Map.take(overrides, Map.keys(defaults())))
      |> normalize()

    :persistent_term.put({__MODULE__, :config}, config)
    :ok
  end

  @doc "Read current process-wide session config."
  @spec get() :: t()
  def get do
    case :persistent_term.get({__MODULE__, :config}, :__ptc_missing__) do
      :__ptc_missing__ ->
        case resolve(%{}) do
          {:ok, config} -> config
          {:error, message} -> raise message
        end

      config ->
        config
    end
  end

  @doc "Clear installed config; useful for tests and short-lived manual runs."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase({__MODULE__, :config})
    :ok
  end

  @doc "True when stateful session tools should be exposed."
  @spec enabled?() :: boolean()
  def enabled?, do: get().enabled == true

  @doc "Configured process-wide prelude source, or nil when no prelude is attached."
  @spec prelude_source() :: String.t() | nil
  def prelude_source, do: get().prelude_source

  @doc "Configured process-wide compiled prelude artifact for SubAgent-backed evals."
  @spec runtime_prelude() :: PtcRunner.Lisp.Prelude.t() | nil
  def runtime_prelude, do: get().runtime_prelude

  @doc "Return only the per-session persisted-state limit keys."
  @spec session_limits() :: map()
  def session_limits do
    config = get()

    %{
      max_memory_bytes: config.max_session_memory_bytes,
      max_binding_bytes: config.max_session_binding_bytes,
      max_bindings: config.max_session_bindings,
      max_history_entry_bytes: config.max_session_history_entry_bytes,
      max_print_entries: config.max_session_print_entries,
      max_print_bytes: config.max_session_print_bytes,
      max_tool_call_entries: config.max_session_tool_call_entries,
      max_tool_call_bytes: config.max_session_tool_call_bytes,
      max_upstream_call_entries: config.max_session_upstream_call_entries,
      max_upstream_call_bytes: config.max_session_upstream_call_bytes,
      max_idle_ms: config.session_idle_timeout_ms
    }
  end

  @doc "Clamp requested TTL to the configured process cap."
  @spec clamp_ttl_ms(term()) :: pos_integer()
  def clamp_ttl_ms(nil), do: get().session_ttl_ms

  def clamp_ttl_ms(value) when is_integer(value) and value > 0 do
    min(value, get().session_ttl_ms)
  end

  def clamp_ttl_ms(_other), do: get().session_ttl_ms

  defp normalize(config) do
    defaults = defaults()

    Map.new(config, fn
      {:enabled, value} -> {:enabled, value == true}
      {:collection_hint, value} -> {:collection_hint, value == true}
      {:prelude_path, value} when is_binary(value) -> {:prelude_path, value}
      {:prelude_source, value} when is_binary(value) -> {:prelude_source, value}
      {:runtime_prelude, %PtcRunner.Lisp.Prelude{} = value} -> {:runtime_prelude, value}
      {:prelude_path, _value} -> {:prelude_path, defaults.prelude_path}
      {:prelude_source, _value} -> {:prelude_source, defaults.prelude_source}
      {:runtime_prelude, _value} -> {:runtime_prelude, defaults.runtime_prelude}
      {key, value} when is_integer(value) and value > 0 -> {key, value}
      {key, _value} -> {key, Map.fetch!(defaults, key)}
    end)
    |> compile_runtime_prelude_from_source()
  end

  defp read_prelude(args, defaults) do
    case env_or(args, :prelude, "PTC_RUNNER_MCP_PRELUDE") do
      nil ->
        {:ok, defaults.prelude_path, defaults.prelude_source, defaults.runtime_prelude}

      path when is_binary(path) ->
        with {:ok, source} <- File.read(path),
             {:ok, runtime_prelude} <- compile_prelude(source, path) do
          {:ok, path, source, runtime_prelude}
        else
          {:error, %PtcRunner.Lisp.Prelude.ValidationError{} = error} ->
            {:error, "--prelude / PTC_RUNNER_MCP_PRELUDE is invalid: #{path} (#{error.message})"}

          {:error, reason} ->
            {:error, "--prelude / PTC_RUNNER_MCP_PRELUDE could not be read: #{path} (#{reason})"}
        end

      value ->
        {:error, "--prelude / PTC_RUNNER_MCP_PRELUDE must be a file path, got: #{inspect(value)}"}
    end
  end

  defp compile_runtime_prelude_from_source(%{prelude_source: source} = config)
       when is_binary(source) do
    case compile_prelude(source, Map.get(config, :prelude_path)) do
      {:ok, runtime_prelude} ->
        %{config | runtime_prelude: runtime_prelude}

      {:error, %PtcRunner.Lisp.Prelude.ValidationError{} = error} ->
        raise ArgumentError, "invalid prelude source: #{error.message}"
    end
  end

  defp compile_runtime_prelude_from_source(config), do: config

  defp compile_prelude(source, _path) do
    PreludeCompiler.compile(source)
  end

  defp read_int(args, key, env_name, default) do
    case env_or(args, key, env_name) do
      nil ->
        {:ok, default}

      n when is_integer(n) and n > 0 ->
        {:ok, n}

      bin when is_binary(bin) ->
        case Integer.parse(String.trim(bin)) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, invalid_int_message(key, env_name, bin)}
        end

      value ->
        {:error, invalid_int_message(key, env_name, value)}
    end
  end

  defp invalid_int_message(key, env_name, value) do
    flag = "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))
    "#{flag} / #{env_name} must be a positive integer, got: #{inspect(value)}"
  end

  defp read_bool(args, key, env_name, default) do
    case env_or(args, key, env_name) do
      nil -> default
      value when is_boolean(value) -> value
      value when is_binary(value) -> parse_bool(value, default)
      _ -> default
    end
  end

  defp parse_bool(value, default) do
    case String.downcase(String.trim(value)) do
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      "0" -> false
      "false" -> false
      "no" -> false
      "off" -> false
      _ -> default
    end
  end

  defp env_or(args, key, env_name) do
    case Map.fetch(args, key) do
      {:ok, value} ->
        value

      :error ->
        case System.get_env(env_name) do
          nil -> nil
          "" -> nil
          value -> value
        end
    end
  end
end
