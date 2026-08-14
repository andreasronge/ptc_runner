defmodule PtcViewer.ReplStoreTest do
  use ExUnit.Case, async: true

  alias PtcViewer.ReplStore
  alias PtcViewer.TestReplAdapter

  test "session lifecycle evaluates, formats, resets, and remains closed after close" do
    %{store: store} = start_store()

    assert {:ok, first} = ReplStore.bootstrap(store)
    first_session = first["session_id"]
    nonce = first["mutation_nonce"]

    assert byte_size(first_session) == 43
    assert byte_size(nonce) == 43
    assert first["generation_sequence"] == 1
    assert first["lifecycle"] == "open"
    assert first["session"][:profile_id] == "run-analysis-v1"

    assert {:ok, evaluated} = ReplStore.evaluate(store, first_session, "(+ 1 2)")
    assert evaluated["evaluation"].status == :ok
    assert [%{source_preview: "(+ 1 2)"}] = evaluated["transcript"]

    assert {:ok, templated} = ReplStore.template(store, first_session, :run, "run-1")
    assert templated["template"]["source"] == ~s[(analysis/open "run-1")]

    assert {:ok, reset} = ReplStore.reset(store, first_session)
    replacement = reset["session_id"]
    refute replacement == first_session
    assert reset["generation_sequence"] == 2
    assert reset["transcript"] == []
    assert {:error, :session_changed} = ReplStore.evaluate(store, first_session, "1")

    assert {:ok, closed} = ReplStore.close(store, replacement)
    assert closed["lifecycle"] == "closed"
    assert {:ok, polled} = ReplStore.bootstrap(store)
    assert polled["session_id"] == replacement
    assert polled["lifecycle"] == "closed"
    assert {:error, :session_closed} = ReplStore.evaluate(store, replacement, "1")
  end

  test "an active evaluation is never queued behind another mutation" do
    %{store: store} = start_store()
    assert {:ok, bootstrap} = ReplStore.bootstrap(store)
    session_id = bootstrap["session_id"]

    evaluation = Task.async(fn -> ReplStore.evaluate(store, session_id, "block") end)
    assert_receive {:evaluation_started, callback}, 1_000

    assert {:error, :operation_active} =
             ReplStore.template(store, session_id, :run, "run-1")

    send(callback, :release_evaluation)
    assert {:ok, response} = Task.await(evaluation, 2_000)
    assert response["evaluation"].status == :ok
    assert length(response["transcript"]) == 1
  end

  test "source and session preconditions are enforced before adapter work" do
    %{store: store, backend: backend} = start_store()
    assert {:ok, bootstrap} = ReplStore.bootstrap(store)
    session_id = bootstrap["session_id"]

    assert {:error, :session_changed} = ReplStore.evaluate(store, random_id(), "1")

    assert {:error, :source_too_large} =
             ReplStore.evaluate(store, session_id, :binary.copy("x", 65_537))

    assert map_size(TestReplAdapter.state(backend).operations) == 0
  end

  test "failed replacement start exposes the persisted predecessor as closed" do
    %{store: store, backend: backend} = start_store()
    assert {:ok, bootstrap} = ReplStore.bootstrap(store)
    session_id = bootstrap["session_id"]
    TestReplAdapter.set_next_start_error(backend, :repl_start_failed)

    assert {:error, :repl_start_failed} = ReplStore.reset(store, session_id)
    assert {:ok, authoritative} = ReplStore.bootstrap(store)
    assert authoritative["session_id"] == session_id
    assert authoritative["lifecycle"] == "closed"
    assert authoritative["transcript"] == bootstrap["transcript"]
  end

  test "a transient acknowledgement failure is retried before replying" do
    %{store: store, backend: backend} = start_store(ack_failures: 1)

    assert {:ok, bootstrap} = ReplStore.bootstrap(store)
    assert bootstrap["lifecycle"] == "open"
    assert map_size(TestReplAdapter.state(backend).operations) == 0
  end

  test "an unacknowledged close stays blocked until background pruning succeeds" do
    %{store: store, backend: backend} = start_store()
    assert {:ok, bootstrap} = ReplStore.bootstrap(store)
    flush_ack_attempts()
    TestReplAdapter.set_ack_failures(backend, 3)

    assert {:error, :adapter_failure} = ReplStore.close(store, bootstrap["session_id"])
    assert_receive {:ack_attempt, close_operation}, 500
    assert_receive {:ack_attempt, ^close_operation}, 500
    assert {:error, :operation_active} = ReplStore.close(store, bootstrap["session_id"])

    assert_receive {:ack_attempt, ^close_operation}, 1_500
    assert_receive {:ack_attempt, ^close_operation}, 1_500
    assert_eventually(fn -> :sys.get_state(store).lifecycle == :closed end)
    assert {:ok, state} = ReplStore.bootstrap(store)
    assert state["lifecycle"] == "closed"
    assert map_size(TestReplAdapter.state(backend).operations) == 0
  end

  test "malformed adapter evaluation projections fail closed and are pruned" do
    %{store: store, backend: backend} = start_store()
    assert {:ok, bootstrap} = ReplStore.bootstrap(store)

    assert {:error, :adapter_failure} =
             ReplStore.evaluate(store, bootstrap["session_id"], "malformed-result")

    assert map_size(TestReplAdapter.state(backend).operations) == 0
  end

  test "shutdown reports a pending background acknowledgement as failure" do
    %{store: store, backend: backend} = start_store()
    assert {:ok, bootstrap} = ReplStore.bootstrap(store)
    TestReplAdapter.set_ack_failures(backend, 10)

    assert {:error, :adapter_failure} = ReplStore.close(store, bootstrap["session_id"])
    assert {:error, :adapter_failure} = ReplStore.shutdown(store)
  end

  test "shutdown does not retry a close that preparation rejected" do
    %{store: store, backend: backend} = start_store()
    assert {:ok, _bootstrap} = ReplStore.bootstrap(store)
    flush_prepare_attempts()
    TestReplAdapter.set_prepare_error(backend, true)

    assert {:error, :adapter_failure} = ReplStore.shutdown(store)
    assert_receive {:prepare_attempt, {:close, _operation_id}}, 500
    refute_receive {:prepare_attempt, {:close, _operation_id}}, 100
  end

  test "oversized usage is omitted from the bounded transcript fallback" do
    %{store: store} = start_store()
    assert {:ok, bootstrap} = ReplStore.bootstrap(store)
    assert {:ok, response} = ReplStore.evaluate(store, bootstrap["session_id"], "large-usage")

    [entry] = response["transcript"]
    assert entry.result.optional_fields_omitted?
    refute Map.has_key?(entry.result, :usage)
    assert byte_size(Jason.encode!(entry)) <= 131_072
    assert byte_size(Jason.encode!(response["transcript"])) <= 262_144
  end

  test "oversized retained scalar fields are rejected before transcript installation" do
    %{store: store} = start_store()
    assert {:ok, bootstrap} = ReplStore.bootstrap(store)

    assert {:error, :adapter_failure} =
             ReplStore.evaluate(store, bootstrap["session_id"], "oversized-duration")

    assert {:ok, response} = ReplStore.bootstrap(store)
    assert response["transcript"] == []
  end

  test "the complete Core evaluator outcome vocabulary remains visible and recoverable" do
    %{store: store} = start_store()
    assert {:ok, bootstrap} = ReplStore.bootstrap(store)

    for {source, outcome, effect} <- [
          {"recoverable-error", :evaluation_error, :preserved},
          {"memory-exceeded", :memory_exceeded, :preserved},
          {"history-exceeded", :history_exceeded, :preserved},
          {"result-exceeded", :result_exceeded, :committed_with_history}
        ] do
      assert {:ok, response} = ReplStore.evaluate(store, bootstrap["session_id"], source)
      assert response["evaluation"].status == :error
      assert response["evaluation"].outcome == outcome
      assert response["evaluation"].continuation_effect == effect
      assert List.last(response["transcript"]).result.outcome == outcome
      assert response["lifecycle"] == "open"
    end
  end

  test "OTP status redacts opaque backend and transcript state" do
    %{store: store} = start_store()
    assert {:ok, bootstrap} = ReplStore.bootstrap(store)
    assert {:ok, _response} = ReplStore.evaluate(store, bootstrap["session_id"], "PRIVATE-SOURCE")

    status = store |> :sys.get_status() |> inspect()
    refute status =~ "PRIVATE-SOURCE"
    refute status =~ "mutation_nonce"
  end

  defp start_store(opts \\ []) do
    config = Map.new([{:test_pid, self()} | opts])
    {:ok, backend, features} = TestReplAdapter.connect(config)
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, store} =
      ReplStore.start_link(
        owner: self(),
        task_supervisor: task_supervisor,
        adapter: TestReplAdapter,
        backend: backend,
        features: features
      )

    on_exit(fn ->
      safe_stop(store, &GenServer.stop/1)
      safe_stop(task_supervisor, &Supervisor.stop/1)
      safe_stop(backend, &Agent.stop/1)
    end)

    %{store: store, backend: backend}
  end

  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp flush_ack_attempts do
    receive do
      {:ack_attempt, _operation} -> flush_ack_attempts()
    after
      0 -> :ok
    end
  end

  defp flush_prepare_attempts do
    receive do
      {:prepare_attempt, _operation} -> flush_prepare_attempts()
    after
      0 -> :ok
    end
  end

  defp assert_eventually(predicate, attempts \\ 100)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      ref = make_ref()
      Process.send_after(self(), {:eventual_retry, ref}, 10)
      assert_receive {:eventual_retry, ^ref}, 100
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp assert_eventually(predicate, 0), do: assert(predicate.())

  defp safe_stop(pid, stop) do
    if Process.alive?(pid), do: stop.(pid)
  catch
    :exit, _reason -> :ok
  end
end
