# Gateway load probe: where the ceiling is, and which part of the gateway is it.
#
#   cd ptc_gateway && mix run bench/gateway_load.exs
#
# Environment: PTC_GATEWAY_BENCH_CALLS (default 200 per concurrency level),
# PTC_GATEWAY_BENCH_CYCLES (default 500 leak cycles per batch).
#
# This reports; it gates nothing and has no committed baseline. The numbers are
# machine- and scheduler-specific, so a comparison is only meaningful against
# another run on the same machine. `mix soak` is the gate — this is the tool for
# deciding what to change before there is anything to gate.
#
# Reading the output:
#
#   * `tools/list` does everything a call does except run a workflow: connection,
#     header validation, authentication, admission, dispatch, response. Its
#     throughput is the gateway's own ceiling.
#   * `tools/call` adds the run. The gap between the two columns is what the
#     workflow costs; the plateau in the first is what the gateway costs.
#   * A mailbox that stays at zero is not the bottleneck, however slow the
#     endpoint looks. One that grows with concurrency is.

Code.require_file(Path.join(__DIR__, "../support/gateway_fixture.exs"))
Code.require_file(Path.join(__DIR__, "../support/gateway_load.exs"))

alias PtcGateway.TestSupport.{GatewayFixture, GatewayLoad}

calls = String.to_integer(System.get_env("PTC_GATEWAY_BENCH_CALLS", "200"))
cycles = String.to_integer(System.get_env("PTC_GATEWAY_BENCH_CYCLES", "500"))
levels = [1, 2, 4, 8, 16, 32, 64]

# Bounds high enough that the probe measures the gateway rather than its own
# configuration: a saturated admission would report a refusal rate, not a cost.
admission = %{
  "max_inflight_requests" => 256,
  "max_concurrent_runs" => 64,
  "max_active_provider_calls" => 4,
  "max_waiting_provider_calls" => 0
}

schema = %{"type" => "object", "properties" => %{"note" => %{"type" => "string"}}}
payload = %{"note" => String.duplicate("payload", 64)}

# Project-local rather than the system temporary directory: the private audit
# rejects a symbolic link anywhere in its hierarchy, and on macOS `$TMPDIR`
# reaches the user's folder through `/var`, which is one (#1985).
# Unique per invocation, and only this directory is removed at the end: a
# shared root would let two concurrent probes delete each other's live
# deployments and audit files.
scratch = Path.join(File.cwd!(), "tmp/gateway-bench-#{System.unique_integer([:positive])}")
File.mkdir_p!(scratch)
dir = Path.join(scratch, "read")
{path, config} = GatewayFixture.fixture(Path.join(dir, "deployment"), :read, schema: schema)
config = Map.put(config, "admission", admission)
File.write!(path, Jason.encode!(config))
env_file = Path.join(dir, "credentials.env")
File.write!(env_file, "GATEWAY_TEST_TOKEN=#{GatewayFixture.token()}\n")

{:ok, owner} = PtcGateway.start_link(path, env_file: env_file)

probes = [
  request_admission: GatewayLoad.request_admission(owner),
  run_admission: GatewayLoad.run_admission(owner),
  domain: owner
]

defmodule Probe do
  def measure(config, calls, concurrency, opts, probes, owner) do
    mailboxes = GatewayLoad.sampler(probes)
    leases = GatewayLoad.lease_sampler(owner)
    started_at = System.monotonic_time(:microsecond)
    results = GatewayLoad.storm(config, calls, [concurrency: concurrency] ++ opts)
    elapsed_us = System.monotonic_time(:microsecond) - started_at
    held = GatewayLoad.stop_peak_sampler(leases)
    depths = GatewayLoad.stop_sampler(mailboxes)

    latencies = GatewayLoad.latencies_ms(results)
    percentiles = GatewayLoad.percentiles(latencies, [50, 95, 99, 100])

    admitted = results |> Enum.count(&(&1.status == 200))

    %{
      concurrency: concurrency,
      rps: calls * 1_000_000 / elapsed_us,
      # Offered load counts refusals, which are cheap; only goodput says how
      # much work the gateway actually did. Reporting the first as throughput
      # makes a saturated endpoint look like a fast one.
      goodput: admitted * 1_000_000 / elapsed_us,
      p50: percentiles[50],
      p95: percentiles[95],
      p99: percentiles[99],
      max: percentiles[100],
      peak_leases: held.peak,
      statuses: GatewayLoad.by_status(results),
      mailboxes: depths
    }
  end

  def table(title, rows) do
    IO.puts("\n#{title}")
    IO.puts(String.duplicate("-", 78))

    IO.puts(
      pad("conc", 6) <>
        pad("req/s", 9) <>
        pad("ok/s", 9) <>
        pad("p50 ms", 9) <>
        pad("p95 ms", 9) <>
        pad("p99 ms", 9) <> pad("max ms", 9) <> pad("leases", 8) <> "statuses"
    )

    Enum.each(rows, fn row ->
      IO.puts(
        pad(row.concurrency, 6) <>
          pad(round(row.rps), 9) <>
          pad(round(row.goodput), 9) <>
          pad(ms(row.p50), 9) <>
          pad(ms(row.p95), 9) <>
          pad(ms(row.p99), 9) <>
          pad(ms(row.max), 9) <>
          pad(row.peak_leases, 8) <>
          inspect(row.statuses)
      )
    end)
  end

  def mailbox_table(rows) do
    IO.puts("\nmailbox depth at each concurrency (peak / mean)")
    IO.puts(String.duplicate("-", 78))

    IO.puts(
      pad("conc", 6) <> pad("request_admission", 22) <> pad("run_admission", 20) <> "domain"
    )

    Enum.each(rows, fn row ->
      IO.puts(
        pad(row.concurrency, 6) <>
          pad(depth(row.mailboxes[:request_admission]), 22) <>
          pad(depth(row.mailboxes[:run_admission]), 20) <>
          depth(row.mailboxes[:domain])
      )
    end)
  end

  defp depth(nil), do: "-"
  defp depth(%{peak: peak, mean: mean}), do: "#{peak} / #{Float.round(mean, 2)}"
  defp ms(nil), do: "-"
  defp ms(value), do: Float.round(value * 1.0, 2)
  defp pad(value, width), do: String.pad_trailing("#{value}", width)
end

IO.puts(
  "gateway load probe — #{calls} calls per level, schedulers: #{System.schedulers_online()}"
)

list_rows =
  Enum.map(levels, fn concurrency ->
    Probe.measure(config, calls, concurrency, [method: "tools/list"], probes, owner)
  end)

Probe.table("tools/list — the gateway's own cost, no workflow runs", list_rows)

call_rows =
  Enum.map(levels, fn concurrency ->
    Probe.measure(config, calls, concurrency, [arguments: payload], probes, owner)
  end)

Probe.table("tools/call — the same path plus one workflow run", call_rows)
Probe.mailbox_table(call_rows)

# Where the gateway stops scaling: the level after which throughput no longer
# improves is the ceiling, and the mailbox column above says which owner it is.
best = Enum.max_by(list_rows, & &1.goodput)

IO.puts(
  "\npeak tools/list goodput: #{round(best.goodput)} req/s at concurrency #{best.concurrency}"
)

# One connection carrying many calls, against one connection per call at the
# same concurrency: the difference is what connection setup costs.
keepalive_started = System.monotonic_time(:microsecond)
statuses = GatewayLoad.keepalive(config, calls)
keepalive_us = System.monotonic_time(:microsecond) - keepalive_started
distinct = statuses |> Enum.uniq() |> inspect()
serial = Enum.find(list_rows, &(&1.concurrency == 1))

IO.puts("\nconnection reuse, #{calls} sequential tools/list calls")
IO.puts(String.duplicate("-", 78))

IO.puts(
  "one connection:      #{round(calls * 1_000_000 / keepalive_us)} req/s  statuses #{distinct}"
)

IO.puts("one per call:        #{round(serial.rps)} req/s")

# The write path adds one durable audit append per call, made from inside a
# single owner while the call still holds its run capacity. If that append is
# the ceiling, write throughput stops scaling where read throughput does not,
# and the audit mailbox is where the queue shows.
write_dir = Path.join(scratch, "write")

{write_path, write_config} =
  GatewayFixture.fixture(Path.join(write_dir, "deployment"), :write, schema: schema)

write_config =
  write_config |> Map.put("admission", admission) |> GatewayFixture.with_write_audit()

File.write!(write_path, Jason.encode!(write_config))
write_env = Path.join(write_dir, "credentials.env")
File.write!(write_env, "GATEWAY_TEST_TOKEN=#{GatewayFixture.token()}\n")
{:ok, write_owner} = PtcGateway.start_link(write_path, env_file: write_env)
audit = GatewayLoad.audit_owner(write_owner)

write_probes = [request_admission: GatewayLoad.request_admission(write_owner), audit: audit]

write_rows =
  Enum.map(levels, fn concurrency ->
    Probe.measure(
      write_config,
      calls,
      concurrency,
      [arguments: payload],
      write_probes,
      write_owner
    )
  end)

Probe.table("tools/call with allow_write — one durable audit append per call", write_rows)

IO.puts("\naudit mailbox depth at each concurrency (peak / mean)")
IO.puts(String.duplicate("-", 78))

Enum.each(write_rows, fn row ->
  depth = row.mailboxes[:audit]

  IO.puts(
    "#{String.pad_trailing("#{row.concurrency}", 6)}#{depth.peak} / #{Float.round(depth.mean, 2)}"
  )
end)

# One append in isolation, for scale: the owner does `:file.write` then
# `:file.sync`, so this is a durable round-trip and nothing else.
record = %{
  "call_id" => "bench",
  "tool_name" => "a",
  "started_at" => "2026-09-16T00:00:00.000Z",
  "ended_at" => "2026-09-16T00:00:01.000Z",
  "outcome_code" => "success",
  "dispatch_state" => "true",
  "write_effects_may_have_occurred" => false,
  "disconnected" => false,
  "cleanup_status" => "complete"
}

{append_us, :ok} =
  :timer.tc(fn ->
    Enum.each(1..200, fn index ->
      :ok = PtcGateway.PrivateAudit.append(audit, %{record | "call_id" => "bench-#{index}"})
    end)
  end)

read_peak = call_rows |> Enum.max_by(& &1.goodput) |> Map.get(:goodput)
write_peak = write_rows |> Enum.max_by(& &1.goodput) |> Map.get(:goodput)
append_ms = append_us / 200 / 1000

IO.puts("\none durable audit append: #{Float.round(append_ms, 3)} ms")
IO.puts("  serialized in one owner, so the write path cannot exceed")
IO.puts("  #{round(1000 / append_ms)} calls/s however much run capacity is configured")
IO.puts("peak read goodput:  #{round(read_peak)} calls/s")
IO.puts("peak write goodput: #{round(write_peak)} calls/s")

GenServer.stop(write_owner)

IO.puts("\nresidue over #{4 * cycles} calls (fitted bytes per call)")
IO.puts(String.duplicate("-", 78))

leak =
  GatewayLoad.leak(4, cycles, fn _ ->
    %{status: 200} = GatewayLoad.call(config, arguments: payload)
  end)

Enum.each(leak.slopes, fn {metric, slope} ->
  IO.puts(String.pad_trailing("#{metric}", 20) <> "#{Float.round(slope, 1)}")
end)

IO.puts("processes: #{leak.processes.before} -> #{leak.processes.after}")
IO.puts("leases still held: #{GatewayLoad.inflight_leases(owner)}")

GenServer.stop(owner)
File.rm_rf!(scratch)
