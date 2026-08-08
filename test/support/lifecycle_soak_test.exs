defmodule PtcRunner.TestSupport.LifecycleSoakTest do
  @moduledoc """
  Proves the leak detector detects leaks.

  A soak harness that reports "flat" is indistinguishable from one that
  measures nothing, and every family soak built on this module inherits
  whichever it is. These tests plant each leak the harness claims to catch and
  assert it fails — the harness's own failing-test-before-trusting-it.

  Deliberately not tagged `:soak`: this runs in the ordinary suite, because a
  harness that only proves itself in a weekly job is a harness nobody notices
  the breakage of.
  """

  use ExUnit.Case, async: false

  alias PtcRunner.TestSupport.LifecycleSoak

  # Small and fixed: these tests are about whether an assertion fires, not
  # about measuring anything, so they must not inherit PTC_SOAK_ITERATIONS.
  @cycles 3
  @batches 3

  # A leaked process fails after this instead of the harness's 5s production
  # default, so proving the gate fires costs milliseconds rather than seconds.
  @gate_opts [termination_timeout_ms: 50]

  describe "ledger/1" do
    test "rejects a field it does not know, rather than silently asserting nothing" do
      assert_raise ArgumentError, ~r/unknown ledger field :procs/, fn ->
        LifecycleSoak.ledger(procs: [self()])
      end
    end

    test "wraps a bare value so a single resource does not have to be listed" do
      assert %{processes: [pid]} = LifecycleSoak.ledger(processes: self())
      assert pid == self()
    end
  end

  describe "exact resource gates" do
    test "a surviving process fails" do
      pid = spawn(fn -> receive do: (:never -> :ok) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      assert_raise ExUnit.AssertionError, ~r/was still alive/, fn ->
        LifecycleSoak.assert_reclaimed!(
          "probe",
          LifecycleSoak.ledger(processes: pid),
          1,
          @gate_opts
        )
      end
    end

    test "a surviving ETS table fails" do
      table = :ets.new(:probe, [:set, :public])
      on_exit(fn -> safe_delete(table) end)

      assert_raise ExUnit.AssertionError, ~r/survived its cycle with 0 entries/, fn ->
        LifecycleSoak.assert_reclaimed!("probe", LifecycleSoak.ledger(tables: table), 1)
      end
    end

    test "a surviving entry fails even though its table is legitimately alive" do
      table = :ets.new(:probe, [:set, :public])
      on_exit(fn -> safe_delete(table) end)
      true = :ets.insert(table, {:leaked, :value})

      assert_raise ExUnit.AssertionError, ~r/ETS entry :leaked survived/, fn ->
        LifecycleSoak.assert_reclaimed!(
          "probe",
          LifecycleSoak.ledger(ets_entries: {table, :leaked}),
          1
        )
      end
    end

    test "a deleted table with a listed entry passes, because the entry is gone with it" do
      table = :ets.new(:probe, [:set, :public])
      true = :ets.insert(table, {:key, :value})
      true = :ets.delete(table)

      assert :ok =
               LifecycleSoak.assert_reclaimed!(
                 "probe",
                 LifecycleSoak.ledger(ets_entries: {table, :key}),
                 1
               )
    end

    test "a surviving port fails" do
      port = Port.open({:spawn, "cat"}, [:binary])
      on_exit(fn -> safe_close(port) end)

      assert_raise ExUnit.AssertionError, ~r/survived its cycle/, fn ->
        LifecycleSoak.assert_reclaimed!("probe", LifecycleSoak.ledger(ports: port), 1)
      end
    end

    test "a surviving persistent_term fails" do
      key = {__MODULE__, :probe}
      :persistent_term.put(key, :value)
      on_exit(fn -> :persistent_term.erase(key) end)

      assert_raise ExUnit.AssertionError, ~r/persistent_term key .* survived/, fn ->
        LifecycleSoak.assert_reclaimed!("probe", LifecycleSoak.ledger(persistent_terms: key), 1)
      end
    end

    test "a clean cycle passes every gate" do
      assert :ok = LifecycleSoak.assert_reclaimed!("probe", LifecycleSoak.ledger(), 1)
    end
  end

  describe "soak!/2" do
    test "a cycle that forgets its ledger fails instead of measuring an empty claim" do
      assert_raise ArgumentError, ~r/cycle functions must return/, fn ->
        soak!(fn _cycle -> :ok end)
      end
    end

    test "fewer than three batches is refused, because one interval cannot carry a slope" do
      assert_raise ArgumentError, ~r/at least 3 batches/, fn ->
        LifecycleSoak.soak!(
          [name: "probe", threshold_bytes_per_cycle: 1, cycles: 1, batches: 2, warmup: 0],
          fn _cycle -> LifecycleSoak.ledger() end
        )
      end
    end

    test "a per-cycle process leak fails the exact gate" do
      assert_raise ExUnit.AssertionError, ~r/was still alive/, fn ->
        soak!(fn _cycle ->
          pid = spawn(fn -> receive do: (:never -> :ok) end)
          send(self(), {:leaked, pid})
          LifecycleSoak.ledger(processes: pid)
        end)
      end

      drain_leaked()
    end

    test "a byte leak the ledger cannot see still fails the slope gate" do
      # Retained off-ledger, so the exact gates have nothing to say and only
      # the fitted byte slope can catch it.
      #
      # Both numbers are chosen against the harness's own rules rather than by
      # feel: byte slopes are gated only at 100 cycles a batch or more, and at
      # 100 cycles the resolution floor is ~4 KB/cycle, so 64 KB a cycle sits an
      # order of magnitude above it. The assertion is about the gate firing, not
      # about where the threshold happens to sit.
      table = :ets.new(:leak, [:set, :public])
      on_exit(fn -> safe_delete(table) end)

      assert_raise ExUnit.AssertionError, ~r/grows .* bytes per cycle/, fn ->
        soak!(
          fn cycle ->
            true =
              :ets.insert(table, {{System.unique_integer(), cycle}, :binary.copy(<<0>>, 65_536)})

            LifecycleSoak.ledger()
          end,
          cycles: 100
        )
      end
    end

    test "below the resolvable cycle count the byte gate is skipped, not silently passed" do
      # The same leak, at a cycle count where the slope cannot be resolved. It
      # must not raise — but it must also say so, because a byte gate that
      # quietly stops applying is indistinguishable from one that passed.
      table = :ets.new(:leak, [:set, :public])
      on_exit(fn -> safe_delete(table) end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          soak!(fn cycle ->
            true =
              :ets.insert(table, {{System.unique_integer(), cycle}, :binary.copy(<<0>>, 65_536)})

            LifecycleSoak.ledger()
          end)
        end)

      assert output =~ "byte slopes NOT gated"
      assert output =~ "exact resource gates above still carry this run's verdict"
    end

    test "a clean cycle passes and returns its batch report" do
      # Three cycles per batch put the resolution floor right at the measured
      # endpoint envelope, so a sensitivity-scale budget here would flake on
      # the VM's own drift. This case is about the plumbing, not the threshold.
      report =
        soak!(fn _cycle -> LifecycleSoak.ledger() end, threshold_bytes_per_cycle: 1_000_000)

      assert report.cycles == @cycles
      assert length(report.batches) == @batches

      assert Enum.map(report.batches, & &1.cumulative_cycles) == [
               @cycles,
               @cycles * 2,
               @cycles * 3
             ]
    end
  end

  describe "slope/2" do
    test "recovers an exact linear rate" do
      assert LifecycleSoak.slope([10, 20, 30], [100, 200, 300]) == 10.0
    end

    test "is zero for a flat series, whatever its level" do
      assert LifecycleSoak.slope([10, 20, 30], [500, 500, 500]) == 0.0
    end

    test "is negative when the series falls, so noise cannot read as growth" do
      assert LifecycleSoak.slope([10, 20, 30], [300, 200, 100]) == -10.0
    end

    test "is zero rather than undefined when every x is identical" do
      assert LifecycleSoak.slope([5, 5, 5], [1, 2, 3]) == 0.0
    end
  end

  describe "effective_threshold/2" do
    test "the caller's budget governs once the cycle count can resolve it" do
      assert LifecycleSoak.effective_threshold(512, 3_000) == 512.0
    end

    test "a short run is floored by what its endpoints can actually resolve" do
      assert LifecycleSoak.effective_threshold(512, 25) > 512.0
    end
  end

  defp soak!(cycle_fun, opts \\ []) do
    LifecycleSoak.soak!(
      Keyword.merge(
        [
          name: "probe",
          threshold_bytes_per_cycle: 1,
          cycles: @cycles,
          batches: @batches,
          warmup: 0,
          termination_timeout_ms: 50
        ],
        opts
      ),
      cycle_fun
    )
  end

  defp drain_leaked do
    receive do
      {:leaked, pid} ->
        Process.exit(pid, :kill)
        drain_leaked()
    after
      0 -> :ok
    end
  end

  defp safe_delete(table) do
    :ets.delete(table)
  rescue
    ArgumentError -> :ok
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
