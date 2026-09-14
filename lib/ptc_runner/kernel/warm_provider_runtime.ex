defmodule PtcRunner.Kernel.WarmProviderRuntime do
  @moduledoc """
  Host-owned infrastructure shared by a frozen set of serving tools.

  Start with `tools:` (a map from tool name to `%{template: template, pins: pins}`),
  `services:`, `bearer_binding:`, `run_admission:`,
  `max_active_provider_calls:` and `max_waiting_provider_calls:`. Optional
  `env_file:` is an already anchored absolute path. Capture resolves the exact
  union of selected credentials and the bearer binding once, inside one exact
  file snapshot scope. The environment and lock are restored before startup
  returns. Restart is required for credential rotation.

  Required applications are started once, after disabling dotenv and configuring
  ReqLLM's default one-shard HTTP/1 pool at the aggregate active ceiling. Explicit
  pools, alternate protocols/names, and prestarted ReqLLM refuse startup; no
  running transport is silently reconfigured. LLMDB is owned only when started
  transitively by ReqLLM. Provider-free tools start no optional application.

  `template/2` returns a bound template. Every bound tool, including tools without
  providers, checks this complete domain's serialized readiness before reservation
  and execution activation. Cached templates cannot bypass a live fenced gate or
  observed connection drift; a pre-dispatch refusal is `admission_unavailable`
  with `dispatched: false`, unless its original deadline has expired.
  Reservations create no provider resource;
  activation borrows with the original reservation deadline. Each call owns new
  input/policy identities, activity, task tracker, provider scope, sinks,
  publication authority and execution state. Acquisition is retained, with exact
  installation and destination/name snapshot pins checked before readiness.
  No automatic reacquisition, re-pin or restart occurs. An acquisition replacement
  requires draining and replacing the entire host domain with newly checked pins.

  One explicit ProviderCallAdmission domain governs installed live workflow,
  mission and connectivity requester invocations, including sequential retries.
  ProviderCallOwner guardians retain their leases until positive transport drain
  and Finch checkout-return evidence. Replay, MCP/OAuth, metadata, embeddings,
  public direct LLM calls and custom bypasses are outside this guarantee.

  `snapshot/1` is bounded and secret-free. Saturation remains ready; loss or fencing
  of any required domain permanently refuses readiness. Effective pool geometry
  is checked on every snapshot, including live shard counts; observed drift
  quiesces all tools and requires whole-domain replacement after drain.
  The host must stop inbound
  admission before `drain/2`. Drain quiesces all acquisitions first and shares one
  absolute cutoff for waiting for borrows. Session cancellation then uses the
  existing installed provider-cleanup budgets. It stops only gateway-started applications, and only after
  run admission, borrows and provider calls have drained. Uncertainty leaves
  applications running, preventing a replacement from resetting live transport
  capacity. Unplanned host death likewise leaves application infrastructure in
  place; restarting over it is refused. After uncertainty, recovery requires
  draining old work and restarting the VM; a healthy completed drain permits
  constructing a new whole domain in the same VM with fresh startup pin checks.

  ## Precedence and retry safety

  | Event | Dispatch state | Serving result / provider result | Retry safety |
  | --- | --- | --- | --- |
  | Invalid input or expired request before reservation | none | invalid_input / cancelled | no dispatch |
  | Run capacity full | none | busy | safe to retry |
  | Run domain unavailable or warm domain fenced | none | admission_unavailable | replace drained domain first |
  | Provider FIFO full | provider not entered | capacity_exhausted | safe provider retry within same deadline |
  | Provider queue deadline elapsed | provider not entered | timeout | original deadline remains expired |
  | Provider gate death/fencing before grant | provider not entered | admission_unavailable | no automatic retry |
  | Earliest request/run/provider deadline after grant | existing requester evidence | cancelled / timeout | writes may have occurred |
  | Gate death after entry, lost completion, cleanup timeout | conservative existing evidence | cleanup_failed | unsafe; permanent fence |
  | Cleanup uncertainty plus any earlier outcome | conservative existing evidence | cleanup_failed wins | unsafe; permanent fence |

  Serving dispatch metadata describes run entry, not provider transport entry.
  Provider errors preserve their own dispatch provenance. While queued, caller
  cancellation removes the guardian; otherwise expiry at decision time beats a
  grant, and a previously unavailable gate refuses admission. Cleanup uncertainty
  outranks all earlier outcomes. Request/run expiry remains active through publication.
  """
  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.{
    CapturedCredentials,
    ProviderApplicationGate,
    ProviderCallAdmission,
    ProviderRuntime,
    ProviderRuntimeServices,
    RunAdmission,
    ServingTemplate,
    WarmProviderApplications
  }

  @required [
    :tools,
    :services,
    :bearer_binding,
    :run_admission,
    :max_active_provider_calls,
    :max_waiting_provider_calls
  ]

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) == MapSet.size(MapSet.new(Keyword.keys(opts))) and
         Keyword.keys(opts) -- (@required ++ [:env_file]) == [] and
         Enum.all?(@required, &Keyword.has_key?(opts, &1)),
       do: GenServer.start_link(__MODULE__, opts),
       else: {:error, :invalid_warm_provider_runtime}
  end

  def start_link(_), do: {:error, :invalid_warm_provider_runtime}

  @spec template(pid(), binary()) :: {:ok, ServingTemplate.t()} | {:error, atom()}
  def template(owner, name),
    do: call(owner, {:template, name}, {:error, :provider_runtime_unavailable})

  @spec snapshot(pid()) :: map()
  def snapshot(owner), do: call(owner, :snapshot, %{ready: false, fenced: true})

  @spec authenticate(pid(), binary()) :: boolean()
  def authenticate(owner, token), do: call(owner, {:authenticate, token}, false)

  @spec drain(pid(), integer()) :: :ok | {:error, atom()}
  def drain(owner, deadline),
    do: call(owner, {:drain, deadline}, {:error, :provider_cleanup_failed}, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      tools: %{},
      runtimes: %{},
      applications: [],
      required_applications: [],
      credentials: nil,
      admission: nil,
      run_admission: opts[:run_admission],
      fenced: false,
      draining: false,
      monitors: [],
      connection: nil,
      active_ceiling: opts[:max_active_provider_calls]
    }

    with :ok <- validate(opts),
         {:ok, plans} <- plans(opts[:tools]) do
      case PtcRunner.Dotenv.with_loaded_file(opts[:env_file], fn -> boot(opts, plans, state) end) do
        {:ok, next} ->
          {:ok, next}

        {:error, code, partial} ->
          cleanup_startup(partial)
          {:stop, code}

        _ ->
          {:stop, :credential_unavailable}
      end
    else
      {:error, code} -> {:stop, code}
    end
  end

  defp validate(opts) do
    cond do
      not is_map(opts[:tools]) or map_size(opts[:tools]) not in 1..128 ->
        {:error, :invalid_warm_provider_runtime}

      not ProviderRuntimeServices.valid?(opts[:services]) ->
        {:error, :invalid_warm_provider_runtime}

      opts[:max_active_provider_calls] not in 1..65_535 or
          opts[:max_waiting_provider_calls] not in 0..65_535 ->
        {:error, :invalid_warm_provider_runtime}

      not is_binary(opts[:bearer_binding]) ->
        {:error, :invalid_warm_provider_runtime}

      opts[:env_file] != nil and
          (not is_binary(opts[:env_file]) or Path.type(opts[:env_file]) != :absolute) ->
        {:error, :invalid_warm_provider_runtime}

      not match?({:ok, %{status: :ready}}, RunAdmission.snapshot(opts[:run_admission])) ->
        {:error, :run_admission_unavailable}

      true ->
        :ok
    end
  end

  defp plans(tools) do
    Enum.reduce_while(Enum.sort(tools), {:ok, []}, fn
      {name, %{template: %ServingTemplate{retained: nil} = template, pins: pins}}, {:ok, acc}
      when is_binary(name) ->
        if pins == %{installation_config_pins: %{}, provider_snapshot_pins: %{}},
          do: {:cont, {:ok, [{name, template, pins, nil} | acc]}},
          else: {:halt, {:error, :provider_pin_mismatch}}

      {name, %{template: %ServingTemplate{} = template, pins: pins}}, {:ok, acc}
      when is_binary(name) ->
        case ServingTemplate.provider_plan(template) do
          {:ok, plan} -> {:cont, {:ok, [{name, template, pins, plan} | acc]}}
          _ -> {:halt, {:error, :invalid_warm_provider_runtime}}
        end

      _, _ ->
        {:halt, {:error, :invalid_warm_provider_runtime}}
    end)
    |> reverse_plans()
  end

  defp reverse_plans({:ok, entries}), do: {:ok, Enum.reverse(entries)}
  defp reverse_plans(error), do: error

  defp boot(opts, plans, state) do
    if Enum.all?(plans, fn
         {_, _, _, nil} ->
           true

         {_, _, _, plan} ->
           ProviderRuntimeServices.bound_to?(opts[:services], plan.catalog.runtime_binding)
       end) do
      capture(opts, plans, state)
    else
      {:error, :invalid_provider_runtime_services, state}
    end
  end

  defp capture(opts, plans, state) do
    names =
      plans
      |> Enum.flat_map(fn
        {_, _, _, nil} ->
          []

        {_, _, _, plan} ->
          Enum.flat_map(
            plan.metadata.provider_declarations,
            &plan.catalog.descriptors[&1.name].credential_names
          )
      end)
      |> Enum.uniq()
      |> Enum.sort()

    requirements =
      plans
      |> Enum.flat_map(fn
        {_, _, _, nil} ->
          []

        {_, _, _, plan} ->
          ProviderApplicationGate.requirements(plan.metadata.provider_declarations, plan.catalog)
      end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.sort()

    case CapturedCredentials.start_link(
           opts[:services].credential_resolver,
           names,
           opts[:bearer_binding]
         ) do
      {:ok, credentials} ->
        start_infrastructure(opts, plans, %{
          state
          | credentials: credentials,
            required_applications: requirements
        })

      _ ->
        {:error, :credential_unavailable, state}
    end
  end

  defp start_infrastructure(opts, plans, state) do
    case WarmProviderApplications.start(
           state.required_applications,
           opts[:max_active_provider_calls]
         ) do
      {:ok, apps, connection} ->
        state = %{state | applications: apps, connection: connection}

        start_admission(opts, plans, state)

      {:error, code, apps} ->
        {:error, code, %{state | applications: apps}}
    end
  end

  defp start_admission(opts, plans, state) do
    case ProviderCallAdmission.start_link(
           max_active_calls: opts[:max_active_provider_calls],
           max_waiters: opts[:max_waiting_provider_calls]
         ) do
      {:ok, admission} -> seal_services(opts, plans, %{state | admission: admission})
      _ -> {:error, :provider_admission_unavailable, state}
    end
  end

  defp seal_services(opts, plans, state) do
    case ProviderRuntimeServices.with_captured_credentials(
           opts[:services],
           state.credentials,
           state.admission
         ) do
      {:ok, services} -> open_tools(plans, services, state)
      _ -> {:error, :invalid_provider_runtime_services, state}
    end
  end

  defp open_tools(plans, services, state) do
    Enum.reduce_while(plans, {:ok, state}, fn
      {name, template, _, nil}, {:ok, next} ->
        bound = ServingTemplate.with_warm_runtime(template, self())
        {:cont, {:ok, put_in(next.tools[name], bound)}}

      {name, template, pins, _}, {:ok, next} ->
        case ProviderRuntime.start_link(template: template, services: services, pins: pins) do
          {:ok, runtime} ->
            {:ok, bound} = ServingTemplate.with_provider_runtime(template, runtime)
            bound = ServingTemplate.with_warm_runtime(bound, self())
            next = put_in(next.runtimes[name], runtime)
            {:cont, {:ok, put_in(next.tools[name], bound)}}

          {:error, code} ->
            {:halt, {:error, code, next}}
        end
    end)
    |> monitor_domains()
  end

  defp monitor_domains({:ok, state}) do
    pids =
      [
        state.credentials,
        state.admission,
        state.run_admission
        | Map.values(state.runtimes)
      ] ++ if(state.connection, do: [state.connection], else: [])

    {:ok, %{state | monitors: Enum.map(pids, &Process.monitor/1)}}
  end

  defp monitor_domains(error), do: error

  @impl true
  def handle_call(:snapshot, _, state) do
    {snapshot, next} = inspect_status(state)
    {:reply, snapshot, next}
  end

  def handle_call({:template, name}, _, state) do
    {snapshot, next} = inspect_status(state)

    result =
      if snapshot.ready,
        do: fetch_template(next.tools, name),
        else: {:error, :provider_runtime_unavailable}

    {:reply, result, next}
  end

  def handle_call({:authenticate, token}, _, state),
    do: {:reply, CapturedCredentials.authenticate(state.credentials, token), state}

  def handle_call({:drain, deadline}, _, state) when is_integer(deadline) do
    Enum.each(state.runtimes, fn {_, runtime} -> ProviderRuntime.quiesce(runtime) end)

    results =
      Enum.map(state.runtimes, fn {_, runtime} -> ProviderRuntime.drain(runtime, deadline) end)

    provider = ProviderCallAdmission.snapshot(state.admission)
    runs = RunAdmission.snapshot(state.run_admission)

    clean =
      Enum.all?(results, &(&1 == :ok)) and
        match?({:ok, %{active: 0, waiting: 0, status: :ready}}, provider) and
        match?({:ok, %{in_use: 0, status: :ready}}, runs)

    clean = clean and stop_applications(state.applications)

    {:reply, if(clean, do: :ok, else: {:error, :provider_cleanup_failed}),
     %{
       state
       | draining: true,
         fenced: state.fenced or not clean,
         applications: if(clean, do: [], else: state.applications)
     }}
  end

  defp fetch_template(tools, name) do
    case Map.fetch(tools, name) do
      {:ok, template} -> {:ok, template}
      :error -> {:error, :provider_runtime_unavailable}
    end
  end

  defp inspect_status(state) do
    apps_ready = Enum.all?(state.required_applications, &running?/1)

    connection_ready =
      state.connection == nil or
        WarmProviderApplications.ready?(state.connection, state.active_ceiling)

    run = RunAdmission.snapshot(state.run_admission)
    provider = ProviderCallAdmission.snapshot(state.admission)

    acquired_ready =
      Enum.all?(state.runtimes, fn {_, runtime} -> ProviderRuntime.status(runtime) == :ready end)

    healthy =
      apps_ready and connection_ready and CapturedCredentials.ready?(state.credentials) and
        match?({:ok, %{status: :ready}}, run) and match?({:ok, %{status: :ready}}, provider) and
        acquired_ready

    next = %{state | fenced: state.fenced or (not healthy and not state.draining)}
    if next.fenced, do: quiesce(next)

    {%{
       ready: healthy and not next.fenced and not next.draining,
       fenced: next.fenced,
       applications: if(apps_ready, do: :ready, else: :unavailable),
       connection: if(connection_ready, do: :ready, else: :unavailable),
       run_admission: safe_snapshot(run),
       provider_call_admission: safe_snapshot(provider)
     }, next}
  end

  defp safe_snapshot({:ok, value}), do: value
  defp safe_snapshot(_), do: %{status: :unavailable}
  defp running?(app), do: Enum.any?(Application.started_applications(), &(elem(&1, 0) == app))

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: fence(state, ref in state.monitors)

  def handle_info({:EXIT, _, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _, _}, state), do: fence(state, true)

  defp fence(state, false), do: {:noreply, state}

  defp fence(state, true) do
    quiesce(state)
    {:noreply, %{state | fenced: true}}
  end

  defp quiesce(state),
    do: Enum.each(state.runtimes, fn {_, runtime} -> ProviderRuntime.quiesce(runtime) end)

  defp cleanup_startup(state) do
    deadline = System.monotonic_time(:millisecond)

    clean =
      Enum.all?(state.runtimes, fn {_, runtime} ->
        ProviderRuntime.drain(runtime, deadline) == :ok
      end)

    for owner <- Map.values(state.runtimes) ++ [state.admission, state.credentials],
        is_pid(owner),
        Process.alive?(owner),
        do: GenServer.stop(owner)

    if clean, do: stop_applications(state.applications)
  end

  defp stop_applications(applications) do
    Enum.reduce(Enum.reverse(applications), true, fn app, clean ->
      Application.stop(app) == :ok and clean
    end)
  end

  @impl true
  def terminate(_, state) do
    # Applications survive an unproved teardown. A subsequent startup refuses
    # prestarted ReqLLM instead of resetting admission under old transport work.
    for owner <- Map.values(state.runtimes) ++ [state.admission, state.credentials],
        is_pid(owner),
        Process.alive?(owner),
        do: GenServer.stop(owner, :shutdown)
  end

  defp call(owner, message, fallback, timeout \\ 5_000) do
    GenServer.call(owner, message, timeout)
  catch
    :exit, _ -> fallback
  end
end
