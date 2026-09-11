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

  defp monotonic_deadline(offset), do: System.monotonic_time(:millisecond) + offset
end
