defmodule PtcRunner.Kernel.ProviderCallOwnerTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel.AdapterCancellationWitness
  alias PtcRunner.Kernel.ProviderCallAdmission
  alias PtcRunner.Kernel.ProviderCallOwner
  alias PtcRunner.Kernel.ProviderError

  test "holds one slot around the complete requester invocation" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 1})
    parent = self()
    deadline = System.monotonic_time(:millisecond) + 5_000

    requester = fn request, context ->
      assert %{llm_request_deadline_ms: ^deadline} = context
      assert map_size(context) == 1
      send(parent, {:entered, request.id, self()})

      receive do
        {:return, response} -> {:ok, %{response: response}}
      end
    end

    first =
      Task.async(fn ->
        ProviderCallOwner.run(admission, requester, %{id: 1}, %{
          llm_request_deadline_ms: deadline,
          provider_cleanup_timeout_ms: 100
        })
      end)

    assert_receive {:entered, 1, first_requester}

    second =
      Task.async(fn ->
        ProviderCallOwner.run(admission, requester, %{id: 2}, %{
          llm_request_deadline_ms: deadline,
          provider_cleanup_timeout_ms: 100
        })
      end)

    refute_receive {:entered, 2, _}
    send(first_requester, {:return, :first})
    assert {:ok, %{response: :first}} = Task.await(first)
    assert_receive {:entered, 2, second_requester}
    send(second_requester, {:return, :second})
    assert {:ok, %{response: :second}} = Task.await(second)

    assert {:ok, %{active: 0, waiting: 0, status: :ready}} =
             ProviderCallAdmission.snapshot(admission)
  end

  test "guardian death terminates the admitted requester and fences the domain" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 0})
    parent = self()
    deadline = System.monotonic_time(:millisecond) + 5_000

    guardian =
      spawn(fn ->
        ProviderCallOwner.run(
          admission,
          fn _, _ ->
            send(parent, {:requester_entered, self()})
            receive do: (:never -> :ok)
          end,
          %{},
          %{llm_request_deadline_ms: deadline, provider_cleanup_timeout_ms: 100}
        )
      end)

    assert_receive {:requester_entered, requester}
    requester_monitor = Process.monitor(requester)
    Process.exit(guardian, :kill)
    assert_receive {:DOWN, ^requester_monitor, :process, ^requester, _reason}

    assert_eventually(fn ->
      match?({:ok, %{status: :unavailable}}, ProviderCallAdmission.snapshot(admission))
    end)
  end

  test "maps pre-dispatch capacity and admission failures to fixed provider errors" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 0})
    deadline = System.monotonic_time(:millisecond) + 5_000
    assert {:ok, lease} = ProviderCallAdmission.checkout(admission, deadline)

    assert {:error,
            %ProviderError{
              kind: :capacity_exhausted,
              details: "LLM provider call capacity exhausted",
              retryable?: true,
              dispatch_provenance: :not_dispatched
            }} =
             ProviderCallOwner.run(admission, fn _, _ -> flunk("dispatched") end, %{}, %{
               llm_request_deadline_ms: deadline
             })

    assert :ok = ProviderCallAdmission.complete(lease, :completed)
    Process.exit(admission, :kill)

    assert {:error,
            %ProviderError{
              kind: :admission_unavailable,
              details: "LLM provider admission unavailable",
              retryable?: false,
              dispatch_provenance: :not_dispatched
            }} =
             ProviderCallOwner.run(admission, fn _, _ -> flunk("dispatched") end, %{}, %{
               llm_request_deadline_ms: deadline
             })
  end

  test "cooperative cancellation waits for the adapter-owned subtree acknowledgement" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 0})
    parent = self()

    requester = fn _, _ ->
      AdapterCancellationWitness.run(fn ->
        send(parent, {:transport_started, self()})
        receive do: (:held -> :ok)
      end)
    end

    guardian =
      spawn(fn ->
        ProviderCallOwner.run(admission, requester, %{}, %{
          llm_request_deadline_ms: System.monotonic_time(:millisecond) + 5_000,
          provider_cleanup_timeout_ms: 1_000
        })
      end)

    assert_receive {:transport_started, transport}
    transport_ref = Process.monitor(transport)
    guardian_ref = Process.monitor(guardian)
    request_ref = make_ref()
    send(guardian, {:cancel_provider_call, self(), request_ref, monotonic_deadline(1_000)})

    assert_receive {:DOWN, ^transport_ref, :process, ^transport, _reason}
    assert_receive {:provider_call_drained, ^request_ref, ^guardian, :drained}
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}
    assert {:ok, %{active: 0, status: :ready}} = ProviderCallAdmission.snapshot(admission)
  end

  test "cancellation resolves atomically against adapter witness registration" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 0})
    parent = self()

    for iteration <- 1..100 do
      guardian =
        spawn(fn ->
          ProviderCallOwner.run(
            admission,
            fn _, _ ->
              AdapterCancellationWitness.run(fn ->
                send(parent, {:racing_transport_started, iteration, self()})
                receive do: (:held -> :ok)
              end)
            end,
            %{},
            %{
              llm_request_deadline_ms: monotonic_deadline(5_000),
              provider_cleanup_timeout_ms: 1_000
            }
          )
        end)

      request_ref = make_ref()
      send(guardian, {:cancel_provider_call, self(), request_ref, monotonic_deadline(1_000)})

      assert_receive {:provider_call_drained, ^request_ref, ^guardian, :drained}

      receive do
        {:racing_transport_started, ^iteration, transport} ->
          refute Process.alive?(transport)
      after
        0 -> :ok
      end

      assert_eventually(fn ->
        match?({:ok, %{active: 0, status: :ready}}, ProviderCallAdmission.snapshot(admission))
      end)
    end
  end

  test "completes the lease before restoring a requester exception" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 0})

    assert_raise RuntimeError, "requester failed", fn ->
      ProviderCallOwner.run(admission, fn _, _ -> raise "requester failed" end, %{}, %{
        llm_request_deadline_ms: monotonic_deadline(1_000),
        provider_cleanup_timeout_ms: 100
      })
    end

    assert {:ok, %{active: 0, status: :ready}} = ProviderCallAdmission.snapshot(admission)
  end

  test "cooperative cancellation terminates an attested custom requester caller" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 0})
    parent = self()

    guardian =
      spawn(fn ->
        ProviderCallOwner.run(
          admission,
          fn _, _ ->
            send(parent, {:custom_requester_started, self()})
            receive do: (:held -> :ok)
          end,
          %{},
          %{
            llm_request_deadline_ms: monotonic_deadline(5_000),
            provider_cleanup_timeout_ms: 1_000
          }
        )
      end)

    assert_receive {:custom_requester_started, requester}
    requester_ref = Process.monitor(requester)
    guardian_ref = Process.monitor(guardian)
    request_ref = make_ref()
    send(guardian, {:cancel_provider_call, self(), request_ref, monotonic_deadline(1_000)})

    assert_receive {:DOWN, ^requester_ref, :process, ^requester, :killed}
    assert_receive {:provider_call_drained, ^request_ref, ^guardian, :drained}
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}
    assert {:ok, %{active: 0, status: :ready}} = ProviderCallAdmission.snapshot(admission)
  end

  test "admission loss anchors cleanup when the loss is observed" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 0})
    parent = self()

    guardian =
      Task.async(fn ->
        ProviderCallOwner.run(
          admission,
          fn _, _ ->
            send(parent, {:requester_started, self()})
            receive do: (:held -> :ok)
          end,
          %{},
          %{
            llm_request_deadline_ms: monotonic_deadline(5_000),
            provider_cleanup_timeout_ms: 10
          }
        )
      end)

    assert_receive {:requester_started, requester}
    requester_ref = Process.monitor(requester)
    Process.send_after(self(), :cleanup_interval_elapsed, 20)
    assert_receive :cleanup_interval_elapsed
    Process.exit(admission, :kill)

    assert_receive {:DOWN, ^requester_ref, :process, ^requester, :killed}

    assert {:error, %ProviderError{kind: :admission_unavailable}} = Task.await(guardian)
  end

  defp monotonic_deadline(offset), do: System.monotonic_time(:millisecond) + offset
end
