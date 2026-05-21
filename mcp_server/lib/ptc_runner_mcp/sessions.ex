defmodule PtcRunnerMcp.Sessions do
  @moduledoc """
  Public facade for stateful PTC-Lisp MCP sessions.

  Routing code can use the high-level `start_session/2`, `eval/4`,
  `inspect/3`, `forget/3`, and `close/3` functions, or the worker-friendly
  `begin_eval/4` / `run_snapshot/3` / `commit_eval/5` protocol.
  """

  import Kernel, except: [inspect: 1]

  alias PtcRunnerMcp.{
    AggregatorTools,
    CatalogBuiltins,
    CatalogConfig,
    DebugConfig,
    Envelope,
    Limits,
    OutputLimits,
    PromptRegistry,
    ResponseProfile,
    Tools,
    UpstreamCalls
  }

  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

  alias PtcRunnerMcp.Sessions.{Config, Owner, Projection, Registry, Session, Supervisor}

  @names_registry PtcRunnerMcp.Sessions.Names

  @sync_tool_names [
    "lisp_session_start",
    "lisp_session_list",
    "lisp_session_inspect",
    "lisp_session_forget",
    "lisp_session_close"
  ]
  @async_tool_names ["lisp_session_eval"]
  @tool_names @sync_tool_names ++ @async_tool_names

  @type owner :: Owner.t()
  @type response :: {:ok, map()} | {:error, map()}

  @doc """
  Start the sessions registry and dynamic supervisor if they are absent.

  This is a Phase 1 convenience. Production supervision can instead add
  `child_specs/0` to `PtcRunnerMcp.Supervisor`.
  """
  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    case ensure_process(@names_registry, names_registry_child_spec()) do
      :ok ->
        case ensure_process(Registry, {Registry, []}) do
          :ok -> ensure_process(Supervisor, {Supervisor, []})
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Child specs for future Application supervision wiring."
  @spec child_specs() :: [Elixir.Supervisor.child_spec() | {module(), term()}]
  def child_specs do
    [
      names_registry_child_spec(),
      {Registry, [session_supervisor: Supervisor]},
      {Supervisor, []}
    ]
  end

  defp names_registry_child_spec do
    {Elixir.Registry,
     keys: :unique, name: @names_registry, partitions: System.schedulers_online()}
  end

  @doc "Return true when stateful sessions are enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

  @doc "True when the given MCP tool name belongs to the sessions surface."
  @spec tool_name?(term()) :: boolean()
  def tool_name?(name), do: is_binary(name) and name in @tool_names

  @doc "True for session tools that must run on the gated async worker path."
  @spec async_tool_name?(term()) :: boolean()
  def async_tool_name?(name), do: is_binary(name) and name in @async_tool_names

  @doc "Tool entries for `tools/list`; empty when sessions are disabled."
  @spec tool_entries() :: [map()]
  def tool_entries do
    if enabled?() do
      [
        session_start_tool(),
        session_list_tool(),
        session_eval_tool(),
        session_inspect_tool(),
        session_forget_tool(),
        session_close_tool()
      ]
    else
      []
    end
  end

  @doc "Handle a session `tools/call` outer params map and return an MCP envelope."
  @spec call(map()) :: map()
  def call(%{"name" => "lisp_session_start", "arguments" => args}) when is_map(args) do
    args
    |> start_session_args()
    |> envelope()
  end

  def call(%{"name" => name, "arguments" => args})
      when is_binary(name) and name in @tool_names and not is_map(args) do
    Envelope.error_envelope(Projection.error(:session_args_error, "arguments must be an object"))
  end

  def call(%{"name" => "lisp_session_start"}),
    do: call(%{"name" => "lisp_session_start", "arguments" => %{}})

  def call(%{"name" => "lisp_session_list", "arguments" => args}) when is_map(args) do
    args
    |> list_session_args()
    |> envelope()
  end

  def call(%{"name" => "lisp_session_eval", "arguments" => args}) when is_map(args) do
    case validate_eval(args) do
      {:ok, validated} -> eval_validated(validated)
      {:error, envelope} -> envelope
    end
  end

  def call(%{"name" => "lisp_session_inspect", "arguments" => args}) when is_map(args) do
    session_id = Map.get(args, "session_id")
    view = Map.get(args, "view", "overview")
    envelope(inspect(session_id, owner_context(args), view))
  end

  def call(%{"name" => "lisp_session_forget", "arguments" => args}) when is_map(args) do
    session_id = Map.get(args, "session_id")
    envelope(forget(session_id, owner_context(args), args))
  end

  def call(%{"name" => "lisp_session_close", "arguments" => args}) when is_map(args) do
    session_id = Map.get(args, "session_id")
    reason = Map.get(args, "reason", "closed")
    envelope(close(session_id, owner_context(args), reason))
  end

  def call(%{"name" => name}) when is_binary(name) and name in @tool_names do
    call(%{"name" => name, "arguments" => %{}})
  end

  def call(%{"name" => name}) when is_binary(name), do: Envelope.unknown_tool(name)
  def call(_params), do: Envelope.unknown_tool("")

  @doc "List live sessions for the given owner without refreshing idle timers."
  @spec list(map() | keyword() | nil) :: response()
  def list(owner_context \\ nil) do
    with :ok <- enabled(),
         :ok <- ensure_started(),
         {:ok, owner} <- Owner.from_context(owner_context) do
      sessions =
        owner
        |> Registry.list()
        |> Enum.flat_map(fn meta ->
          try do
            case Session.summary(meta.pid, owner) do
              {:ok, summary} -> [summary]
              {:error, _response} -> []
            end
          catch
            :exit, _reason -> []
          end
        end)
        |> Enum.sort_by(&summary_updated_at/1, {:desc, DateTime})

      {:ok, Projection.list(sessions)}
    else
      :disabled -> {:error, disabled_error()}
      {:error, reason} when is_atom(reason) -> {:error, registry_error(reason)}
      {:error, response} when is_map(response) -> {:error, response}
    end
  end

  @doc "Validate `lisp_session_eval` arguments before acquiring the global eval gate."
  @spec validate_eval(map()) :: {:ok, map()} | {:error, map()}
  def validate_eval(args) when is_map(args) do
    with {:ok, session_id} <- required_string(args, "session_id"),
         {:ok, program} <- required_string(args, "program"),
         :ok <- validate_program_size(program),
         {:ok, context} <- validate_context(Map.get(args, "context", %{})),
         {:ok, parsed_signature} <- Tools.validate_output_contract(args) do
      {:ok,
       %{
         session_id: session_id,
         program: program,
         context: context,
         owner_context: owner_context(args),
         parsed_signature: parsed_signature
       }}
    else
      {:error, message} ->
        {:error, Envelope.error_envelope(Projection.error(:session_args_error, message))}
    end
  end

  @doc "Run a previously validated `lisp_session_eval` argument map."
  @spec eval_validated(map(), keyword()) :: map()
  def eval_validated(validated, opts \\ []) when is_map(validated) do
    eval_opts =
      validated
      |> Map.take([:context, :parsed_signature])
      |> Map.merge(Map.new(opts))

    validated.session_id
    |> eval(validated.program, validated.owner_context, eval_opts)
    |> envelope()
  end

  @doc "Start a session for the given owner context."
  @spec start_session(map() | keyword() | nil, map() | keyword()) :: response()
  def start_session(owner_context \\ nil, opts \\ %{}) do
    with :ok <- enabled(),
         :ok <- ensure_started(),
         {:ok, owner} <- Owner.from_context(owner_context),
         {:ok, meta} <- Registry.start_session(owner, opts),
         {:ok, response} <- Session.start_response(meta.pid, owner) do
      {:ok, response}
    else
      :disabled -> {:error, disabled_error()}
      {:error, reason} when is_atom(reason) -> {:error, registry_error(reason)}
      {:error, response} when is_map(response) -> {:error, response}
    end
  end

  @doc """
  Evaluate a PTC-Lisp program against a session.

  This function is safe for MCP routing workers: it reserves the session, runs
  `PtcRunner.Lisp.run/2` in the caller process, then commits or rejects the
  candidate state transactionally.
  """
  @spec eval(String.t(), String.t(), map() | keyword() | nil, map()) :: response()
  def eval(session_id, program, owner_context \\ nil, opts \\ %{})

  def eval(session_id, program, owner_context, opts) when is_binary(session_id) do
    opts = Map.new(opts)
    request_id = Map.get(opts, :request_id, make_ref())

    with :ok <- enabled(),
         :ok <- ensure_started(),
         {:ok, owner} <- Owner.from_context(owner_context),
         {:ok, meta} <- Registry.lookup(session_id),
         {:ok, snapshot} <- Session.begin_eval(meta.pid, owner, request_id, %{program: program}) do
      execute_and_commit(meta.pid, owner, request_id, snapshot, program, opts)
    else
      :disabled -> {:error, disabled_error()}
      {:error, reason} when is_atom(reason) -> {:error, registry_error(reason)}
      {:error, response} when is_map(response) -> {:error, response}
    end
  catch
    kind, reason ->
      {:error,
       Projection.error(
         :session_args_error,
         "session eval failed before commit",
         %{kind: kind, detail: Kernel.inspect(reason)}
       )}
  end

  def eval(_session_id, _program, _owner_context, _opts) do
    {:error, Projection.error(:session_args_error, "session_id must be a non-empty string")}
  end

  @doc "Reserve a session for eval and return a snapshot for a worker."
  @spec begin_eval(String.t(), owner(), term(), map()) :: {:ok, map()} | {:error, map()}
  def begin_eval(session_id, owner, request_id, args) do
    with :ok <- enabled(),
         :ok <- ensure_started(),
         {:ok, meta} <- Registry.lookup(session_id) do
      Session.begin_eval(meta.pid, owner, request_id, args)
    else
      :disabled -> {:error, disabled_error()}
      {:error, reason} when is_atom(reason) -> {:error, registry_error(reason)}
    end
  end

  @doc "Run a previously acquired eval snapshot."
  @spec run_snapshot(map(), String.t(), map()) ::
          {:ok, PtcRunner.Step.t()} | {:error, PtcRunner.Step.t()}
  def run_snapshot(snapshot, program, opts \\ %{}) when is_map(snapshot) and is_binary(program) do
    PtcRunner.Lisp.run(program, Session.lisp_opts(snapshot, program, opts))
  end

  @doc "Commit a worker eval result."
  @spec commit_eval(String.t(), owner(), term(), {:ok, map()} | {:error, map()}, map()) ::
          response()
  def commit_eval(session_id, owner, request_id, result, opts \\ %{}) do
    with :ok <- enabled(),
         :ok <- ensure_started(),
         {:ok, meta} <- Registry.lookup(session_id) do
      Session.commit_eval(meta.pid, owner, request_id, result, opts)
    else
      :disabled -> {:error, disabled_error()}
      {:error, reason} when is_atom(reason) -> {:error, registry_error(reason)}
    end
  end

  @doc "Atomically reserve a session eval before the global eval gate is acquired."
  @spec reserve_eval(map(), term()) :: {:ok, map()} | {:error, map()}
  def reserve_eval(
        %{session_id: session_id, owner_context: owner_context} = validated,
        request_id
      ) do
    with :ok <- enabled(),
         :ok <- ensure_started(),
         {:ok, owner} <- Owner.from_context(owner_context),
         {:ok, meta} <- Registry.lookup(session_id) do
      case Session.reserve_eval(meta.pid, owner, request_id, %{program: validated.program}) do
        {:ok, snapshot} ->
          {:ok,
           %{
             pid: meta.pid,
             owner: owner,
             request_id: request_id,
             snapshot: snapshot,
             program: validated.program,
             opts: Map.take(validated, [:context, :parsed_signature])
           }}

        {:error, response} ->
          {:error, response}
      end
    else
      :disabled -> {:error, disabled_error()}
      {:error, reason} when is_atom(reason) -> {:error, registry_error(reason)}
      {:error, response} when is_map(response) -> {:error, response}
    end
  end

  @doc "Run an eval previously reserved by `reserve_eval/2`."
  @spec eval_reserved(map(), keyword()) :: map()
  def eval_reserved(reservation, opts \\ []) when is_map(reservation) do
    owner = Map.fetch!(reservation, :owner)
    pid = Map.fetch!(reservation, :pid)
    request_id = Map.fetch!(reservation, :request_id)

    case Session.attach_eval_worker(pid, owner, request_id, self()) do
      :ok ->
        eval_opts =
          reservation
          |> Map.get(:opts, %{})
          |> Map.merge(Map.new(opts))

        reservation
        |> Map.fetch!(:snapshot)
        |> then(&execute_and_commit(pid, owner, request_id, &1, reservation.program, eval_opts))
        |> envelope()

      {:error, response} when is_map(response) ->
        Envelope.error_envelope(response)
    end
  end

  @doc "Abort an eval previously reserved by `reserve_eval/2`."
  @spec abort_reserved_eval(map(), term()) :: :ok | {:error, map()}
  def abort_reserved_eval(reservation, reason \\ :aborted) when is_map(reservation) do
    Session.abort_eval(
      Map.fetch!(reservation, :pid),
      Map.fetch!(reservation, :owner),
      Map.fetch!(reservation, :request_id),
      reason
    )
  end

  @doc "Inspect a session."
  @spec inspect(String.t(), map() | keyword() | nil, String.t()) :: response()
  def inspect(session_id, owner_context \\ nil, view \\ "overview")

  def inspect(session_id, owner_context, view) when is_binary(session_id) do
    with :ok <- enabled(),
         :ok <- ensure_started(),
         {:ok, owner} <- Owner.from_context(owner_context),
         {:ok, meta} <- Registry.lookup(session_id) do
      Session.inspect_view(meta.pid, owner, view)
    else
      :disabled -> {:error, disabled_error()}
      {:error, reason} when is_atom(reason) -> {:error, registry_error(reason)}
      {:error, response} when is_map(response) -> {:error, response}
    end
  end

  def inspect(_session_id, _owner_context, _view) do
    {:error, Projection.error(:session_args_error, "session_id must be a non-empty string")}
  end

  @doc "Forget selected bindings and histories."
  @spec forget(String.t(), map() | keyword() | nil, map() | keyword()) :: response()
  def forget(session_id, owner_context \\ nil, opts \\ %{})

  def forget(session_id, owner_context, opts) when is_binary(session_id) do
    with :ok <- enabled(),
         :ok <- ensure_started(),
         {:ok, owner} <- Owner.from_context(owner_context),
         {:ok, meta} <- Registry.lookup(session_id) do
      Session.forget(meta.pid, owner, Map.new(opts))
    else
      :disabled -> {:error, disabled_error()}
      {:error, reason} when is_atom(reason) -> {:error, registry_error(reason)}
      {:error, response} when is_map(response) -> {:error, response}
    end
  end

  def forget(_session_id, _owner_context, _opts) do
    {:error, Projection.error(:session_args_error, "session_id must be a non-empty string")}
  end

  @doc "Close a session and delete its state."
  @spec close(String.t(), map() | keyword() | nil, term()) :: response()
  def close(session_id, owner_context \\ nil, reason \\ "closed")

  def close(session_id, owner_context, reason) when is_binary(session_id) do
    with :ok <- enabled(),
         :ok <- ensure_started(),
         {:ok, owner} <- Owner.from_context(owner_context),
         {:ok, meta} <- Registry.lookup(session_id) do
      Session.close(meta.pid, owner, reason)
    else
      :disabled -> {:error, disabled_error()}
      {:error, reason} when is_atom(reason) -> {:error, registry_error(reason)}
      {:error, response} when is_map(response) -> {:error, response}
    end
  end

  def close(_session_id, _owner_context, _reason) do
    {:error, Projection.error(:session_args_error, "session_id must be a non-empty string")}
  end

  @doc "Close every live PTC-Lisp session owned by the given owner context."
  @spec close_owner(map() | keyword() | nil, term()) :: :ok
  def close_owner(owner_context, reason \\ "owner_closed") do
    with :ok <- enabled(),
         :ok <- ensure_started(),
         {:ok, owner} <- Owner.from_context(owner_context) do
      owner
      |> Registry.list()
      |> Enum.each(fn meta ->
        _ = Session.close(meta.pid, owner, reason)
      end)
    end

    :ok
  end

  defp enabled do
    if Config.enabled?(), do: :ok, else: :disabled
  end

  defp ensure_process(name, child_spec) do
    case Process.whereis(name) do
      nil ->
        module = elem(child_spec, 0)
        opts = Keyword.put_new(elem(child_spec, 1), :name, name)

        case module.start_link(opts) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  defp disabled_error do
    Projection.error(
      :sessions_disabled,
      "stateful PTC-Lisp sessions are disabled; start the server with --sessions or PTC_RUNNER_MCP_SESSIONS=true"
    )
  end

  defp registry_error(:session_not_found) do
    Projection.error(:session_not_found, "session not found")
  end

  defp registry_error(:session_closed) do
    Projection.error(:session_closed, "session is closed")
  end

  defp registry_error(:session_args_error) do
    Projection.error(:session_args_error, "malformed session arguments")
  end

  defp registry_error(:max_sessions_exceeded) do
    Projection.error(
      :session_limit_exceeded,
      "maximum number of sessions reached"
    )
  end

  defp registry_error(:max_sessions_per_owner_exceeded) do
    Projection.error(
      :session_limit_exceeded,
      "maximum number of sessions for this owner reached"
    )
  end

  defp registry_error(reason) do
    Projection.error(:session_args_error, Kernel.inspect(reason))
  end

  defp execute_and_commit(pid, owner, request_id, snapshot, program, opts) do
    {run_opts, drain_upstream_calls} = aggregator_run_opts(opts, request_id)
    result = run_snapshot(snapshot, program, run_opts)
    commit_opts = Map.put(opts, :upstream_calls, drain_upstream_calls.())
    Session.commit_eval(pid, owner, request_id, result, commit_opts)
  catch
    kind, reason ->
      _ = Session.abort_eval(pid, owner, request_id, reason)

      {:error,
       Projection.error(
         :session_args_error,
         "session eval failed before commit",
         %{kind: kind, detail: Kernel.inspect(reason)}
       )}
  end

  defp envelope({:ok, response}) do
    profile = ResponseProfile.current()
    {public, diagnostic} = pop_debug_structured(response)
    session_eval? = session_eval_payload?(public) or is_map(diagnostic)

    payload = if profile == :debug and is_map(diagnostic), do: diagnostic, else: public

    payload
    |> OutputLimits.shape_session_payload(:ok, profile)
    |> wrap_session_success(session_eval?)
    |> OutputLimits.limit_envelope(profile)
    |> maybe_attach_debug_structured(diagnostic)
  end

  defp envelope({:error, response}) when is_map(response) do
    profile = ResponseProfile.current()
    {public, diagnostic} = pop_debug_structured(response)
    session_eval? = session_eval_payload?(public) or is_map(diagnostic)

    payload = if profile == :debug and is_map(diagnostic), do: diagnostic, else: public

    payload
    |> OutputLimits.shape_session_payload(:error, profile)
    |> wrap_session_error(session_eval?)
    |> OutputLimits.limit_envelope(profile)
    |> maybe_attach_debug_structured(diagnostic)
  end

  defp wrap_session_success(payload, session_eval?) do
    if session_eval? do
      Envelope.ptc_lisp_session_success(payload)
    else
      Envelope.success(payload)
    end
  end

  defp wrap_session_error(payload, session_eval?) do
    if session_eval? do
      Envelope.ptc_lisp_session_error(payload)
    else
      Envelope.error_envelope(payload)
    end
  end

  defp session_eval_payload?(payload) when is_map(payload) do
    Map.has_key?(payload, "result") and is_map(Map.get(payload, "session"))
  end

  defp pop_debug_structured(response) when is_map(response) do
    {Map.delete(response, "__lisp_debug_structured"),
     Map.get(response, "__lisp_debug_structured")}
  end

  defp maybe_attach_debug_structured(envelope, diagnostic) when is_map(diagnostic) do
    if DebugConfig.enabled?() do
      Map.put(envelope, "__lisp_debug_structured", diagnostic)
    else
      envelope
    end
  end

  defp maybe_attach_debug_structured(envelope, _diagnostic), do: envelope

  defp start_session_args(args) do
    case validate_start_args(args) do
      :ok ->
        opts =
          %{}
          |> maybe_put(:title, Map.get(args, "title"))
          |> maybe_put(:ttl_ms, Map.get(args, "ttl_ms"))

        start_session(owner_context(args), opts)

      {:error, message} ->
        {:error, Projection.error(:session_args_error, message)}
    end
  end

  defp list_session_args(args) do
    case Map.drop(args, [:owner]) do
      empty when map_size(empty) == 0 ->
        owner_context = owner_context(args)
        list(owner_context)

      _other ->
        {:error, Projection.error(:session_args_error, "lisp_session_list takes no arguments")}
    end
  end

  defp owner_context(args) when is_map(args) do
    # Internal/test override for ownership simulation. Public clients should
    # rely on transport-derived ownership and should not send this field.
    Map.get(args, :owner) || Map.get(args, "owner") || nil
  end

  defp validate_start_args(args) when is_map(args) do
    case Enum.find(Map.keys(args), &(not start_arg_key?(&1))) do
      nil -> :ok
      key -> {:error, "unexpected lisp_session_start argument: #{key}"}
    end
  end

  defp start_arg_key?(key) when key in ["title", "ttl_ms", "owner", :owner], do: true
  defp start_arg_key?(_key), do: false

  defp summary_updated_at(%{"updated_at" => updated_at}) when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> DateTime.from_unix!(0)
    end
  end

  defp summary_updated_at(_summary), do: DateTime.from_unix!(0)

  defp required_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} must be a non-empty string"}
    end
  end

  defp validate_context(context) when is_map(context) and not is_struct(context) do
    with :ok <- validate_context_keys(context),
         :ok <- validate_context_bytes(context) do
      {:ok, context}
    end
  end

  defp validate_context(_context), do: {:error, "context must be an object when supplied"}

  defp validate_context_keys(context) do
    Enum.reduce_while(context, :ok, fn
      {key, _value}, _acc when not is_binary(key) ->
        {:halt, {:error, "context keys must be strings"}}

      {"", _value}, _acc ->
        {:halt, {:error, "context keys must be non-empty"}}

      {key, _value}, _acc ->
        if String.contains?(key, "/") do
          {:halt, {:error, "context keys may not contain `/`"}}
        else
          {:cont, :ok}
        end
    end)
  end

  defp validate_context_bytes(context) do
    case Jason.encode(context) do
      {:ok, encoded} ->
        if byte_size(encoded) <= Limits.max_context_bytes() do
          :ok
        else
          {:error, "context exceeds max_context_bytes"}
        end

      {:error, reason} ->
        {:error, "context is not JSON-encodable: #{Kernel.inspect(reason)}"}
    end
  end

  defp validate_program_size(program) do
    if byte_size(program) <= Limits.max_program_bytes() do
      :ok
    else
      {:error, "program exceeds max_program_bytes"}
    end
  end

  defp aggregator_run_opts(opts, request_id) do
    if Tools.configured_aggregator_mode?() do
      catalog_config = CatalogConfig.get()

      call_context =
        UpstreamCalls.new_call_context(
          collector_pid: self(),
          collector_ref: make_ref(),
          max_calls: Limits.max_upstream_calls_per_program(),
          max_catalog_ops: catalog_config.max_catalog_ops_per_program,
          call_timeout_ms: Limits.upstream_call_timeout_ms(),
          max_response_bytes: Limits.max_upstream_response_bytes(),
          max_catalog_result_bytes: catalog_config.max_catalog_result_bytes
        )

      tools = AggregatorTools.build(call_context, request_id: request_id)

      catalog_exec =
        CatalogBuiltins.build(call_context,
          registry: UpstreamRegistry,
          catalog_config: catalog_config
        )

      run_opts =
        opts
        |> Map.put(:tools, tools)
        |> Map.put(:catalog_exec, catalog_exec)
        |> Map.put(:profile, :mcp_aggregator)

      {run_opts, fn -> UpstreamCalls.drain(call_context.collector_ref) end}
    else
      {opts, fn -> [] end}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp session_start_tool do
    %{
      "name" => "lisp_session_start",
      "description" => PromptRegistry.render(:mcp_session_start_description, []),
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string"},
          "ttl_ms" => %{"type" => "integer", "minimum" => 1}
        },
        "additionalProperties" => false
      },
      "outputSchema" => session_output_schema(["status", "session_id"])
    }
  end

  defp session_list_tool do
    %{
      "name" => "lisp_session_list",
      "description" => PromptRegistry.render(:mcp_session_list_description, []),
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      },
      "outputSchema" => session_output_schema(["status", "count", "sessions"])
    }
  end

  defp session_eval_tool do
    opts =
      if Tools.configured_aggregator_mode?() do
        [catalog: PtcRunnerMcp.CatalogDescription.render()]
      else
        []
      end

    %{
      "name" => "lisp_session_eval",
      "description" => PromptRegistry.render(session_eval_description_key(), opts),
      "inputSchema" => %{
        "type" => "object",
        "required" => ["session_id", "program"],
        "properties" => %{
          "session_id" => %{"type" => "string"},
          "program" => %{"type" => "string"},
          "context" => %{"type" => "object"},
          "output_schema" => %{
            "type" => "object",
            "description" =>
              "JSON Schema validated against the program's return value. On mismatch, the eval is rejected and session state is not committed."
          }
        },
        "additionalProperties" => false
      }
    }
    |> maybe_put("outputSchema", session_eval_output_schema(ResponseProfile.current()))
  end

  defp session_eval_description_key do
    if Tools.configured_aggregator_mode?() do
      :mcp_session_eval_with_upstreams_description
    else
      :mcp_session_eval_description
    end
  end

  defp session_eval_output_schema(:slim), do: nil
  defp session_eval_output_schema(_profile), do: session_output_schema(["status", "session"])

  defp session_inspect_tool do
    %{
      "name" => "lisp_session_inspect",
      "description" => PromptRegistry.render(:mcp_session_inspect_description, []),
      "inputSchema" => %{
        "type" => "object",
        "required" => ["session_id"],
        "properties" => %{
          "session_id" => %{"type" => "string"},
          "view" => %{
            "type" => "string",
            "enum" => ["overview", "memory", "prints", "tool_calls", "history", "limits"]
          }
        }
      },
      "outputSchema" => session_output_schema(["status", "session_id", "session"])
    }
  end

  defp session_forget_tool do
    %{
      "name" => "lisp_session_forget",
      "description" => PromptRegistry.render(:mcp_session_forget_description, []),
      "inputSchema" => %{
        "type" => "object",
        "required" => ["session_id"],
        "properties" => %{
          "session_id" => %{"type" => "string"},
          "bindings" => %{"type" => "array", "items" => %{"type" => "string"}},
          "clear" => %{
            "type" => "array",
            "items" => %{
              "type" => "string",
              "enum" => ["memory", "history", "prints", "tool_calls", "upstream_calls"]
            }
          }
        }
      },
      "outputSchema" => session_output_schema(["status", "session_id"])
    }
  end

  defp session_close_tool do
    %{
      "name" => "lisp_session_close",
      "description" => PromptRegistry.render(:mcp_session_close_description, []),
      "inputSchema" => %{
        "type" => "object",
        "required" => ["session_id"],
        "properties" => %{
          "session_id" => %{"type" => "string"},
          "reason" => %{"type" => "string"}
        }
      },
      "outputSchema" => session_output_schema(["status", "session_id", "closed"])
    }
  end

  defp session_output_schema(success_required) do
    %{
      "type" => "object",
      "oneOf" => [session_success_schema(success_required), session_error_schema()]
    }
  end

  defp session_success_schema(required) do
    %{
      "type" => "object",
      "required" => required,
      "properties" => session_common_properties(%{"status" => %{"const" => "ok"}}),
      "additionalProperties" => true
    }
  end

  defp session_error_schema do
    %{
      "type" => "object",
      "required" => ["status", "reason", "message", "feedback"],
      "properties" =>
        session_common_properties(%{
          "status" => %{"const" => "error"},
          "reason" => %{"type" => "string"}
        }),
      "additionalProperties" => true
    }
  end

  defp session_common_properties(overrides) do
    Map.merge(
      %{
        "status" => %{"type" => "string", "enum" => ["ok", "error"]},
        "reason" => %{"type" => "string"},
        "message" => %{"type" => "string"},
        "feedback" => %{"type" => "string"},
        "session_id" => %{"type" => "string"},
        "session" => %{"type" => "object"},
        "count" => %{"type" => "integer"},
        "sessions" => %{"type" => "array"},
        "limits" => %{"type" => "object"},
        "memory" => %{"type" => "object"},
        "result" => %{"type" => "string"},
        "prints" => %{"type" => "array"},
        "text" => %{"type" => "string"},
        "closed" => %{"type" => "boolean"},
        "truncated" => %{"type" => "boolean"},
        "output_truncated" => %{"type" => "boolean"},
        "prints_truncated" => %{"type" => "boolean"},
        "feedback_truncated" => %{"type" => "boolean"},
        "validated" => %{},
        "validated_preview" => %{"type" => "string"},
        "validated_preview_truncated" => %{"type" => "boolean"},
        "validated_bytes" => %{"type" => "integer", "minimum" => 0}
      },
      overrides
    )
  end
end
