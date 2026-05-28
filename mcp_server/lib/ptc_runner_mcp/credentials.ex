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

    * `materialize/1` is deliberately scheme-agnostic at the source
      layer (§7.2). Scheme-specific shaping is the job of the pure
      `apply_emitter/2` function (also defined in this module per
      §7.3) — it has visibility into the consuming auth emitter's
      scheme and produces an opaque `%RedactedHeaders{}` wrapper.
      `apply_emitter/2` does NOT route through this GenServer.
    * The `Credentials.Redactor.scrub/1` filter — added by stream 1C.
      Stream 1C reads this module's ETS table via `:ets.tab2list/1`
      using the name returned by `table_name/0`.
    * Application/supervision wiring — added by stream 1D.

  Spec: `Plans/http-transport-credentials.md` §4.2, §5.4.1, §7.1, §7.2,
  §7.3, §7.4, §7.5.
  """

  use GenServer

  alias PtcRunnerMcp.Credentials.Binding
  alias PtcRunnerMcp.Credentials.RedactedHeaders
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
    # §11 telemetry — `:credentials, :resolve, :start | :stop | :error`.
    # Wraps the GenServer call so `duration_ms` measures the full
    # resolve including source I/O (env / file). Metadata never carries
    # the resolved value — only the binding name, the source atom, and
    # (on error) a short atom reason.
    start_mono = System.monotonic_time()

    :telemetry.execute(
      [:ptc_lisp, :credentials, :resolve, :start],
      %{system_time: System.system_time()},
      %{binding: name}
    )

    raw_result = GenServer.call(server, {:materialize, name})

    duration_ms =
      System.convert_time_unit(
        System.monotonic_time() - start_mono,
        :native,
        :millisecond
      )

    {result, source} = strip_source(raw_result)
    emit_resolve_outcome(name, result, source, duration_ms)
    result
  end

  # The GenServer returns a result map with an internal `:_source` key
  # so we can tag telemetry without re-fetching the binding. Strip it
  # before handing the materialization back to the caller — the
  # documented `materialization()` shape does not include `:_source`,
  # and `apply_emitter/2` does not look at it.
  defp strip_source({:ok, %{_source: source} = m}) do
    {{:ok, Map.delete(m, :_source)}, source}
  end

  defp strip_source({:ok, m}), do: {{:ok, m}, :unknown}

  defp strip_source({:error, _, _} = err), do: {err, :unknown}

  # Map a `materialize/1` result onto the appropriate :stop / :error
  # telemetry event. The resolved bytes are NEVER passed into
  # telemetry metadata — only the binding name, the source atom, and
  # the duration (or short atom reason on error).
  defp emit_resolve_outcome(name, {:ok, _m}, source, duration_ms) do
    :telemetry.execute(
      [:ptc_lisp, :credentials, :resolve, :stop],
      %{duration_ms: duration_ms},
      %{binding: name, source: source}
    )
  end

  defp emit_resolve_outcome(name, {:error, :unknown_binding, _detail}, _source, duration_ms) do
    # `:unknown_binding` has no source — we never reached resolution.
    # Use `:unknown` as the source atom; the reason atom carries the
    # diagnosis. No detail string is included (no path leak risk).
    :telemetry.execute(
      [:ptc_lisp, :credentials, :resolve, :error],
      %{duration_ms: duration_ms},
      %{binding: name, source: :unknown, reason: :unknown_binding}
    )
  end

  defp emit_resolve_outcome(name, {:error, :resolution_failed, detail}, _source_in, duration_ms) do
    {source, reason} = classify_resolution_failure(detail)

    :telemetry.execute(
      [:ptc_lisp, :credentials, :resolve, :error],
      %{duration_ms: duration_ms},
      %{binding: name, source: source, reason: reason}
    )
  end

  # Map `resolution_failed` detail strings to (source, short-atom
  # reason) pairs. The detail strings are produced by `resolve/1` in
  # this module:
  #   * `"env var '<VAR>' is not set"`        → :env, :env_missing
  #   * `"file '<path>' is empty"`            → :file, :file_empty
  #   * `"file '<path>': <enoent|eacces|…>"`  → :file, :file_not_found / :file_unreadable
  #
  # We deliberately match on the leading prefix so the reason atom
  # never echoes the path (which could appear in operator dashboards)
  # — §11 mandates short atoms, not detail strings.
  defp classify_resolution_failure(detail) when is_binary(detail) do
    cond do
      String.starts_with?(detail, "env var ") ->
        {:env, :env_missing}

      String.starts_with?(detail, "file ") and String.contains?(detail, "is empty") ->
        {:file, :file_empty}

      String.starts_with?(detail, "file ") and String.contains?(detail, "no such file") ->
        {:file, :file_not_found}

      String.starts_with?(detail, "file ") ->
        {:file, :file_unreadable}

      true ->
        {:unknown, :resolution_failed}
    end
  end

  defp classify_resolution_failure(_), do: {:unknown, :resolution_failed}

  @typedoc """
  Auth emitter spec consumed by `apply_emitter/2`. Atom keys.

    * `:scheme` — the consuming HTTP auth scheme (`:bearer`, `:basic`,
      or `:custom_header`).
    * `:binding` — the credential binding name (informational here;
      `apply_emitter/2` does not look it up).
    * `:header` — required when `:scheme` is `:custom_header`; the
      header name to emit (lowercased on output). `nil` for `:bearer`
      and `:basic` schemes.
  """
  @type emitter :: %{
          scheme: :bearer | :basic | :custom_header,
          binding: String.t(),
          header: String.t() | nil
        }

  @type apply_error_reason :: :scheme_mismatch | :unencodable

  @doc """
  Convert a `materialize/1` result plus an auth emitter spec into a
  `%RedactedHeaders{}` wrapper carrying the auth-bearing HTTP headers.

  This is a **pure function** — it does NOT route through the
  Credentials GenServer. Callers (the `Upstream.Http` request layer)
  invoke it directly with the materialization they already hold.

  Per spec §7.3:

    * `:bearer` → `[{"authorization", "Bearer " <> raw}]`.
    * `:custom_header` → `[{lowercase(emitter.header), raw}]`. The
      emitter's `:header` field is taken verbatim (config-load
      validation already enforced grammar and rejected `Authorization`
      as a custom header name); we only lowercase for HTTP/2 wire
      hygiene.
    * `:basic` → `[{"authorization", "Basic " <> Base.encode64(user <> ":" <> pass)}]`.
      `raw` may be either a `user:pass` colon-separated binary (split
      on the **first** `:`, so passwords may contain colons) or a
      JSON-shaped binary that decodes to `{"user":"…","pass":"…"}`
      (auto-detected by leading `{`). A `raw` that conforms to
      neither shape returns `{:error, :unencodable, "basic_shape_invalid"}`.
      The detail string `"basic_shape_invalid"` is canonical (§5.5 #7,
      §6.4, `upstream_calls` `error` field).

  `scheme_hint` runtime check: if the materialization's
  `:scheme_hint` is set and does NOT match `emitter.scheme`, returns
  `{:error, :scheme_mismatch, detail}`. `:raw` matches any scheme.

  The runtime check is a defense-in-depth duplicate of
  `Application.check_scheme_hint_compat!/4` (which fires at config
  load); it stays here so callers that assemble emitter +
  materialization without going through the validated config path
  still get a guaranteed mismatch error rather than a silently
  malformed Authorization header.

  ## Empty user / empty pass for `:basic`

  `raw: ":pass"` (empty user) and `raw: "user:"` (empty pass) are both
  **accepted**. RFC 7617 permits empty userid / empty password and
  several real-world upstreams use one or the other (e.g. Stripe-style
  "API token in user position with empty password", or "API token in
  password position with empty user"). Returning the canonically
  encoded `Basic` header here is more useful than rejecting bytes the
  upstream may have meant to receive.
  """
  @spec apply_emitter(materialization(), emitter()) ::
          {:ok, RedactedHeaders.t()}
          | {:error, apply_error_reason(), String.t()}
  def apply_emitter(%{raw: raw, scheme_hint: hint}, %{scheme: scheme} = emitter)
      when is_binary(raw) and is_atom(hint) and is_atom(scheme) do
    with :ok <- check_scheme_hint(hint, scheme) do
      shape_headers(scheme, raw, emitter)
    end
  end

  @doc "Sorted list of binding names known to the registry."
  @spec list_bindings() :: [String.t()]
  def list_bindings, do: list_bindings(__MODULE__)

  @doc "See `list_bindings/0`. Variant that targets a specific server (for tests)."
  @spec list_bindings(GenServer.server()) :: [String.t()]
  def list_bindings(server) do
    GenServer.call(server, :list_bindings)
  end

  @doc false
  @spec register_redaction_secrets([String.t()]) :: :ok
  def register_redaction_secrets(secrets) when is_list(secrets) do
    register_redaction_secrets(__MODULE__, secrets)
  end

  @doc false
  @spec register_redaction_secrets(GenServer.server(), [String.t()]) :: :ok
  def register_redaction_secrets(server, secrets) when is_list(secrets) do
    GenServer.call(server, {:register_redaction_secrets, secrets})
  catch
    :exit, _ -> :ok
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

  def handle_call({:register_redaction_secrets, secrets}, _from, %{table: table} = state)
      when is_list(secrets) do
    secrets
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) > 0))
    |> Enum.each(&:ets.insert(table, {&1, true}))

    {:reply, :ok, state}
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

            # `:_source` is an internal-only key that lets `materialize/2`
            # tag the `:credentials, :resolve, :stop` telemetry with the
            # binding's source atom (`:env | :file | :literal`) without
            # forcing a second `Map.fetch/2` on the binding map. The
            # leading underscore signals "not part of the documented
            # `materialization()` shape" — `apply_emitter/2` ignores it.
            {:ok,
             %{
               raw: raw,
               scheme_hint: b.scheme_hint || :raw,
               expires_at: :never,
               _source: b.source
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

  # ---- apply_emitter/2 helpers ---------------------------------------------

  # `:raw` hint matches any emitter scheme. Otherwise the hint atom
  # MUST equal the emitter's scheme atom.
  defp check_scheme_hint(:raw, _scheme), do: :ok
  defp check_scheme_hint(hint, scheme) when hint == scheme, do: :ok

  defp check_scheme_hint(hint, scheme) do
    {:error, :scheme_mismatch,
     "binding scheme_hint #{inspect(hint)} is incompatible with emitter scheme #{inspect(scheme)}"}
  end

  defp shape_headers(:bearer, raw, _emitter) do
    {:ok, RedactedHeaders.new([{"authorization", "Bearer " <> raw}])}
  end

  defp shape_headers(:custom_header, raw, %{header: header}) when is_binary(header) do
    {:ok, RedactedHeaders.new([{String.downcase(header), raw}])}
  end

  defp shape_headers(:basic, raw, _emitter) do
    case parse_basic(raw) do
      {:ok, user, pass} ->
        encoded = Base.encode64(user <> ":" <> pass)
        {:ok, RedactedHeaders.new([{"authorization", "Basic " <> encoded}])}

      :error ->
        {:error, :unencodable, "basic_shape_invalid"}
    end
  end

  # JSON-shaped basic credentials: leading `{` triggers JSON
  # auto-detect. The decoded object MUST contain string `"user"` and
  # `"pass"` keys with binary values — anything else (decode error,
  # missing keys, non-binary values) is `:error`, which the caller
  # converts to the canonical `"basic_shape_invalid"`.
  defp parse_basic(<<"{", _::binary>> = raw) do
    case Jason.decode(raw) do
      {:ok, %{"user" => user, "pass" => pass}} when is_binary(user) and is_binary(pass) ->
        {:ok, user, pass}

      _ ->
        :error
    end
  end

  # `user:pass` form: split on the FIRST `:` so passwords may contain
  # colons (some upstreams use colon-bearing tokens as the password).
  # Empty user (`":pass"`) and empty pass (`"user:"`) are both
  # accepted — see moduledoc on `apply_emitter/2`.
  defp parse_basic(raw) when is_binary(raw) do
    case :binary.split(raw, ":") do
      [user, pass] -> {:ok, user, pass}
      _ -> :error
    end
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
