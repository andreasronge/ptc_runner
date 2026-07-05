defmodule PtcRunnerMcp.Sessions.Config do
  @moduledoc """
  Runtime configuration for opt-in PTC-Lisp MCP sessions.

  This module is intentionally independent of `PtcRunnerMcp.Application`
  plumbing so Phase 1 routing can call it before the collision-prone boot
  files are wired. Values may be installed with `set/1`; until then `get/0`
  resolves CLI-shaped args from an empty map plus environment variables.
  """

  alias PtcRunner.Evidence
  alias PtcRunner.Evidence.Bundle, as: EvidenceBundle
  alias PtcRunner.Evidence.Holder, as: EvidenceHolder
  alias PtcRunner.Lisp.Prelude.Compiler, as: PreludeCompiler
  alias PtcRunnerMcp.{Lifecycle, Log}
  alias PtcRunnerMcp.Sessions.Policy

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
  @default_allow_prelude_write false
  @default_prelude_path nil
  @default_prelude_source nil
  @default_runtime_prelude nil
  @default_prelude_store nil
  @default_evidence_bundle_path nil
  @default_evidence_bundle nil
  @default_evidence_holder nil
  @default_evidence_tools nil
  @default_roles_path nil
  @default_policy Policy.unrestricted()

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
          allow_prelude_write: boolean(),
          prelude_path: String.t() | nil,
          prelude_source: String.t() | nil,
          runtime_prelude: PtcRunner.Lisp.Prelude.t() | nil,
          prelude_store: PtcRunner.PreludeStore.t() | nil,
          evidence_bundle_path: String.t() | nil,
          evidence_bundle: EvidenceBundle.t() | nil,
          evidence_holder: pid() | nil,
          evidence_tools: map() | nil,
          roles_path: String.t() | nil,
          policy: Policy.t()
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
      allow_prelude_write: @default_allow_prelude_write,
      prelude_path: @default_prelude_path,
      prelude_source: @default_prelude_source,
      runtime_prelude: @default_runtime_prelude,
      prelude_store: @default_prelude_store,
      evidence_bundle_path: @default_evidence_bundle_path,
      evidence_bundle: @default_evidence_bundle,
      evidence_holder: @default_evidence_holder,
      evidence_tools: @default_evidence_tools,
      roles_path: @default_roles_path,
      policy: @default_policy
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
         {:ok, prelude_path, prelude_source, _runtime_prelude} <- read_prelude(args, defaults),
         {:ok, prelude_store} <- read_prelude_store(args, defaults),
         {:ok, evidence_bundle_path, evidence_bundle} <- read_evidence_bundle(args, defaults),
         {:ok, roles_path, policy} <- read_policy(args, defaults),
         {:ok, runtime_prelude} <-
           compile_composed_prelude(compose_prelude_source(prelude_source, evidence_bundle)) do
      composed_prelude_source = compose_prelude_source(prelude_source, evidence_bundle)

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
         allow_prelude_write:
           read_bool(
             args,
             :sessions_allow_prelude_write,
             "PTC_RUNNER_MCP_SESSIONS_ALLOW_PRELUDE_WRITE",
             defaults.allow_prelude_write
           ),
         prelude_path: prelude_path,
         prelude_source: composed_prelude_source,
         runtime_prelude: runtime_prelude,
         prelude_store: prelude_store,
         evidence_bundle_path: evidence_bundle_path,
         evidence_bundle: evidence_bundle,
         evidence_holder: nil,
         evidence_tools: nil,
         roles_path: roles_path,
         policy: policy
       }}
    end
  end

  @doc "Install process-wide session config."
  @spec set(map()) :: :ok
  def set(overrides) when is_map(overrides) do
    old_config = :persistent_term.get({__MODULE__, :config}, nil)
    overrides = clear_replaced_evidence_holder(overrides, old_config)

    config =
      defaults()
      |> Map.merge(Map.take(overrides, Map.keys(defaults())))
      |> normalize()

    stop_replaced_evidence_holder(old_config, config)
    :persistent_term.put({__MODULE__, :config}, config)
    :ok
  end

  @doc "Read current process-wide session config."
  @spec get() :: t()
  def get do
    case :persistent_term.get({__MODULE__, :config}, :__ptc_missing__) do
      :__ptc_missing__ ->
        case resolve(%{}) do
          {:ok, config} ->
            set(config)
            :persistent_term.get({__MODULE__, :config})

          {:error, message} ->
            raise message
        end

      config ->
        config
    end
  end

  @doc "Clear installed config; useful for tests and short-lived manual runs."
  @spec reset() :: :ok
  def reset do
    :persistent_term.get({__MODULE__, :config}, nil)
    |> stop_evidence_holder()

    :persistent_term.erase({__MODULE__, :config})
    :ok
  end

  @doc "True when stateful session tools should be exposed."
  @spec enabled?() :: boolean()
  def enabled?, do: get().enabled == true

  @doc "True when write_capable sessions may author into the configured prelude store."
  @spec allow_prelude_write?() :: boolean()
  def allow_prelude_write?, do: get().allow_prelude_write == true

  @doc "Configured process-wide prelude source, or nil when no prelude is attached."
  @spec prelude_source() :: String.t() | nil
  def prelude_source, do: get().prelude_source

  @doc "Configured process-wide compiled prelude artifact for SubAgent-backed evals."
  @spec runtime_prelude() :: PtcRunner.Lisp.Prelude.t() | nil
  def runtime_prelude, do: get().runtime_prelude

  @doc "Configured process-wide versioned prelude store, or nil when start-time selection is unavailable."
  @spec prelude_store() :: PtcRunner.PreludeStore.t() | nil
  def prelude_store, do: get().prelude_store

  @doc "Configured process-wide evidence bundle, or nil when evidence is not granted."
  @spec evidence_bundle() :: EvidenceBundle.t() | nil
  def evidence_bundle, do: get().evidence_bundle

  @doc "Configured role policy for MCP sessions."
  @spec policy() :: Policy.t()
  def policy, do: get().policy

  @doc "Merge evidence tools into an eval tool map/list when evidence is configured."
  @spec with_evidence_tools(map() | keyword() | nil) :: map() | keyword() | nil
  def with_evidence_tools(base) do
    case evidence_bundle() do
      nil ->
        base

      %EvidenceBundle{} ->
        merge_evidence_tools!(base, evidence_tools())
    end
  end

  @doc false
  @spec evidence_tools() :: map()
  def evidence_tools, do: get().evidence_tools || %{}

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
      {:allow_prelude_write, value} -> {:allow_prelude_write, value == true}
      {:prelude_path, value} when is_binary(value) -> {:prelude_path, value}
      {:prelude_source, value} when is_binary(value) -> {:prelude_source, value}
      {:runtime_prelude, %PtcRunner.Lisp.Prelude{} = value} -> {:runtime_prelude, value}
      {:prelude_store, %PtcRunner.PreludeStore{} = value} -> {:prelude_store, value}
      {:evidence_bundle_path, value} when is_binary(value) -> {:evidence_bundle_path, value}
      {:evidence_bundle, %EvidenceBundle{} = value} -> {:evidence_bundle, value}
      {:evidence_holder, value} when is_pid(value) -> {:evidence_holder, value}
      {:evidence_tools, value} when is_map(value) -> {:evidence_tools, value}
      {:roles_path, value} when is_binary(value) -> {:roles_path, value}
      {:policy, %Policy{} = value} -> {:policy, value}
      {:prelude_path, _value} -> {:prelude_path, defaults.prelude_path}
      {:prelude_source, _value} -> {:prelude_source, defaults.prelude_source}
      {:runtime_prelude, _value} -> {:runtime_prelude, defaults.runtime_prelude}
      {:prelude_store, _value} -> {:prelude_store, defaults.prelude_store}
      {:evidence_bundle_path, _value} -> {:evidence_bundle_path, defaults.evidence_bundle_path}
      {:evidence_bundle, _value} -> {:evidence_bundle, defaults.evidence_bundle}
      {:evidence_holder, _value} -> {:evidence_holder, defaults.evidence_holder}
      {:evidence_tools, _value} -> {:evidence_tools, defaults.evidence_tools}
      {:roles_path, _value} -> {:roles_path, defaults.roles_path}
      {:policy, _value} -> {:policy, defaults.policy}
      {key, value} when is_integer(value) and value > 0 -> {key, value}
      {key, _value} -> {key, Map.fetch!(defaults, key)}
    end)
    |> ensure_evidence_prelude_source()
    |> compile_runtime_prelude_from_source()
    |> install_evidence_tools()
    |> warn_unreachable_evidence_roles()
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

  defp read_prelude_store(args, defaults) do
    case Map.get(args, :prelude_store, defaults.prelude_store) do
      %PtcRunner.PreludeStore{} = store ->
        {:ok, store}

      nil ->
        {:ok, defaults.prelude_store}

      value ->
        {:error, ":prelude_store must be a %PtcRunner.PreludeStore{}, got: #{inspect(value)}"}
    end
  end

  defp read_evidence_bundle(args, defaults) do
    case env_or(args, :evidence_bundle, "PTC_RUNNER_MCP_EVIDENCE_BUNDLE") do
      nil ->
        {:ok, defaults.evidence_bundle_path, defaults.evidence_bundle}

      path when is_binary(path) ->
        try do
          {:ok, path, EvidenceBundle.load!(path)}
        rescue
          exception ->
            {:error,
             "--evidence-bundle / PTC_RUNNER_MCP_EVIDENCE_BUNDLE is invalid: #{path} " <>
               "(#{Exception.message(exception)})"}
        end

      value ->
        {:error,
         "--evidence-bundle / PTC_RUNNER_MCP_EVIDENCE_BUNDLE must be a file path, got: " <>
           inspect(value)}
    end
  end

  defp read_policy(args, defaults) do
    case env_or(args, :session_roles, "PTC_RUNNER_MCP_SESSION_ROLES") do
      nil ->
        {:ok, defaults.roles_path, defaults.policy}

      path when is_binary(path) ->
        case Policy.load_file(path) do
          {:ok, policy} ->
            {:ok, path, policy}

          {:error, message} ->
            {:error, "--session-roles / PTC_RUNNER_MCP_SESSION_ROLES is invalid: #{message}"}
        end

      value ->
        {:error,
         "--session-roles / PTC_RUNNER_MCP_SESSION_ROLES must be a file path, got: " <>
           inspect(value)}
    end
  end

  defp compose_prelude_source(nil, nil), do: nil
  defp compose_prelude_source(source, nil), do: source
  defp compose_prelude_source(nil, %EvidenceBundle{}), do: Evidence.prelude_source()

  defp compose_prelude_source(source, %EvidenceBundle{}) when is_binary(source) do
    source <> "\n\n;; --- ptc_runner evidence prelude ---\n\n" <> Evidence.prelude_source()
  end

  defp ensure_evidence_prelude_source(%{evidence_bundle: %EvidenceBundle{} = bundle} = config) do
    source = Map.get(config, :prelude_source)

    if official_evidence_prelude_present?(source) do
      config
    else
      %{config | prelude_source: compose_prelude_source(source, bundle)}
    end
  end

  defp ensure_evidence_prelude_source(config), do: config

  defp official_evidence_prelude_present?(source) when is_binary(source),
    do: String.contains?(source, Evidence.prelude_source())

  defp official_evidence_prelude_present?(_source), do: false

  defp compile_composed_prelude(nil), do: {:ok, nil}

  defp compile_composed_prelude(source) when is_binary(source) do
    case compile_prelude(source, nil) do
      {:ok, runtime_prelude} ->
        {:ok, runtime_prelude}

      {:error, %PtcRunner.Lisp.Prelude.ValidationError{} = error} ->
        {:error, "--prelude / --evidence-bundle composed prelude is invalid: #{error.message}"}
    end
  end

  defp install_evidence_tools(
         %{evidence_bundle: %EvidenceBundle{}, evidence_holder: holder} = config
       )
       when is_pid(holder) do
    if Process.alive?(holder) do
      %{config | evidence_tools: Evidence.tools(config.evidence_bundle, holder: holder)}
    else
      install_evidence_tools(%{config | evidence_holder: nil, evidence_tools: nil})
    end
  end

  defp install_evidence_tools(%{evidence_bundle: %EvidenceBundle{} = bundle} = config) do
    {:ok, holder} = EvidenceHolder.start(bundle, owner: nil)

    %{
      config
      | evidence_holder: holder,
        evidence_tools: Evidence.tools(bundle, holder: holder)
    }
  end

  defp install_evidence_tools(config), do: config

  # Flags roles whose explicit `ptc_tools` allowlist cannot reach any
  # configured evidence tool. Partial evidence grants (some but not all of
  # evidence_bundle/evidence_read/evidence_page) are an intentional, tested
  # scoping pattern and are not flagged; only the zero-overlap case is, since
  # it is indistinguishable at parse time from an operator forgetting to list
  # the evidence tools.
  defp warn_unreachable_evidence_roles(%{evidence_bundle: %EvidenceBundle{}} = config) do
    evidence_tool_names = MapSet.new(Map.keys(config.evidence_tools))

    Enum.each(config.policy.roles, fn {role, grant} ->
      unless Enum.any?(evidence_tool_names, &Policy.ptc_tool_allowed?(grant, &1)) do
        Log.log(
          :warn,
          "role_evidence_tools_unreachable",
          Lifecycle.lifecycle_fields(%{
            role: role,
            grant_fingerprint: grant.fingerprint,
            evidence_tools: Enum.sort(evidence_tool_names)
          })
        )
      end
    end)

    config
  end

  defp warn_unreachable_evidence_roles(config), do: config

  defp merge_evidence_tools!(base, evidence_tools) do
    base_map = as_tool_map(base)

    collisions =
      base_map
      |> Map.keys()
      |> MapSet.new(&to_string/1)
      |> MapSet.intersection(MapSet.new(Map.keys(evidence_tools), &to_string/1))

    if MapSet.size(collisions) > 0 do
      names = collisions |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")
      raise ArgumentError, "evidence tools collide with configured tools: #{names}"
    end

    Map.merge(base_map, evidence_tools)
  end

  defp as_tool_map(nil), do: %{}
  defp as_tool_map(base) when is_map(base), do: base
  defp as_tool_map(base) when is_list(base), do: Map.new(base)
  defp as_tool_map(base), do: Map.new(base)

  defp clear_replaced_evidence_holder(overrides, nil), do: overrides

  defp clear_replaced_evidence_holder(overrides, old_config) do
    if evidence_bundle_changed?(overrides, old_config) do
      overrides
      |> Map.put(:evidence_holder, nil)
      |> Map.put(:evidence_tools, nil)
    else
      overrides
    end
  end

  defp evidence_bundle_changed?(overrides, old_config) do
    Map.get(overrides, :evidence_bundle_path) != Map.get(old_config, :evidence_bundle_path) or
      Map.get(overrides, :evidence_bundle) != Map.get(old_config, :evidence_bundle)
  end

  defp stop_replaced_evidence_holder(nil, _new_config), do: :ok

  defp stop_replaced_evidence_holder(old_config, new_config) do
    if Map.get(old_config, :evidence_holder) != Map.get(new_config, :evidence_holder) do
      stop_evidence_holder(old_config)
    end

    :ok
  end

  defp stop_evidence_holder(%{evidence_holder: holder}) when is_pid(holder) do
    if Process.alive?(holder), do: EvidenceHolder.stop(holder)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_evidence_holder(_config), do: :ok

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
