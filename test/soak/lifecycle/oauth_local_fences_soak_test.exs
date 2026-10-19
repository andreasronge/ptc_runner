defmodule PtcRunner.Soak.OAuthLocalFencesSoakTest do
  @moduledoc """
  Non-gating characterization of unresolved OAuth transitions.

  Counts store-owned fences while persistence deliberately fails. Live stores
  retain their transitions; teardown reclaims them without node-global state.
  The workload independently counts block calls so an unreached path cannot
  masquerade as a flat fence count.
  """

  # async: false — measures VM-wide counters (processes, ETS, atoms, memory) that any concurrent
  # test would perturb (class D).
  use ExUnit.Case, async: false

  @moduletag :soak
  @moduletag timeout: :infinity

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.LocalFences
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.MCPOAuth.TokenManager
  alias PtcRunner.Test.MCPOAuthRecordingStore
  alias PtcRunner.TestSupport.LifecycleSoak
  alias PtcRunner.TestSupport.MemorySoak

  @batches 4

  test "distinct rejections under one fixed identity" do
    started = start_manager()
    on_exit(fn -> tear_down([started]) end)

    report =
      measure("fixed identity", fn generation ->
        _rejected = TokenManager.reject(started.manager, generation, deadline())
        started.memory.pid
      end)

    refute report.blocks == 0, broken_workload_message()
  end

  test "distinct rejections across churning identities" do
    # Managers and stores accumulate for the duration and are torn down at the
    # end rather than per transition. Closing a manager whose persistence is
    # deliberately failing means waiting out its retry budget, and killing its
    # store first leaves it retrying against a dead process — either way the
    # teardown would dominate the run and none of it is what this row measures.
    #
    # Accumulated in the test process's own mailbox, and drained here rather
    # than from `on_exit`: that callback runs in a *different* process, so
    # anything owned by this one is already gone by the time it fires.
    report =
      measure("churning identity", fn generation ->
        started = start_manager()
        send(self(), {:started, started})
        _rejected = TokenManager.reject(started.manager, generation, deadline())
        started.memory.pid
      end)

    tear_down(drain_started([]))

    refute report.blocks == 0, broken_workload_message()
  end

  defp drain_started(acc) do
    receive do
      {:started, started} -> drain_started([started | acc])
    after
      0 -> acc
    end
  end

  # Hard kills, in dependency order and without waiting on any graceful path:
  # every manager here has an unresolvable persistence operation by
  # construction, so `close/1` would spend its retry budget before returning.
  defp tear_down(started) do
    Enum.each(started, fn %{manager: manager, memory: memory} ->
      kill(manager.pid)
      kill(memory.pid)
    end)
  end

  defp kill(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> Process.demonitor(ref, [:flush])
      end
    end

    :ok
  end

  defp broken_workload_message do
    "no LocalFences.block/3 call was observed, so this workload never reached the " <>
      "code under test and proves nothing about the candidate. Fix the workload; " <>
      "do not read the flat fence count as a result."
  end

  # ── measurement ──────────────────────────────────────────────────────────

  # Call counting through the tracer, not inferred from the fence table. The
  # whole point of this row is that a flat table and an unreached code path are
  # indistinguishable without this number.
  defp measure(label, transition) do
    # `trace_pattern/3` silently matches *zero* functions on a module that has
    # not been loaded yet, and lazy loading means that is the normal state for
    # whichever of these tests runs first. The counter then reads 0 both before
    # and after, and the run reports "no blocks observed" — indistinguishable
    # from a workload that never reached the code, which is precisely the
    # ambiguity this instrument exists to remove. Load the module, then assert
    # the pattern actually armed one function.
    Code.ensure_loaded!(LocalFences)

    assert :erlang.trace_pattern({LocalFences, :block, 3}, true, [:call_count]) == 1,
           "call-count tracing did not arm on LocalFences.block/3; the block count " <>
             "this run reports would be meaningless"

    before_blocks = call_count()
    per_batch = transitions_per_batch()

    {counts, _stores} =
      Enum.map_reduce(1..@batches, MapSet.new(), fn batch, stores ->
        stores =
          Enum.reduce(1..per_batch, stores, fn index, stores ->
            MapSet.put(stores, transition.((batch - 1) * per_batch + index))
          end)

        MemorySoak.gc_everywhere()
        {%{transitions: batch * per_batch, fences: fence_count(stores)}, stores}
      end)

    blocks = call_count() - before_blocks
    :erlang.trace_pattern({LocalFences, :block, 3}, false, [:call_count])

    fitted =
      LifecycleSoak.slope(
        Enum.map(counts, & &1.transitions),
        Enum.map(counts, & &1.fences)
      )

    IO.puts("""

    LocalFences characterization — #{label} (row 17, non-gating)
      observed LocalFences.block/3 calls: #{blocks} over #{@batches * per_batch} distinct transitions
    #{Enum.map_join(counts, "\n", &"    after #{&1.transitions} transitions: #{&1.fences} live fences")}
      fitted fence slope: #{Float.round(fitted, 4)} fences per transition
      verdict: #{verdict(blocks, fitted)}
    """)

    %{blocks: blocks, slope: fitted, counts: counts}
  end

  defp verdict(0, _slope),
    do: "WORKLOAD BROKEN — no block/3 calls observed; this run proves nothing"

  defp verdict(_blocks, slope) when slope > 0.5,
    do: "RETAINED — unresolved transitions remain in live stores"

  defp verdict(_blocks, _slope),
    do: "BOUNDED — blocks were observed and the fence count stayed flat"

  defp call_count do
    case :erlang.trace_info({LocalFences, :block, 3}, :call_count) do
      {:call_count, count} when is_integer(count) -> count
      _unavailable -> 0
    end
  end

  defp fence_count(stores) do
    Enum.reduce(stores, 0, fn pid, total ->
      fences = :sys.get_state(pid).local_fences
      total + Enum.sum(Enum.map(fences, fn {_identity, entries} -> map_size(entries) end))
    end)
  end

  # Deliberately small, and fixed independently of `PTC_SOAK_ITERATIONS`.
  #
  # This row characterizes a *rate*. If the fence count rises one-for-one with
  # distinct transitions, twenty points show it as unambiguously as a thousand
  # would, and the slope is what gets reported either way.
  #
  # The cap is also load-bearing rather than cosmetic: a manager holding N
  # unresolvable persistence operations re-examines all of them on each
  # transition, so driving hundreds of failing transitions into one manager
  # makes the *test* superlinear without telling us anything more about the
  # fence table. That cost is worth its own look, but it is not this row.
  defp transitions_per_batch, do: 5

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp start_manager do
    {:ok, memory} = Memory.start(owner: self())
    {:ok, base_store} = Memory.store(memory)

    {:ok, store} =
      MCPOAuthRecordingStore.wrap(base_store, self(),
        interceptor: fn
          {:mark_access_rejected, _key, _generation}, _deadline ->
            # The transition blocks its fence before persistence is attempted;
            # only the durable write fails, which is exactly what leaves the
            # fence unresolved.
            {:return, {:error, :store_error}}

          _operation, _deadline ->
            :delegate
        end
      )

    authority = authority()

    {:ok, context} =
      Context.new(
        tenant_id: "soak-tenant",
        principal_id: "soak-principal-#{System.unique_integer([:positive])}",
        store: store,
        deadline: Deadline.new(5_000)
      )

    {:ok, claims} =
      Store.claim_authorities(
        store,
        "soak-tenant",
        [{authority.installation_id, authority.fingerprint}],
        Deadline.new(5_000)
      )

    epoch = claims[authority.installation_id]

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: context,
        authority: authority,
        authority_epoch: epoch
      )

    %{
      manager: manager,
      memory: memory,
      identity: LocalFences.identity(store, Context.grant_key(context, authority, epoch))
    }
  end

  defp authority do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "soak-fences",
          "issuer" => "https://auth.example",
          "scope_ceiling" => ["read", "write"],
          "default_scopes" => ["read"],
          "refresh_access" => "when_supported",
          "client" => %{
            "registration" => "pre_registered",
            "client_id" => "client",
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code", "refresh_token"],
            "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
          }
        },
        "https://mcp.example/mcp",
        MapSet.new()
      )

    authority
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
