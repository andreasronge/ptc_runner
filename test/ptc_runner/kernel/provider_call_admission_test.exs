defmodule PtcRunner.Kernel.ProviderCallAdmissionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ProviderCallAdmission

  test "validates its closed options and exposes a temporary child" do
    assert {:error, :invalid_provider_call_admission} = ProviderCallAdmission.start_link([])

    assert {:error, :invalid_provider_call_admission} =
             ProviderCallAdmission.start_link(max_active_calls: 1, max_waiters: 0, extra: true)

    assert {:error, :invalid_provider_call_admission} =
             ProviderCallAdmission.start_link(
               max_active_calls: 1,
               max_active_calls: 2,
               max_waiters: 0
             )

    assert %{restart: :temporary} =
             ProviderCallAdmission.child_spec(max_active_calls: 1, max_waiters: 0)
  end

  test "bounds active calls and fail-fast capacity before owner entry" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 0})
    deadline = System.monotonic_time(:millisecond) + 5_000

    assert {:ok, lease} = ProviderCallAdmission.checkout(admission, deadline)

    assert {:error, :provider_capacity_exhausted} =
             ProviderCallAdmission.checkout(admission, deadline)

    assert {:ok, %{capacity: 1, active: 1, waiting: 0, status: :ready}} =
             ProviderCallAdmission.snapshot(admission)

    assert :ok = ProviderCallAdmission.complete(lease, :completed)
  end

  test "waiters are FIFO and expired waiters are never granted" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 2})
    now = System.monotonic_time(:millisecond)
    assert {:ok, lease} = ProviderCallAdmission.checkout(admission, now + 5_000)
    parent = self()

    first =
      spawn(fn ->
        result = ProviderCallAdmission.checkout(admission, now + 5_000)
        send(parent, {:first, result})

        receive do
          {:complete, first_lease} -> ProviderCallAdmission.complete(first_lease, :completed)
        end
      end)

    _second =
      spawn(fn ->
        send(parent, {:second, ProviderCallAdmission.checkout(admission, now + 20)})
      end)

    assert_receive {:second, {:error, :provider_admission_timeout}}, 1_000
    assert :ok = ProviderCallAdmission.complete(lease, :completed)
    assert_receive {:first, {:ok, first_lease}}, 1_000
    assert first_lease.owner == first
    assert {:complete, ^first_lease} = send(first, {:complete, first_lease})
  end

  test "guardian death while active fences the domain" do
    admission = start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 1})
    parent = self()

    guardian =
      spawn(fn ->
        result =
          ProviderCallAdmission.checkout(admission, System.monotonic_time(:millisecond) + 5_000)

        send(parent, {:lease, result})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:lease, {:ok, _lease}}
    Process.exit(guardian, :kill)

    assert_eventually(fn ->
      match?({:ok, %{status: :unavailable}}, ProviderCallAdmission.snapshot(admission))
    end)

    assert {:error, :provider_admission_unavailable} =
             ProviderCallAdmission.checkout(admission, System.monotonic_time(:millisecond) + 100)
  end

  test "uncertain and protocol-fault completions fence" do
    for completion <- [:uncertain, :duplicate, :foreign] do
      admission =
        start_supervised!({ProviderCallAdmission, max_active_calls: 1, max_waiters: 0},
          id: completion
        )

      deadline = System.monotonic_time(:millisecond) + 1_000
      assert {:ok, lease} = ProviderCallAdmission.checkout(admission, deadline)

      case completion do
        :uncertain ->
          assert {:error, :provider_cleanup_failed} =
                   ProviderCallAdmission.complete(lease, :uncertain)

        :duplicate ->
          assert :ok = ProviderCallAdmission.complete(lease, :completed)

          assert {:error, :duplicate_completion} =
                   ProviderCallAdmission.complete(lease, :completed)

        :foreign ->
          task = Task.async(fn -> ProviderCallAdmission.complete(lease, :completed) end)
          assert {:error, :not_lease_owner} = Task.await(task)
      end

      assert {:ok, %{status: :unavailable}} = ProviderCallAdmission.snapshot(admission)
    end
  end

  defp assert_eventually(assertion, attempts \\ 100)
  defp assert_eventually(assertion, 0), do: assert(assertion.())

  defp assert_eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      receive do
      after
        1 -> assert_eventually(assertion, attempts - 1)
      end
    end
  end
end
