defmodule PtcRunner.Kernel.StateHandleTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.StateHandle

  test "serializes checkout and invalidates the handle at run end" do
    assert {:ok, handle} = StateHandle.start(byte_cap: 10_000)
    assert {:ok, %{}, lease} = StateHandle.checkout(handle)
    assert {:busy, %{}} = StateHandle.checkout(handle)
    assert :ok = StateHandle.checkin(handle, lease, %{"x" => 1})

    assert {:ok, %{defined_count: 1, busy: false, memory_bytes: bytes}} =
             StateHandle.projection(handle)

    assert is_integer(bytes)
    assert :ok = StateHandle.stop(handle)
    assert {:error, :stale_handle} = StateHandle.checkout(handle)
  end

  test "rejects stale tokens and over-cap commits without replacing memory" do
    assert {:ok, handle} = StateHandle.start(byte_cap: 200)
    stale = %{handle | token: make_ref()}

    assert {:error, :stale_handle} = StateHandle.checkout(stale)
    assert {:ok, %{}, lease} = StateHandle.checkout(handle)

    assert {:error, :memory_limit_exceeded} =
             StateHandle.checkin(handle, lease, %{"large" => String.duplicate("x", 1_000)})

    assert {:ok, %{}, lease} = StateHandle.checkout(handle)
    assert :ok = StateHandle.release(handle, lease)
    assert :ok = StateHandle.stop(handle)
  end

  test "rejects foreign leases and clears an abandoned checkout" do
    assert {:ok, handle} = StateHandle.start(byte_cap: 10_000)
    parent = self()

    holder =
      spawn(fn ->
        {:ok, %{}, lease} = StateHandle.checkout(handle)
        send(parent, {:lease, lease})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:lease, lease}
    foreign_lease = make_ref()
    assert {:error, :stale_lease} = StateHandle.release(handle, foreign_lease)
    assert {:error, :stale_lease} = StateHandle.checkin(handle, foreign_lease, %{"bad" => 1})
    assert {:error, :stale_lease} = StateHandle.release(handle, lease)
    assert {:error, :stale_lease} = StateHandle.checkin(handle, lease, %{"bad" => 1})
    assert {:busy, %{}} = StateHandle.checkout(handle)

    holder_monitor = Process.monitor(holder)
    send(holder, :stop)
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, _reason}

    assert {:ok, %{}, next_lease} = StateHandle.checkout(handle)
    assert {:error, :stale_lease} = StateHandle.checkin(handle, lease, %{"stale" => 1})
    assert :ok = StateHandle.checkin(handle, next_lease, %{"fresh" => 1})
    assert :ok = StateHandle.stop(handle)
  end

  test "owner death cleans up the state process" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, handle} = StateHandle.start(owner: self(), byte_cap: 10_000)
        send(parent, {:handle, handle})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:handle, handle}
    state_monitor = Process.monitor(handle.pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^state_monitor, :process, _pid, _reason}
    assert {:error, :stale_handle} = StateHandle.projection(handle)
  end
end
