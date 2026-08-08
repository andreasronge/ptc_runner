defmodule PtcRunner.TestSupport.LifecycleSoak do
  @moduledoc """
  Repeated-churn leak detection for the long-lived owner lifecycles.

  `PtcRunner.TestSupport.MemorySoak` soaks two entry points that reap their
  sandbox process when the call returns, so per-call leakage there is bounded by
  construction. This module is its sibling for everything that is *not* bounded
  that way: session owners, provider acquisition, credential leases, transports,
  REPL sessions, and OAuth managers. Those have good single-cycle tests; none of
  them was ever run N times with the aggregate asserted flat, and a per-cycle
  residue small enough to pass every single-cycle assertion is exactly what
  accumulates over a host's lifetime.

  ## The oracle

  `run K batches of N cycles`, forcing a system-wide GC at each batch boundary.
  A one-shot cost (lazy module loading, first-use interning) appears in batch 1
  only; a linear leak appears in every batch.

  The detector is a **slope**, not a trend. "The per-batch delta does not grow"
  is satisfied by a constant positive delta in every batch — which is precisely
  the leak being hunted — so it must not be the assertion. Byte metrics are
  regressed against cumulative cycles over batches 2..K and the fitted slope is
  asserted below a per-metric threshold. Batch 1 is excluded from the fit and
  kept in the report, because it is the warmup cost and worth reading.

  ## Tiers

  Not every sample can carry the same authority.

    * **Gating, exact.** Resources the cycle itself created: owned processes,
      the ETS entries it inserted, tables it allocated, ports it opened,
      `:persistent_term` keys it wrote. The legitimate steady-state value is
      zero, so these are asserted exactly, per cycle, through `ledger/1`.
      They are deliberately **not** global counts: a global
      `:erlang.system_info(:process_count)` both flaps on a shared VM and can
      hide a real leak when an unrelated process exits and offsets it.

    * **Gating, thresholded.** `:erlang.memory/0` byte totals, via the slope
      assertion above against a caller-supplied threshold.

    * **Diagnostic, non-gating.** Global counts, allocator carrier utilization
      and RSS. Recorded and printed on every run, never failing a build. RSS
      and carrier behavior are platform- and allocator-dependent, so they
      inform an investigation rather than deciding it.

  Monitors do not appear as their own gate. The plan lists "monitors held by the
  family's owners" as exact, but every owner a cycle creates is asserted dead,
  and a dead process holds no monitors — the process gate subsumes it. The
  global monitor total stays as diagnostic context.

  ## Writing a family soak

      LifecycleSoak.soak!(
        [name: "credential lease", threshold_bytes_per_cycle: 512],
        fn _index ->
          {:ok, owner, _fence, table} = HostCredentialLease.start(self())
          :ok = HostCredentialLease.close(owner, fence, table)
          LifecycleSoak.ledger(processes: [owner], tables: [table])
        end
      )

  The cycle function creates, terminates, and returns a ledger of what it made.
  Capturing identities at creation is the whole mechanism: there is no scanning
  for owners, because outside `HostInstallationOwner` and `ReplSession` nothing
  publishes a discoverable marker, and adding one to a production module purely
  so a test can find it would put a test affordance in the runtime for no
  runtime benefit.

  A ledger that omits a resource the cycle really created is the failure this
  module exists to prevent, and it is easy to write: the omission is invisible
  precisely because nothing then checks it. Two traps in this codebase have
  each produced it more than once.

    * **Every `RunState` starts a `ProviderTaskTracker` alongside it**
      (`run_state.ex:995`), reachable as `run_state.provider_tracker.pid`. A
      family that ledgers its run state and stops there is missing a process
      per cycle.
    * **A capped family has no byte-slope backstop.** Byte gating applies only
      at #{@min_cycles_for_byte_gate} cycles a batch or more, so in a family
      capped below that an unledgered resource is invisible to *every* gate at
      *every* iteration count — not merely to the exact ones.

  When adding a family, enumerate what each cycle causes to exist rather than
  what its API returns, and read owned pids out of live state before any
  variant kills the owner.

  Termination must be deterministic — monitors and explicit acknowledgement,
  never `Process.sleep/1`.
  """

  alias PtcRunner.TestSupport.MemorySoak

  @typedoc """
  What one churn cycle created, so the exact assertions can be scoped to it.

    * `:processes` — must all be dead when the cycle returns
    * `:tables` — ETS tables that must be gone
    * `:ets_entries` — `{table, key}` pairs that must be absent, for tables
      that legitimately outlive the cycle (`ReplSession` allocates one
      `:private` table per *creator process*, not per session, so a leaked
      session entry never changes the table count)
    * `:ports` — must all be closed
    * `:persistent_terms` — keys that must be absent
  """
  @type ledger :: %{
          processes: [pid()],
          tables: [:ets.table()],
          ets_entries: [{:ets.table(), term()}],
          ports: [port()],
          persistent_terms: [term()]
        }

  @empty_ledger %{processes: [], tables: [], ets_entries: [], ports: [], persistent_terms: []}

  @default_batches 4
  @termination_timeout_ms 5_000

  # Measured envelope of how far a batch endpoint moves between batches on an
  # unchanged workload. This noise is an absolute quantity — the VM's drift
  # between two GC points, not something each cycle contributes — so the
  # per-cycle resolution it implies is `@endpoint_noise_bytes / cycles`. A byte
  # budget tighter than that cannot be measured, only failed at random.
  #
  # Measured **under the condition the suite actually runs in**: every family in
  # one VM, via `mix soak`, not one family on an idle one. That distinction cost
  # a round of flakes. Isolated, a single family's endpoints sit inside a ~50 KB
  # band; with the whole suite resident, repeated runs at 10 cycles a batch put
  # fitted slopes anywhere in -9.5..+29.3 KB/cycle with no leak present, which
  # is an endpoint excursion near 300 KB. 400 KB covers that with margin.
  #
  # The consequence is deliberate at both ends. A short local run (10 cycles)
  # gets a 40 KB/cycle floor and effectively cannot gate on bytes — its verdict
  # comes from the exact resource gates, which do not depend on cycle count at
  # all. A `PTC_SOAK_ITERATIONS=3000` run gets a 133 B/cycle floor, well under
  # every caller's budget, so there the caller's number governs and a real
  # per-cycle leak of even 1 KB stands 3 MB above the noise.
  @endpoint_noise_bytes 400_000

  # Below this many cycles a batch, the byte slope is not gated at all — it is
  # measured and printed, and the verdict comes from the exact resource gates,
  # which do not depend on cycle count.
  #
  # This is the honest end of the resolution argument rather than a bigger
  # constant. Endpoint drift is roughly fixed per batch, so at 10 cycles it is
  # comparable to any budget worth setting: repeated clean runs of this suite
  # produced fitted slopes from -9.5 to +41 KB/cycle with no leak present. No
  # threshold separates signal from noise there, and one tuned until the flakes
  # stop is not a gate, it is a number that happens not to fire yet.
  #
  # `PTC_SOAK_ITERATIONS=3000` — what the scheduled workflow runs — is two
  # orders of magnitude above this, so CI always gates.
  @min_cycles_for_byte_gate 100

  @gated_memory_keys [:total, :processes, :ets, :binary]

  @doc "Builds a ledger from keyword options; every field defaults to empty."
  @spec ledger(keyword()) :: ledger()
  def ledger(opts \\ []) do
    Enum.reduce(opts, @empty_ledger, fn {key, value}, acc ->
      unless Map.has_key?(@empty_ledger, key) do
        raise ArgumentError,
              "unknown ledger field #{inspect(key)}; expected one of " <>
                inspect(Map.keys(@empty_ledger))
      end

      Map.put(acc, key, List.wrap(value))
    end)
  end

  @doc """
  Churns `cycle_fun` and asserts the gating metrics stay flat across batches.

  Options:

    * `:name` — required; names the owner family in every message
    * `:cycles` — cycles per batch, default `MemorySoak.iteration_count/0`
    * `:batches` — default #{@default_batches}; at least 3, because two batches
      leave a single interval and the slope would rest on the batch that still
      carries warmup
    * `:warmup` — warmup cycles, default `PTC_SOAK_WARMUP`
    * `:threshold_bytes_per_cycle` — required; the byte-slope budget, chosen
      from the metric's observed batch-to-batch noise on this workload rather
      than from a round number. Byte slopes are gated only at
      `#{@min_cycles_for_byte_gate}` cycles a batch or more; below that they are
      printed and the exact resource gates carry the verdict. When they are
      gated, the budget applied is the larger of this and the resolution floor
      `#{@endpoint_noise_bytes} / cycles`, so `PTC_SOAK_ITERATIONS=3000` gates on
      the caller's number
    * `:atoms_per_cycle` — atom-slope budget, default `0.1`
    * `:termination_timeout_ms` — how long a cycle's owner may take to die
      before the exact gate fails, default #{@termination_timeout_ms}

  Returns the batch report so a characterization test can print its own
  numbers without failing the build.
  """
  @spec soak!(keyword(), (non_neg_integer() -> ledger())) :: map()
  def soak!(opts, cycle_fun) when is_function(cycle_fun, 1) do
    name = Keyword.fetch!(opts, :name)
    threshold = Keyword.fetch!(opts, :threshold_bytes_per_cycle)
    cycles = Keyword.get(opts, :cycles, MemorySoak.iteration_count())
    batches = Keyword.get(opts, :batches, @default_batches)
    warmup = Keyword.get(opts, :warmup, MemorySoak.warmup_count())
    atoms_per_cycle = Keyword.get(opts, :atoms_per_cycle, 0.1)
    gate_opts = Keyword.take(opts, [:termination_timeout_ms])

    if batches < 3 do
      raise ArgumentError, "soak!/2 needs at least 3 batches to fit a slope, got #{batches}"
    end

    run_cycles(name, cycle_fun, warmup, :warmup, gate_opts)

    report = %{
      name: name,
      cycles: cycles,
      batches: run_batches(name, cycle_fun, cycles, batches, gate_opts)
    }

    IO.puts(format(report))

    assert_slopes!(report, effective_threshold(threshold, cycles), atoms_per_cycle, cycles)
    report
  end

  @doc """
  The byte budget `soak!/2` actually applies at a given cycle count.

  Below `#{@endpoint_noise_bytes} / cycles` a byte slope is indistinguishable
  from the VM's own drift between GC points, so a tighter budget would only
  produce random failures. The exact resource gates are unaffected — they do
  not depend on cycle count at all, which is why they are the ones that carry
  the verdict on a short run.
  """
  @spec effective_threshold(number(), pos_integer()) :: float()
  def effective_threshold(threshold, cycles) when cycles > 0,
    do: max(threshold * 1.0, @endpoint_noise_bytes / cycles)

  @doc """
  Counts live `:persistent_term` keys accepted by `match_fun`.

  Family-scoped by construction: the caller supplies the predicate for its own
  key shape, so the count never includes another subsystem's entries.
  """
  @spec count_persistent_terms((term() -> boolean())) :: non_neg_integer()
  def count_persistent_terms(match_fun) when is_function(match_fun, 1) do
    Enum.count(:persistent_term.get(), fn {key, _value} -> match_fun.(key) end)
  end

  @doc """
  Fits a least-squares slope of `values` against `xs`.

  Returns `0.0` when every `x` is identical, which cannot happen for batch
  endpoints but keeps the helper total.
  """
  @spec slope([number()], [number()]) :: float()
  def slope(xs, values) when length(xs) == length(values) do
    n = length(xs)
    mean_x = Enum.sum(xs) / n
    mean_y = Enum.sum(values) / n

    {covariance, variance} =
      Enum.zip(xs, values)
      |> Enum.reduce({0.0, 0.0}, fn {x, y}, {cov, var} ->
        {cov + (x - mean_x) * (y - mean_y), var + (x - mean_x) * (x - mean_x)}
      end)

    if variance == 0.0, do: 0.0, else: covariance / variance
  end

  @doc """
  Asserts every resource in `ledger` is gone, with a message naming the family.

  Called after each cycle by `soak!/2`; exposed so a single-cycle test can use
  the same definition of "reclaimed" as the soak does.
  """
  @spec assert_reclaimed!(binary(), ledger(), non_neg_integer(), keyword()) :: :ok
  def assert_reclaimed!(name, ledger, cycle, opts \\ []) do
    timeout = Keyword.get(opts, :termination_timeout_ms, @termination_timeout_ms)
    Enum.each(ledger.processes, &assert_dead!(name, &1, cycle, timeout))
    Enum.each(ledger.tables, &assert_table_gone!(name, &1, cycle))
    Enum.each(ledger.ets_entries, &assert_entry_gone!(name, &1, cycle))
    Enum.each(ledger.ports, &assert_port_closed!(name, &1, cycle))
    Enum.each(ledger.persistent_terms, &assert_persistent_term_gone!(name, &1, cycle))
    :ok
  end

  # ── batches ──────────────────────────────────────────────────────────────

  defp run_batches(name, cycle_fun, cycles, batches, gate_opts) do
    for batch <- 1..batches do
      run_cycles(name, cycle_fun, cycles, batch, gate_opts)
      MemorySoak.gc_everywhere()

      %{
        batch: batch,
        cumulative_cycles: batch * cycles,
        snapshot: MemorySoak.snapshot(gc: false)
      }
    end
  end

  defp run_cycles(_name, _cycle_fun, 0, _label, _gate_opts), do: :ok

  defp run_cycles(name, cycle_fun, count, label, gate_opts) do
    Enum.each(1..count, fn index ->
      ledger = normalize!(name, label, index, cycle_fun.(index))
      assert_reclaimed!(name, ledger, index, gate_opts)
    end)
  end

  # A cycle that forgets to return a ledger would silently assert nothing, and
  # the soak would pass by measuring an empty claim.
  defp normalize!(_name, _label, _index, %{processes: _, tables: _} = ledger), do: ledger

  defp normalize!(name, label, index, other) do
    raise ArgumentError,
          "#{name} #{label} cycle #{index} returned #{inspect(other)}; " <>
            "cycle functions must return LifecycleSoak.ledger/1"
  end

  # ── exact assertions ─────────────────────────────────────────────────────

  # Monitor-based, so termination is observed rather than waited out. A monitor
  # on an already-dead process fires `:noproc` immediately, so this is correct
  # whether the cycle's owner died before or after the ledger was built.
  defp assert_dead!(name, pid, cycle, timeout) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])

        flunk(
          name,
          cycle,
          "process #{inspect(pid)} was still alive #{timeout}ms after its " <>
            "cycle returned: #{inspect(Process.info(pid, [:current_function, :dictionary]))}"
        )
    end
  end

  defp assert_table_gone!(name, table, cycle) do
    case :ets.info(table, :size) do
      :undefined ->
        :ok

      size ->
        flunk(
          name,
          cycle,
          "ETS table #{inspect(table)} survived its cycle with #{size} entries " <>
            "(owner #{inspect(:ets.info(table, :owner))})"
        )
    end
  end

  defp assert_entry_gone!(name, {table, key}, cycle) do
    case safe_lookup(table, key) do
      [] ->
        :ok

      :table_gone ->
        :ok

      entries ->
        flunk(name, cycle, "ETS entry #{inspect(key)} survived its cycle: #{inspect(entries)}")
    end
  end

  defp assert_port_closed!(name, port, cycle) do
    case Port.info(port) do
      nil -> :ok
      info -> flunk(name, cycle, "port #{inspect(port)} survived its cycle: #{inspect(info)}")
    end
  end

  defp assert_persistent_term_gone!(name, key, cycle) do
    case :persistent_term.get(key, :absent) do
      :absent ->
        :ok

      value ->
        flunk(
          name,
          cycle,
          ":persistent_term key #{inspect(key)} survived its cycle: #{inspect(value)}"
        )
    end
  end

  defp safe_lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> :table_gone
  end

  defp flunk(name, cycle, message) do
    raise ExUnit.AssertionError,
      message: "#{name} soak, cycle #{cycle}: #{message}"
  end

  # ── slope assertions ─────────────────────────────────────────────────────

  # The atom slope gates at every cycle count: atoms never GC, so the count is
  # monotonic and no drift can offset it. Only the byte slopes need enough
  # cycles to out-resolve the VM's own movement.
  defp assert_slopes!(report, threshold, atoms_per_cycle, cycles)
       when cycles < @min_cycles_for_byte_gate do
    IO.puts(
      "  byte slopes NOT gated: #{cycles} cycles per batch is below the " <>
        "#{@min_cycles_for_byte_gate} needed to resolve them. The exact resource " <>
        "gates above still carry this run's verdict."
    )

    assert_atom_slope!(report, atoms_per_cycle)
    _unused = threshold
    :ok
  end

  defp assert_slopes!(report, threshold, atoms_per_cycle, _cycles) do
    Enum.each(@gated_memory_keys, fn key ->
      fitted = memory_slope(report, key)

      if fitted > threshold do
        raise ExUnit.AssertionError,
          message: """
          #{report.name} soak: `#{key}` grows #{Float.round(fitted, 2)} bytes per cycle \
          across batches 2..#{length(report.batches)} (budget #{Float.round(threshold, 2)} \
          at #{report.cycles} cycles per batch).

          A constant per-batch delta is what a linear leak looks like, so this is \
          fitted as a slope over cumulative cycles rather than compared batch to batch.

          #{format(report)}
          """
      end
    end)

    assert_atom_slope!(report, atoms_per_cycle)
  end

  defp assert_atom_slope!(report, atoms_per_cycle) do
    fitted_atoms = atom_slope(report)

    if fitted_atoms > atoms_per_cycle do
      raise ExUnit.AssertionError,
        message:
          "#{report.name} soak: atom table grows #{Float.round(fitted_atoms, 4)} atoms per " <>
            "cycle (budget #{atoms_per_cycle}). Atoms never GC.\n\n#{format(report)}"
    end

    :ok
  end

  # Batch 1 carries lazy module loading and first-use interning. Excluding it
  # from the fit is what lets the same harness read a one-shot cost and a
  # linear leak apart; it stays in the printed report.
  defp fitted_batches(report), do: Enum.drop(report.batches, 1)

  defp memory_slope(report, key) do
    batches = fitted_batches(report)

    slope(
      Enum.map(batches, & &1.cumulative_cycles),
      Enum.map(batches, &Keyword.fetch!(&1.snapshot.mem, key))
    )
  end

  defp atom_slope(report) do
    batches = fitted_batches(report)
    slope(Enum.map(batches, & &1.cumulative_cycles), Enum.map(batches, & &1.snapshot.atoms))
  end

  # ── reporting ────────────────────────────────────────────────────────────

  @doc "Renders the batch table, including the diagnostic-tier samples."
  @spec format(map()) :: binary()
  def format(report) do
    rows =
      Enum.map_join(report.batches, "\n", fn %{batch: batch, snapshot: snapshot} = entry ->
        "  batch #{batch} (#{entry.cumulative_cycles} cycles): " <>
          "total=#{MemorySoak.format_bytes(snapshot.mem[:total])} " <>
          "procs_mem=#{MemorySoak.format_bytes(snapshot.mem[:processes])} " <>
          "ets=#{MemorySoak.format_bytes(snapshot.mem[:ets])} " <>
          "bin=#{MemorySoak.format_bytes(snapshot.mem[:binary])} " <>
          "atoms=#{snapshot.atoms} procs=#{snapshot.procs} " <>
          "tables=#{snapshot.ets_tables} entries=#{snapshot.ets_entries} " <>
          "ports=#{snapshot.ports} pterms=#{snapshot.persistent_terms} " <>
          "monitors=#{snapshot.monitors} " <>
          "carrier_use=#{snapshot.carrier_utilization} rss=#{rss(snapshot)}"
      end)

    slopes =
      Enum.map_join(@gated_memory_keys, ", ", fn key ->
        "#{key}=#{Float.round(memory_slope(report, key), 2)}"
      end)

    """
    #{report.name} lifecycle soak: #{report.cycles} cycles x #{length(report.batches)} batches
    #{rows}
      fitted slope over batches 2..#{length(report.batches)} (bytes/cycle): #{slopes}
      fitted atom slope: #{Float.round(atom_slope(report), 4)} atoms/cycle
      exact resource gates (processes, tables, entries, ports, persistent terms) passed every cycle
      global counts, allocator utilization and RSS above are diagnostic only.
    """
  end

  defp rss(%{rss_bytes: nil}), do: "unavailable"
  defp rss(%{rss_bytes: bytes}), do: MemorySoak.format_bytes(bytes)
end
