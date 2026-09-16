defmodule PtcGatewayLoadTest do
  @moduledoc """
  What the gateway does under concurrent load, measured from outside it.

  `PtcGatewayTest` proves the contract one request at a time: the busy code, the
  unavailable code, a reclaimed lease, a disconnect mid-stream. Every one of
  those cases drives a single request, so none of them can see the failures that
  only exist when requests overlap — a ceiling that admits one too many, a slot
  that is returned on the happy path and kept on every other, a serialization
  point that is the real ceiling, or a per-request residue too small to notice
  until the ten-thousandth call.

  Three questions, each needing a different instrument:

    * **Are the ceilings real?** Read from the owner that enforces each one, at
      the peak of a burst that fills it. The client-side overlap is reported
      beside it and asserted on nothing: it measures when bytes reached the
      client, which under a burst is mostly scheduling. `GatewayLoad` records
      what that cost in wrong readings before the instrument was changed.
    * **Is a slot always returned?** Asserted on the paths that are not the happy
      one: saturation, a reset peer, a half-open peer, a reused connection, and
      a client that never finishes its request.
    * **Does a call cost anything permanently?** A fitted byte slope over batches,
      because a per-call residue small enough to pass a single-cycle assertion is
      exactly what accumulates across a long-lived host.

  The readings are printed as well as asserted. A run that passes its ceiling
  but reports a peak of one exercised no concurrency, and the number is the only
  way to tell those apart.
  """

  # async: false — measures VM-wide memory and process counts, and binds a real
  # listener; any concurrent test perturbs both.
  use ExUnit.Case, async: false

  import PtcGateway.TestSupport.GatewayFixture

  alias PtcGateway.TestSupport.GatewayLoad

  @moduletag :soak
  @moduletag timeout: :infinity

  # Enough concurrent connections that the ceilings are actually reached rather
  # than merely respected, and enough cycles that a per-call residue of a few
  # hundred bytes clears the VM's own drift between batch endpoints.
  @burst 64
  @leak_batches 4
  @leak_cycles String.to_integer(System.get_env("PTC_GATEWAY_SOAK_CYCLES", "250"))

  # Contract compilation injects `additionalProperties: false`, so every key a
  # call sends or returns is declared here or the call comes back as a contract
  # error wearing an HTTP 200.
  @schema %{
    "type" => "object",
    "properties" => %{
      "note" => %{"type" => "string"},
      "sum" => %{"type" => "integer"}
    }
  }
  @payload %{"note" => String.duplicate("payload", 64)}

  # Roughly 100 ms of arithmetic. Long enough that two overlapping runs are
  # observable from both the owner's accounting and the client's clock, short
  # enough that a burst of sixteen stays under a second.
  @slow_body "(return {:sum (reduce + 0 (range 120000))})"
  @slow_sum Enum.sum(0..119_999)

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "ceilings under a burst" do
    @tag :tmp_dir
    test "the in-flight bound holds and every slot comes back", %{tmp_dir: dir} do
      inflight = 8

      {owner, config} =
        start_gateway(dir, [max_inflight_requests: inflight, max_concurrent_runs: @burst],
          schema: @schema
        )

      mailboxes =
        GatewayLoad.sampler(
          request_admission: GatewayLoad.request_admission(owner),
          run_admission: GatewayLoad.run_admission(owner),
          domain: owner
        )

      leases = GatewayLoad.lease_sampler(owner)
      results = GatewayLoad.storm(config, @burst, arguments: @payload)
      held = GatewayLoad.stop_peak_sampler(leases)
      mailboxes = GatewayLoad.stop_sampler(mailboxes)

      observed = results |> GatewayLoad.inflight_intervals() |> GatewayLoad.max_overlap()
      statuses = GatewayLoad.by_status(results)

      report("burst of #{@burst}, in-flight bound #{inflight}", %{
        "statuses" => inspect(statuses),
        "peak leases held (owner)" => "#{held.peak} of #{inflight}, #{held.samples} samples",
        "peak overlap (client)" => "#{observed} — waiting, not working",
        "latency ms" =>
          inspect(GatewayLoad.percentiles(GatewayLoad.latencies_ms(results), [50, 95, 100])),
        "mailbox depth" => inspect(mailboxes)
      })

      # Closure: saturation is a refusal, never a crash and never a hang.
      assert Map.keys(statuses) -- [200, 429] == [],
             "unexpected terminal statuses: #{inspect(statuses)}"

      # The ceiling, from the lease table that enforces it. A sampler can only
      # under-report a peak it missed, so this direction is sound.
      assert held.peak <= inflight
      assert held.peak >= 1, "the sampler observed no lease at all"

      # That the bound was *reached* is proved by the refusals rather than by
      # the sampler: run capacity is #{@burst} here, so nothing but a full lease
      # table can produce a 429.
      assert Map.get(statuses, 429, 0) > 0,
             "the burst never saturated, so the bound was not exercised"

      # Every admitted call produced its real result, not an empty stream and
      # not a contract error wearing an HTTP 200.
      for result <- results, result.status == 200 do
        assert get_in(result.result, ["result", "structuredContent"]) == @payload
        assert get_in(result.result, ["result", "isError"]) == false
      end

      # No slot survived its request.
      assert GatewayLoad.await_leases(owner, 0) == 0
      assert response(config, "/health/ready").status == 200
    end

    @tag :tmp_dir
    test "the concurrent-run bound holds, by the owner's own accounting", %{tmp_dir: dir} do
      runs = 2

      # A run that returns in microseconds cannot be counted from the client:
      # the intervals then measure client scheduling, not held capacity. This
      # workload lasts long enough that the two readings agree.
      {owner, config} =
        start_gateway(dir, [max_inflight_requests: 32, max_concurrent_runs: runs],
          body: @slow_body,
          schema: @schema
        )

      sampler = GatewayLoad.capacity_sampler(owner)
      results = GatewayLoad.storm(config, 16, timeout_ms: 60_000)
      capacity = GatewayLoad.stop_peak_sampler(sampler)

      client_peak = results |> GatewayLoad.run_intervals() |> GatewayLoad.max_overlap()
      statuses = GatewayLoad.by_status(results)

      report("burst of 16, run bound #{runs}", %{
        "statuses" => inspect(statuses),
        "peak concurrent runs (owner)" =>
          "#{capacity.peak} of #{runs}, #{capacity.samples} samples",
        "peak concurrent runs (client)" => client_peak,
        "latency ms" =>
          inspect(GatewayLoad.percentiles(GatewayLoad.latencies_ms(results), [50, 100]))
      })

      assert Map.keys(statuses) -- [200, 429] == [],
             "unexpected terminal statuses: #{inspect(statuses)}"

      # The ceiling, from the owner that enforces it.
      assert capacity.peak <= runs
      assert capacity.peak >= 1, "the sampler observed no reservation at all"

      # With no waiting queue for execution capacity the overflow is refused
      # rather than delayed, and in-flight capacity is 32 against a burst of 16,
      # so every one of these refusals is run capacity and nothing else.
      assert Map.get(statuses, 429, 0) > 0,
             "run capacity never filled, so the bound was not exercised"

      assert Map.get(statuses, 200, 0) >= 1

      # `client_peak` is reported above and gated on nothing. It is recorded
      # when a client task was scheduled to read, so under a burst it can exceed
      # a bound the server never exceeded; asserting on it would make this gate
      # depend on the scheduler.

      for result <- results, result.status == 200 do
        assert get_in(result.result, ["result", "structuredContent"]) == %{"sum" => @slow_sum}
      end

      assert GatewayLoad.await_leases(owner, 0) == 0
      assert response(config, "/health/ready").status == 200
    end
  end

  describe "the write path" do
    @tag :tmp_dir
    test "every admitted write is durable before its slot is released", %{tmp_dir: dir} do
      runs = 4

      {owner, config, audit_dir} =
        start_write_gateway(dir, max_inflight_requests: 32, max_concurrent_runs: runs)

      audit = GatewayLoad.sampler(audit: GatewayLoad.audit_owner(owner))
      capacity = GatewayLoad.capacity_sampler(owner)
      started_at = System.monotonic_time(:microsecond)
      results = GatewayLoad.storm(config, @burst, arguments: @payload)
      elapsed_us = System.monotonic_time(:microsecond) - started_at
      peak = GatewayLoad.stop_peak_sampler(capacity)
      depths = GatewayLoad.stop_sampler(audit)

      statuses = GatewayLoad.by_status(results)
      admitted = Map.get(statuses, 200, 0)

      # Every call has returned and every slot is back, so no append is in
      # flight and one read sees the complete set.
      assert GatewayLoad.await_run_capacity(owner, 0) == 0
      records = GatewayLoad.audit_records(audit_dir)

      report("write burst of #{@burst}, run bound #{runs}", %{
        "statuses" => inspect(statuses),
        "throughput" => "#{round(@burst * 1_000_000 / elapsed_us)} calls/s",
        "peak concurrent runs" => "#{peak.peak} of #{runs}",
        "audit mailbox" => inspect(depths[:audit]),
        "durable records" => length(records),
        "latency ms" =>
          inspect(GatewayLoad.percentiles(GatewayLoad.latencies_ms(results), [50, 95, 100]))
      })

      assert Map.keys(statuses) -- [200, 429] == [],
             "unexpected terminal statuses: #{inspect(statuses)}"

      assert peak.peak <= runs

      # Without these two, the durability assertion below reads `0 == 0` on a
      # burst where nothing was admitted, and every record check is skipped.
      assert admitted >= 1, "no write was admitted, so durability was not exercised"

      assert peak.peak >= 2,
             "write capacity peaked at #{peak.peak}: the burst never ran two writes at once"

      # The audit is the point of the write path: a call whose slot was released
      # without its record reaching disk is the failure this asserts away. The
      # records are read back from the files, not from the owner.
      assert length(records) == admitted,
             "#{admitted} calls succeeded but #{length(records)} records are durable"

      for record <- records do
        assert record["outcome_code"] == "success"
        assert record["cleanup_status"] == "complete"
        assert record["disconnected"] == false
        assert record["tool_name"] in ["a", "z"]
      end

      # Call IDs identify records; a collision under load would silently merge
      # two calls into one line of evidence.
      assert records |> Enum.map(& &1["call_id"]) |> Enum.uniq() |> length() == length(records)

      assert GatewayLoad.await_leases(owner, 0) == 0
      assert response(config, "/health/ready").status == 200
    end

    @tag :tmp_dir
    test "a peer that vanishes mid-run is still audited, and marked disconnected", %{
      tmp_dir: dir
    } do
      {owner, config, audit_dir} =
        start_write_gateway(dir, [max_inflight_requests: 8, max_concurrent_runs: 8],
          body: @slow_body
        )

      # The run has to still be running when the peer goes, or this proves
      # nothing about execution: a write may already have happened and the audit
      # record is the only thing that will ever say so. The workload is slow
      # enough that the disconnect lands between the SSE commit and publication.
      assert :accepted = GatewayLoad.disconnect_mid_run(config, timeout_ms: 60_000)

      # The record is durable before run capacity is released, so waiting for
      # capacity is both the synchronization and an assertion of that ordering.
      # Polling the file instead would race the append and could read a partial
      # line, and seeing bytes would not have proved the sync returned.
      assert GatewayLoad.await_run_capacity(owner, 0) == 0

      assert [record] = GatewayLoad.audit_records(audit_dir)
      assert record["disconnected"] == true
      assert record["tool_name"] == "a"
      assert record["cleanup_status"] == "complete"

      # The gateway survives it: the slot came back and the next call is served.
      assert GatewayLoad.await_leases(owner, 0) == 0
      assert %{status: 200} = GatewayLoad.call(config, timeout_ms: 60_000)
      assert GatewayLoad.await_run_capacity(owner, 0) == 0
      assert length(GatewayLoad.audit_records(audit_dir)) == 2
    end
  end

  describe "slots on the paths that are not the happy one" do
    @tag :tmp_dir
    test "a reset peer mid-stream returns its slot", %{tmp_dir: dir} do
      {owner, config} = start_gateway(dir, max_inflight_requests: 4, max_concurrent_runs: 4)

      sockets =
        for _ <- 1..4 do
          {:ok, socket} = GatewayLoad.stall_body(config)
          socket
        end

      assert GatewayLoad.await_leases(owner, 4) == 4
      Enum.each(sockets, &GatewayLoad.close_abruptly/1)

      assert GatewayLoad.await_leases(owner, 0) == 0
      assert %{status: 200} = GatewayLoad.call(config, arguments: @payload)
      assert response(config, "/health/ready").status == 200
    end

    @tag :tmp_dir
    test "a half-open peer is not mistaken for a gone one", %{tmp_dir: dir} do
      {owner, config} = start_gateway(dir, max_inflight_requests: 4, max_concurrent_runs: 4)

      {:ok, socket} = GatewayLoad.stall_body(config)
      assert GatewayLoad.await_leases(owner, 1) == 1

      # The client stops writing but keeps reading. The body will never arrive,
      # so the server must end this itself rather than wait on a peer that is
      # still, by every socket-level test, present.
      :ok = GatewayLoad.half_close(socket)
      assert {:closed, elapsed_ms, _status} = GatewayLoad.await_close(socket, 60_000)
      report("half-open peer", %{"server closed after ms" => elapsed_ms})

      assert GatewayLoad.await_leases(owner, 0) == 0
      assert %{status: 200} = GatewayLoad.call(config, arguments: @payload)
    end

    @tag :tmp_dir
    test "a reused connection returns its slot between calls", %{tmp_dir: dir} do
      {owner, config} = start_gateway(dir, max_inflight_requests: 1, max_concurrent_runs: 1)

      # One slot and ten sequential calls: every call after the first depends on
      # the previous one having released, on a socket that never closed.
      assert GatewayLoad.keepalive(config, 10) == List.duplicate(200, 10)
      assert GatewayLoad.await_leases(owner, 0) == 0
    end

    @tag :tmp_dir
    test "saturation refuses without consuming a slot", %{tmp_dir: dir} do
      {owner, config} = start_gateway(dir, max_inflight_requests: 2, max_concurrent_runs: 2)

      held =
        for _ <- 1..2 do
          {:ok, socket} = GatewayLoad.stall_body(config)
          socket
        end

      assert GatewayLoad.await_leases(owner, 2) == 2

      # A dozen refusals must not leave a lease behind, or the endpoint would
      # never recover from a single burst it already rejected.
      refused = GatewayLoad.storm(config, 12, arguments: @payload)
      assert Enum.all?(refused, &(&1.status == 429))
      assert GatewayLoad.await_leases(owner, 2) == 2

      Enum.each(held, &GatewayLoad.close_abruptly/1)
      assert GatewayLoad.await_leases(owner, 0) == 0
      assert %{status: 200} = GatewayLoad.call(config, arguments: @payload)
    end
  end

  describe "a client that never finishes its request" do
    @tag :tmp_dir
    test "withholding the body holds an in-flight slot while readiness stays green", %{
      tmp_dir: dir
    } do
      inflight = 4

      {owner, config} =
        start_gateway(dir, max_inflight_requests: inflight, max_concurrent_runs: 4)

      # Admission is acquired before the body is read (mcp.ex:55 then :71), so a
      # request whose headers are perfect and whose body never arrives owns a
      # slot for as long as the server waits for those bytes.
      sockets =
        for _ <- 1..inflight do
          {:ok, socket} = GatewayLoad.stall_body(config)
          socket
        end

      assert GatewayLoad.await_leases(owner, inflight) == inflight

      # Every slot is now held by a client that has sent no body. The MCP
      # endpoint is starved.
      assert %{status: 429} = GatewayLoad.call(config, arguments: @payload)

      # Readiness reports on the warm runtime, not on request admission, so it
      # stays green throughout. An operator watching only this endpoint cannot
      # see the starvation.
      assert response(config, "/health/ready").status == 200

      # The exposure is bounded: the server ends these itself. How long it waits
      # is the size of the exposure, and the status it ends with is what a client
      # is told to do about it.
      [first | _] = sockets
      assert {:closed, elapsed_ms, status} = GatewayLoad.await_close(first, 120_000)
      report("withheld body", %{"server closed after ms" => elapsed_ms, "status" => status})

      # A client that did not finish its request is not a server fault. Reporting
      # -32603 tells it to retry against a server it believes is broken.
      assert status == 408

      # The window one stalled client can hold a slot for. Bandit's per-read
      # default is 15 s, which at this bound is a 15-second outage of the whole
      # endpoint; the gateway sets its own budget instead.
      assert elapsed_ms < 5_000,
             "a stalled client held an in-flight slot for #{elapsed_ms} ms"

      Enum.each(sockets, &GatewayLoad.close_abruptly/1)
      assert GatewayLoad.await_leases(owner, 0) == 0
      assert %{status: 200} = GatewayLoad.call(config, arguments: @payload)
    end

    @tag :tmp_dir
    test "a keep-alive peer that stops sending is closed on the same budget", %{tmp_dir: dir} do
      {owner, config} =
        start_gateway(dir, [max_inflight_requests: 4, max_concurrent_runs: 4], schema: @schema)

      # Without `connection: close` from the client, the reply alone does not end
      # the exchange: the transport is left to drain a body that never arrives,
      # on its own default timeout rather than this one. The slot returns either
      # way, so only the socket's lifetime shows the difference.
      {:ok, socket} = GatewayLoad.stall_body(config, connection: "keep-alive")
      assert GatewayLoad.await_leases(owner, 1) == 1

      assert {:closed, elapsed_ms, status} = GatewayLoad.await_close(socket, 60_000)
      report("withheld body, keep-alive", %{"closed after ms" => elapsed_ms, "status" => status})

      assert status == 408

      assert elapsed_ms < 5_000,
             "a keep-alive connection lingered #{elapsed_ms} ms after its 408"

      assert GatewayLoad.await_leases(owner, 0) == 0
      assert %{status: 200} = GatewayLoad.call(config, arguments: @payload)
    end

    @tag :tmp_dir
    test "withholding the headers costs a socket and no slot", %{tmp_dir: dir} do
      {owner, config} = start_gateway(dir, max_inflight_requests: 2, max_concurrent_runs: 2)

      sockets =
        for _ <- 1..8 do
          {:ok, socket} = GatewayLoad.stall_headers(config)
          socket
        end

      # Eight incomplete requests, four times the in-flight bound, and none of
      # them has been routed or admitted: admission sits behind header
      # validation, so the endpoint keeps serving.
      assert GatewayLoad.inflight_leases(owner) == 0
      assert %{status: 200} = GatewayLoad.call(config, arguments: @payload)

      Enum.each(sockets, &GatewayLoad.close_abruptly/1)
      assert GatewayLoad.await_leases(owner, 0) == 0
    end
  end

  describe "residue" do
    @tag :tmp_dir
    test "a completed call keeps nothing", %{tmp_dir: dir} do
      {owner, config} = start_gateway(dir, max_inflight_requests: 8, max_concurrent_runs: 4)

      report =
        GatewayLoad.leak(@leak_batches, @leak_cycles, fn _cycle ->
          %{status: 200} = GatewayLoad.call(config, arguments: @payload)
        end)

      report("leak over #{@leak_batches}x#{@leak_cycles} calls", %{
        "bytes/call" => inspect(Map.new(report.slopes, fn {k, v} -> {k, Float.round(v, 1)} end)),
        "processes" => "#{report.processes.before} -> #{report.processes.after}"
      })

      # Exact, and the gate that matters. A call creates a Bandit connection
      # process, a serving worker, a request monitor and a run; all are
      # transient, so a leaked one shows here with no noise at all. Across every
      # run measured this returned to its starting value exactly.
      assert report.processes.after == report.processes.before,
             "process count moved #{report.processes.before} -> #{report.processes.after}"

      # Thresholded, on the two metrics quiet enough to carry a threshold: their
      # fitted slope stayed within +-60 bytes per call across thirteen runs, so
      # 512 leaves room for drift while still catching a retained binary.
      for metric <- [:binary, :ets] do
        assert report.slopes[metric] < 512,
               "#{metric} grew #{Float.round(report.slopes[metric], 1)} bytes per call"
      end

      # `:processes` and `:total` are reported and gated on nothing. Their
      # run-to-run spread on this workload is about 7,600 bytes per call --
      # VM-wide process memory moves with whatever else the node is doing -- so
      # any threshold stable enough not to flake would be far too coarse to
      # catch a real leak. The exact process-count assertion above is what
      # covers that failure instead.
      assert GatewayLoad.await_leases(owner, 0) == 0
      assert response(config, "/health/ready").status == 200
    end
  end

  # ---------------------------------------------------------------------------

  defp start_gateway(dir, admission, fixture_opts \\ []) do
    {effect, fixture_opts} = Keyword.pop(fixture_opts, :effect, :read)
    {write?, fixture_opts} = Keyword.pop(fixture_opts, :write, false)
    {path, config} = fixture(Path.join(dir, "deployment"), effect, fixture_opts)
    config = if write?, do: with_write_audit(config), else: config

    config =
      Enum.reduce(admission, config, fn {key, value}, acc ->
        put_in(acc, ["admission", Atom.to_string(key)], value)
      end)

    File.write!(path, Jason.encode!(config))
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{token()}\n")

    {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)
    {owner, config}
  end

  defp start_write_gateway(dir, admission, fixture_opts \\ []) do
    opts = Keyword.merge([effect: :write, schema: @schema, write: true], fixture_opts)
    {owner, config} = start_gateway(dir, admission, opts)
    {owner, config, Path.join(dir, "deployment/audit")}
  end

  defp report(title, rows) do
    IO.puts("\n  #{title}")
    Enum.each(rows, fn {label, value} -> IO.puts("    #{label}: #{value}") end)
  end
end
