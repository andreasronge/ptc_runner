defmodule PtcRunnerMcp.Credentials do
  @moduledoc """
  Singleton GenServer that owns parsed credential `Binding`s and the
  ETS-backed redaction set.

  ## Responsibilities

    * Hold the parsed `%PtcRunnerMcp.Credentials.Binding{}` map (built
      by `PtcRunnerMcp.Credentials.Binding.parse_block/1` at config
      load).
    * Resolve a binding to bytes on demand via `materialize/1`. Source
      resolution follows §5.4.1: `env` and `file` are re-read on every
      call (no in-process value cache, §7.4); `literal` is read from
      the parsed spec.
    * Own the **`#{inspect(:credentials_redaction_set)}`** ETS table —
      `:set`, `:protected`, `:named_table`, `read_concurrency: true`.
      Plaintext bytes are inserted into the table **before**
      `materialize/1` returns its first successful result for a given
      value (§7.5.2 first-emission-race rule).

  ## Why `:protected`?

  Per §7.5: only the GenServer (table owner) is allowed to write into
  the redaction set; any BEAM process must be able to read it for
  substring redaction. `:public` would let stray code register false
  positives, `:private` would block cross-process readers entirely.

  ## What's NOT here

    * Scheme-specific shaping (`apply/2`) — that lives in a separate
      module added by a later phase, with visibility into the consuming
      auth emitter's scheme. `materialize/1` is deliberately
      scheme-agnostic at the source layer (§7.2).
    * The `Credentials.Redactor.scrub/1` filter — added by stream 1C.
      Stream 1C reads this module's ETS table via `:ets.tab2list/1`
      using the name returned by `table_name/0`.
    * Application/supervision wiring — added by stream 1D.

  Spec: `Plans/http-transport-credentials.md` §4.2, §5.4.1, §7.1, §7.2,
  §7.4, §7.5.
  """

  use GenServer

  alias PtcRunnerMcp.Credentials.Binding
  alias PtcRunnerMcp.Log

  import Bitwise, only: [&&&: 2]

  @table :credentials_redaction_set

  @type materialization :: %{
          raw: binary(),
          scheme_hint: :bearer | :basic | :raw,
          expires_at: integer() | :never
        }

  @type materialize_error_reason :: :unknown_binding | :resolution_failed

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the singleton.

  ## Options

    * `:bindings` — `%{String.t() => Binding.t()}`. Defaults to `%{}`.
    * `:name` — the registered name. Defaults to `__MODULE__`.

  Test code typically passes a unique `:name` so multiple instances
  may run in parallel without colliding on the global named ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    bindings = Keyword.get(opts, :bindings, %{})
    GenServer.start_link(__MODULE__, %{bindings: bindings, name: name}, name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Resolve a binding to bytes.

  Re-reads `env` / `file` sources on every call (§7.4). On success,
  registers the resolved bytes into the redaction-set ETS table
  *before* returning (§7.5.2).

  Returns:

    * `{:ok, %{raw, scheme_hint, expires_at: :never}}` on success.
      `scheme_hint` echoes the binding's hint or `:raw` if unset
      (§7.2).
    * `{:error, :unknown_binding, detail}` if the name is not in the
      registry.
    * `{:error, :resolution_failed, detail}` if the source can't be
      read (env var not set, file missing, etc.).
  """
  @spec materialize(String.t()) ::
          {:ok, materialization()}
          | {:error, materialize_error_reason(), String.t()}
  def materialize(name) when is_binary(name) do
    materialize(__MODULE__, name)
  end

  @doc "See `materialize/1`. Variant that targets a specific server (for tests)."
  @spec materialize(GenServer.server(), String.t()) ::
          {:ok, materialization()}
          | {:error, materialize_error_reason(), String.t()}
  def materialize(server, name) when is_binary(name) do
    GenServer.call(server, {:materialize, name})
  end

  @doc "Sorted list of binding names known to the registry."
  @spec list_bindings() :: [String.t()]
  def list_bindings, do: list_bindings(__MODULE__)

  @doc "See `list_bindings/0`. Variant that targets a specific server (for tests)."
  @spec list_bindings(GenServer.server()) :: [String.t()]
  def list_bindings(server) do
    GenServer.call(server, :list_bindings)
  end

  @doc """
  ETS table name. Compile-time constant — exposed so the redactor
  filter (stream 1C) can look the table up without reaching into this
  GenServer's state.
  """
  @spec table_name() :: atom()
  def table_name, do: @table

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(%{bindings: bindings, name: name}) do
    # Per spec §7.1: do **not** trap exits. If we crash, the supervisor
    # restarts us; the named ETS table dies with the owner, which is
    # acceptable per §7.1's `:rest_for_one` reasoning (children that
    # held materialized values are restarted too).
    table = ensure_table(name)
    {:ok, %{bindings: bindings, table: table}}
  end

  @impl GenServer
  def handle_call({:materialize, name}, _from, state) do
    {:reply, do_materialize(name, state), state}
  end

  def handle_call(:list_bindings, _from, %{bindings: bindings} = state) do
    {:reply, bindings |> Map.keys() |> Enum.sort(), state}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # The production singleton (registered as `__MODULE__`) owns the
  # globally-named ETS table that the redactor filter (stream 1C) reads
  # by name. Test instances (with a unique `:name`) get a private,
  # *unnamed* table so they can run in parallel without colliding on
  # the global name.
  defp ensure_table(__MODULE__) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
  end

  defp ensure_table(_other_name) do
    :ets.new(@table, [:set, :protected, read_concurrency: true])
  end

  defp do_materialize(name, %{bindings: bindings, table: table}) do
    case Map.fetch(bindings, name) do
      :error ->
        {:error, :unknown_binding, "unknown binding #{inspect(name)}"}

      {:ok, %Binding{} = b} ->
        case resolve(b) do
          {:ok, raw} ->
            # §7.5.2: register BEFORE returning so callers cannot see
            # a value that isn't yet in the redaction set.
            :ets.insert(table, {raw, true})

            {:ok,
             %{
               raw: raw,
               scheme_hint: b.scheme_hint || :raw,
               expires_at: :never
             }}

          {:error, detail} ->
            {:error, :resolution_failed, detail}
        end
    end
  end

  defp resolve(%Binding{source: :env, spec: %{var: var}}) do
    case System.get_env(var) do
      nil -> {:error, "env var '#{var}' is not set"}
      "" -> {:error, "env var '#{var}' is not set"}
      value -> {:ok, value}
    end
  end

  defp resolve(%Binding{source: :file, name: name, spec: %{path: path}}) do
    case File.read(path) do
      {:ok, contents} ->
        case String.trim_trailing(contents) do
          "" ->
            {:error, "file '#{path}' is empty"}

          trimmed ->
            log_loose_file_mode(name, path)
            {:ok, trimmed}
        end

      {:error, reason} ->
        detail = reason |> :file.format_error() |> List.to_string()
        {:error, "file '#{path}': #{detail}"}
    end
  end

  defp resolve(%Binding{source: :literal, spec: %{value: value}}) do
    {:ok, value}
  end

  defp resolve(%Binding{source: :exec}) do
    # Defensive: Binding.parse/2 already rejects `exec` at config
    # load. If a hand-built binding sneaks past, fail uniformly here.
    {:error, "exec source deferred to v1.1"}
  end

  defp log_loose_file_mode(binding_name, path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        if (mode &&& 0o077) != 0 do
          Log.log(:info, "credentials_file_mode_loose", %{
            binding: binding_name,
            path: path,
            mode: mode
          })
        end

      {:error, _} ->
        # If we read the file successfully but can't stat it, just
        # skip the loose-mode warning. Don't fail the resolution.
        :ok
    end
  end
end
