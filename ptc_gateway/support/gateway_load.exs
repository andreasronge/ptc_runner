defmodule PtcGateway.TestSupport.GatewayLoad do
  @moduledoc """
  A load driver that measures the gateway's bounds from outside it.

  ## Why raw sockets rather than `Req`

  The three configured bounds are only distinguishable if the client can see
  *when* each phase of a call begins. A pooled HTTP client hands back one
  duration covering reservation, execution and publication together, and the
  widest window it can offer already includes time spent queued on
  `RequestAdmission` — so an overlap computed from it is an upper bound on run
  concurrency, and an upper bound cannot prove a ceiling was respected.

  The server-sent stream makes the phases observable. `commit_sse/5` writes
  `: accepted` only after run admission is reserved, and `event: message`
  arrives when the outcome publishes. So `[accepted_at, message_at]` brackets
  the interval during which this call held one of `max_concurrent_runs`, and
  `[sent_at, closed_at]` brackets one of `max_inflight_requests`. Each SSE frame
  is written in one `Plug.Conn.chunk/2` call, so its bytes reach the socket
  contiguously and the markers are not an artifact of chunked framing.

  ## What a client-side interval cannot prove

  A client timestamps a marker when its own process is scheduled to read the
  socket, not when the server wrote it. Under a burst that jitter is not a small
  correction — it is most of the measurement, and it inflates every interval in
  the same direction.

  Both readings were tried as ceilings here and both were wrong. Sixty-four
  simultaneous calls against a bound of eight in-flight requests produced
  twenty-three client intervals that each spanned the same forty-six
  milliseconds, because every one of them was sent at the same instant and
  finished at the same instant whatever the server did in between. The same
  burst against a run bound of two measured a peak of thirty-nine overlapping
  runs, while the owner's own accounting never held more than one reservation.

  So a ceiling is read from the owner that enforces it — `capacity_sampler/2`
  for `max_concurrent_runs`, `lease_sampler/2` for `max_inflight_requests`. The
  client intervals stay, as a diagnostic rather than a gate, because the gap
  between the two readings answers a question neither answers alone: how much of
  a call's latency was spent waiting rather than working. A workload slow enough
  for the two to converge (`GatewayFixture.fixture/3`'s `:body` option) is the
  only case in which they should agree at all.

  ## What each entry point is for

    * `storm/3` — N calls at a chosen concurrency, each one fully timestamped.
    * `max_overlap/1`, `percentiles/2` — the two readings taken from a storm.
    * `stall_body/2` — a connection that completes its headers and then sends no
      body, for measuring how long one client can hold an in-flight slot.
    * `stall_headers/2` — the same question one phase earlier, before admission.
    * `close_abruptly/1`, `half_close/1` — the two disconnects that differ for a
      streaming response: a reset peer and a peer that stopped writing but is
      still reading.
    * `keepalive/3` — several calls down one connection, because a lease is
      per-request while a socket is not.
    * `leak/3` — batched churn with a fitted byte slope, for the leaks that are
      too small to see in one cycle.
    * `sampler/2` — mailbox depths while a storm runs, which is what tells you
      *which* serialization point is the ceiling.
    * `capacity_sampler/2`, `lease_sampler/2` — each owner's own accounting of
      what it is holding, the authoritative readings the client-side ones cannot
      replace.

  Termination is always awaited — a closed socket, a dead process, a bounded
  retry — never slept through.
  """

  @revision "2026-07-28"
  @connect_timeout_ms 5_000
  @recv_timeout_ms 250

  # ---------------------------------------------------------------------------
  # One timestamped call
  # ---------------------------------------------------------------------------

  @typedoc """
  One call's observed timeline, in monotonic microseconds, plus what came back.

  `accepted_at` and `message_at` are `nil` for a call that never committed a
  stream — a 429, a 503, or a rejected envelope — which is exactly what
  excludes it from the run-concurrency reading.
  """
  @type call_result :: %{
          status: pos_integer() | nil,
          sent_at: integer(),
          headers_at: integer() | nil,
          accepted_at: integer() | nil,
          message_at: integer() | nil,
          closed_at: integer(),
          body: binary(),
          result: map() | nil,
          error: term() | nil
        }

  @doc """
  Performs one MCP call over its own connection and returns its timeline.

  Options: `:method` (default `"tools/call"`), `:tool` (default `"a"`),
  `:arguments`, `:token`, and `:timeout_ms` for the whole exchange.
  """
  @spec call(map(), keyword()) :: call_result()
  def call(config, opts \\ []) do
    port = config["listen"]["port"]
    deadline = now() + Keyword.get(opts, :timeout_ms, 30_000) * 1_000

    case :gen_tcp.connect(
           ~c"127.0.0.1",
           port,
           [:binary, active: false, nodelay: true],
           @connect_timeout_ms
         ) do
      {:ok, socket} ->
        request = request_bytes(config, opts)
        sent_at = now()
        :ok = :gen_tcp.send(socket, request)
        result = collect(socket, blank(sent_at), "", deadline)
        :gen_tcp.close(socket)
        result

      {:error, reason} ->
        at = now()
        %{blank(at) | closed_at: at, error: {:connect, reason}}
    end
  end

  @doc """
  Runs `count` calls at `concurrency` and returns every timeline.

  `concurrency: count` makes it a burst, which is what proves a ceiling;
  a lower value makes it sustained load, which is what measures throughput.
  """
  @spec storm(map(), pos_integer(), keyword()) :: [call_result()]
  def storm(config, count, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, count)

    1..count
    |> Task.async_stream(fn _ -> call(config, opts) end,
      max_concurrency: concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # ---------------------------------------------------------------------------
  # Readings
  # ---------------------------------------------------------------------------

  @doc """
  The most intervals that were ever open at once.

  A pair that merely touches — one closing at the instant the next opens — is
  not an overlap, so closing events sort ahead of opening events at an equal
  timestamp. Intervals with a `nil` endpoint are dropped rather than guessed at.
  """
  @spec max_overlap([{integer() | nil, integer() | nil}]) :: non_neg_integer()
  def max_overlap(intervals) do
    intervals
    |> Enum.reject(fn {open, close} -> is_nil(open) or is_nil(close) end)
    |> Enum.flat_map(fn {open, close} -> [{open, 1}, {close, -1}] end)
    |> Enum.sort()
    |> Enum.reduce({0, 0}, fn {_at, delta}, {open, peak} ->
      open = open + delta
      {open, max(open, peak)}
    end)
    |> elem(1)
  end

  @doc "The intervals during which each call held one of `max_concurrent_runs`."
  @spec run_intervals([call_result()]) :: [{integer() | nil, integer() | nil}]
  def run_intervals(results), do: Enum.map(results, &{&1.accepted_at, &1.message_at})

  @doc """
  The intervals during which each call held one of `max_inflight_requests`.

  A call rejected for saturation never held a slot of its own, so it is excluded:
  counting it would let the rejection inflate the very number it reports on.
  """
  @spec inflight_intervals([call_result()]) :: [{integer() | nil, integer() | nil}]
  def inflight_intervals(results) do
    results
    |> Enum.reject(&(&1.status in [429, 503]))
    |> Enum.map(&{&1.sent_at, &1.closed_at})
  end

  @doc "Requested percentiles of a sample, by nearest rank, in the sample's own unit."
  @spec percentiles([number()], [number()]) :: %{number() => number()}
  def percentiles([], _wanted), do: %{}

  def percentiles(sample, wanted) do
    sorted = Enum.sort(sample)
    size = length(sorted)

    Map.new(wanted, fn percentile ->
      rank = max(1, ceil(percentile / 100 * size))
      {percentile, Enum.at(sorted, rank - 1)}
    end)
  end

  @doc """
  End-to-end milliseconds per call, for calls that produced a result.

  A `tools/call` completes at its `event: message` frame, with the connection
  close that follows costing nothing the caller waits on. `tools/list` has no
  frame, so it completes when its body is fully read. Using the close for both
  would charge a streamed call for a teardown its caller never waited for.
  """
  @spec latencies_ms([call_result()]) :: [float()]
  def latencies_ms(results) do
    results
    |> Enum.filter(&(&1.status == 200))
    |> Enum.map(&(((&1.message_at || &1.closed_at) - &1.sent_at) / 1_000))
  end

  @doc "How many calls ended at each HTTP status, `nil` for a connection that produced none."
  @spec by_status([call_result()]) :: %{(pos_integer() | nil) => pos_integer()}
  def by_status(results), do: Enum.frequencies_by(results, & &1.status)

  # ---------------------------------------------------------------------------
  # Admission introspection
  # ---------------------------------------------------------------------------

  @doc "The gateway's request-admission owner."
  @spec request_admission(pid()) :: pid()
  def request_admission(owner), do: :sys.get_state(owner).request_admission

  @doc "The gateway's run-admission owner, the one that bounds `max_concurrent_runs`."
  @spec run_admission(pid()) :: pid()
  def run_admission(owner), do: :sys.get_state(owner).run_admission

  @doc "The gateway's private-audit owner, or `nil` when no tool may write."
  @spec audit_owner(pid()) :: pid() | nil
  def audit_owner(owner), do: :sys.get_state(owner).audit

  @doc """
  Every durable audit record written so far, oldest file first.

  Read from the files rather than from the owner: a record the owner believes it
  wrote and a record that survives the process are different claims, and only the
  second one is what the audit is for.
  """
  @spec audit_records(binary()) :: [map()]
  def audit_records(directory) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(&Path.join(directory, &1))
    # The owner keeps its exclusive lock in this directory too, and it is not a
    # record file. Reading regular files only also keeps this honest if the
    # layout grows something else.
    |> Enum.filter(&match?({:ok, %File.Stat{type: :regular}}, File.stat(&1)))
    |> Enum.flat_map(fn path ->
      path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end)
  end

  @doc """
  Starts a sampler over `RunAdmission`'s own snapshot: the authoritative
  concurrent-run reading.

  Sampling is a `GenServer.call` against the owner under test, so it is paced
  rather than spun — a tight loop would contend with the very admission it is
  measuring.
  """
  @spec capacity_sampler(pid(), pos_integer()) :: pid()
  def capacity_sampler(owner, interval_ms \\ 1) do
    admission = run_admission(owner)
    peak_sampler(fn -> in_use(admission) end, interval_ms)
  end

  @doc """
  Starts a sampler over `RequestAdmission`'s lease table: the authoritative
  in-flight reading.

  The lease map *is* the enforcement state — `acquire/1` refuses once it reaches
  `max_inflight_requests` — so its size is what the bound means, not a proxy for it.

  A sampler can only ever under-report a peak it did not catch, which makes
  `peak <= bound` sound and `peak == bound` a coin toss on a burst that clears
  in twenty milliseconds. Prove the bound was *reached* from the refusals
  instead: a 429 is returned only when the table is full.
  """
  @spec lease_sampler(pid(), pos_integer()) :: pid()
  def lease_sampler(owner, interval_ms \\ 1) do
    admission = request_admission(owner)
    peak_sampler(fn -> lease_count(admission) end, interval_ms)
  end

  @doc """
  Starts a sampler that calls `reading` every `interval_ms` and tracks its peak.

  Both admissions are sampled rather than instrumented so that nothing in the
  server exists only to make a measurement possible.
  """
  @spec peak_sampler((-> non_neg_integer()), pos_integer()) :: pid()
  def peak_sampler(reading, interval_ms \\ 1) do
    spawn_link(fn ->
      {:ok, timer} = :timer.send_interval(interval_ms, :sample)
      peak_loop(reading, 0, 0, timer)
    end)
  end

  @doc "Stops a peak sampler and returns the peak it saw and how many samples it took."
  @spec stop_peak_sampler(pid()) :: %{peak: non_neg_integer(), samples: non_neg_integer()}
  def stop_peak_sampler(sampler) do
    send(sampler, {:stop, self()})

    receive do
      {:peak, ^sampler, peak, samples} -> %{peak: peak, samples: samples}
    after
      5_000 -> %{peak: 0, samples: 0}
    end
  end

  @doc "How many in-flight request leases are held right now."
  @spec inflight_leases(pid()) :: non_neg_integer()
  def inflight_leases(owner), do: owner |> request_admission() |> lease_count()

  defp lease_count(admission),
    do: admission |> :sys.get_state() |> Map.fetch!(:leases) |> map_size()

  @doc """
  Polls until the lease count reaches `expected`, then returns it; returns the
  last reading if it never does, so a regression reports the number it saw
  rather than a timeout.

  The budget is wall-clock rather than a retry count. A count is a budget in
  machine speed: five hundred `:sys.get_state` round-trips can elapse before the
  listener has even accepted the sockets being waited on, which fails the test
  on a fast machine and passes it on a slow one.
  """
  @spec await_leases(pid(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  def await_leases(owner, expected, timeout_ms \\ 5_000) do
    admission = request_admission(owner)
    poll_leases(admission, expected, now() + timeout_ms * 1_000)
  end

  defp poll_leases(admission, expected, deadline) do
    case lease_count(admission) do
      ^expected -> expected
      other -> if now() >= deadline, do: other, else: poll_leases(admission, expected, deadline)
    end
  end

  # ---------------------------------------------------------------------------
  # Connection handling
  # ---------------------------------------------------------------------------

  @doc """
  Opens a connection that sends complete, valid headers announcing a body, and
  then sends none of it.

  Admission is acquired before the body is read, so this connection holds one of
  `max_inflight_requests` for as long as the server is willing to wait for the
  bytes. Returns the socket; `await_close/2` reports how long that was.
  """
  @spec stall_body(map(), keyword()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def stall_body(config, opts \\ []) do
    body = body_bytes(Keyword.put_new(opts, :method, "tools/list"))
    announced = byte_size(body) + Keyword.get(opts, :withheld_bytes, 64)

    with {:ok, socket} <- connect(config) do
      headers = header_lines(config, Keyword.put_new(opts, :method, "tools/list"), announced)
      :ok = :gen_tcp.send(socket, [headers, "\r\n", body])
      {:ok, socket}
    end
  end

  @doc """
  Opens a connection that sends a request line and one header, then stops —
  never completing the header block.

  The counterpart to `stall_body/2` one phase earlier: this request has not been
  routed, authenticated or admitted, so it should cost a socket and nothing else.
  """
  @spec stall_headers(map(), keyword()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def stall_headers(config, _opts \\ []) do
    with {:ok, socket} <- connect(config) do
      :ok = :gen_tcp.send(socket, ["POST /mcp HTTP/1.1\r\n", "host: ", authority(config), "\r\n"])
      {:ok, socket}
    end
  end

  @doc """
  Waits for the server to close the connection, returning how long it took and
  what it said before closing.

  The status matters as much as the timing: a server that ends a stalled request
  is doing the right thing, and a server that ends it by calling the client's
  incomplete request an internal error is not.
  """
  @spec await_close(:gen_tcp.socket(), pos_integer()) ::
          {:closed, float(), pos_integer() | nil} | :open
  def await_close(socket, timeout_ms) do
    started_at = now()
    deadline = started_at + timeout_ms * 1_000
    drain_until_closed(socket, started_at, deadline, "")
  end

  @doc "Closes with a reset rather than a graceful shutdown: the peer vanishes mid-stream."
  @spec close_abruptly(:gen_tcp.socket()) :: :ok
  def close_abruptly(socket) do
    :inet.setopts(socket, [{:linger, {true, 0}}])
    :gen_tcp.close(socket)
  end

  @doc "Stops writing but keeps reading: the half-open peer a liveness probe must not mistake for gone."
  @spec half_close(:gen_tcp.socket()) :: :ok
  def half_close(socket), do: :gen_tcp.shutdown(socket, :write)

  @doc """
  Sends `count` sequential calls down one connection and returns each status.

  A lease is per request and a socket is not, so a reused connection must return
  its slot between calls; a leak here looks like a connection that works once.
  """
  @spec keepalive(map(), pos_integer(), keyword()) :: [pos_integer() | nil]
  def keepalive(config, count, opts \\ []) do
    opts = Keyword.put_new(opts, :method, "tools/list")

    case connect(config) do
      {:ok, socket} ->
        statuses =
          Enum.map(1..count, fn _ ->
            request = request_bytes(config, Keyword.put(opts, :connection, "keep-alive"))
            :ok = :gen_tcp.send(socket, request)
            read_one_keepalive_status(socket, "", now() + 10_000_000)
          end)

        :gen_tcp.close(socket)
        statuses

      {:error, reason} ->
        [{:error, reason}]
    end
  end

  # ---------------------------------------------------------------------------
  # Leak slope
  # ---------------------------------------------------------------------------

  @typedoc "Fitted bytes-per-cycle for each gated metric, plus the raw batch readings."
  @type leak_report :: %{
          slopes: %{atom() => float()},
          batches: [%{cycles: pos_integer(), memory: %{atom() => integer()}}],
          processes: %{before: non_neg_integer(), after: non_neg_integer()}
        }

  @doc """
  Runs `batches` batches of `cycles` invocations of `fun` and fits a byte slope.

  The detector is a slope, not a trend: a constant positive delta in every batch
  *is* the leak, so "the delta stopped growing" must not be the oracle. Batch 1
  is measured and reported but excluded from the fit, because first-use costs —
  lazy module loading, interning, pool warmup — are real and are not leaks.
  """
  @spec leak(pos_integer(), pos_integer(), (pos_integer() -> any())) :: leak_report()
  def leak(batches, cycles, fun) do
    collect_garbage()
    before_processes = :erlang.system_info(:process_count)

    readings =
      Enum.map(1..batches, fn batch ->
        Enum.each(1..cycles, fn cycle -> fun.((batch - 1) * cycles + cycle) end)
        collect_garbage()
        %{cycles: batch * cycles, memory: memory_sample()}
      end)

    collect_garbage()

    %{
      slopes: fit_slopes(Enum.drop(readings, 1)),
      batches: readings,
      processes: %{before: before_processes, after: :erlang.system_info(:process_count)}
    }
  end

  # ---------------------------------------------------------------------------
  # Mailbox sampling
  # ---------------------------------------------------------------------------

  @doc """
  Starts a sampler over `named_pids` and returns a handle for `stop_sampler/1`.

  A saturated bound and a saturated *mailbox* look identical from the client —
  both are just latency. The difference is visible only here: a serialization
  point that is the ceiling has a queue, and one that is not stays at zero.
  """
  @spec sampler([{atom(), pid()}], pos_integer()) :: pid()
  def sampler(named_pids, interval_ms \\ 5) do
    parent = self()

    spawn_link(fn ->
      {:ok, timer} = :timer.send_interval(interval_ms, :sample)
      sample_loop(named_pids, [], parent, timer)
    end)
  end

  @doc "Stops a sampler and returns the peak and mean mailbox depth seen per name."
  @spec stop_sampler(pid()) :: %{atom() => %{peak: non_neg_integer(), mean: float()}}
  def stop_sampler(sampler) do
    send(sampler, {:stop, self()})

    receive do
      {:samples, ^sampler, samples} -> summarize_samples(samples)
    after
      5_000 -> %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Request construction
  # ---------------------------------------------------------------------------

  defp connect(config) do
    :gen_tcp.connect(
      ~c"127.0.0.1",
      config["listen"]["port"],
      [:binary, active: false, nodelay: true],
      @connect_timeout_ms
    )
  end

  defp authority(config), do: "127.0.0.1:#{config["listen"]["port"]}"

  defp request_bytes(config, opts) do
    body = body_bytes(opts)
    [header_lines(config, opts, byte_size(body)), "\r\n", body]
  end

  defp header_lines(config, opts, content_length) do
    method = Keyword.get(opts, :method, "tools/call")
    token = Keyword.get(opts, :token, PtcGateway.TestSupport.GatewayFixture.token())

    name_header =
      if method == "tools/call", do: [{"mcp-name", Keyword.get(opts, :tool, "a")}], else: []

    headers =
      [
        {"host", authority(config)},
        {"authorization", "Bearer #{token}"},
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", @revision},
        {"mcp-method", method},
        {"content-length", Integer.to_string(content_length)},
        {"connection", Keyword.get(opts, :connection, "close")}
      ] ++ name_header

    [
      "POST /mcp HTTP/1.1\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
    ]
  end

  defp body_bytes(opts) do
    method = Keyword.get(opts, :method, "tools/call")

    params =
      %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @revision,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
      |> then(fn meta ->
        if method == "tools/call" do
          meta
          |> Map.put("name", Keyword.get(opts, :tool, "a"))
          |> Map.put("arguments", Keyword.get(opts, :arguments, %{}))
        else
          meta
        end
      end)

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => Keyword.get(opts, :id, 1),
      "method" => method,
      "params" => params
    })
  end

  # ---------------------------------------------------------------------------
  # Response collection
  # ---------------------------------------------------------------------------

  defp blank(sent_at) do
    %{
      status: nil,
      sent_at: sent_at,
      headers_at: nil,
      accepted_at: nil,
      message_at: nil,
      closed_at: sent_at,
      body: "",
      result: nil,
      error: nil
    }
  end

  defp collect(socket, acc, buffer, deadline) do
    if now() >= deadline do
      %{acc | closed_at: now(), error: :deadline, body: buffer}
    else
      case :gen_tcp.recv(socket, 0, @recv_timeout_ms) do
        {:ok, chunk} ->
          buffer = buffer <> chunk
          collect(socket, mark(acc, buffer), buffer, deadline)

        {:error, :timeout} ->
          collect(socket, acc, buffer, deadline)

        {:error, :closed} ->
          acc = mark(acc, buffer)
          %{acc | closed_at: now(), body: buffer, result: decode_result(buffer)}

        {:error, reason} ->
          %{acc | closed_at: now(), body: buffer, error: reason}
      end
    end
  end

  # Each marker is timestamped the first time the buffer contains it. The frames
  # arrive in order and each is written in one chunk call, so "contains" cannot
  # run ahead of the frame actually being on the wire.
  defp mark(acc, buffer) do
    acc
    |> mark_at(:headers_at, buffer, "\r\n\r\n")
    |> put_status(buffer)
    |> mark_at(:accepted_at, buffer, ": accepted")
    |> mark_at(:message_at, buffer, "event: message")
  end

  defp mark_at(acc, key, buffer, marker) do
    if is_nil(Map.fetch!(acc, key)) and String.contains?(buffer, marker) do
      Map.put(acc, key, now())
    else
      acc
    end
  end

  defp put_status(%{status: nil} = acc, buffer) do
    case buffer do
      <<"HTTP/1.1 ", code::binary-size(3), _::binary>> -> %{acc | status: String.to_integer(code)}
      _ -> acc
    end
  end

  defp put_status(acc, _buffer), do: acc

  defp decode_result(buffer) do
    case Regex.run(~r/^data: (.+)$/m, buffer) do
      [_, json] -> json |> String.trim() |> Jason.decode() |> ok_or_nil()
      nil -> body_json(buffer)
    end
  end

  defp body_json(buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [_headers, body] -> body |> String.trim() |> Jason.decode() |> ok_or_nil()
      _ -> nil
    end
  end

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_), do: nil

  defp drain_until_closed(socket, started_at, deadline, buffer) do
    if now() >= deadline do
      :open
    else
      case :gen_tcp.recv(socket, 0, @recv_timeout_ms) do
        {:ok, chunk} -> drain_until_closed(socket, started_at, deadline, buffer <> chunk)
        {:error, :timeout} -> drain_until_closed(socket, started_at, deadline, buffer)
        {:error, _reason} -> {:closed, (now() - started_at) / 1_000, status_of(buffer)}
      end
    end
  end

  defp read_one_keepalive_status(socket, buffer, deadline) do
    complete? = String.contains?(buffer, "\r\n0\r\n\r\n") or terminated_body?(buffer)

    cond do
      complete? -> status_of(buffer)
      now() >= deadline -> status_of(buffer)
      true -> continue_keepalive(socket, buffer, deadline)
    end
  end

  defp continue_keepalive(socket, buffer, deadline) do
    case :gen_tcp.recv(socket, 0, @recv_timeout_ms) do
      {:ok, chunk} -> read_one_keepalive_status(socket, buffer <> chunk, deadline)
      {:error, :timeout} -> read_one_keepalive_status(socket, buffer, deadline)
      {:error, _} -> status_of(buffer)
    end
  end

  defp terminated_body?(buffer) do
    case Regex.run(~r/content-length: (\d+)/i, buffer) do
      [_, length] ->
        case String.split(buffer, "\r\n\r\n", parts: 2) do
          [_, body] -> byte_size(body) >= String.to_integer(length)
          _ -> false
        end

      nil ->
        false
    end
  end

  defp status_of(<<"HTTP/1.1 ", code::binary-size(3), _::binary>>), do: String.to_integer(code)
  defp status_of(_), do: nil

  # ---------------------------------------------------------------------------
  # Sampling and fitting
  # ---------------------------------------------------------------------------

  defp sample_loop(named_pids, samples, parent, timer) do
    receive do
      :sample ->
        sample =
          Map.new(named_pids, fn {name, pid} ->
            {name, mailbox_depth(pid)}
          end)

        sample_loop(named_pids, [sample | samples], parent, timer)

      {:stop, from} ->
        :timer.cancel(timer)
        send(from, {:samples, self(), samples})
    end
  end

  defp peak_loop(reading, peak, samples, timer) do
    receive do
      :sample ->
        peak_loop(reading, max(peak, reading.()), samples + 1, timer)

      {:stop, from} ->
        :timer.cancel(timer)
        send(from, {:peak, self(), max(peak, reading.()), samples})
    end
  end

  defp in_use(admission) do
    case GenServer.call(admission, :snapshot, 5_000) do
      {:ok, %{in_use: in_use}} -> in_use
      _ -> 0
    end
  catch
    :exit, _ -> 0
  end

  defp mailbox_depth(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} -> length
      nil -> 0
    end
  end

  defp summarize_samples([]), do: %{}

  defp summarize_samples(samples) do
    samples
    |> Enum.flat_map(&Map.to_list/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {name, depths} ->
      {name, %{peak: Enum.max(depths), mean: Enum.sum(depths) / length(depths)}}
    end)
  end

  defp memory_sample do
    memory = :erlang.memory()
    Map.new([:total, :processes, :binary, :ets], &{&1, Keyword.fetch!(memory, &1)})
  end

  defp fit_slopes([]), do: %{}
  defp fit_slopes([_single]), do: %{}

  defp fit_slopes(readings) do
    xs = Enum.map(readings, & &1.cycles)

    [:total, :processes, :binary, :ets]
    |> Map.new(fn metric ->
      {metric, slope(xs, Enum.map(readings, &Map.fetch!(&1.memory, metric)))}
    end)
  end

  # Ordinary least squares. A flat fit means the batch endpoints are noise
  # around a constant; a positive fit means each cycle keeps something.
  defp slope(xs, ys) do
    count = length(xs)
    mean_x = Enum.sum(xs) / count
    mean_y = Enum.sum(ys) / count

    covariance =
      Enum.zip(xs, ys)
      |> Enum.map(fn {x, y} -> (x - mean_x) * (y - mean_y) end)
      |> Enum.sum()

    variance = xs |> Enum.map(&((&1 - mean_x) * (&1 - mean_x))) |> Enum.sum()

    if variance == 0.0, do: 0.0, else: covariance / variance
  end

  defp collect_garbage do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    :erlang.garbage_collect()
  end

  defp now, do: System.monotonic_time(:microsecond)
end
