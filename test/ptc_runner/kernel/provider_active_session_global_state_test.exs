defmodule PtcRunner.Kernel.ProviderActiveSessionGlobalStateTest do
  # async: false — these cases stop and restart :req_llm and :llm_db, set persistent ReqLLM pool
  # and :llm_adapter app env, or change the VM's cwd (class D). The rest of ProviderActiveSession
  # coverage is async in ProviderActiveSessionTest.
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.ProviderActiveSessionFixtures

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActiveSession
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.TestSupport.LLMSupport
  alias PtcRunner.TestSupport.MCPHTTPFixture

  test "a session lost before begin preserves only application activity" do
    for {application, services, expected_activity, revision} <- [
          {nil, services(), false, "lost-inert-v1"},
          {:req_llm, services(:command_vm), true, "lost-application-v1"}
        ] do
      if application do
        restore_provider_applications_on_exit()
        stop_provider_applications()
      end

      {:ok, prepared, catalog} =
        fixture(
          fn _selection, _context -> :ok end,
          ["first"],
          nil,
          revision,
          application
        )

      assert {:ok, session} = open_owned_setup(prepared, catalog, services)
      session_ref = Process.monitor(session.pid)
      Process.exit(session.pid, :kill)
      assert_receive {:DOWN, ^session_ref, :process, _pid, :killed}, 1_000

      assert {:error, %CommandDiagnostic{} = diagnostic} =
               ProviderActiveSession.begin_owned_operation(
                 session,
                 prepared,
                 catalog,
                 services,
                 :run
               )

      assert diagnostic.code == :internal_error
      assert diagnostic.provider_activity == expected_activity
      assert :ok = PreparedRun.close(prepared)
    end
  end

  test "host-owned mode requires the selected provider application to be running" do
    restore_provider_applications_on_exit()
    stop_provider_applications()

    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "custom-v1", :req_llm)

    assert {:error,
            %CommandDiagnostic{
              phase: :active_preflight,
              code: :provider_application_unavailable,
              provider_activity: false
            } = diagnostic} =
             open_owned(prepared, catalog, services(:host_owned))

    assert diagnostic.subject.name == "selected"
    assert diagnostic.subject.operation == :application
    assert diagnostic.subject.occurrence == nil
    assert ProviderActivity.value(prepared.provider_activity) == true
    assert :ok = PreparedRun.close(prepared)
  end

  @tag :tmp_dir
  test "command VM startup disables dotenv readers and warms provider metadata", %{
    tmp_dir: directory
  } do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_owner = Application.get_env(:ptc_runner, :host_llm_test_owner)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())
    Application.put_env(:req_llm, :load_dotenv, true, persistent: true)
    Application.put_env(:llm_db, :load_dotenv, true, persistent: true)

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:host_llm_test_owner, previous_owner)
    end)

    sentinel = "PTC_PROVIDER_APPLICATION_DOTENV_SENTINEL"
    previous_sentinel = System.get_env(sentinel)
    System.delete_env(sentinel)

    on_exit(fn ->
      if previous_sentinel,
        do: System.put_env(sentinel, previous_sentinel),
        else: System.delete_env(sentinel)
    end)

    File.write!(Path.join(directory, ".env"), "#{sentinel}=must-not-load\n")

    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "custom-v1", :req_llm)

    File.cd!(directory, fn ->
      assert {:ok, session} =
               open_owned(prepared, catalog, services(:command_vm))

      assert Application.get_env(:req_llm, :load_dotenv) == false
      assert Application.get_env(:llm_db, :load_dotenv) == false
      assert System.get_env(sentinel) == nil
      assert :req_llm in started_applications()
      assert :llm_db in started_applications()
      assert_receive {:host_llm_ensure_ready, warmup_pid}
      assert warmup_pid == self()

      close(session, prepared)
    end)
  end

  test "command VM sizes one ReqLLM pool from the installed provider ceiling" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.delete_env(:req_llm, :finch, persistent: true)
    Application.delete_env(:req_llm, :stream_pool_protocols, persistent: true)

    {:ok, installed_limits} = Limits.installed(live_provider_tasks: 6)

    {:ok, prepared, catalog} =
      fixture(
        fn _selection, _context -> :ok end,
        ["first"],
        installed_limits,
        "installed-pool-v1",
        :req_llm,
        [],
        %{"live_provider_tasks" => 2}
      )

    assert prepared.request.package.limits.live_provider_tasks == 2
    assert catalog.installed_limits.live_provider_tasks == 6
    assert {:ok, session} = open_owned(prepared, catalog, services(:command_vm))

    assert Application.get_env(:req_llm, :stream_pool_count) == 1
    assert Application.get_env(:req_llm, :stream_pool_size) == 6

    assert %{default: default_pool} =
             ReqLLM.Application.get_finch_config() |> Keyword.fetch!(:pools)

    assert Keyword.fetch!(default_pool, :count) == 1
    assert Keyword.fetch!(default_pool, :size) == 6

    close(session, prepared)
  end

  test "one command-owned ReqLLM pool admits eight simultaneously held requests" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.delete_env(:req_llm, :finch, persistent: true)
    Application.delete_env(:req_llm, :stream_pool_protocols, persistent: true)

    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "pool-contention-v1", :req_llm)

    assert {:ok, session} = open_owned(prepared, catalog, services(:command_vm))

    parent = self()
    release_gate = spawn(fn -> receive do: (:release -> :ok) end)

    server =
      MCPHTTPFixture.start(fn _request ->
        release_ref = Process.monitor(release_gate)
        send(parent, {:held_finch_request, self()})

        receive do
          {:DOWN, ^release_ref, :process, ^release_gate, _reason} -> {200, [], "ok"}
        end
      end)

    start_ref = make_ref()
    shared_hash_key = make_ref()

    requesters =
      Enum.map(1..8, fn _index ->
        spawn_monitor(fn ->
          send(parent, {:finch_request_ready, self()})

          receive do
            {:start_finch_request, ^start_ref} ->
              request = Finch.build(:get, server.endpoint)

              result =
                Finch.request(request, ReqLLM.Finch,
                  pool_strategy: {Finch.Pool.Strategy.Hash, shared_hash_key},
                  pool_timeout: 2_000,
                  receive_timeout: 10_000
                )

              send(parent, {:finch_request_result, self(), result})
          end
        end)
      end)

    try do
      requester_pids = Enum.map(requesters, &elem(&1, 0))

      Enum.each(requester_pids, fn requester ->
        assert_receive {:finch_request_ready, ^requester}
      end)

      Enum.each(requester_pids, &send(&1, {:start_finch_request, start_ref}))

      # The observation window deliberately exceeds the pool checkout timeout:
      # the old eight-by-one geometry can admit only one request for this shared
      # hash key before its seven waiters time out, while the one-by-eight pool
      # admits all eight even on a loaded CI scheduler.
      held = collect_held_finch_requests(8, Deadline.new(5_000), [])
      assert length(held) == 8

      send(release_gate, :release)

      Enum.each(requester_pids, fn requester ->
        assert_receive {:finch_request_result, ^requester, {:ok, %Finch.Response{status: 200}}},
                       2_000
      end)
    after
      if Process.alive?(release_gate), do: Process.exit(release_gate, :kill)
      server.close.()

      Enum.each(requesters, fn {pid, monitor} ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
      end)

      close(session, prepared)
    end
  end

  test "command VM preserves an explicit HTTP/2 ReqLLM pool" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.delete_env(:req_llm, :finch, persistent: true)
    Application.put_env(:req_llm, :stream_pool_protocols, [:http2], persistent: true)
    Application.put_env(:req_llm, :stream_pool_count, 3, persistent: true)
    Application.put_env(:req_llm, :stream_pool_size, 4, persistent: true)

    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "http2-pool-v1", :req_llm)

    assert {:ok, session} = open_owned(prepared, catalog, services(:command_vm))
    assert Application.get_env(:req_llm, :stream_pool_protocols) == [:http2]
    assert Application.get_env(:req_llm, :stream_pool_count) == 3
    assert Application.get_env(:req_llm, :stream_pool_size) == 4

    assert %{default: default_pool} =
             ReqLLM.Application.get_finch_config() |> Keyword.fetch!(:pools)

    assert Keyword.fetch!(default_pool, :protocols) == [:http2]
    assert Keyword.fetch!(default_pool, :count) == 3
    assert Keyword.fetch!(default_pool, :size) == 4

    close(session, prepared)
  end

  test "command VM mode rejects a prestarted target while host-owned mode accepts it" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
    Application.put_env(:llm_db, :load_dotenv, false, persistent: true)
    Application.put_env(:req_llm, :stream_pool_count, 3, persistent: true)
    Application.put_env(:req_llm, :stream_pool_size, 4, persistent: true)
    Application.put_env(:req_llm, :finch, [name: ReqLLM.Finch], persistent: true)
    assert {:ok, _started} = Application.ensure_all_started(:req_llm)

    {:ok, command_prepared, command_catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "command-v1", :req_llm)

    assert {:error,
            %CommandDiagnostic{code: :provider_application_unavailable, provider_activity: false}} =
             open_owned(
               command_prepared,
               command_catalog,
               services(:command_vm)
             )

    assert Application.get_env(:req_llm, :stream_pool_count) == 3
    assert Application.get_env(:req_llm, :stream_pool_size) == 4
    assert Application.get_env(:req_llm, :finch) == [name: ReqLLM.Finch]

    {:ok, host_prepared, host_catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "host-v1", :req_llm)

    assert {:ok, session} =
             open_owned(host_prepared, host_catalog, services(:host_owned))

    assert Application.get_env(:req_llm, :stream_pool_count) == 3
    assert Application.get_env(:req_llm, :stream_pool_size) == 4
    assert Application.get_env(:req_llm, :finch) == [name: ReqLLM.Finch]

    close(session, host_prepared)
  end

  test "provider-free command VM admission leaves ReqLLM configuration unchanged" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.put_env(:req_llm, :stream_pool_count, 3, persistent: true)
    Application.put_env(:req_llm, :stream_pool_size, 4, persistent: true)
    Application.put_env(:req_llm, :finch, [name: ReqLLM.Finch], persistent: true)

    {:ok, prepared, catalog} = fixture(fn _selection, _context -> :ok end)
    assert {:ok, session} = open_owned(prepared, catalog, services(:command_vm))

    assert Application.get_env(:req_llm, :stream_pool_count) == 3
    assert Application.get_env(:req_llm, :stream_pool_size) == 4
    assert Application.get_env(:req_llm, :finch) == [name: ReqLLM.Finch]
    refute :req_llm in started_applications()

    close(session, prepared)
  end

  test "command VM startup failures preserve attempted provider activity" do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.put_env(:req_llm, :finch, %{}, persistent: true)
    Application.delete_env(:req_llm, :stream_pool_protocols, persistent: true)
    # Seeded rather than deleted: the subject is that a failed start leaves the
    # pool geometry exactly as it found it, which an absent key cannot tell
    # apart from a start that wrote the same value another test had left behind.
    Application.put_env(:req_llm, :stream_pool_count, 5, persistent: true)
    Application.put_env(:req_llm, :stream_pool_size, 6, persistent: true)

    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> :ok end, ["first"], nil, "command-v1", :req_llm)

    assert {:error,
            %CommandDiagnostic{code: :provider_application_unavailable, provider_activity: true}} =
             open_owned(prepared, catalog, services(:command_vm))

    assert Application.get_env(:req_llm, :stream_pool_count) == 5
    assert Application.get_env(:req_llm, :stream_pool_size) == 6
    assert ProviderActivity.value(prepared.provider_activity) == true
    assert :ok = PreparedRun.close(prepared)
  end

  defp started_applications,
    do: Application.started_applications() |> Enum.map(&elem(&1, 0))

  defp stop_provider_applications do
    LLMSupport.stop_provider_applications()
  end

  defp restore_provider_applications_on_exit do
    snapshot = LLMSupport.snapshot_provider_applications()
    on_exit(fn -> LLMSupport.restore_provider_applications(snapshot) end)
  end

  defp collect_held_finch_requests(0, _deadline, held), do: held

  defp collect_held_finch_requests(remaining, deadline, held) do
    case Deadline.remaining(deadline) do
      0 ->
        held

      timeout_ms ->
        receive do
          {:held_finch_request, holder} ->
            collect_held_finch_requests(remaining - 1, deadline, [holder | held])
        after
          timeout_ms -> held
        end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_runner, key)

  defp restore_env(key, value), do: Application.put_env(:ptc_runner, key, value)
end
