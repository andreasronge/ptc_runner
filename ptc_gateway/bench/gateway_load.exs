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

dir = Path.join(System.tmp_dir!(), "ptc-gateway-bench-#{System.unique_integer([:positive])}")
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

    %{
      concurrency: concurrency,
      rps: calls * 1_000_000 / elapsed_us,
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
        pad("req/s", 10) <>
        pad("p50 ms", 9) <>
        pad("p95 ms", 9) <>
        pad("p99 ms", 9) <> pad("max ms", 9) <> pad("leases", 8) <> "statuses"
    )

    Enum.each(rows, fn row ->
      IO.puts(
        pad(row.concurrency, 6) <>
          pad(round(row.rps), 10) <>
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
best = Enum.max_by(list_rows, & &1.rps)

IO.puts(
  "\npeak tools/list throughput: #{round(best.rps)} req/s at concurrency #{best.concurrency}"
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
File.rm_rf!(dir)
