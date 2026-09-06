defmodule PtcRunner.Kernel.RunAdmissionTest do
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
