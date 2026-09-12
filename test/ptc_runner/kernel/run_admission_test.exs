defmodule PtcRunner.Kernel.RunAdmissionTest do
  # async: false — one case installs a node-wide :telemetry handler that blocks every sandbox arm in
  # the VM (class D); the other cases could run async in a sibling module.
  use ExUnit.Case, async: false
  import PtcRunner.TestSupport.ProviderExecutionFixture
  import PtcRunner.TestSupport.Eventually

  alias PtcRunner.Kernel.{
    Capability,
    ExecutionOutcome,
    PreparedRun,
    PublicationAuthority,
    RunAdmission,
    RunBuilder
  }

  test "successful admitted execution retains the canonical publication result and readmits" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    for _ <- 1..2 do
      fixture = fixture()
      assert {:ok, outcome} = execute(host, fixture)
      assert ExecutionOutcome.valid?(outcome)

      assert {:ok, %{result: {:ok, %{value: %{"answer" => 42}}}}} =
               RunBuilder.publish_execution_report(outcome, fixture.authority)

      assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
      PublicationAuthority.close(fixture.authority)
    end
  end

  test "provider-free runs use the same admission and publication lifecycle" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture(provider_free: true)
    assert {:ok, outcome} = RunAdmission.execute(host, fixture.prepared, fixture.authority)

    assert {:ok, %{result: {:ok, %{value: %{"answer" => 42}}}}} =
             RunBuilder.publish_execution_report(outcome, fixture.authority)

    refute_received {:provider_phase, _}
    assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
  end

  test "disconnect retains admission while the provider closer is held" do
    parent = self()
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    fixture =
      fixture(
        block: true,
        close: fn ->
          send(parent, {:closing, self()})
          receive do: (:release -> :ok)
        end
      )

    {caller, ref} = spawn_monitor(fn -> execute(host, fixture) end)
    assert_receive {:running, _provider}, 5_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    assert_receive {:closing, closer}, 5_000
    assert {:ok, %{in_use: 1, status: :ready}} = RunAdmission.snapshot(host)
    next = fixture()
    assert {:error, :run_capacity_exhausted} = execute(host, next)
    assert PreparedRun.valid?(next.prepared)
    assert PublicationAuthority.authorized?(next.authority)
    send(closer, :release)
    assert_eventually(fn -> match?({:ok, %{in_use: 0}}, RunAdmission.snapshot(host)) end)
    assert {:ok, _} = execute(host, next)
  end

  test "concurrent runs share one capacity domain and excess work stays reusable" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 2})
    fixtures = for _ <- 1..2, do: fixture(block: true)
    tasks = Enum.map(fixtures, fn fixture -> Task.async(fn -> execute(host, fixture) end) end)

    providers =
      for _ <- tasks do
        assert_receive {:running, provider}, 5_000
        provider
      end

    assert {:ok, %{in_use: 2}} = RunAdmission.snapshot(host)
    next = fixture()
    assert {:error, :run_capacity_exhausted} = execute(host, next)
    assert PreparedRun.valid?(next.prepared)
    Enum.each(providers, &send(&1, :finish))
    Enum.each(tasks, fn task -> assert {:ok, _} = Task.await(task, 5_000) end)
    assert {:ok, _} = execute(host, next)
  end

  test "caller death during admission leaves preparation unused and releases the provisional owner" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture()
    :ok = :sys.suspend(host)
    {caller, caller_ref} = spawn_monitor(fn -> execute(host, fixture) end)

    try do
      owner =
        assert_eventually(fn ->
          {:messages, messages} = Process.info(host, :messages)

          Enum.find_value(messages, fn
            {:"$gen_call", {owner, _}, :admit} -> owner
            _ -> nil
          end)
        end)

      owner_ref = Process.monitor(owner)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
      :ok = :sys.resume(host)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000
      assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
      assert PreparedRun.valid?(fixture.prepared)
      assert {:ok, _} = execute(host, fixture)
    after
      :sys.resume(host)
      Process.exit(caller, :kill)
    end
  end

  test "a claimed publication authority releases provisional admission without consuming preparation" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture()
    assert {:ok, _lease} = PublicationAuthority.claim(fixture.authority)
    assert {:error, _} = execute(host, fixture)
    assert PreparedRun.valid?(fixture.prepared)
    assert PublicationAuthority.claimed?(fixture.authority)
    assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
    assert {:ok, _} = execute(host, fixture())
  end

  test "unexpected execution-owner death fences the host rather than recycling its lease" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture(block: true)
    task = Task.async(fn -> execute(host, fixture) end)
    assert_receive {:running, _}, 5_000
    [owner] = Map.keys(:sys.get_state(host).owners)
    Process.exit(owner, :kill)
    assert {:error, _} = Task.await(task, 5_000)
    assert {:ok, %{status: :unavailable}} = RunAdmission.snapshot(host)
    next = fixture()
    assert {:error, :run_admission_unavailable} = execute(host, next)
    assert PreparedRun.valid?(next.prepared)
  end

  test "admission-owner death cancels its active execution and registered roots" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture(block: true)
    task = Task.async(fn -> execute(host, fixture) end)
    assert_receive {:running, provider}, 5_000
    assert_receive {:provider_root, root, :ok}, 5_000
    refs = for pid <- [provider, root], do: {pid, Process.monitor(pid)}
    Process.exit(host, :kill)
    assert {:error, _} = Task.await(task, 5_000)
    for {pid, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 5_000)
    assert {:error, :run_admission_unavailable} = RunAdmission.snapshot(host)
  end

  test "a failed provider closer fences further admission even after normal execution" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture(close: fn -> raise "private-closer-failure" end)
    result = execute(host, fixture)
    refute match?({:ok, %{result: {:ok, _}}}, result)
    assert {:ok, %{status: :unavailable}} = RunAdmission.snapshot(host)
    assert {:error, :run_admission_unavailable} = execute(host, fixture())
  end

  test "admission death during result handoff cannot return success with revoked publication" do
    parent = self()
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture(block: true)
    caller = spawn(fn -> send(parent, {:result, execute(host, fixture)}) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:running, provider}, 5_000
    [owner] = Map.keys(:sys.get_state(host).owners)
    owner_ref = Process.monitor(owner)
    true = :erlang.suspend_process(caller)

    try do
      send(provider, :finish)
      assert_eventually(fn -> :sys.get_state(owner).handoff_waiting? end)
      Process.exit(host, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _}, 5_000
    after
      :erlang.resume_process(caller)
    end

    assert_receive {:result, {:error, :run_admission_unavailable}}, 5_000
  end

  test "hosted execution refuses command-owned application startup before consumption" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture(provider_application_mode: :command_vm)
    assert {:error, :invalid_provider_execution} = execute(host, fixture)
    assert PreparedRun.valid?(fixture.prepared)
    assert {:ok, %{in_use: 0}} = RunAdmission.snapshot(host)
  end

  test "request death also kills the workflow sandbox" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ptc_runner, :sandbox, :armed],
        &__MODULE__.hold_sandbox/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {caller, ref} = spawn_monitor(fn -> execute(host, fixture) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:sandbox_armed, sandbox}, 5_000
    on_exit(fn -> Process.exit(sandbox, :kill) end)
    sandbox_ref = Process.monitor(sandbox)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}, 5_000
    assert_receive {:DOWN, ^sandbox_ref, :process, ^sandbox, :killed}, 1_000
  end

  test "unused reservations saturate, close once, and expire without preparing execution" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})

    assert {:ok, reservation} =
             RunAdmission.reserve(host, System.monotonic_time(:millisecond) + 100)

    assert {:error, :run_capacity_exhausted} = RunAdmission.reserve(host, :infinity)
    assert :ok = RunAdmission.cancel(reservation)
    assert {:error, :run_admission_unavailable} = RunAdmission.cancel(reservation)
    assert {:ok, expired} = RunAdmission.reserve(host, System.monotonic_time(:millisecond) + 10)
    assert_eventually(fn -> match?({:ok, %{in_use: 0}}, RunAdmission.snapshot(host)) end)
    assert {:error, :run_admission_unavailable} = RunAdmission.activate(expired, nil, nil)
    refute_received {:provider_phase, _}
  end

  test "reservation caller death releases capacity and another caller cannot cancel" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    parent = self()

    {caller, ref} =
      spawn_monitor(fn ->
        send(parent, {:reserved, RunAdmission.reserve(host, :infinity)})
        receive do: (:never -> :ok)
      end)

    assert_receive {:reserved, {:ok, reservation}}
    assert {:error, :run_admission_unavailable} = RunAdmission.cancel(reservation)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, _}

    assert_eventually(fn ->
      match?({:ok, %{in_use: 0, status: :ready}}, RunAdmission.snapshot(host))
    end)
  end

  test "activation transfers reserved capacity and cancellation holds it through cleanup" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    parent = self()

    fixture =
      fixture(
        block: true,
        close: fn ->
          send(parent, {:closing, self()})
          receive do: (:release -> :ok)
        end
      )

    assert {:ok, reservation} = RunAdmission.reserve(host, :infinity)

    assert {:ok, execution} =
             RunAdmission.activate(
               reservation,
               fixture.prepared,
               fixture.authority,
               fixture.catalog,
               fixture.execution.services
             )

    assert_receive {:running, _}, 5_000
    assert :ok = RunAdmission.cancel(reservation)
    assert_receive {:closing, closer}, 5_000
    assert {:ok, %{in_use: 1}} = RunAdmission.snapshot(host)
    assert {:error, :run_capacity_exhausted} = RunAdmission.reserve(host, :infinity)
    send(closer, :release)
    assert {:error, _} = RunAdmission.await(execution)
    assert_eventually(fn -> match?({:ok, %{in_use: 0}}, RunAdmission.snapshot(host)) end)
    assert {:ok, next} = RunAdmission.reserve(host, :infinity)
    assert {:error, :run_admission_unavailable} = RunAdmission.cancel(reservation)
    assert {:ok, %{in_use: 1}} = RunAdmission.snapshot(host)
    assert :ok = RunAdmission.close(next)
  end

  test "concurrent reservations atomically saturate and response failures release only their slots" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 2})
    parent = self()

    callers =
      for _ <- 1..16 do
        spawn_monitor(fn ->
          receive do: (:reserve -> :ok)
          result = RunAdmission.reserve(host, :infinity)
          send(parent, {:reservation_result, self(), result})

          case result do
            {:ok, reservation} ->
              receive do: (:response_failed -> :ok)
              send(parent, {:closed, RunAdmission.close(reservation)})

            _ ->
              :ok
          end
        end)
      end

    Enum.each(callers, fn {pid, _} -> send(pid, :reserve) end)

    results =
      for _ <- callers do
        assert_receive {:reservation_result, pid, result}
        {pid, result}
      end

    admitted = Enum.filter(results, fn {_, result} -> match?({:ok, _}, result) end)
    assert length(admitted) == 2

    assert Enum.count(results, fn {_, result} ->
             result == {:error, :run_capacity_exhausted}
           end) == 14

    assert {:ok, %{in_use: 2}} = RunAdmission.snapshot(host)
    Enum.each(admitted, fn {pid, _} -> send(pid, :response_failed) end)
    for _ <- admitted, do: assert_receive({:closed, :ok})
    for {pid, ref} <- callers, do: assert_receive({:DOWN, ^ref, :process, ^pid, :normal})
    assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
    assert {:ok, reservation} = RunAdmission.reserve(host, :infinity)
    assert :ok = RunAdmission.close(reservation)
  end

  test "deadline wins queued activation without consuming preparation or publication" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture(provider_free: true)
    parent = self()

    {caller, ref} =
      spawn_monitor(fn ->
        {:ok, reservation} = RunAdmission.reserve(host, System.monotonic_time(:millisecond) + 100)
        send(parent, {:reserved, reservation})
        receive do: (:activate -> :ok)

        send(
          parent,
          {:activated, RunAdmission.activate(reservation, fixture.prepared, fixture.authority)}
        )
      end)

    assert_receive {:reserved, _reservation}
    :ok = :sys.suspend(host)

    try do
      send(caller, :activate)

      assert_eventually(fn ->
        {:messages, messages} = Process.info(host, :messages)
        Enum.any?(messages, &match?({:reservation_deadline, _}, &1))
      end)
    after
      :sys.resume(host)
    end

    assert_receive {:activated, {:error, :run_admission_unavailable}}
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
    assert PreparedRun.valid?(fixture.prepared)
    assert PublicationAuthority.authorized?(fixture.authority)
    assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
    refute_received {:provider_phase, _}
  end

  test "reserved execution caller death holds capacity during cleanup and cleanup failure fences reservations" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    parent = self()

    fixture =
      fixture(
        block: true,
        close: fn ->
          send(parent, {:closing, self()})
          receive do: (:release -> raise "cleanup failed")
        end
      )

    {caller, ref} =
      spawn_monitor(fn ->
        {:ok, reservation} = RunAdmission.reserve(host, :infinity)

        {:ok, execution} =
          RunAdmission.activate(
            reservation,
            fixture.prepared,
            fixture.authority,
            fixture.catalog,
            fixture.execution.services
          )

        RunAdmission.await(execution)
      end)

    assert_receive {:running, _}, 5_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    assert_receive {:closing, closer}, 5_000
    assert {:error, :run_capacity_exhausted} = RunAdmission.reserve(host, :infinity)
    send(closer, :release)

    assert_eventually(fn ->
      match?({:ok, %{status: :unavailable}}, RunAdmission.snapshot(host))
    end)

    assert {:error, :run_admission_unavailable} = RunAdmission.reserve(host, :infinity)
  end

  test "admission death invalidates unused reservations and cancels reserved execution roots" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 2})
    assert {:ok, unused} = RunAdmission.reserve(host, :infinity)
    fixture = fixture(block: true)
    {:ok, reservation} = RunAdmission.reserve(host, :infinity)

    {:ok, execution} =
      RunAdmission.activate(
        reservation,
        fixture.prepared,
        fixture.authority,
        fixture.catalog,
        fixture.execution.services
      )

    assert_receive {:running, provider}, 5_000
    assert_receive {:provider_root, root, :ok}, 5_000
    refs = for pid <- [provider, root], do: {pid, Process.monitor(pid)}
    Process.exit(host, :kill)
    assert {:error, :run_admission_unavailable} = RunAdmission.await(execution)
    for {pid, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 5_000)
    assert {:error, :run_admission_unavailable} = RunAdmission.cancel(unused)
    assert {:error, :run_admission_unavailable} = RunAdmission.activate(unused, nil, nil)
  end

  test "provider-free activation rejects foreign awaiting and completes its reservation once" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    fixture = fixture(provider_free: true)
    assert {:ok, reservation} = RunAdmission.reserve(host, :infinity)

    assert {:ok, execution} =
             RunAdmission.activate(reservation, fixture.prepared, fixture.authority)

    foreign = Task.async(fn -> RunAdmission.await(execution) end)
    assert {:error, :execution_session_unavailable} = Task.await(foreign)

    assert {:error, :run_admission_unavailable} =
             RunAdmission.activate(reservation, fixture.prepared, fixture.authority)

    assert {:ok, outcome} = RunAdmission.await(execution)
    assert ExecutionOutcome.valid?(outcome)
    assert {:ok, %{in_use: 0, status: :ready}} = RunAdmission.snapshot(host)
    assert {:error, :run_admission_unavailable} = RunAdmission.complete(host, true)
    assert {:ok, next} = RunAdmission.reserve(host, :infinity)
    assert {:error, :run_admission_unavailable} = RunAdmission.cancel(reservation)
    assert {:ok, %{in_use: 1}} = RunAdmission.snapshot(host)
    assert :ok = RunAdmission.close(next)
  end

  @tag :nightly
  test "active reservation deadline requests cancellation and retains capacity through cleanup" do
    host = start_supervised!({RunAdmission, max_concurrent_runs: 1})
    parent = self()

    fixture =
      fixture(
        block: true,
        close: fn ->
          send(parent, {:closing, self()})
          receive do: (:release -> :ok)
        end
      )

    {:ok, reservation} = RunAdmission.reserve(host, System.monotonic_time(:millisecond) + 5_000)

    {:ok, execution} =
      RunAdmission.activate(
        reservation,
        fixture.prepared,
        fixture.authority,
        fixture.catalog,
        fixture.execution.services
      )

    assert_receive {:running, _}, 5_000
    assert_receive {:closing, closer}, 10_000
    assert {:ok, %{in_use: 1}} = RunAdmission.snapshot(host)
    assert {:error, :run_capacity_exhausted} = RunAdmission.reserve(host, :infinity)
    send(closer, :release)
    assert {:error, _} = RunAdmission.await(execution)

    assert_eventually(fn ->
      match?({:ok, %{in_use: 0, status: :ready}}, RunAdmission.snapshot(host))
    end)
  end

  def hold_sandbox(_, _, %{live_run: _, pid: pid}, parent) do
    send(parent, {:sandbox_armed, pid})
    receive do: (:unused -> :ok)
  end

  def hold_sandbox(_, _, _, _), do: :ok

  defp fixture(opts \\ []) do
    parent = self()
    block? = Keyword.get(opts, :block, false)

    opts =
      Keyword.put_new(
        opts,
        :body,
        if(block?, do: "(return (tool/fixture {}))", else: "(return {\"answer\" 42})")
      )

    acquire = fn context ->
      scoped_root(parent, context)

      {:ok, capability} =
        Capability.new(
          name: "fixture",
          input_schema: %{"type" => "object", "additionalProperties" => false},
          callback: fn _ ->
            if block? do
              send(parent, {:running, self()})
              receive do: (:finish -> :ok)
            end

            {:ok, %{}}
          end
        )

      {:ok, %{capabilities: [capability], close: Keyword.get(opts, :close, fn -> :ok end)}}
    end

    provider_fixture(Keyword.put(opts, :acquire, acquire))
  end

  defp execute(host, fixture),
    do:
      RunAdmission.execute(
        host,
        fixture.prepared,
        fixture.authority,
        fixture.catalog,
        fixture.execution.services
      )
end
