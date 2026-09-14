defmodule PtcRunner.Kernel.ProviderRuntime do
  @moduledoc """
  Host-owned acquire-once runtime for a provider-bearing serving template.

  Start with `template:`, `services:` and `pins:` only. Only LLM installations
  are shareable (`:provider_runtime_unsupported` otherwise). Acquisition uses
  the active provider pipeline. Exact installation pins and destination/name
  snapshot pins are checked before readiness; failures close everything and
  retain nothing. Closed pin failures are `:installation_pin_mismatch`,
  `:provider_pin_mismatch` and `:provider_pin_unavailable`.

  `pins: :discover` performs real acquisition, prints the two safe pin maps and
  closes the resources; it never becomes ready. Borrowing takes an absolute
  monotonic admission deadline, creates a caller-monitored non-owning token,
  and shares only capabilities. Return the token after execution; caller exit
  also returns it. An executing borrow remains counted against its execution
  owner until per-call task cleanup settles, including cancellation and caller
  death. A return during execution cannot release it early. Draining refuses
  new borrows, waits until the supplied
  absolute deadline, and closes the session once even if borrows remain. It
  reports their count as `{:error, {:outstanding_borrows, count}}`.

  Malformed startup options or foreign returns use `:invalid_provider_runtime`.
  A non-ready or draining runtime refuses borrows with
  `:provider_runtime_unavailable`; an unavailable owner uses
  `:provider_runtime_lost`. Cleanup failure is `:provider_cleanup_failed` and
  outranks an earlier acquisition or pin refusal.

  Session or registry authority loss permanently marks readiness
  `{:not_ready, :provider_runtime_lost}`. There is no reacquisition or re-pin.
  ServingCall borrows this acquisition with its reservation deadline.
  WarmProviderRuntime owns captured credentials, provider applications and
  aggregate provider-call admission for the complete host.
  """
  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.InstallationConfigDigest
  alias PtcRunner.Kernel.ProviderRuntimeOpening

  alias PtcRunner.Kernel.{
    Attestation,
    Deadline,
    PreparedRun,
    ProviderActivity,
    ProviderExecution,
    ProviderRegistry,
    ProviderRuntimeServices,
    ProviderSession,
    ServingTemplate
  }

  alias PtcRunner.Kernel.ProviderRuntime.Borrow

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == [:pins, :services, :template] do
      GenServer.start_link(__MODULE__, opts)
    else
      {:error, :invalid_provider_runtime}
    end
  end

  def start_link(_opts), do: {:error, :invalid_provider_runtime}

  @spec status(pid()) :: :ready | :draining | {:not_ready, atom()}
  def status(runtime), do: safe_call(runtime, :status, {:not_ready, :provider_runtime_lost})
  @spec borrow(pid(), integer()) :: {:ok, Borrow.t()} | {:error, atom()}
  def borrow(runtime, deadline) when is_integer(deadline),
    do: safe_call(runtime, {:borrow, deadline}, {:error, :provider_runtime_lost})

  def borrow(_runtime, _deadline), do: {:error, :invalid_provider_runtime}
  @spec return(Borrow.t()) :: :ok | {:error, atom()}
  def return(%Borrow{caller: caller} = borrow) when caller == self(),
    do: safe_call(borrow.runtime, {:return, borrow}, {:error, :provider_runtime_lost})

  def return(_borrow), do: {:error, :invalid_provider_runtime}
  @doc false
  @spec release_borrow(Borrow.t()) :: :ok | {:error, atom()}
  def release_borrow(%Borrow{} = borrow),
    do: safe_call(borrow.runtime, {:release, borrow}, {:error, :provider_runtime_lost})

  @doc false
  def hold_borrow(%Borrow{} = borrow),
    do: safe_call(borrow.runtime, {:hold, borrow}, {:error, :provider_runtime_lost})

  @doc "Refuses new borrows before the host begins draining all destinations."
  @spec quiesce(pid()) :: :ok | {:error, :provider_runtime_lost}
  def quiesce(runtime), do: safe_call(runtime, :quiesce, {:error, :provider_runtime_lost})

  @spec drain(pid(), integer()) :: :ok | {:error, term()}
  def drain(runtime, deadline) when is_integer(deadline),
    do: safe_call(runtime, {:drain, deadline}, {:error, :provider_runtime_lost}, :infinity)

  @doc false
  @spec plan_identity(PreparedRun.t()) :: tuple()
  def plan_identity(prepared),
    do:
      {prepared.catalog_attestation, prepared.effective_application_digest,
       prepared.installation_config_digests}

  @doc false
  @spec valid_borrow?(term()) :: boolean()
  def valid_borrow?(%Borrow{} = borrow) do
    Attestation.valid?(
      Borrow,
      Map.delete(Map.from_struct(borrow), :attestation),
      borrow.attestation
    ) and
      ProviderSession.alive?(borrow.session) and
      safe_call(borrow.runtime, {:valid_borrow, borrow.monitor}, false)
  end

  def valid_borrow?(_borrow), do: false

  @doc "Checks a runtime against the exact sealed template without borrowing."
  @spec matches_template?(pid(), ServingTemplate.t()) :: boolean()
  def matches_template?(runtime, template),
    do: matches_template_with_timeout?(runtime, template, 5_000)

  @doc false
  @spec matches_template?(pid(), ServingTemplate.t(), integer()) :: boolean()
  def matches_template?(runtime, template, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    remaining > 0 and matches_template_with_timeout?(runtime, template, remaining)
  end

  defp matches_template_with_timeout?(runtime, template, timeout) do
    case ServingTemplate.provider_plan(template) do
      {:ok, retained} ->
        {digest, digests} = ServingTemplate.runtime_context(template).identity
        identity = {retained.catalog.attestation, digest, digests}

        safe_call(runtime, {:matches_template, identity}, false, timeout)

      _ ->
        false
    end
  end

  @impl true
  def init(opts) do
    with {:ok, retained} <- ServingTemplate.provider_plan(opts[:template]),
         true <- ProviderRuntimeServices.valid?(opts[:services]),
         :ok <- supported(retained),
         {:ok, execution} <- ProviderExecution.new(retained.catalog, opts[:services], []),
         {:ok, prepared} <-
           ProviderActivity.start_owned(fn activity ->
             PreparedRun.new(
               retained.request,
               retained.workflow_bundle,
               retained.mission_bundles,
               retained.entry_source,
               activity,
               retained.catalog,
               retained.metadata
             )
           end) do
      open(prepared, execution, opts[:pins])
    else
      {:error, code} -> {:stop, code}
      _invalid -> {:stop, :invalid_provider_runtime}
    end
  rescue
    _exception -> {:stop, :invalid_provider_runtime}
  catch
    _kind, _reason -> {:stop, :invalid_provider_runtime}
  end

  defp supported(retained) do
    if Enum.all?(retained.metadata.provider_declarations, fn declaration ->
         retained.catalog.descriptors[declaration.name].source == :llm
       end), do: :ok, else: {:error, :provider_runtime_unsupported}
  end

  defp open(prepared, execution, pins) do
    case ProviderRuntimeOpening.open(
           prepared,
           execution,
           Deadline.new(prepared.request.package.limits.run_duration_ms)
         ) do
      {:ok, opened} ->
        case verify_pins(prepared, opened.snapshot_sites, pins) do
          {:ok, actual} when pins == :discover ->
            case cleanup(opened) do
              :ok -> discover_closed(actual, prepared)
              {:error, _reason} -> {:stop, :provider_cleanup_failed}
            end

          {:ok, _actual} ->
            monitors = [
              Process.monitor(ProviderSession.worker_cancel_target(opened.session))
              | registry_monitor(opened.registry)
            ]

            {:ok,
             %{
               status: :ready,
               opened: opened,
               borrows: %{},
               monitors: monitors,
               draining: nil,
               execution: execution,
               identity: plan_identity(prepared)
             }}

          {:error, code} ->
            case cleanup(opened) do
              :ok -> {:stop, code}
              {:error, _reason} -> {:stop, :provider_cleanup_failed}
            end
        end

      {:error, %{code: code}} ->
        {:stop, code}

      {:error, code} ->
        {:stop, code}
    end
  after
    PreparedRun.close(prepared)
  end

  defp discover_closed(actual, prepared) do
    {:ok, encoded} =
      DeterministicJSON.encode(%{
        "installation_config_pins" => actual.installation_config_pins,
        "provider_snapshot_pins" => actual.provider_snapshot_pins
      })

    IO.puts(encoded)

    {:ok,
     %{
       status: {:not_ready, :provider_runtime_required},
       opened: nil,
       borrows: %{},
       monitors: [],
       draining: nil,
       identity: plan_identity(prepared)
     }}
  end

  defp registry_monitor(registry) do
    case ProviderRegistry.monitor_owner(registry) do
      nil -> []
      monitor -> [monitor]
    end
  end

  defp verify_pins(prepared, sites, pins) do
    expected_names =
      prepared.provider_declarations |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()

    if Enum.any?(sites, &unpinnable_site?/1) or
         Enum.sort(Map.keys(prepared.installation_config_digests)) != expected_names do
      {:error, :provider_pin_unavailable}
    else
      actual = %{
        installation_config_pins: prepared.installation_config_digests,
        provider_snapshot_pins:
          Map.new(sites, fn site ->
            {"#{site.destination}/#{site.name}", "sha256:" <> site.acquisition_identity_hash}
          end)
      }

      compare_pins(actual, pins)
    end
  end

  defp unpinnable_site?(%{acquisition_identity_hash: hash}) when is_binary(hash),
    do: not InstallationConfigDigest.valid_digest?("sha256:" <> hash)

  defp unpinnable_site?(_site), do: true

  defp compare_pins(actual, pins) do
    cond do
      pins == :discover ->
        {:ok, actual}

      not is_map(pins) or
          Map.get(pins, :installation_config_pins) != actual.installation_config_pins ->
        {:error, :installation_pin_mismatch}

      Map.keys(pins) -- [:installation_config_pins, :provider_snapshot_pins] != [] or
          Map.get(pins, :provider_snapshot_pins) != actual.provider_snapshot_pins ->
        {:error, :provider_pin_mismatch}

      true ->
        {:ok, actual}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:matches_template, identity}, _from, state),
    do: {:reply, state.status == :ready and state.identity == identity, state}

  def handle_call(:quiesce, _from, state),
    do: {:reply, :ok, %{state | status: :draining}}

  def handle_call({:valid_borrow, monitor}, _from, state),
    do:
      {:reply,
       state.status in [:ready, :draining] and state.opened != nil and
         Map.has_key?(state.borrows, monitor), state}

  def handle_call({:borrow, deadline}, {caller, _tag}, %{status: :ready} = state) do
    case ProviderSession.borrow(state.opened.session, deadline) do
      {:ok, session} ->
        monitor = Process.monitor(caller)

        borrow = %Borrow{
          runtime: self(),
          caller: caller,
          monitor: monitor,
          session: session,
          providers: state.opened.providers,
          registry: state.opened.registry,
          plan_identity: state.identity,
          execution: state.execution,
          attestation: <<>>
        }

        borrow = %{
          borrow
          | attestation:
              Attestation.attest(Borrow, Map.delete(Map.from_struct(borrow), :attestation))
        }

        {:reply, {:ok, borrow}, put_in(state.borrows[monitor], %{caller: caller, owner: nil})}

      _lost ->
        {:reply, {:error, :provider_runtime_lost},
         %{state | status: {:not_ready, :provider_runtime_lost}}}
    end
  end

  def handle_call({:borrow, _deadline}, _from, state),
    do: {:reply, {:error, :provider_runtime_unavailable}, state}

  def handle_call({:return, %Borrow{caller: caller} = borrow}, {caller, _tag}, state) do
    release(borrow, state, caller)
  end

  def handle_call({:release, borrow}, from, state), do: release(borrow, state, elem(from, 0))

  def handle_call({:hold, borrow}, {owner, _}, state) do
    if valid_token?(borrow) and match?(%{owner: nil}, state.borrows[borrow.monitor]) do
      entry = %{caller: borrow.caller, owner: {owner, Process.monitor(owner)}}
      {:reply, :ok, put_in(state.borrows[borrow.monitor], entry)}
    else
      {:reply, {:error, :invalid_provider_runtime}, state}
    end
  end

  def handle_call({:drain, _deadline}, _from, %{opened: nil} = state), do: {:reply, :ok, state}

  def handle_call({:drain, deadline}, from, %{draining: nil} = state) do
    timer = drain_timer(deadline)

    {:noreply, maybe_finish(%{state | status: :draining, draining: {from, timer, deadline}})}
  end

  def handle_call({:drain, _deadline}, _from, state),
    do: {:reply, {:error, :provider_runtime_unavailable}, state}

  defp valid_token?(borrow) do
    Attestation.valid?(
      Borrow,
      Map.delete(Map.from_struct(borrow), :attestation),
      borrow.attestation
    ) and borrow.runtime == self()
  end

  defp release(borrow, state, caller) do
    if valid_token?(borrow) do
      case state.borrows[borrow.monitor] do
        %{owner: {owner, _}} when owner != caller -> {:reply, :ok, state}
        _ -> {:reply, :ok, maybe_finish(remove_borrow(state, borrow.monitor))}
      end
    else
      {:reply, {:error, :invalid_provider_runtime}, state}
    end
  end

  defp remove_borrow(state, monitor) do
    Process.demonitor(monitor, [:flush])

    case state.borrows[monitor] do
      %{owner: {_pid, ref}} -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end

    %{state | borrows: Map.delete(state.borrows, monitor)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    cond do
      monitor in state.monitors ->
        {:noreply, %{state | status: {:not_ready, :provider_runtime_lost}}}

      match?(%{owner: nil}, state.borrows[monitor]) ->
        {:noreply, maybe_finish(remove_borrow(state, monitor))}

      true ->
        owned =
          Enum.find(state.borrows, fn {_key, entry} ->
            match?({_owner, ^monitor}, entry.owner)
          end)

        case owned do
          {key, _} -> {:noreply, maybe_finish(remove_borrow(state, key))}
          nil -> {:noreply, state}
        end
    end
  end

  def handle_info(:drain_deadline, %{draining: nil} = state), do: {:noreply, state}

  def handle_info(:drain_deadline, %{draining: {from, timer, deadline}} = state) do
    if Deadline.expired?(Deadline.from_expires_at(deadline)) do
      {:noreply, finish(state)}
    else
      Process.cancel_timer(timer)
      {:noreply, %{state | draining: {from, drain_timer(deadline), deadline}}}
    end
  end

  defp drain_timer(deadline) do
    delay = deadline |> Deadline.from_expires_at() |> Deadline.remaining() |> min(4_294_967_295)
    Process.send_after(self(), :drain_deadline, delay)
  end

  defp maybe_finish(%{draining: draining, borrows: borrows} = state)
       when not is_nil(draining) and map_size(borrows) == 0, do: finish(state)

  defp maybe_finish(state), do: state

  defp finish(state) do
    {from, timer, _deadline} = state.draining
    Process.cancel_timer(timer)
    Enum.each(state.monitors, &Process.demonitor(&1, [:flush]))
    result = cleanup(state.opened)

    reply =
      if result == :ok and map_size(state.borrows) > 0,
        do: {:error, {:outstanding_borrows, map_size(state.borrows)}},
        else: result

    GenServer.reply(from, reply)
    %{state | opened: nil, monitors: [], draining: nil, status: :draining}
  end

  defp cleanup(nil), do: :ok

  defp cleanup(opened) do
    result = ProviderSession.close(opened.session)
    ProviderRegistry.close(opened.registry)
    result
  end

  @impl true
  def terminate(_reason, state), do: cleanup(state.opened)

  defp safe_call(pid, request, fallback, timeout \\ 5_000) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, _reason -> fallback
  end
end
