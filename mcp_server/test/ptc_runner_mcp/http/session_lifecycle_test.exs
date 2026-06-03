defmodule PtcRunnerMcp.Http.SessionLifecycleTest do
  @moduledoc """
  Deterministic coverage for the eviction and concurrency-control branches of
  `PtcRunnerMcp.Http.Session` and `PtcRunnerMcp.Http.SessionRegistry`.

  These tests drive the real production path (the GenServers' own `request/4`,
  `create/3`, and `:cleanup` message) without timers or `Process.sleep`:

    * registry `:cleanup` is forced with `send(pid, :cleanup)` and TTL/idle
      thresholds of `0`, so eviction is immediate and deterministic;
    * in-flight branches are exercised by holding a long-running `lisp_eval`
      worker open (confirmed via `:sys.get_state/1` + `wait_until`) while a
      second overlapping request is issued.
  """

  use ExUnit.Case, async: false

  import PtcRunnerMcp.TestSupport.WaitHelpers

  alias PtcRunnerMcp.ConcurrencyGate
  alias PtcRunnerMcp.Envelope
  alias PtcRunnerMcp.Http.Auth
  alias PtcRunnerMcp.Http.Config, as: HttpConfig
  alias PtcRunnerMcp.Http.Session
  alias PtcRunnerMcp.Http.SessionRegistry
  alias PtcRunnerMcp.McpTestHelpers
  alias PtcRunnerMcp.Version

  @token String.duplicate("b", 32)

  setup do
    ConcurrencyGate.init()
    ConcurrencyGate.reset()
    on_exit(fn -> ConcurrencyGate.reset() end)
    :ok
  end

  describe "SessionRegistry :cleanup eviction" do
    test "TTL-expired sessions are evicted on cleanup with a :ttl reason" do
      {registry, owner} = start_registry(session_ttl_ms: 0, session_idle_timeout_ms: 600_000)

      {:ok, meta} = SessionRegistry.create(owner, Version.primary(), registry)
      session_ref = Process.monitor(meta.pid)

      handler = attach_session_closed_telemetry()
      send(registry, :cleanup)

      assert_receive {:DOWN, ^session_ref, :process, _pid, _reason}, 1_000
      assert_receive {:session_closed, ^handler, %{reason: :ttl}}, 1_000

      assert SessionRegistry.lookup(meta.id, owner, registry) == {:error, :not_found}
    end

    test "idle (but not expired) sessions are evicted on cleanup with an :idle reason" do
      # High TTL so `expired?` is false; idle timeout 0 so an in-flight-free
      # session is immediately idle.
      {registry, owner} = start_registry(session_ttl_ms: 3_600_000, session_idle_timeout_ms: 0)

      {:ok, meta} = SessionRegistry.create(owner, Version.primary(), registry)
      session_ref = Process.monitor(meta.pid)

      handler = attach_session_closed_telemetry()
      send(registry, :cleanup)

      assert_receive {:DOWN, ^session_ref, :process, _pid, _reason}, 1_000
      assert_receive {:session_closed, ^handler, %{reason: :idle}}, 1_000

      assert SessionRegistry.lookup(meta.id, owner, registry) == {:error, :not_found}
    end

    test "a session with in-flight work is not evicted by the idle path on cleanup" do
      {registry, owner} = start_registry(session_ttl_ms: 3_600_000, session_idle_timeout_ms: 0)

      {:ok, meta} = SessionRegistry.create(owner, Version.primary(), registry)

      task = async_tool_call(meta.pid, "inflight-guard")
      wait_until(fn -> in_flight_count(meta.pid) == 1 end, 5_000)

      send(registry, :cleanup)
      # No timer to wait on; assert the registry round-trips and the session
      # is still present after the cleanup pass has been processed.
      assert SessionRegistry.lookup(meta.id, owner, registry) == {:ok, meta}
      assert in_flight_count(meta.pid) == 1

      Task.shutdown(task, :brutal_kill)
      wait_until(fn -> in_flight_count(meta.pid) == 0 end, 5_000)
    end
  end

  describe "Http.Session in-flight concurrency control" do
    test "a second overlapping call returns a busy envelope when max_in_flight is 1" do
      {:ok, session} = start_session(max_in_flight: 1)

      task = async_tool_call(session, "slow-1")
      wait_until(fn -> in_flight_count(session) == 1 end, 5_000)

      reply = Session.request(session, tool_call_frame("fast-2"), [], 5_000)
      assert {:reply, %{"id" => "fast-2", "result" => result}} = reply

      busy = Envelope.busy(1)
      assert result["structuredContent"]["reason"] == busy["structuredContent"]["reason"]
      assert result["structuredContent"]["status"] == busy["structuredContent"]["status"]

      Task.shutdown(task, :brutal_kill)
    end

    test "a duplicate request id while in flight returns a -32600 duplicate reply" do
      {:ok, session} = start_session(max_in_flight: 4)

      task = async_tool_call(session, "dup-id")
      wait_until(fn -> in_flight_count(session) == 1 end, 5_000)

      reply = Session.request(session, tool_call_frame("dup-id"), [], 5_000)

      assert {:reply, %{"id" => "dup-id", "error" => %{"code" => -32_600, "message" => message}}} =
               reply

      assert message =~ "already in flight"
      # The duplicate must not have evicted or doubled the in-flight slot.
      assert in_flight_count(session) == 1

      Task.shutdown(task, :brutal_kill)
    end

    test "an abnormal worker crash frees the slot and replies with -32603 internal error" do
      {:ok, session} = start_session(max_in_flight: 4)

      task = async_tool_call(session, "crash-me")
      wait_until(fn -> in_flight_count(session) == 1 end, 5_000)
      assert ConcurrencyGate.in_flight() == 1

      # The :DOWN arm for an abnormal, non-:killed/non-:normal worker exit
      # (existing tests only cover the :killed arm) is a genuine race against
      # the sandbox finishing the worker on its own. We freeze the session with
      # :sys.suspend so it cannot process the worker's real :async_reply,
      # capture the still-registered worker, kill it, then deliver the exact
      # production :DOWN message with an abnormal reason and resume. This drives
      # `handle_info({:DOWN, ...})` deterministically with no race or sleep.
      :sys.suspend(session)
      %{"crash-me" => %{pid: worker_pid, ref: worker_ref}} = :sys.get_state(session).in_flight
      Process.exit(worker_pid, :kill)
      send(session, {:DOWN, worker_ref, :process, worker_pid, :boom})
      :sys.resume(session)

      assert {:reply,
              %{"id" => "crash-me", "error" => %{"code" => -32_603, "message" => message}}} =
               Task.await(task, 1_000)

      assert message == "Internal error"

      # The slot and the global permit are both released.
      wait_until(fn -> in_flight_count(session) == 0 and ConcurrencyGate.in_flight() == 0 end)
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp start_registry(overrides) do
    McpTestHelpers.stop_existing_registry(SessionRegistry)
    {:ok, cfg} = HttpConfig.resolve(%{http: true, http_auth_token: @token})
    cfg = Enum.reduce(overrides, cfg, fn {k, v}, acc -> Map.put(acc, k, v) end)
    pid = start_supervised!({SessionRegistry, [config: cfg]})
    {pid, Auth.owner_for(@token)}
  end

  defp start_session(opts) do
    owner = Auth.owner_for(@token)

    session =
      start_supervised!(
        {Session,
         [
           id: "sess_#{System.unique_integer([:positive])}",
           owner: owner,
           owner_hash: owner.hash,
           protocol_version: Version.primary(),
           max_in_flight: Keyword.fetch!(opts, :max_in_flight)
         ]}
      )

    {:ok, session}
  end

  defp async_tool_call(session, id) do
    Task.async(fn -> Session.request(session, tool_call_frame(id), [], 30_000) end)
  end

  defp tool_call_frame(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "lisp_eval",
        "arguments" => %{"program" => long_running_program(), "context" => %{}}
      }
    }
  end

  defp in_flight_count(pid), do: map_size(:sys.get_state(pid).in_flight)

  defp attach_session_closed_telemetry do
    handler_id = "session-lifecycle-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:ptc_lisp, :http, :session, :closed],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:session_closed, handler_id, metadata})
        end,
        %{}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp long_running_program do
    "((fn ack [m n] " <>
      "(cond (= m 0) (+ n 1) " <>
      "(= n 0) (ack (- m 1) 1) " <>
      ":else (ack (- m 1) (ack m (- n 1))))) 3 8)"
  end
end
