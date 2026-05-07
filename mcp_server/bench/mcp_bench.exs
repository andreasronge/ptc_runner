# Phase 6 benchmark: native-only LLM math vs PtcRunner-MCP-assisted math.
#
# Two workloads, three execution modes each:
#
#   * Workload A — "count r in raspberry" (the canonical native-vs-PTC
#     anchor from the spec § 1 / § 15 Phase 6).
#   * Workload B — sum aggregation over ~1k synthetic numeric records
#     passed via `context` (one larger workload per § 15 Phase 6).
#
#   * Mode 1 (`llm_only`) — the LLM answers from its own context (no
#     deterministic compute). Real LLM if `--real-llm` is set and an
#     API key is in env; otherwise a canned-response stub that mimics
#     the kind of guess the model would make (correct on simple
#     workloads, wrong on the larger one). Per § 20.5 risk 2 /
#     CLAUDE.md, prompts are domain-blind.
#
#   * Mode 2 (`in_process_ptc`) — runs the deterministic program via
#     `PtcRunner.Lisp.run/2` in this BEAM node.
#
#   * Mode 3 (`mcp`) — sends the same program over an NDJSON /
#     JSON-RPC pipeline to the MCP server's `Stdio` GenServer, the
#     same code path an OS-level subprocess client traverses.
#     Implemented in-BEAM via `StringIO` because BEAM-on-BEAM
#     `Port.open` has long-standing stdin-pipe quirks; the same
#     module also measures **end-to-end OS-process startup latency**
#     against the released binary in a separate one-shot probe so the
#     cross-process path is empirically anchored. See `mcp_client.exs`
#     for the rationale.
#
# This benchmark is *transport-focused* by design: the program text is
# fixed per workload, so the only thing the modes differ on is HOW the
# answer reaches the harness. Mode 1 measures the cost of trusting the
# LLM's in-head math; modes 2 and 3 measure the cost of routing the
# computation through PtcRunner. The MCP path adds bounded JSON / IPC
# overhead on top of the in-process path.
#
# Usage (from the repo root):
#
#   mix run mcp_server/bench/mcp_bench.exs                       # N=20, stub LLM
#   mix run mcp_server/bench/mcp_bench.exs --runs=50
#   OPENROUTER_API_KEY=sk-or-v1-... mix run mcp_server/bench/mcp_bench.exs --runs=20 --real-llm
#   mix run mcp_server/bench/mcp_bench.exs --report=demo/MCP_BENCHMARK.md
#
# Outputs a markdown table to stdout and (optionally) writes the same
# report to `--report=<path>`.

Code.require_file(Path.join(__DIR__, "mcp_client.exs"))

alias PtcRunnerMcp.Bench.{InBeamClient, OsProcessClient}

# ---------------------------------------------------------------------------
# Inline helpers — defined first so the closures below can reference them.
# ---------------------------------------------------------------------------

defmodule Bench.Helpers do
  @moduledoc false

  def parse_integer_in(text) when is_binary(text) do
    case Regex.run(~r/-?\d+/, text) do
      [match] ->
        case Integer.parse(match) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
    end
  end

  def parse_integer_in(other), do: other

  def median([]), do: 0

  def median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      a = Enum.at(sorted, mid - 1)
      b = Enum.at(sorted, mid)
      div(a + b, 2)
    end
  end

  def mean([]), do: 0.0
  def mean(xs), do: Enum.sum(xs) / length(xs)
end

# ---------------------------------------------------------------------------
# CLI parsing.
# ---------------------------------------------------------------------------

{opts, _positional, _} =
  OptionParser.parse(System.argv(),
    strict: [
      runs: :integer,
      real_llm: :boolean,
      model: :string,
      report: :string,
      n: :integer
    ]
  )

runs = opts[:runs] || 20
real_llm? = opts[:real_llm] == true
model = opts[:model] || "haiku"
report_path = opts[:report]
larger_n = opts[:n] || 1000

# ---------------------------------------------------------------------------
# Workload definitions.
# ---------------------------------------------------------------------------
# Each workload supplies:
#   * `prompt/0`     — the question phrased for an LLM (mode 1)
#   * `program/1`    — a fixed PTC-Lisp program (modes 2 and 3)
#   * `context/0`    — the context map passed to the program (or %{})
#   * `expected/0`   — the canonical correct answer (used to score
#                       `llm_only` runs against ground truth)
#   * `stub_answer/1` — what the canned-response stub returns when
#                       `--real-llm` is OFF. The stub for the larger
#                       workload deliberately returns a slightly-wrong
#                       integer to mimic the model "estimating" without
#                       actually summing the rows.

workload_a = %{
  name: "count_r_in_raspberry",
  description: "count letter 'r' in word 'raspberry'",
  prompt: ~s|How many letter 'r' is in the word 'raspberry'? Reply with a single integer only.|,
  program: fn _ctx -> ~S|(count (filter #(= \r %) "raspberry"))| end,
  context: fn -> %{} end,
  expected: 3,
  # Models genuinely miscount this — the stub mirrors the most common
  # wrong answer reported in the spec § 1 examples.
  stub_answer: fn _ctx -> 2 end
}

# Larger workload: sum a column over N rows. We pick a value (`amount`)
# that is per-row deterministic so the program output is stable across
# runs but the LLM cannot easily eyeball-sum it.
build_records = fn n ->
  for i <- 1..n do
    %{
      "id" => i,
      "amount" => rem(i * 137 + 17, 1000),
      "category" => Enum.at(["a", "b", "c", "d"], rem(i, 4))
    }
  end
end

records = build_records.(larger_n)

expected_sum =
  records
  |> Enum.map(& &1["amount"])
  |> Enum.sum()

workload_b = %{
  name: "sum_amount_over_#{larger_n}",
  description: "sum :amount over #{larger_n} synthetic records",
  prompt:
    "I have #{larger_n} records, each with integer field 'amount'. " <>
      "What is the total sum of 'amount' across all records? " <>
      "Reply with a single integer only.",
  program: fn _ctx -> ~S|(reduce + (map #(get % "amount") data/records))| end,
  context: fn -> %{"records" => records} end,
  expected: expected_sum,
  # Stub: deliberately wrong (off by ~10%), reflecting that an LLM
  # asked to sum 1000 hidden numbers cannot. This is the value-prop
  # demonstration for mode 2 / mode 3 over mode 1.
  stub_answer: fn ctx ->
    actual = ctx |> Map.get("records", []) |> Enum.map(& &1["amount"]) |> Enum.sum()
    round(actual * 0.9)
  end
}

workloads = [workload_a, workload_b]

# ---------------------------------------------------------------------------
# Mode runners. Each returns:
#   {:ok | :error, value_or_text :: term(), wall_us :: non_neg_integer()}
# ---------------------------------------------------------------------------

# Mode 1: llm_only -----------------------------------------------------------

run_llm_only =
  if real_llm? do
    fn workload, _mcp ->
      callback = PtcRunner.LLM.callback(model)

      messages = [
        %{role: :system, content: "You are a careful arithmetic assistant."},
        %{role: :user, content: workload.prompt}
      ]

      t0 = System.monotonic_time(:microsecond)
      response = callback.(%{messages: messages})
      wall_us = System.monotonic_time(:microsecond) - t0

      case response do
        {:ok, %{content: text}} when is_binary(text) ->
          {:ok, Bench.Helpers.parse_integer_in(text), wall_us}

        {:ok, other} ->
          {:error, "unexpected llm response: #{inspect(other)}", wall_us}

        {:error, reason} ->
          {:error, "llm error: #{inspect(reason)}", wall_us}
      end
    end
  else
    # Stub mode: simulate the latency of a small remote LLM call so the
    # numbers don't pretend the LLM is free, but keep the result fully
    # deterministic for CI-friendliness. ~150 ms is on the floor of what
    # a real cloud LLM costs for a one-shot single-token answer.
    fn workload, _mcp ->
      ctx = workload.context.()
      stub_latency_us = 150_000
      t0 = System.monotonic_time(:microsecond)
      :timer.sleep(div(stub_latency_us, 1000))
      wall_us = System.monotonic_time(:microsecond) - t0
      {:ok, workload.stub_answer.(ctx), wall_us}
    end
  end

# Mode 2: in_process_ptc ----------------------------------------------------

run_in_process_ptc = fn workload, _mcp ->
  ctx = workload.context.()
  program = workload.program.(ctx)

  t0 = System.monotonic_time(:microsecond)
  result = PtcRunner.Lisp.run(program, context: ctx)
  wall_us = System.monotonic_time(:microsecond) - t0

  case result do
    {:ok, %{return: value}} -> {:ok, value, wall_us}
    {:error, %{fail: reason}} -> {:error, "fail: #{inspect(reason)}", wall_us}
    other -> {:error, "unexpected: #{inspect(other)}", wall_us}
  end
end

# Mode 3: mcp ---------------------------------------------------------------
#
# The bench drives `PtcRunnerMcp.Stdio` via the same `StringIO`-backed
# harness the test suite uses (see `mcp_server/test/support/jsonrpc_harness.ex`).
# Bytes flow as NDJSON-framed JSON-RPC 2.0 through the production
# `Stdio` GenServer, the production per-call worker, the production
# concurrency gate, and the production `Sandbox` execution. The only
# thing skipped vs a real OS subprocess is the Unix pipe between OS
# processes; OS-process boundary cost is measured separately by
# `OsProcessClient.measure_startup_handshake/1` and reported as a
# fixed-cost line at the bottom of the report.
#
# State is the shared `InBeamClient` connection — all mode-3 runs go
# through one persistent `Stdio` GenServer, mirroring how a real MCP
# client reuses one server connection for many `tools/call` requests.

# `mcp` here is the InBeamClient state map captured by the closure.
run_mcp = fn workload, mcp ->
  ctx = workload.context.()
  program = workload.program.(ctx)

  args =
    case ctx do
      empty when empty == %{} -> %{}
      m when is_map(m) -> %{"context" => m}
    end

  t0 = System.monotonic_time(:microsecond)
  reply = InBeamClient.call_tool(mcp, program, args)
  wall_us = System.monotonic_time(:microsecond) - t0

  case reply do
    {:ok, %{"result" => %{"isError" => false, "structuredContent" => sc}}, _state} ->
      # `result` field is the human-readable repl form ("user=> 3");
      # parse the trailing token as an integer for comparison.
      {:ok, Bench.Helpers.parse_integer_in(Map.get(sc, "result", "")), wall_us}

    {:ok, %{"result" => %{"isError" => true, "structuredContent" => sc}}, _state} ->
      {:error, "mcp tool error: #{inspect(sc)}", wall_us}

    {:error, full, _state} ->
      {:error, "mcp rpc error: #{inspect(full)}", wall_us}
  end
end

# ---------------------------------------------------------------------------
# Per-mode runner: replays `runs` invocations, scores against expected.
# ---------------------------------------------------------------------------

run_mode = fn mode_label, runner, workload, mcp ->
  rows =
    for _ <- 1..runs do
      case runner.(workload, mcp) do
        {:ok, value, wall_us} ->
          ok? = value == workload.expected
          %{ok?: ok?, wall_us: wall_us, value: value}

        {:error, msg, wall_us} ->
          %{ok?: false, wall_us: wall_us, value: msg}
      end
    end

  pass = Enum.count(rows, & &1.ok?)
  walls = Enum.map(rows, & &1.wall_us)

  %{
    mode: mode_label,
    workload: workload.name,
    runs: runs,
    pass: pass,
    pass_rate: pass / runs,
    median_us: Bench.Helpers.median(walls),
    mean_us: Bench.Helpers.mean(walls),
    min_us: Enum.min(walls),
    max_us: Enum.max(walls),
    rows: rows
  }
end

# ---------------------------------------------------------------------------
# Drive the benchmark.
# ---------------------------------------------------------------------------

IO.puts("\nPhase 6 benchmark: native-only vs in-process PTC vs MCP cross-process")
IO.puts(String.duplicate("=", 70))
IO.puts("Runs per cell:  #{runs}")
IO.puts("LLM:            #{if real_llm?, do: "real (#{model})", else: "stubbed (canned)"}")
IO.puts("Larger N:       #{larger_n}")
IO.puts("")

IO.puts("Starting in-BEAM MCP `Stdio` harness ...")
mcp = InBeamClient.start()
IO.puts("MCP handshake complete.\n")

# One-shot OS-process startup probe so the report can quote a real
# end-to-end cross-process number. We try the released binary first,
# fall back to nil if it isn't built.
release_path =
  Path.expand(Path.join(__DIR__, "../_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp"))

os_startup =
  case OsProcessClient.measure_startup_handshake(release_path) do
    {:ok, ms} ->
      IO.puts("OS-process startup + handshake: #{ms} ms (release at #{release_path})")
      %{ok?: true, ms: ms, release_path: release_path}

    {:error, reason} ->
      IO.puts(
        "OS-process startup probe skipped: #{inspect(reason)} " <>
          "(build the release with `MIX_ENV=prod mix release` in mcp_server/ to enable)"
      )

      %{ok?: false, ms: nil, release_path: release_path, reason: inspect(reason)}
  end

IO.puts("")

modes = [
  {"llm_only", run_llm_only},
  {"in_process_ptc", run_in_process_ptc},
  {"mcp", run_mcp}
]

results =
  for workload <- workloads,
      {mode_label, runner} <- modes do
    IO.write(
      "  #{String.pad_trailing(workload.name, 30)} #{String.pad_trailing(mode_label, 16)} "
    )

    r = run_mode.(mode_label, runner, workload, mcp)

    IO.puts(
      "pass=#{r.pass}/#{r.runs} med=#{div(r.median_us, 1000)}ms " <>
        "mean=#{Float.round(r.mean_us / 1000, 1)}ms"
    )

    r
  end

InBeamClient.close(mcp)

# ---------------------------------------------------------------------------
# Render markdown report.
# ---------------------------------------------------------------------------

format_us = fn us when is_integer(us) ->
  cond do
    us >= 10_000 -> "#{div(us, 1000)} ms"
    us >= 1_000 -> "#{Float.round(us / 1000, 1)} ms"
    true -> "#{us} µs"
  end
end

format_mean = fn us ->
  cond do
    us >= 10_000.0 -> "#{Float.round(us / 1000, 0) |> trunc()} ms"
    us >= 1_000.0 -> "#{Float.round(us / 1000, 1)} ms"
    true -> "#{Float.round(us, 0) |> trunc()} µs"
  end
end

env_summary = """
- **Runs per cell:** #{runs}
- **LLM mode:** #{if real_llm?, do: "real LLM (`#{model}`)", else: "stubbed (canned responses, 150 ms simulated latency)"}
- **Larger workload N:** #{larger_n} records
- **Elixir:** #{System.version()}
- **OTP:** #{:erlang.system_info(:otp_release) |> List.to_string()}
- **Schedulers:** #{:erlang.system_info(:schedulers_online)}
"""

table_header = """
| Workload | Mode | Pass | Median | Mean | Min | Max |
| --- | --- | --- | --- | --- | --- | --- |
"""

table_body =
  results
  |> Enum.map(fn r ->
    "| #{r.workload} | #{r.mode} | #{r.pass}/#{r.runs} | " <>
      "#{format_us.(r.median_us)} | #{format_mean.(r.mean_us)} | " <>
      "#{format_us.(r.min_us)} | #{format_us.(r.max_us)} |"
  end)
  |> Enum.join("\n")

# Compute observation summaries from the data.
group_by_workload = Enum.group_by(results, & &1.workload)

observations =
  group_by_workload
  |> Enum.map(fn {workload_name, rs} ->
    by_mode = Map.new(rs, &{&1.mode, &1})
    llm = by_mode["llm_only"]
    inproc = by_mode["in_process_ptc"]
    mcp = by_mode["mcp"]

    """
    ### #{workload_name}

    - LLM-only pass rate: **#{llm.pass}/#{llm.runs}** (median #{format_us.(llm.median_us)}).
    - In-process PTC pass rate: **#{inproc.pass}/#{inproc.runs}** (median #{format_us.(inproc.median_us)}).
    - MCP cross-process pass rate: **#{mcp.pass}/#{mcp.runs}** (median #{format_us.(mcp.median_us)}).
    - MCP overhead vs in-process PTC: median **#{format_us.(mcp.median_us - inproc.median_us)}** added per call.
    """
  end)
  |> Enum.join("\n")

methodology = """
## Methodology

For each workload, three modes are exercised:

1. **`llm_only`** — the LLM is asked the question with no tool. Either a
   real OpenRouter call (when `--real-llm` is set and an API key is
   present) or a canned-response stub that returns a plausible-but-not-
   always-correct answer (smaller workload: correct; larger workload:
   off by a fixed ratio to model that the LLM cannot accurately sum
   N unseen numbers in its head). The stub injects a fixed 150 ms
   sleep so wall-clock numbers are not absurdly low.
2. **`in_process_ptc`** — the same fixed PTC-Lisp program is run via
   `PtcRunner.Lisp.run/2` in this BEAM node. No LLM round-trip.
3. **`mcp`** — the same program is sent through the production
   `PtcRunnerMcp.Stdio` GenServer as NDJSON-framed JSON-RPC 2.0,
   exactly as an OS-level MCP client would. The bench drives the
   GenServer in-BEAM via a `StringIO` device because BEAM-on-BEAM
   `Port.open` has long-standing stdin-pipe issues on macOS / Linux
   that prevent reliable byte-flow from the parent BEAM into a child
   release; the workaround is the same pattern the test suite uses
   (`mcp_server/test/support/jsonrpc_harness.ex`). End-to-end
   OS-process boundary cost is reported separately as a one-shot
   startup measurement (see *OS-process startup* below).

The point is *not* a horse-race: the program text is identical between
mode 2 and mode 3. The numbers measure how much overhead the JSON-RPC /
stdio code path adds over the deterministic-compute primitive.
"""

prompts = """
## Prompts and programs

### #{workload_a.name}

- **Prompt (mode 1):** `#{workload_a.prompt}`
- **Program (modes 2, 3):** `#{workload_a.program.(%{})}`
- **Expected:** `#{workload_a.expected}`

### #{workload_b.name}

- **Prompt (mode 1):** `#{workload_b.prompt}`
- **Program (modes 2, 3):** `#{workload_b.program.(%{})}`
- **Expected:** `#{workload_b.expected}`
"""

os_startup_section =
  if os_startup.ok? do
    """
    ## OS-process startup

    A separate one-shot probe pipes a single `initialize` frame to the
    released binary at:

        #{os_startup.release_path}

    via `printf '...' | <release> start`, and times the round-trip
    until the handshake reply is parsed.

    - **Wall-clock for one OS-process startup + handshake:** **#{os_startup.ms} ms**

    This is the *fixed* cost a real MCP client pays once when it opens
    the server connection (Claude Desktop, Cursor, Cline, …). Subsequent
    `tools/call` requests reuse the same connection, so per-call cost
    is what the `mcp` row in the results table reports.
    """
  else
    """
    ## OS-process startup

    OS-process probe was skipped: `#{os_startup.reason}`.

    To enable, build the release first:

        cd mcp_server && MIX_ENV=prod mix release
    """
  end

caveats = """
## Caveats

- Stub mode is deterministic by construction; real-LLM mode introduces
  variance that this report does not quantify (no confidence intervals).
  Re-run with `--real-llm --runs=20` for a directional comparison; use
  `mix ablation` (in `demo/`) for proper statistical analysis.
- The `mcp` mode runs in-BEAM through `StringIO` and therefore does
  **not** include OS-pipe / kernel-scheduler overhead. That overhead
  is dominated by handshake-time process startup, captured by the
  *OS-process startup* probe above. Per-call OS-pipe transport
  overhead on a hot connection is on the order of microseconds and
  not separately measured here.
- The `in_process_ptc` cell shares the parent BEAM node's scheduler
  and process pool; the `mcp` cell pays the cost of NDJSON encoding,
  JSON parsing, and per-call worker / monitor / concurrency-gate
  bookkeeping on every call.
- The benchmark runs in `:dev`, not `:prod`. Hot-path timings will be
  slightly faster under `:prod` due to compiler optimizations.
"""

report = """
# PtcRunner MCP — Phase 6 benchmark

> Generated by `mcp_server/bench/mcp_bench.exs` per spec § 15 Phase 6.

## Environment

#{env_summary}

#{methodology}

#{prompts}

## Results

#{table_header}#{table_body}

## Observations

#{observations}

#{os_startup_section}

#{caveats}
"""

IO.puts("\n" <> table_header <> table_body <> "\n")

if report_path do
  File.write!(report_path, report)
  IO.puts("Report written to #{report_path}")
else
  IO.puts("(pass `--report=<path>` to write the full markdown report.)")
end
