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
  also returns it. Draining refuses new borrows, waits until the supplied
  absolute deadline, and closes the session once even if borrows remain. It
  reports their count as `{:error, {:outstanding_borrows, count}}`.

  Malformed startup options or foreign returns use `:invalid_provider_runtime`.
  A non-ready or draining runtime refuses borrows with
  `:provider_runtime_unavailable`; an unavailable owner uses
  `:provider_runtime_lost`. Cleanup failure is `:provider_cleanup_failed` and
  outranks an earlier acquisition or pin refusal.

  Session or registry authority loss permanently marks readiness
  `{:not_ready, :provider_runtime_lost}`. There is no reacquisition or re-pin.
  Provider-call admission and ServingCall wiring belong to the host layer.
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
          attestation: <<>>
        }

        borrow = %{
          borrow
          | attestation:
              Attestation.attest(Borrow, Map.delete(Map.from_struct(borrow), :attestation))
        }

        {:reply, {:ok, borrow}, put_in(state.borrows[monitor], caller)}

      _lost ->
        {:reply, {:error, :provider_runtime_lost},
         %{state | status: {:not_ready, :provider_runtime_lost}}}
    end
  end

  def handle_call({:borrow, _deadline}, _from, state),
    do: {:reply, {:error, :provider_runtime_unavailable}, state}

  def handle_call({:return, %Borrow{caller: caller} = borrow}, {caller, _tag}, state) do
    release(borrow, state)
  end

  def handle_call({:release, borrow}, _from, state), do: release(borrow, state)

  def handle_call({:drain, _deadline}, _from, %{opened: nil} = state), do: {:reply, :ok, state}

  def handle_call({:drain, deadline}, from, %{draining: nil} = state) do
    timer =
      Process.send_after(
        self(),
        :drain_deadline,
        max(deadline - System.monotonic_time(:millisecond), 0)
      )

    {:noreply, maybe_finish(%{state | status: :draining, draining: {from, timer}})}
  end

  def handle_call({:drain, _deadline}, _from, state),
    do: {:reply, {:error, :provider_runtime_unavailable}, state}

  defp release(borrow, state) do
    if Attestation.valid?(
         Borrow,
         Map.delete(Map.from_struct(borrow), :attestation),
         borrow.attestation
       ) and borrow.runtime == self() do
      Process.demonitor(borrow.monitor, [:flush])
      {:reply, :ok, maybe_finish(%{state | borrows: Map.delete(state.borrows, borrow.monitor)})}
    else
      {:reply, {:error, :invalid_provider_runtime}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    if monitor in state.monitors do
      {:noreply, %{state | status: {:not_ready, :provider_runtime_lost}}}
    else
      {:noreply, maybe_finish(%{state | borrows: Map.delete(state.borrows, monitor)})}
    end
  end

  def handle_info(:drain_deadline, %{draining: nil} = state), do: {:noreply, state}
  def handle_info(:drain_deadline, state), do: {:noreply, finish(state)}

  defp maybe_finish(%{draining: draining, borrows: borrows} = state)
       when not is_nil(draining) and map_size(borrows) == 0, do: finish(state)

  defp maybe_finish(state), do: state

  defp finish(state) do
    {from, timer} = state.draining
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
