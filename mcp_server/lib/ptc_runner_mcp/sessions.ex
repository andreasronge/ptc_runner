defmodule PtcRunnerMcp.Sessions do
  @moduledoc """
  Public facade for stateful PTC-Lisp MCP sessions.

  Routing code can use the high-level `start_session/2`, `eval/4`,
  `inspect/3`, `forget/3`, and `close/3` functions, or the worker-friendly
  `begin_eval/4` / `run_snapshot/3` / `commit_eval/5` protocol.
  """

  import Kernel, except: [inspect: 1]

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler, as: PreludeCompiler
  alias PtcRunner.Lisp.Prelude.Export
  alias PtcRunner.PreludeStore.Selection
  alias PtcRunner.PreludeStore.Tools, as: PreludeStoreTools
  alias PtcRunner.Upstream.{Eval, RunContext, Runtime}

  alias PtcRunnerMcp.{
    CatalogConfig,
    DebugConfig,
    Envelope,
    Limits,
    OutputLimits,
    PromptRegistry,
    ResponseProfile,
    RootUpstreamRuntime,
    Tools,
    TurnLogConfig
  }

  alias PtcRunnerMcp.Http.AuthClaims
  alias PtcRunnerMcp.Sessions.{Config, Owner, Policy, Projection, Registry, Session, Supervisor}

  @names_registry PtcRunnerMcp.Sessions.Names

  @sync_tool_names [
    "lisp_session_start",
    "lisp_session_list",
    "lisp_session_list_preludes",
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
      {Registry, [session_supervisor: Supervisor, trap_exit: true]},
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
        session_list_preludes_tool(),
        session_eval_tool(),
        session_inspect_tool(),
        session_forget_tool(),
        session_close_tool()
      ]
      |> Enum.filter(&Policy.mcp_tool_allowed?(Config.policy(), &1["name"]))
    else
      []
    end
  end

  @doc "True when an outer MCP session tool is allowed by process-level policy."
  @spec outer_tool_allowed?(String.t()) :: boolean()
  def outer_tool_allowed?(name), do: Policy.mcp_tool_allowed?(Config.policy(), name)

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

  def call(%{"name" => "lisp_session_list_preludes", "arguments" => args}) when is_map(args) do
    args
    |> list_preludes_args()
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

  @doc "Return the frozen prelude refs selected when the session was started."
  @spec list_preludes(String.t(), map() | keyword() | nil) :: response()
  def list_preludes(session_id, owner_context \\ nil)

  def list_preludes(session_id, owner_context) when is_binary(session_id) do
    with :ok <- enabled(),
         :ok <- ensure_started(),
         {:ok, owner} <- Owner.from_context(owner_context),
         {:ok, meta} <- Registry.lookup(session_id) do
      Session.list_preludes(meta.pid, owner)
    else
      :disabled -> {:error, disabled_error()}
      {:error, reason} when is_atom(reason) -> {:error, registry_error(reason)}
      {:error, response} when is_map(response) -> {:error, response}
    end
  end

  def list_preludes(_session_id, _owner_context) do
    {:error, Projection.error(:session_args_error, "session_id must be a non-empty string")}
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
         {:ok, start_opts} <- prepare_start_opts(opts),
         {:ok, meta} <- Registry.start_session(owner, start_opts),
         {:ok, response} <- Session.start_response(meta.pid, owner) do
      {:ok, response}
    else
      :disabled ->
        {:error, disabled_error()}

      {:error, reason} when is_atom(reason) ->
        {:error, registry_error(reason)}

      {:error, response} when is_map(response) ->
        {:error, response}

      {:error, message} when is_binary(message) ->
        {:error, Projection.error(:session_args_error, message)}
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
          {:ok, PtcRunner.Lisp.Result.t()} | {:error, PtcRunner.Lisp.Result.t()}
  def run_snapshot(snapshot, program, opts \\ %{}) when is_map(snapshot) and is_binary(program) do
    PtcRunner.Lisp.run_native(program, Session.lisp_opts(snapshot, program, opts))
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
    opts = Map.put(opts, :grant, Map.get(snapshot, :grant))
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
    Map.get(payload, "status") == "ok" and is_map(Map.get(payload, "session")) and
      is_map(Map.get(payload, "memory")) and Map.has_key?(payload, "history_notices")
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
          |> maybe_put(:preludes, Map.get(args, "preludes"))
          |> maybe_put(:mode, Map.get(args, "mode"))
          |> maybe_put(:tags, Map.get(args, "tags"))
          |> maybe_put(:role, Map.get(args, "role"))
          |> maybe_put(:scoped_base_surface, Map.get(args, "scoped_base_surface"))
          |> maybe_put(:auth_claims, Map.get(args, :auth_claims))

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

  defp list_preludes_args(args) do
    case validate_list_preludes_args(args) do
      :ok ->
        list_preludes(Map.get(args, "session_id"), owner_context(args))

      {:error, message} ->
        {:error, Projection.error(:session_args_error, message)}
    end
  end

  defp owner_context(args) when is_map(args) do
    # Internal/test override for ownership simulation. Public clients should
    # rely on transport-derived ownership and should not send this field.
    Map.get(args, :owner) || Map.get(args, "owner") || nil
  end

  defp validate_start_args(args) when is_map(args) do
    case Enum.find(Map.keys(args), &(not start_arg_key?(&1))) do
      nil ->
        with :ok <- validate_tags_arg(Map.get(args, "tags")),
             :ok <- validate_no_default_tag_conflicts(Map.get(args, "tags")) do
          validate_scoped_base_surface_arg(Map.get(args, "scoped_base_surface"))
        end

      key ->
        {:error, "unexpected lisp_session_start argument: #{key}"}
    end
  end

  defp validate_tags_arg(nil), do: :ok

  defp validate_tags_arg(tags) when is_map(tags) and not is_struct(tags) do
    if map_size(tags) > 32 do
      {:error, "tags may contain at most 32 entries"}
    else
      with :ok <- validate_tag_entries(tags) do
        if Jason.encode!(tags) |> byte_size() > 4_096 do
          {:error, "tags exceed 4096 encoded bytes"}
        else
          :ok
        end
      end
    end
  end

  defp validate_tags_arg(_tags), do: {:error, "tags must be an object when supplied"}

  defp validate_no_default_tag_conflicts(tags) do
    caller_tags = normalize_tags_for_conflict_check(tags)
    default_tags = TurnLogConfig.default_tags()

    case Enum.find(default_tags, fn {key, boot_value} ->
           Map.has_key?(caller_tags, key) and Map.fetch!(caller_tags, key) != boot_value
         end) do
      nil ->
        :ok

      {key, boot_value} ->
        {:error, "tag #{Kernel.inspect(key)} is boot-stamped to #{Kernel.inspect(boot_value)}"}
    end
  end

  defp normalize_tags_for_conflict_check(tags) when is_map(tags) and not is_struct(tags) do
    Enum.reduce(tags, %{}, fn
      {key, value}, acc
      when is_binary(key) and
             (is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)) ->
        Map.put(acc, key, value)

      _other, acc ->
        acc
    end)
  end

  defp normalize_tags_for_conflict_check(_tags), do: %{}

  defp validate_scoped_base_surface_arg(nil), do: :ok
  defp validate_scoped_base_surface_arg(value) when is_boolean(value), do: :ok

  defp validate_scoped_base_surface_arg(_value),
    do: {:error, "scoped_base_surface must be a boolean when supplied"}

  defp validate_tag_entries(tags) do
    Enum.reduce_while(tags, :ok, fn
      {key, value}, :ok
      when is_binary(key) and key != "" and
             (is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)) ->
        {:cont, :ok}

      _other, :ok ->
        {:halt,
         {:error, "tags must be an object with non-empty string keys and scalar JSON values"}}
    end)
  end

  defp prepare_start_opts(opts) when is_map(opts) or is_list(opts) do
    opts = Map.new(opts)
    policy = Config.policy()
    role_arg = Map.get(opts, :role) || Map.get(opts, "role")
    auth_claims = trusted_auth_claims(Map.get(opts, :auth_claims))

    with {:ok, role_arg} <- effective_role_arg(policy, role_arg, auth_claims),
         {:ok, grant} <- Policy.resolve_grant(policy, role_arg),
         :ok <- validate_auth_claims_grant(grant, auth_claims),
         {:ok, mode} <- validate_mode(Map.get(opts, :mode) || Map.get(opts, "mode")),
         :ok <- validate_grant_credentials(grant),
         :ok <- validate_grant_upstream_tools(grant),
         {:ok, scoped_base_surface?} <-
           normalize_scoped_base_surface(start_option(opts, :scoped_base_surface)),
         :ok <- validate_grant_mode(grant, mode) do
      opts =
        opts
        |> Map.delete("role")
        |> Map.delete("scoped_base_surface")
        |> Map.delete(:scoped_base_surface)
        |> Map.delete("auth_claims")
        |> Map.put(:scoped_base_surface, scoped_base_surface?)
        |> Map.delete(:auth_claims)
        |> Map.put(:role, if(grant, do: grant.role))
        |> Map.put(:grant, grant)
        |> Map.put(:grant_fingerprint, if(grant, do: grant.fingerprint))

      case mode do
        :write_capable ->
          prepare_write_capable_start_opts(opts)

        mode ->
          opts |> Map.delete("mode") |> Map.put(:mode, mode) |> prepare_read_only_start_opts()
      end
    end
  end

  defp prepare_start_opts(_opts), do: {:error, "session start options must be an object"}

  defp trusted_auth_claims(%AuthClaims{} = claims) do
    if AuthClaims.trusted?(claims), do: claims, else: nil
  end

  defp trusted_auth_claims(_claims), do: nil

  defp effective_role_arg(_policy, role_arg, nil), do: {:ok, role_arg}

  defp effective_role_arg(policy, nil, %AuthClaims{allowed_roles: allowed_roles}) do
    cond do
      is_binary(policy.default_role) and policy.default_role in allowed_roles ->
        {:ok, policy.default_role}

      length(allowed_roles) == 1 ->
        {:ok, hd(allowed_roles)}

      true ->
        {:error, "role is required for this credential"}
    end
  end

  defp effective_role_arg(_policy, role_arg, %AuthClaims{}), do: {:ok, role_arg}

  defp validate_auth_claims_grant(_grant, nil), do: :ok

  defp validate_auth_claims_grant(%{role: role}, %AuthClaims{allowed_roles: allowed_roles}) do
    if role in allowed_roles do
      :ok
    else
      {:error, "role is not allowed for this credential"}
    end
  end

  defp validate_auth_claims_grant(_grant, %AuthClaims{}),
    do: {:error, "role is not allowed for this credential"}

  defp validate_grant_mode(nil, _mode), do: :ok

  defp validate_grant_mode(grant, mode) do
    if Policy.mode_allowed?(grant, mode) do
      :ok
    else
      {:error, "mode #{mode} is not granted for role #{grant.role}"}
    end
  end

  defp validate_grant_credentials(nil), do: :ok

  defp validate_grant_credentials(grant) do
    if RootUpstreamRuntime.configured?() do
      unknown_granted_credentials(grant)
      |> case do
        [] ->
          :ok

        unknown ->
          {:error, "role #{grant.role} grants unknown credential(s): #{Enum.join(unknown, ", ")}"}
      end
    else
      :ok
    end
  end

  defp validate_grant_upstream_tools(nil), do: :ok

  defp validate_grant_upstream_tools(grant) do
    if RootUpstreamRuntime.configured?() do
      unknown_granted_upstream_tools(grant)
      |> case do
        [] ->
          :ok

        unknown ->
          {:error,
           "role #{grant.role} grants unknown upstream operation(s): #{Enum.join(unknown, ", ")}"}
      end
    else
      :ok
    end
  end

  defp unknown_granted_credentials(grant) do
    case Policy.credential_grants(grant) do
      :all ->
        []

      grants ->
        known = MapSet.new(Runtime.credential_binding_names(RootUpstreamRuntime.runtime()))
        grants |> MapSet.difference(known) |> MapSet.to_list() |> Enum.sort()
    end
  end

  defp unknown_granted_upstream_tools(grant) do
    case Policy.upstream_tool_grants(grant) do
      :all ->
        []

      grants when is_struct(grants, MapSet) ->
        if MapSet.size(grants) == 0 do
          []
        else
          unknown_granted_upstream_tool_ids(grants)
        end
    end
  end

  defp unknown_granted_upstream_tool_ids(grants) do
    snapshot = Runtime.catalog_snapshot(RootUpstreamRuntime.runtime(), materialize: false)

    loaded_servers =
      snapshot
      |> Enum.filter(&(Map.get(&1, "catalog_loaded") == true))
      |> MapSet.new(&Map.get(&1, "name"))

    configured_servers = MapSet.new(snapshot, &Map.get(&1, "name"))

    known_loaded_ops =
      snapshot
      |> Enum.filter(&(Map.get(&1, "catalog_loaded") == true))
      |> Enum.flat_map(fn server ->
        server_name = Map.get(server, "name")

        Enum.map(Map.get(server, "tools", []), fn tool ->
          "upstream:#{server_name}/#{Map.get(tool, "name")}"
        end)
      end)
      |> MapSet.new()

    grants
    |> Enum.reject(fn id ->
      case parse_upstream_tool_id(id) do
        {:ok, server} ->
          (MapSet.member?(configured_servers, server) and
             not MapSet.member?(loaded_servers, server)) or
            MapSet.member?(known_loaded_ops, id)

        :error ->
          false
      end
    end)
    |> Enum.sort()
  end

  defp parse_upstream_tool_id("upstream:" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [server, tool] when server != "" and tool != "" -> {:ok, server}
      _ -> :error
    end
  end

  defp parse_upstream_tool_id(_id), do: :error

  defp prepare_read_only_start_opts(opts) do
    case Map.get(opts, :preludes) || Map.get(opts, "preludes") do
      nil ->
        opts =
          opts
          |> Map.delete("preludes")
          |> maybe_put_read_prelude()

        {:ok, opts}

      refs when is_list(refs) ->
        with {:ok, refs} <- normalize_prelude_refs(refs),
             :ok <- Policy.preludes_allowed?(Map.get(opts, :grant), refs),
             {:ok, selected} <- resolve_start_preludes(refs, opts) do
          start_opts =
            opts
            |> Map.delete("preludes")
            |> Map.delete(:preludes)
            |> maybe_put(:runtime_prelude, Map.get(selected, :runtime_prelude))
            |> maybe_put(:preludes, Map.get(selected, :preludes))
            |> maybe_put(:prelude_projection, Map.get(selected, :prelude_projection))
            |> maybe_put(:prelude_presentation, Map.get(selected, :prelude_presentation))
            |> maybe_put(:direct_namespaces, Map.get(selected, :direct_namespaces))
            |> maybe_put(
              :transitive_namespace_requirers,
              Map.get(selected, :transitive_namespace_requirers)
            )

          {:ok, start_opts}
        end

      _other ->
        {:error, "preludes must be an array when supplied"}
    end
  end

  # A write_capable session attaches the host-shipped `prelude/` capability so
  # the model can author into the configured store via `(prelude/write …)`. It
  # is gated behind `--sessions-allow-prelude-write` (off by default) and a
  # configured store. Combining the write capability with attached data preludes
  # is not yet supported, so write_capable sessions start with no data preludes;
  # the private backing store tools are granted per-eval in `Session.lisp_opts/3`.
  defp prepare_write_capable_start_opts(opts) do
    cond do
      not Config.allow_prelude_write?() ->
        {:error,
         "write_capable sessions are disabled; start the server with --sessions-allow-prelude-write"}

      Config.prelude_store() == nil ->
        {:error, "write_capable sessions require a configured prelude store"}

      Policy.prelude_store_level(Map.get(opts, :grant)) != :write ->
        {:error, "write_capable sessions require a role with prelude_store write grant"}

      (Map.get(opts, :preludes) || Map.get(opts, "preludes")) not in [nil, []] ->
        {:error,
         "write_capable sessions cannot also attach data preludes yet; " <>
           "start a read_only session to attach them"}

      true ->
        case write_capable_runtime_prelude() do
          {:ok, capability} ->
            start_opts =
              opts
              |> Map.delete("preludes")
              |> Map.delete(:preludes)
              |> Map.delete("mode")
              |> Map.put(:mode, :write_capable)
              |> Map.put(:runtime_prelude, capability)

            {:ok, start_opts}

          {:error, error} ->
            {:error, "failed to compile prelude write capability: #{Kernel.inspect(error)}"}
        end
    end
  end

  defp validate_mode(nil), do: {:ok, :read_only}
  defp validate_mode("read_only"), do: {:ok, :read_only}
  defp validate_mode(:read_only), do: {:ok, :read_only}
  defp validate_mode("write_capable"), do: {:ok, :write_capable}
  defp validate_mode(:write_capable), do: {:ok, :write_capable}

  defp validate_mode(other),
    do: {:error, "mode must be \"read_only\" or \"write_capable\", got: #{Kernel.inspect(other)}"}

  defp normalize_scoped_base_surface(nil), do: {:ok, false}
  defp normalize_scoped_base_surface(value) when is_boolean(value), do: {:ok, value}

  defp normalize_scoped_base_surface(_value),
    do: {:error, "scoped_base_surface must be a boolean when supplied"}

  defp start_option(opts, key) when is_atom(key) do
    case Map.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Map.get(opts, Atom.to_string(key))
    end
  end

  defp write_capable_runtime_prelude do
    configured_source = Config.prelude_source()

    source =
      case configured_source do
        nil ->
          PreludeStoreTools.prelude_source()

        source when is_binary(source) ->
          PreludeStoreTools.prelude_source() <>
            "\n\n;; --- ptc_runner configured runtime prelude ---\n\n" <> source
      end

    PreludeCompiler.compile(source)
  end

  defp resolve_start_preludes(refs, opts) do
    case Selection.resolve_with_prefix!(
           Config.prelude_store(),
           refs,
           read_prelude_prefixes(opts),
           configured_prelude_opts(opts)
         ) do
      {nil, []} ->
        {:ok, %{}}

      {runtime_prelude, resolved} ->
        projection = Policy.project_prelude(runtime_prelude, Map.get(opts, :grant))
        filtered_prelude = projection.prelude

        presentation =
          prelude_presentation(
            resolved,
            refs,
            Map.get(opts, :scoped_base_surface),
            filtered_prelude
          )

        {:ok,
         %{
           runtime_prelude: runtime_prelude,
           preludes: resolved,
           prelude_projection: projection,
           prelude_presentation: presentation,
           direct_namespaces: direct_namespaces(runtime_prelude, refs),
           transitive_namespace_requirers:
             transitive_namespace_requirers(runtime_prelude, resolved, refs)
         }}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp direct_namespaces(%Prelude{} = prelude, refs) do
    direct_ids = refs |> Enum.map(&prelude_ref_id/1) |> MapSet.new()

    prelude
    |> prelude_components()
    |> Enum.filter(&(Map.get(&1, :id) in direct_ids))
    |> Enum.flat_map(&Map.get(&1, :namespaces, []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp direct_namespaces(_prelude, _refs), do: []

  defp transitive_namespace_requirers(%Prelude{} = prelude, resolved, refs) do
    direct_ids = refs |> Enum.map(&prelude_ref_id/1) |> MapSet.new()
    components_by_id = Map.new(prelude_components(prelude), &{Map.get(&1, :id), &1})

    resolved
    |> Enum.reject(&(Map.get(&1, :id) in direct_ids))
    |> Enum.flat_map(fn ref ->
      namespaces =
        components_by_id
        |> Map.get(Map.get(ref, :id), %{})
        |> Map.get(:namespaces, [])

      Enum.map(namespaces, &{&1, Map.get(ref, :required_by, [])})
    end)
    |> Map.new()
  end

  defp transitive_namespace_requirers(_prelude, _resolved, _refs), do: %{}

  defp prelude_presentation(_resolved, _refs, false, _filtered_prelude), do: nil
  defp prelude_presentation(_resolved, _refs, nil, _filtered_prelude), do: nil

  defp prelude_presentation(resolved, refs, true, filtered_prelude) do
    direct_ids = refs |> Enum.map(&prelude_ref_id/1) |> MapSet.new()

    case scoped_base_export_mask(resolved, direct_ids, filtered_prelude) do
      {:ok, mask} when map_size(mask) == 0 ->
        nil

      {:ok, mask} ->
        %{export_mask: mask, warnings: []}

      {:fallback, warnings} ->
        %{export_mask: nil, warnings: warnings}
    end
  end

  @doc false
  def __prelude_presentation_for_test__(
        resolved,
        refs,
        scoped_base_surface,
        filtered_prelude \\ nil
      ) do
    prelude_presentation(resolved, refs, scoped_base_surface, filtered_prelude)
  end

  defp scoped_base_export_mask(resolved, direct_ids, filtered_prelude) do
    resolved_by_id = Map.new(resolved, &{Map.get(&1, :id), &1})
    allowed_direct_refs = allowed_direct_export_refs(filtered_prelude, resolved, direct_ids)

    with :ok <- validate_mask_components(resolved, resolved_by_id, direct_ids),
         {:ok, refs} <-
           reachable_dependency_refs(resolved_by_id, allowed_direct_refs) do
      {:ok, Enum.reduce(resolved, %{}, &add_component_mask(&1, &2, refs, direct_ids))}
    end
  end

  defp add_component_mask(component, acc, refs, direct_ids) do
    id = Map.get(component, :id)

    cond do
      id in [nil, ""] or MapSet.member?(direct_ids, id) ->
        acc

      Map.get(component, :required_by, []) == [] ->
        acc

      true ->
        Enum.reduce(Map.get(component, :namespaces, []), acc, &add_namespace_mask(&2, &1, refs))
    end
  end

  defp add_namespace_mask(acc, namespace, refs) do
    namespace_refs = Enum.filter(refs, &String.starts_with?(&1, namespace <> "/"))

    Map.update(
      acc,
      namespace,
      Enum.sort(namespace_refs),
      &Enum.sort(Enum.uniq(&1 ++ namespace_refs))
    )
  end

  defp validate_mask_components(resolved, resolved_by_id, direct_ids) do
    Enum.reduce_while(resolved, :ok, fn component, :ok ->
      id = Map.get(component, :id)

      cond do
        id in [nil, ""] ->
          {:cont, :ok}

        Map.get(component, :required_by, []) == [] and not MapSet.member?(direct_ids, id) ->
          {:cont, :ok}

        not valid_mask_component?(component) ->
          {:halt,
           {:fallback, ["missing presentation metadata for prelude #{Kernel.inspect(id)}"]}}

        true ->
          case validate_requirers(component, resolved_by_id) do
            :ok -> {:cont, :ok}
            {:fallback, warning} -> {:halt, {:fallback, [warning]}}
          end
      end
    end)
  end

  defp validate_requirers(component, resolved_by_id) do
    component
    |> Map.get(:required_by, [])
    |> Enum.reduce_while(:ok, fn requirer_id, :ok ->
      case Map.fetch(resolved_by_id, requirer_id) do
        {:ok, requirer} ->
          if valid_mask_component?(requirer) do
            {:cont, :ok}
          else
            {:halt, {:fallback, missing_requirer_metadata_warning(component, requirer_id)}}
          end

        :error ->
          {:halt, {:fallback, missing_requirer_metadata_warning(component, requirer_id)}}
      end
    end)
  end

  defp missing_requirer_metadata_warning(component, requirer_id) do
    component_id = Map.get(component, :id)

    "missing presentation metadata for prelude #{Kernel.inspect(requirer_id)} required by #{Kernel.inspect(component_id)}"
  end

  defp valid_mask_component?(component) do
    non_empty_binary?(Map.get(component, :id)) and positive_integer?(Map.get(component, :version)) and
      non_empty_binary?(Map.get(component, :checksum)) and valid_namespace_list?(component) and
      valid_form_graph_metadata?(component) and valid_required_by_list?(component)
  end

  defp allowed_direct_export_refs(nil, resolved, direct_ids) do
    resolved
    |> Enum.filter(&(Map.get(&1, :id) in MapSet.to_list(direct_ids)))
    |> Enum.flat_map(&public_form_refs/1)
    |> MapSet.new()
  end

  defp allowed_direct_export_refs(%Prelude{exports: exports}, resolved, direct_ids) do
    namespace_to_component_id = namespace_component_index(resolved)

    exports
    |> Enum.flat_map(fn
      %Export{ref: ref, namespace: namespace} when is_binary(ref) and is_binary(namespace) ->
        if Map.get(namespace_to_component_id, namespace) in MapSet.to_list(direct_ids) do
          [ref]
        else
          []
        end

      _other ->
        []
    end)
    |> MapSet.new()
  end

  defp reachable_dependency_refs(resolved_by_id, allowed_direct_refs) do
    namespace_to_component_id = namespace_component_index(Map.values(resolved_by_id))

    with {:ok, initial_refs} <-
           reduce_direct_dependency_refs(
             MapSet.to_list(allowed_direct_refs),
             namespace_to_component_id,
             resolved_by_id
           ),
         {:ok, refs} <-
           expand_dependency_refs(
             initial_refs,
             [],
             namespace_to_component_id,
             resolved_by_id
           ) do
      {:ok, Enum.sort(refs)}
    end
  end

  defp reduce_direct_dependency_refs(refs, namespace_to_component_id, resolved_by_id) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case dependency_refs_for_public_ref(ref, namespace_to_component_id, resolved_by_id) do
        {:ok, dep_refs} -> {:cont, {:ok, acc ++ dep_refs}}
        {:fallback, _warnings} = fallback -> {:halt, fallback}
      end
    end)
  end

  defp dependency_refs_for_public_ref(ref, namespace_to_component_id, resolved_by_id) do
    with {:ok, entry} <- public_form_entry_for_ref(ref, namespace_to_component_id, resolved_by_id),
         {:ok, dep_refs} <- entry_dep_calls(entry) do
      {:ok, dep_refs}
    else
      _error -> mask_metadata_fallback(ref)
    end
  end

  defp expand_dependency_refs([], seen, _namespace_to_component_id, _resolved_by_id),
    do: {:ok, seen}

  defp expand_dependency_refs([ref | rest], seen, namespace_to_component_id, resolved_by_id) do
    if ref in seen do
      expand_dependency_refs(rest, seen, namespace_to_component_id, resolved_by_id)
    else
      seen = [ref | seen]

      next_refs =
        case public_form_entry_for_ref(ref, namespace_to_component_id, resolved_by_id) do
          {:ok, entry} ->
            case entry_dep_calls(entry) do
              {:ok, dep_refs} -> dep_refs
              :error -> :invalid_metadata
            end

          {:error, :not_found} ->
            []

          {:error, :invalid_metadata} ->
            :invalid_metadata
        end

      case next_refs do
        :invalid_metadata ->
          mask_metadata_fallback(ref)

        refs ->
          expand_dependency_refs(rest ++ refs, seen, namespace_to_component_id, resolved_by_id)
      end
    end
  end

  defp namespace_component_index(components) do
    components
    |> Enum.flat_map(fn component ->
      id = Map.get(component, :id)
      Enum.map(Map.get(component, :namespaces, []), &{&1, id})
    end)
    |> Map.new()
  end

  defp public_form_entry_for_ref(ref, namespace_to_component_id, resolved_by_id) do
    with [namespace, symbol] <- String.split(ref, "/", parts: 2),
         component_id when is_binary(component_id) <-
           Map.get(namespace_to_component_id, namespace),
         %{form_graph: form_graph} <- Map.get(resolved_by_id, component_id),
         namespace_graph when is_map(namespace_graph) <- Map.get(form_graph, namespace),
         entry when is_map(entry) <- Map.get(namespace_graph, symbol),
         true <- valid_public_form_entry?(entry) do
      {:ok, entry}
    else
      %{visibility: :public} -> {:error, :invalid_metadata}
      _ -> {:error, :not_found}
    end
  end

  defp public_form_refs(component) do
    component
    |> Map.get(:form_graph, %{})
    |> Enum.flat_map(fn {namespace, namespace_graph}
                        when is_binary(namespace) and is_map(namespace_graph) ->
      namespace_graph
      |> Enum.flat_map(fn
        {symbol, entry} when is_binary(symbol) and is_map(entry) ->
          if Map.get(entry, :visibility) == :public, do: ["#{namespace}/#{symbol}"], else: []

        _other ->
          []
      end)
    end)
  end

  defp non_empty_binary?(value), do: is_binary(value) and value != ""
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_form_graph_metadata?(component) do
    case Map.get(component, :form_graph) do
      form_graph when is_map(form_graph) ->
        Enum.all?(form_graph, fn
          {namespace, namespace_graph} when is_binary(namespace) and is_map(namespace_graph) ->
            Enum.all?(namespace_graph, fn
              {symbol, entry} when is_binary(symbol) and is_map(entry) ->
                Map.get(entry, :visibility) != :public or valid_public_form_entry?(entry)

              _other ->
                false
            end)

          _other ->
            false
        end)

      _other ->
        false
    end
  end

  defp valid_public_form_entry?(entry) when is_map(entry) do
    Map.get(entry, :visibility) == :public and
      entry
      |> Map.get(:dep_calls)
      |> case do
        %{transitive: refs} when is_list(refs) -> Enum.all?(refs, &is_binary/1)
        _other -> false
      end
  end

  defp valid_namespace_list?(component) do
    component
    |> Map.get(:namespaces)
    |> valid_non_empty_binary_list?()
  end

  defp valid_required_by_list?(component) do
    component
    |> Map.get(:required_by)
    |> valid_non_empty_binary_list?()
  end

  defp valid_non_empty_binary_list?(values) when is_list(values) do
    Enum.all?(values, &non_empty_binary?/1)
  end

  defp valid_non_empty_binary_list?(_values), do: false

  defp entry_dep_calls(entry) when is_map(entry) do
    case Map.get(entry, :dep_calls) do
      %{transitive: refs} when is_list(refs) ->
        if Enum.all?(refs, &is_binary/1), do: {:ok, refs}, else: :error

      _other ->
        :error
    end
  end

  defp mask_metadata_fallback(ref) do
    {:fallback, ["missing presentation metadata for prelude export #{Kernel.inspect(ref)}"]}
  end

  defp prelude_components(%Prelude{metadata: %{components: components}}) when is_list(components),
    do: components

  defp prelude_components(_prelude), do: []

  defp prelude_ref_id(ref) when is_binary(ref) do
    ref |> String.split("@", parts: 2) |> hd()
  end

  defp prelude_ref_id(%{id: id}) when is_binary(id), do: id
  defp prelude_ref_id(%{"id" => id}) when is_binary(id), do: id

  defp normalize_prelude_refs(refs) do
    refs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {ref, index}, {:ok, acc} ->
      case normalize_prelude_ref(ref, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _message} = error -> error
    end
  end

  defp normalize_prelude_ref(ref, index) when is_binary(ref) do
    case String.split(ref, "@", parts: 2) do
      [id] ->
        validate_prelude_ref_id(id, index, ref)

      [id, version] ->
        with {:ok, _id} <- validate_prelude_ref_id(id, index, ref),
             {int, ""} when int > 0 <- Integer.parse(version) do
          {:ok, ref}
        else
          _ -> {:error, "preludes[#{index}] must be a valid prelude id or id@version ref"}
        end
    end
  end

  defp normalize_prelude_ref(ref, index) when is_map(ref) do
    with :ok <- validate_prelude_ref_keys(ref, index),
         {:ok, id} <- prelude_ref_string(ref, "id", index),
         {:ok, version} <- prelude_ref_version(ref, index),
         {:ok, checksum} <- prelude_ref_optional_string(ref, "checksum", index) do
      normalized = %{id: id, version: version}
      {:ok, maybe_put(normalized, :checksum, checksum)}
    end
  end

  defp normalize_prelude_ref(_ref, index) do
    {:error, "preludes[#{index}] must be a non-empty string or ref object"}
  end

  defp validate_prelude_ref_id(id, index, _original) do
    if id == "" or not Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_.-]*\z/, id) do
      {:error, "preludes[#{index}] must be a valid prelude id or id@version ref"}
    else
      {:ok, id}
    end
  end

  defp validate_prelude_ref_keys(ref, index) do
    allowed = ["id", "version", "checksum", :id, :version, :checksum]

    case Enum.find(Map.keys(ref), &(&1 not in allowed)) do
      nil -> :ok
      _key -> {:error, "preludes[#{index}] contains an unexpected field"}
    end
  end

  defp prelude_ref_string(ref, key, index) do
    case Map.get(ref, key) || Map.get(ref, String.to_existing_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "preludes[#{index}].#{key} must be a non-empty string"}
    end
  end

  defp prelude_ref_version(ref, index) do
    case Map.get(ref, "version") || Map.get(ref, :version) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, "preludes[#{index}].version must be a positive integer"}
    end
  end

  defp prelude_ref_optional_string(ref, key, index) do
    case Map.get(ref, key) || Map.get(ref, String.to_existing_atom(key)) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "preludes[#{index}].#{key} must be a non-empty string when supplied"}
    end
  end

  defp start_arg_key?(key)
       when key in [
              "title",
              "ttl_ms",
              "preludes",
              "mode",
              "tags",
              "role",
              "scoped_base_surface",
              "owner",
              :owner,
              :auth_claims
            ],
       do: true

  defp start_arg_key?(_key), do: false

  defp validate_list_preludes_args(args) do
    case Enum.find(Map.keys(args), &(not list_preludes_arg_key?(&1))) do
      nil -> :ok
      key -> {:error, "unexpected lisp_session_list_preludes argument: #{key}"}
    end
  end

  defp list_preludes_arg_key?(key) when key in ["session_id", "owner", :owner], do: true
  defp list_preludes_arg_key?(_key), do: false

  defp configured_prelude_opts(opts) do
    cond do
      Map.get(opts, :runtime_prelude) != nil ->
        [runtime_prelude: Map.fetch!(opts, :runtime_prelude)]

      evidence_only_configured_prelude?() ->
        []

      Config.runtime_prelude() != nil ->
        [runtime_prelude: Config.runtime_prelude()]

      true ->
        []
    end
  end

  defp evidence_only_configured_prelude? do
    Config.evidence_bundle() != nil and
      Config.prelude_source() == PtcRunner.Evidence.prelude_source()
  end

  defp maybe_put_read_prelude(opts) do
    case read_prelude_prefixes(opts) do
      [] ->
        opts

      prefixes ->
        case Selection.resolve_with_prefix!(Config.prelude_store(), [], prefixes, []) do
          {nil, _refs} -> opts
          {runtime_prelude, _refs} -> Map.put(opts, :runtime_prelude, runtime_prelude)
        end
    end
  rescue
    error in ArgumentError -> reraise error, __STACKTRACE__
  end

  defp read_prelude_prefixes(opts) do
    cond do
      Config.prelude_store() == nil ->
        configured_prelude_prefixes()

      Policy.prelude_store_level(Map.get(opts, :grant)) == :none ->
        configured_prelude_prefixes()

      configured_prelude_opts(opts) != [] ->
        []

      true ->
        case PreludeStoreTools.read_prelude() do
          {:ok, prelude} ->
            [
              %{
                id: "ptc_runner_prelude_read",
                checksum: prelude.source_hash,
                source: PreludeStoreTools.read_prelude_source(),
                prelude: prelude,
                origin: :host
              }
            ] ++ configured_prelude_prefixes()

          {:error, error} ->
            raise ArgumentError,
                  "failed to compile prelude read capability: #{Kernel.inspect(error)}"
        end
    end
  end

  defp configured_prelude_prefixes do
    case Config.runtime_prelude() do
      nil ->
        []

      runtime_prelude ->
        [
          %{
            id: "ptc_runner_configured_prelude",
            checksum: runtime_prelude.source_hash,
            source: Config.prelude_source(),
            prelude: runtime_prelude,
            origin: :host
          }
        ]
    end
  end

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

  defp aggregator_run_opts(opts, _request_id) do
    if RootUpstreamRuntime.configured?() do
      root_aggregator_run_opts(opts)
    else
      {opts, fn -> [] end}
    end
  end

  defp root_aggregator_run_opts(opts) do
    catalog_config = CatalogConfig.get()
    runtime = projected_root_runtime(Map.get(opts, :grant))

    {:ok, context} =
      Eval.run_context(runtime,
        max_tool_calls: Limits.max_upstream_calls_per_program(),
        max_catalog_ops: catalog_config.max_catalog_ops_per_program,
        call_timeout_ms: Limits.upstream_call_timeout_ms(),
        max_response_bytes: Limits.max_upstream_response_bytes(),
        max_catalog_result_bytes: catalog_config.max_catalog_result_bytes
      )

    eval_opts = Eval.eval_options(context)

    run_opts =
      opts
      |> Map.put(:tools, eval_opts[:tools])
      |> Map.put(:discovery_exec, eval_opts[:discovery_exec])
      |> Map.put(:runtime, runtime)
      |> Map.put(:profile, :mcp_aggregator)

    drain = fn ->
      try do
        RunContext.drain_calls(context)
      after
        RunContext.close(context)
      end
    end

    {run_opts, drain}
  end

  defp projected_root_runtime(nil), do: RootUpstreamRuntime.runtime()

  defp projected_root_runtime(grant) do
    {:ok, runtime} =
      Runtime.project(RootUpstreamRuntime.runtime(),
        credential_grants: Policy.credential_grants(grant),
        upstream_tool_grants: Policy.upstream_tool_grants(grant)
      )

    runtime
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
          "ttl_ms" => %{"type" => "integer", "minimum" => 1},
          "mode" => %{
            "type" => "string",
            "enum" => ["read_only", "write_capable"]
          },
          "role" => %{"type" => "string"},
          "scoped_base_surface" => %{
            "type" => "boolean",
            "description" =>
              "When true, future discovery may narrow transitive base namespaces to exports used by directly selected preludes. Execution authority is unchanged."
          },
          "preludes" => %{
            "type" => "array",
            "items" => %{
              "oneOf" => [
                %{"type" => "string"},
                %{
                  "type" => "object",
                  "required" => ["id", "version"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "version" => %{"type" => "integer", "minimum" => 1},
                    "checksum" => %{"type" => "string"}
                  },
                  "additionalProperties" => false
                }
              ]
            }
          },
          "tags" => %{
            "type" => "object",
            "maxProperties" => 32,
            "additionalProperties" => %{
              "type" => ["string", "number", "boolean", "null"]
            }
          }
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

  defp session_list_preludes_tool do
    %{
      "name" => "lisp_session_list_preludes",
      "description" => PromptRegistry.render(:mcp_session_list_preludes_description, []),
      "inputSchema" => %{
        "type" => "object",
        "required" => ["session_id"],
        "properties" => %{
          "session_id" => %{"type" => "string"}
        },
        "additionalProperties" => false
      },
      "outputSchema" => session_output_schema(["status", "session_id", "prelude_refs"])
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
        "preludes" => %{
          "type" => "array",
          "description" =>
            "Prompt-visible attached prelude namespaces with compact docs and discovery forms."
        },
        "prelude_refs" => %{
          "type" => "array",
          "description" => "Frozen store prelude references attached to this session.",
          "items" => %{
            "type" => "object",
            "required" => ["id", "version", "checksum", "origin"],
            "properties" => %{
              "id" => %{"type" => "string"},
              "version" => %{"type" => "integer", "minimum" => 1},
              "checksum" => %{"type" => "string"},
              "origin" => %{"type" => ["string", "null"]}
            },
            "additionalProperties" => true
          }
        },
        "prelude_projection" => %{
          "type" => "object",
          "description" =>
            "Grant projection summary for attached preludes, including exports removed from this session's callable surface."
        },
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
