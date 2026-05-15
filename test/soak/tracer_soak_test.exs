defmodule PtcRunner.TracerSoakTest do
  @moduledoc """
  Soak test: `PtcRunner.Tracer` is a pure data struct, so per-tracer
  memory growth is bounded only by what the caller appends. The risk
  is callers that hold a long-lived tracer (e.g. an aggregator over
  many turns) without setting `:max_entries`, or that pin large
  refc-binaries inside entry payloads.

  This soak verifies three things:

    1. **Bounded tracers stay bounded** — `Tracer.new(max_entries: N)`
       must cap memory regardless of how many `add_entry/2` calls fire.

    2. **Short-lived tracers are GC'd** — creating + finalizing +
       dropping many tracers in a tight loop must not grow host
       memory (catches accidental persistent_term / module-attribute
       caching of tracer state).

    3. **Large binary payloads don't leak refc-binaries** — entries
       with large `:data` values should be reclaimed when the tracer
       goes out of scope. A growing `:binary` total here = the
       classic small-term-references-refc-binary leak.

  ## Run

      mix test --only soak test/soak/tracer_soak_test.exs

      PTC_SOAK_ITERATIONS=50000 \\
        mix test --only soak test/soak/tracer_soak_test.exs
  """
  use ExUnit.Case, async: false

  alias PtcRunner.TestSupport.MemorySoak
  alias PtcRunner.Tracer

  @moduletag :soak
  @moduletag timeout: :infinity

  setup do
    {:ok, iters: MemorySoak.iteration_count()}
  end

  test "bounded tracer stays under max_entries no matter how many appends", %{iters: iters} do
    max = 100
    tracer = Tracer.new(max_entries: max)

    before = MemorySoak.snapshot()
    IO.puts("BEFORE (bounded, n=#{iters}):\n#{MemorySoak.format(before)}")

    final =
      Enum.reduce(1..iters, tracer, fn i, acc ->
        Tracer.add_entry(acc, %{type: :llm_call, data: %{turn: i, payload: payload(1_000)}})
      end)

    assert length(final.entries) <= max
    assert final.entry_count == min(iters, max)

    final = nil
    _ = final

    aft = MemorySoak.snapshot()
    IO.puts("AFTER  (bounded, n=#{iters}):\n#{MemorySoak.format(aft)}")

    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 50)
    MemorySoak.assert_atoms_per_iter!(before, aft, iters)
  end

  test "short-lived tracers are reclaimed cleanly", %{iters: iters} do
    {before, aft} =
      MemorySoak.measure(iters, fn _phase ->
        tracer = Tracer.new()

        tracer =
          Enum.reduce(1..10, tracer, fn i, acc ->
            Tracer.add_entry(acc, %{type: :tool_call, data: %{i: i, blob: payload(500)}})
          end)

        finalized = Tracer.finalize(tracer)
        _ = Tracer.entries(finalized)
        :ok
      end)

    IO.puts("BEFORE (short-lived, n=#{iters}):\n#{MemorySoak.format(before)}")
    IO.puts("AFTER  (short-lived, n=#{iters}):\n#{MemorySoak.format(aft)}")

    MemorySoak.assert_flat!(before, aft, :total, tolerance_pct: 20)
    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 50)
    MemorySoak.assert_atoms_per_iter!(before, aft, iters)
    MemorySoak.assert_procs_stable!(before, aft, tolerance: 5)
  end

  test "large refc-binary payloads don't pin after tracer is dropped", %{iters: iters} do
    # ~64 KB binary — above the heap-binary threshold (64 bytes), so
    # each one is a refc-binary that survives until every reference
    # is GC'd. If we leak even one reference, the binary stays alive.
    big_size = 64 * 1024

    {before, aft} =
      MemorySoak.measure(iters, fn _phase ->
        tracer = Tracer.new()

        tracer =
          Tracer.add_entry(tracer, %{type: :llm_response, data: %{blob: payload(big_size)}})

        _ = Tracer.finalize(tracer)
        :ok
      end)

    IO.puts("BEFORE (refc, n=#{iters}):\n#{MemorySoak.format(before)}")
    IO.puts("AFTER  (refc, n=#{iters}):\n#{MemorySoak.format(aft)}")

    # `:binary` is the headline metric here — if refc-binaries leaked,
    # this number climbs proportional to `iters * big_size`.
    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 50)
    MemorySoak.assert_flat!(before, aft, :total, tolerance_pct: 20)
  end

  defp payload(size) do
    # Build a fresh binary each call to avoid sharing a global blob.
    :crypto.strong_rand_bytes(size) |> Base.encode64()
  end
end
