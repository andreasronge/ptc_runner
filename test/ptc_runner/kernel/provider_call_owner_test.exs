defmodule PtcRunner.Kernel.ProviderCallOwnerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ProviderCallAdmission
  alias PtcRunner.Kernel.ProviderCallOwner
  alias PtcRunner.Kernel.ProviderError

  test "holds one slot around the complete requester invocation" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 1})
    parent = self()

    requester = fn request, _context ->
      send(parent, {:entered, request.id, self()})

      receive do
        {:return, response} -> {:ok, %{response: response}}
      end
    end

    deadline = System.monotonic_time(:millisecond) + 5_000

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
end
