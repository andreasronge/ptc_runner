defmodule PtcRunner.Soak.CredentialLeaseSoakTest do
  @moduledoc """
  Repeated `HostCredentialLease` churn (use-case row 12).

  Resource model, written down before the workload:

  | resource | creator | owner | authorized user | closer |
  |---|---|---|---|---|
  | lease `GenServer` | `start/1`'s caller | itself | anyone holding `{fence, table}` | `close/3`, or its own `:DOWN` on the authority owner |
  | lease ETS table | `start/1`'s caller | the lease `GenServer` after `give_away/3` | same | `maybe_finish_close/1` deletes it before stopping |
  | per-worker lease entry | `claim/3` | the table | the claiming worker | `release/4`, or the worker's `:DOWN` |

  Behavior on termination:

    * **caller death** — the caller is only the constructor; the table's heir
      and the monitored owner are the *authority* owner, so a dead constructor
      changes nothing.
    * **authority-owner death** — the lease owner sees `:DOWN`, closes the
      fence, kills every leased worker, deletes the table, and stops.
    * **worker death while leasing** — the lease owner sees the worker's
      `:DOWN`, deletes that entry, and stays open.

  This family has no deadline of its own to expire: `close/3` bounds itself
  with `@reply_timeout_ms` and escalates to `force_close/3`. Rather than
  inventing a fake deadline variant, the third variant here is a worker dying
  while it holds a lease — the other path on which the owner must reclaim
  something without being told to.

  `force_close/3` itself is **not** covered: reaching it means wedging the
  owner so it cannot reply within its own budget, which is a single-cycle
  behaviour rather than a churn property.
  """

  use ExUnit.Case, async: false

  @moduletag :soak
  @moduletag timeout: :infinity

  alias PtcRunner.Kernel.HostCredentialLease
  alias PtcRunner.TestSupport.LifecycleSoak

  # Measured on a quiet darwin/arm64 run: the fitted byte slope for this
  # workload sits within +-120 B/cycle across batches. 512 leaves room for the
  # VM's own drift without being able to absorb a leaked GenServer (a bare
  # process is already ~2.7 KB) or a leaked ETS table.
  @threshold_bytes_per_cycle 512

  describe "normal completion" do
    test "close/3 leaves no owner, table, or entry behind" do
      LifecycleSoak.soak!(
        [
          name: "credential lease (normal close)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle
        ],
        fn _cycle ->
          authority = spawn_authority()
          {:ok, owner, fence, table} = HostCredentialLease.start(authority)
          {:ok, lease} = claim_from_worker(owner, fence, table)

          :ok = HostCredentialLease.close(owner, fence, table)
          stop_authority(authority)

          LifecycleSoak.ledger(
            processes: [owner, authority],
            tables: [table],
            ets_entries: [{table, lease}]
          )
        end
      )
    end
  end

  describe "owner death" do
    test "authority-owner death drains the lease table" do
      LifecycleSoak.soak!(
        [
          name: "credential lease (authority-owner death)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle
        ],
        fn _cycle ->
          authority = spawn_authority()
          {:ok, owner, fence, table} = HostCredentialLease.start(authority)

          # The lease is held, not released, across the authority's death.
          # Releasing first would leave `state.leases` empty at `:DOWN`, so the
          # drain this variant exists to exercise — `stop_workers/1` killing
          # every leased worker, then `maybe_finish_close/1` waiting for their
          # DOWNs before deleting the table — would never run, and the test
          # would assert cleanup of nothing.
          {worker, _lease} = claim_and_hold(owner, fence, table)

          # No close/3 at all. The lease owner has to notice on its own, which
          # is the path where `terminate/2` never runs and a leak is most
          # likely to survive.
          stop_authority(authority)

          LifecycleSoak.ledger(processes: [owner, authority, worker], tables: [table])
        end
      )
    end

    test "a worker dying mid-lease drops only its own entry" do
      LifecycleSoak.soak!(
        [
          name: "credential lease (worker death)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle
        ],
        fn _cycle ->
          authority = spawn_authority()
          {:ok, owner, fence, table} = HostCredentialLease.start(authority)

          {worker, lease} = claim_and_hold(owner, fence, table)
          kill_and_await(worker)

          # The lease owner is still open here; proving the entry is gone
          # before the owner closes is the point of this variant. `close/3`
          # would delete the whole table and hide a per-entry leak.
          await_entry_gone(owner, table, lease)

          :ok = HostCredentialLease.close(owner, fence, table)
          stop_authority(authority)

          LifecycleSoak.ledger(processes: [owner, authority, worker], tables: [table])
        end
      )
    end
  end

  # The lease owner monitors this process, and the table names it as heir, so
  # it must be a real process rather than the long-lived test process.
  defp spawn_authority do
    parent = self()

    spawn(fn ->
      send(parent, {:authority_ready, self()})

      receive do
        :stop -> :ok
      end
    end)
    |> tap(fn pid -> assert_receive {:authority_ready, ^pid} end)
  end

  defp stop_authority(authority) do
    ref = Process.monitor(authority)
    send(authority, :stop)
    assert_receive {:DOWN, ^ref, :process, ^authority, _reason}
    :ok
  end

  # `claim/3` admits the *calling* process, and the lease owner links to it —
  # so claiming from the test process would link the test process to a
  # GenServer this cycle is about to kill.
  defp claim_from_worker(owner, fence, table) do
    {worker, lease} = claim_and_hold(owner, fence, table)
    :ok = HostCredentialLease.release(owner, table, lease, worker)
    kill_and_await(worker)
    {:ok, lease}
  end

  defp claim_and_hold(owner, fence, table) do
    parent = self()

    worker =
      spawn(fn ->
        # `claim/3` links the worker, so an unhandled exit here would take the
        # lease owner with it; trapping keeps the kill signal explicit.
        Process.flag(:trap_exit, true)
        {:ok, lease} = HostCredentialLease.claim(owner, fence, table)
        send(parent, {:claimed, self(), lease})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:claimed, ^worker, lease}
    {worker, lease}
  end

  defp kill_and_await(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    :ok
  end

  # The worker's `:DOWN` reaches the lease owner and the test independently,
  # so seeing our own gives no guarantee the owner has handled its one. There
  # is no acknowledgement to wait on: nothing in the API reports "I processed
  # that exit".
  #
  # `:sys.get_state/1` is a synchronous system message, so each call is a real
  # acknowledgement that everything already in the owner's mailbox has been
  # handled — retrying it converges the instant the `:DOWN` lands, and never
  # sleeps. The deadline exists so a genuinely leaked entry fails loudly
  # instead of spinning forever.
  defp await_entry_gone(owner, table, lease) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_entry_gone(owner, table, lease, deadline)
  end

  defp await_entry_gone(owner, table, lease, deadline) do
    %{leases: leases} = :sys.get_state(owner)

    cond do
      not Map.has_key?(leases, lease) ->
        assert :ets.lookup(table, lease) == [],
               "lease owner dropped #{inspect(lease)} from its state but left the ETS entry"

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("lease #{inspect(lease)} outlived its worker by 5s: #{inspect(leases)}")

      true ->
        await_entry_gone(owner, table, lease, deadline)
    end
  end
end
