# Phase 2.3 decision-point mini-benchmark.
#
# Spec: Plans/ptc-runner-mcp-aggregator.md §12.4.3, §14.
#
# One representative cross-server-filter workflow run two ways:
#
#   Scenario A — naive multi-call: simulates an LLM client that issues
#                N separate `tools/call` requests (one per upstream
#                tool), then "the model" composes the result
#                client-side. We approximate the LLM-perceived token
#                cost by serializing the request and response envelopes
#                to JSON and dividing bytes by 4.
#
#   Scenario B — aggregator: one `lisp_eval` call whose program
#                orchestrates the same upstream calls and returns only
#                the transformed value (a 2-field map).
#
# Workflow: read three files from a Fake filesystem-MCP, count lines
# in each, return the file with the largest line count. The transform
# is `apply max-key`. Output is `{:file <name> :line-count <int>}`.
#
# Six §14 fields are measured:
#
#   1. Token comparison (bytes/4 approximation; see notes inline).
#   2. Program success rate (deterministic; 100/100 expected).
#   3. Latency: sequential `(map ...)` vs `(pmap ...)` with each
#      Fake `call/4` sleeping 50 ms.
#   4. Failure clarity (synthetic `{:error, :upstream_error, ...}`
#      from one Fake; show the resulting `upstream_calls` payload).
#   5. `:json-null` ergonomics (Fake forced to return `{:ok, nil}`;
#      program checks `(= result :json-null)`).
#   6. Client behavior — DEFERRED (requires real MCP clients).
#
# This is signal-gathering, not a statistical study:
#
#   * One run per measurement (no sampling distribution).
#   * No real LLM (token counts are bytes/4, structural comparison only).
#   * No external network (all in-process Fakes).
#   * No new dependencies (Jason, :timer, System.monotonic_time/1 only).
#
# Run from `mcp_server/`:
#
#     cd mcp_server
#     mix run --no-start bench/aggregator_vs_native.exs
#
# Why `cd mcp_server/` (not the parent repo root): the parent
# `ptc_runner` Mix project does NOT depend on `:ptc_runner_mcp`, so
# `mix run` launched from the parent does not compile this app. On a
# fresh checkout `_build/dev/lib/ptc_runner_mcp/ebin` is absent and
# the bench crashes on the first `PtcRunnerMcp.*` reference.
# Running from `mcp_server/` lets `mix run` compile the nested
# project automatically.
#
# Why `--no-start`: the OTP application's default `start/2` spawns
# the `Stdio` GenServer, which immediately starts reading the
# script's own stdin and shuts BEAM down on EOF before the bench
# can run. `--no-start` skips the auto-boot; we then call
# `Application.ensure_all_started/1` ourselves AFTER setting
# `:attach_stdio` to `false`, so Stdio never enters the supervision
# tree.
#
# Writeup of results (with the §14 fields and the decision) is at
# `../Plans/phase2-decision-point-results.md`.

# §5.1 upstreams-config scrubbing. The bench is fake-only — no real
# subprocess MCP servers, no network. But if the user has a real
# upstreams config installed (env var `PTC_RUNNER_MCP_UPSTREAMS`
# pointing at a JSON file, or an XDG-default
# `~/.config/ptc_runner_mcp/upstreams.json`), `Application.start/2`
# would spin up `Upstream.Supervisor` + Registry pre-populated with
# real upstreams BEFORE the bench installs its fakes. The bench's
# subsequent `Registry.start_link(name: PtcRunnerMcp.Upstream.Registry)`
# would then race a supervisor-restarted child, and the measurement
# would silently mix real + fake upstreams (or just crash). Point
# the env var at a non-existent path so `load_upstreams_config/1`
# returns `[]` (the file-read returns `:enoent`), and the XDG branch
# never runs because the env-var branch wins resolution order in
# `Application.load_upstreams_config/1`.
System.put_env("PTC_RUNNER_MCP_UPSTREAMS", "/nonexistent/ptc_runner_mcp_bench_no_upstreams")

# Suppress production stdio attachment so starting the application
# below does not race the bench for OS stdin / stdout. With
# `mix run --no-start` the OTP app has not booted yet, so this
# `put_env` lands BEFORE `Application.start/2` reads it.
Application.put_env(:ptc_runner_mcp, :attach_stdio, false)

# Now boot the app explicitly. `--no-start` prevented the auto-boot;
# this respects the env scrub above and the `:attach_stdio` flag.
{:ok, _} = Application.ensure_all_started(:ptc_runner_mcp)

# Quiet the per-call `info` logs so the bench output stays readable.
PtcRunnerMcp.Log.set_level("error")

# Trap exits in the script's own process. The bench links itself to
# `Upstream.Registry` instances we spin up and tear down, and the
# Registry's children (Connections, Fake GenServers) propagate `:kill`
# signals up the link tree. Without trap_exit the bench script would
# itself die when we recycle the Registry between fields. ExUnit
# tests get this for free; a `mix run` script does not.
Process.flag(:trap_exit, true)

# When the OTP app starts with no upstreams configured, the Upstream
# subsystem (Fake.Names + Connection.Names + DynamicSupervisor) is
# absent — production design, see `Application.aggregator_children/1`.
# Tests spin these up once globally via `test_helper.exs`; for the
# bench we do the same here so that `Registry.put_fake/3` against a
# test-driven `Upstream.Registry` GenServer can register Fakes and
# Connection workers without crashing on `unknown registry`.
for name <- [
      PtcRunnerMcp.Upstream.Fake.Names,
      PtcRunnerMcp.Upstream.Stdio.Names,
      PtcRunnerMcp.Upstream.Connection.Names
    ] do
  if Process.whereis(name) == nil do
    {:ok, _} = Registry.start_link(keys: :unique, name: name)
  end
end

if Process.whereis(PtcRunnerMcp.Upstream.DynamicSupervisor) == nil do
  {:ok, _} =
    DynamicSupervisor.start_link(
      name: PtcRunnerMcp.Upstream.DynamicSupervisor,
      strategy: :one_for_one
    )
end

alias PtcRunnerMcp.{Limits, Tools}
alias PtcRunnerMcp.Upstream.Registry

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

defmodule Bench.AvN.Helpers do
  @moduledoc false

  # Bytes-per-token approximation. Real tokenizers vary, but for
  # JSON-shaped text Claude/GPT-4-class tokenizers land near ~4 bytes
  # per token. The §14 question is "is the difference order-of-magnitude
  # meaningful," not "what is the exact token count," so this is fine.
  @bytes_per_token 4

  def tokens(payload) when is_binary(payload) do
    div(byte_size(payload), @bytes_per_token)
  end

  def tokens(payload) do
    payload
    |> Jason.encode!()
    |> tokens()
  end

  def section(title) do
    IO.puts("")
    IO.puts(String.duplicate("=", 72))
    IO.puts("  #{title}")
    IO.puts(String.duplicate("=", 72))
  end

  def kv(label, value) do
    IO.puts("  #{String.pad_trailing(label, 32)} #{inspect(value)}")
  end

  def text(value), do: IO.puts("  #{value}")

  def now_ms, do: System.monotonic_time(:millisecond)

  def stop_existing_registry(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  def tools_config(tools) when is_map(tools) do
    %{
      tools:
        Map.new(tools, fn {n, fun} ->
          {n,
           {%{
              name: n,
              input_schema: %{
                "type" => "object",
                "properties" => %{"path" => %{"type" => "string"}},
                "required" => ["path"]
              },
              description: "Read a fixture file's text content."
            }, fun}}
        end)
    }
  end
end

alias Bench.AvN.Helpers, as: H

# ---------------------------------------------------------------------------
# Fixtures: three deterministic files with distinct line counts.
# ---------------------------------------------------------------------------

registry_name = PtcRunnerMcp.Upstream.Registry
server_name = "fs"

# Three files with distinct line counts. Largest is c.txt (60 lines).
# Each file's content is intentionally non-trivial in size (~1KB) so
# the token comparison is representative of "filtering a non-trivial
# tool output," not "transferring a few hundred bytes." A real-world
# `read_text_file` against e.g. a config file or a log snippet would
# be at least this large; tinier payloads under-sell the aggregator's
# point (only the transformed value reaches the LLM, not the raw
# upstream content).
build_lines = fn n, prefix ->
  1..n
  |> Enum.map_join("\n", fn i ->
    "#{prefix}-line-#{i}: lorem ipsum dolor sit amet consectetur adipiscing elit"
  end)
  |> Kernel.<>("\n")
end

files = %{
  "a.txt" => build_lines.(20, "a"),
  "b.txt" => build_lines.(40, "b"),
  "c.txt" => build_lines.(60, "c")
}

# Per-call sleep used for the latency comparison (Field 3). Set to
# 50 ms so 3 sequential calls take ~150 ms and 3 pmap calls take
# ~50 ms — a 3× ratio that's well above wall-clock noise on a
# developer laptop.
call_delay_ms = 50

# ---------------------------------------------------------------------------
# Per-scenario Fake configurations.
# ---------------------------------------------------------------------------

# Standard read-file Fake: returns the upstream MCP-style payload that
# real `@modelcontextprotocol/server-filesystem` would return. Format
# matches `real_filesystem_test`'s observed shape:
#
#     %{"content" => [%{"type" => "text", "text" => "<file>"}],
#       "isError" => false}
read_file_tool = fn delay_ms, files ->
  fn %{"path" => path}, _opts ->
    if delay_ms > 0, do: :timer.sleep(delay_ms)

    case Map.get(files, path) do
      nil ->
        {:error, :upstream_error, "no such file: #{path}"}

      content ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => content}],
           "isError" => false
         }}
    end
  end
end

# Fake that always fails for Field 4 (failure clarity).
failing_read_file_tool = fn %{"path" => _path}, _opts ->
  {:error, :upstream_error, "synthetic-failure-reason"}
end

# Fake that returns top-level JSON null for Field 5 (`:json-null`).
null_returning_tool = fn _args, _opts ->
  {:ok, nil}
end

# ---------------------------------------------------------------------------
# Scenario A — naive multi-call.
# ---------------------------------------------------------------------------

# Boilerplate JSON-RPC `tools/call` request envelope for a single
# upstream tool call (the shape an LLM client would send if each
# upstream tool were natively exposed).
build_naive_request = fn id, server, tool, args ->
  %{
    "jsonrpc" => "2.0",
    "id" => id,
    "method" => "tools/call",
    "params" => %{
      "name" => "#{server}__#{tool}",
      "arguments" => args
    }
  }
end

# Boilerplate response envelope. We don't route through the aggregator
# for Scenario A — the point is to count tokens against the wire shape
# an MCP server would emit if `read_file` were exposed natively. We
# pull the upstream's payload directly from the Fake so we get the
# same fixture content.
build_naive_response = fn id, payload ->
  %{
    "jsonrpc" => "2.0",
    "id" => id,
    "result" => %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}],
      "isError" => false,
      "structuredContent" => payload
    }
  }
end

run_scenario_a = fn ->
  paths = Map.keys(files)

  # Native-exposure premise: each upstream tool is a top-level MCP
  # tool, and every call's full payload reaches the LLM verbatim. We
  # construct the upstream payload directly from the `files` fixture
  # (matching the Fake's wrap shape) — this is just an accounting
  # exercise; no actual upstream wiring is needed for Scenario A.
  payload_for = fn path ->
    %{
      "content" => [%{"type" => "text", "text" => Map.fetch!(files, path)}],
      "isError" => false
    }
  end

  {req_tokens, resp_tokens, payloads} =
    paths
    |> Enum.with_index(1)
    |> Enum.reduce({0, 0, []}, fn {path, id}, {req_acc, resp_acc, payloads} ->
      req = build_naive_request.(id, server_name, "read_file", %{"path" => path})
      payload = payload_for.(path)
      resp = build_naive_response.(id, payload)

      {req_acc + H.tokens(req), resp_acc + H.tokens(resp), [payload | payloads]}
    end)

  # The "model" composes the answer client-side from the three
  # payloads. The composed answer is a 2-field map; that's the
  # "response" the user/agent ultimately sees, but the §14 question
  # is about the LLM's input/output token cost — and the LLM has
  # already paid the cost of reading every payload above.
  composed =
    payloads
    |> Enum.map(fn p ->
      [%{"text" => text}] = p["content"]
      lines = text |> String.split("\n", trim: true) |> length()
      %{lines: lines, text: text}
    end)
    |> Enum.max_by(& &1.lines)

  # Final synthesis token cost: the LLM emits a small structured
  # answer. We attribute that to "output" tokens.
  synthesis = %{file: "winner", line_count: composed.lines}
  output_tokens = H.tokens(synthesis)

  %{
    request_tokens: req_tokens,
    response_tokens: resp_tokens,
    output_tokens: output_tokens,
    total_tokens: req_tokens + resp_tokens + output_tokens
  }
end

# ---------------------------------------------------------------------------
# Scenario B — aggregator (one lisp_eval call).
# ---------------------------------------------------------------------------

scenario_b_program = """
(let [files ["a.txt" "b.txt" "c.txt"]
      counts (map (fn [path]
                    (let [resp (tool/mcp-call {:server "#{server_name}"
                                               :tool "read_file"
                                               :args {:path path}})
                          text (get-in resp ["content" 0 "text"])
                          lines (split-lines text)]
                      {:file path :line-count (count lines)}))
                  files)
      winner (apply max-key :line-count counts)]
  winner)
"""

run_scenario_b = fn program ->
  H.stop_existing_registry(registry_name)
  {:ok, _} = Registry.start_link(name: registry_name)
  Limits.set(Map.merge(Limits.defaults(), Limits.aggregator_defaults()))

  :ok =
    Registry.put_fake(
      server_name,
      H.tools_config(%{"read_file" => read_file_tool.(0, files)}),
      registry_name
    )

  request = %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "tools/call",
    "params" => %{
      "name" => "lisp_eval",
      "arguments" => %{"program" => program}
    }
  }

  request_tokens = H.tokens(request)

  envelope = Tools.call_with_gate(%{"program" => program})

  response = %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "result" => envelope
  }

  response_tokens = H.tokens(response)

  %{
    request_tokens: request_tokens,
    response_tokens: response_tokens,
    total_tokens: request_tokens + response_tokens,
    envelope: envelope
  }
end

# ---------------------------------------------------------------------------
# Field 1: Token comparison.
# ---------------------------------------------------------------------------

H.section("Field 1 — Token comparison (bytes/4 approximation)")

a_tokens = run_scenario_a.()
b_tokens = run_scenario_b.(scenario_b_program)

H.kv("Scenario A request tokens", a_tokens.request_tokens)
H.kv("Scenario A response tokens", a_tokens.response_tokens)
H.kv("Scenario A output tokens", a_tokens.output_tokens)
H.kv("Scenario A total", a_tokens.total_tokens)
IO.puts("")
H.kv("Scenario B request tokens", b_tokens.request_tokens)
H.kv("Scenario B response tokens", b_tokens.response_tokens)
H.kv("Scenario B total", b_tokens.total_tokens)
IO.puts("")

ratio = Float.round(a_tokens.total_tokens / max(b_tokens.total_tokens, 1), 2)
H.kv("Ratio (A / B)", ratio)
H.kv("Absolute delta (A - B)", a_tokens.total_tokens - b_tokens.total_tokens)

# Sanity check: Scenario B should have produced the expected winner.
b_result = b_tokens.envelope["structuredContent"]["result"]
H.kv("Scenario B result", b_result)

# ---------------------------------------------------------------------------
# Field 2: Program success rate (100 runs of Scenario B).
# ---------------------------------------------------------------------------

H.section("Field 2 — Program success rate (100 deterministic runs of Scenario B)")

# Spin up the registry + Fake once; reuse for all 100 runs. The
# alternative shape (start_link + put_fake per iteration) hammers
# the supervisor / Connection / Fake link tree harder than what
# we're asking. Field 2 is "given the same program text, does the
# runtime produce the right answer reliably?" not "does
# Registry.start_link survive 100 cold starts?".
H.stop_existing_registry(registry_name)
{:ok, _} = Registry.start_link(name: registry_name)
Limits.set(Map.merge(Limits.defaults(), Limits.aggregator_defaults()))

:ok =
  Registry.put_fake(
    server_name,
    H.tools_config(%{"read_file" => read_file_tool.(0, files)}),
    registry_name
  )

success_count =
  Enum.reduce(1..100, 0, fn i, acc ->
    env = Tools.call_with_gate(%{"program" => scenario_b_program})
    structured = env["structuredContent"]

    success? =
      env["isError"] == false and
        is_binary(structured["result"]) and
        structured["result"] =~ "c.txt" and
        structured["result"] =~ "60"

    if not success? do
      IO.puts("  [run #{i}] FAIL: #{inspect(env, limit: 400)}")
    end

    if success?, do: acc + 1, else: acc
  end)

H.kv("Successful runs", "#{success_count}/100")

H.text(
  "Note: this measures the runtime, not the LLM. The §14 question is " <>
    "\"can a calling LLM reliably write correct programs?\" — that requires " <>
    "an LLM-in-the-loop and is not measured here."
)

# ---------------------------------------------------------------------------
# Field 3: Latency (sequential vs pmap, with 50ms per upstream call).
# ---------------------------------------------------------------------------

H.section("Field 3 — Latency: sequential map vs pmap (50ms per upstream call)")

setup_fakes_with_delay = fn ->
  H.stop_existing_registry(registry_name)
  {:ok, _} = Registry.start_link(name: registry_name)
  Limits.set(Map.merge(Limits.defaults(), Limits.aggregator_defaults()))

  :ok =
    Registry.put_fake(
      server_name,
      H.tools_config(%{"read_file" => read_file_tool.(call_delay_ms, files)}),
      registry_name
    )
end

sequential_program = """
(let [files ["a.txt" "b.txt" "c.txt"]
      counts (map (fn [path]
                    (let [resp (tool/mcp-call {:server "#{server_name}"
                                               :tool "read_file"
                                               :args {:path path}})
                          text (get-in resp ["content" 0 "text"])
                          lines (split-lines text)]
                      {:file path :line-count (count lines)}))
                  files)]
  (apply max-key :line-count counts))
"""

pmap_program = """
(let [files ["a.txt" "b.txt" "c.txt"]
      counts (pmap (fn [path]
                     (let [resp (tool/mcp-call {:server "#{server_name}"
                                                :tool "read_file"
                                                :args {:path path}})
                           text (get-in resp ["content" 0 "text"])
                           lines (split-lines text)]
                       {:file path :line-count (count lines)}))
                   files)]
  (apply max-key :line-count counts))
"""

setup_fakes_with_delay.()
t0 = H.now_ms()
seq_env = Tools.call_with_gate(%{"program" => sequential_program})
seq_ms = H.now_ms() - t0

setup_fakes_with_delay.()
t0 = H.now_ms()
pmap_env = Tools.call_with_gate(%{"program" => pmap_program})
pmap_ms = H.now_ms() - t0

H.kv("Sequential wall-clock (ms)", seq_ms)
H.kv("pmap wall-clock (ms)", pmap_ms)
H.kv("Speedup (seq / pmap)", Float.round(seq_ms / max(pmap_ms, 1), 2))
H.kv("Sequential isError", seq_env["isError"])
H.kv("pmap isError", pmap_env["isError"])

# ---------------------------------------------------------------------------
# Field 4: Failure clarity. One Fake tool returns
# `{:error, :upstream_error, "synthetic-failure-reason"}`.
# ---------------------------------------------------------------------------

H.section("Field 4 — Failure clarity (synthetic upstream failure)")

H.stop_existing_registry(registry_name)
{:ok, _} = Registry.start_link(name: registry_name)
Limits.set(Map.merge(Limits.defaults(), Limits.aggregator_defaults()))

:ok =
  Registry.put_fake(
    server_name,
    H.tools_config(%{
      "read_file" => read_file_tool.(0, files),
      "broken_read" => failing_read_file_tool
    }),
    registry_name
  )

failure_program = """
(let [ok-resp (tool/mcp-call {:server "#{server_name}"
                              :tool "read_file"
                              :args {:path "a.txt"}})
      bad-resp (tool/mcp-call {:server "#{server_name}"
                               :tool "broken_read"
                               :args {:path "a.txt"}})]
  {:ok-content (get-in ok-resp ["content" 0 "text"])
   :bad-result bad-resp})
"""

failure_env = Tools.call_with_gate(%{"program" => failure_program})

H.kv("isError", failure_env["isError"])

upstream_calls = failure_env["structuredContent"]["upstream_calls"] || []

IO.puts("  upstream_calls payload (n=#{length(upstream_calls)}):")

Enum.each(upstream_calls, fn entry ->
  IO.puts("    " <> Jason.encode!(entry))
end)

H.text(
  "Comment: an LLM reading the error entry sees `tool`, `server`, " <>
    "`reason: \"upstream_error\"`, and `error: \"synthetic-failure-reason\"`. " <>
    "That's enough to choose retry vs narrow vs surface — there's a " <>
    "stable reason taxonomy and a freeform detail string."
)

# ---------------------------------------------------------------------------
# Field 5: `:json-null` ergonomics. One Fake returns `{:ok, nil}` and
# the program checks `(= result :json-null)`.
# ---------------------------------------------------------------------------

H.section("Field 5 — `:json-null` ergonomics")

H.stop_existing_registry(registry_name)
{:ok, _} = Registry.start_link(name: registry_name)
Limits.set(Map.merge(Limits.defaults(), Limits.aggregator_defaults()))

:ok =
  Registry.put_fake(
    server_name,
    H.tools_config(%{"null_tool" => null_returning_tool}),
    registry_name
  )

null_program = """
(let [resp (tool/mcp-call {:server "#{server_name}"
                           :tool "null_tool"
                           :args {}})]
  {:resp resp
   :is-json-null (= resp :json-null)
   :is-elixir-nil (nil? resp)
   :branch (if (= resp :json-null) "null-handled" "got data")})
"""

null_env = Tools.call_with_gate(%{"program" => null_program})

H.kv("isError", null_env["isError"])
H.kv("structured.result", null_env["structuredContent"]["result"])

null_calls = null_env["structuredContent"]["upstream_calls"] || []
H.kv("upstream_calls n", length(null_calls))
H.kv("upstream_calls[0].status", List.first(null_calls)["status"])

H.text(
  "Confirms §7.3: `{:ok, nil}` from the upstream surfaces as the " <>
    "`:json-null` keyword sentinel inside the sandbox. The program " <>
    "distinguishes it from a world-fault (Elixir nil) and dispatches " <>
    "on equality."
)

# ---------------------------------------------------------------------------
# Field 6: Client behavior — DEFERRED.
# ---------------------------------------------------------------------------

H.section("Field 6 — Client behavior (DEFERRED)")

H.text(
  "Out of scope for this bench: requires real MCP clients (Claude " <>
    "Desktop, Claude Code, etc.) to verify they accept the extended " <>
    "`outputSchema` carrying the `upstream_calls` array and the inline " <>
    "catalog (Phase 3). Documented as deferred in the writeup."
)

# ---------------------------------------------------------------------------
# Cleanup.
# ---------------------------------------------------------------------------

H.stop_existing_registry(registry_name)
Limits.set(Limits.defaults())

IO.puts("")
IO.puts(String.duplicate("=", 72))
IO.puts("  Done. See Plans/phase2-decision-point-results.md for the writeup.")
IO.puts(String.duplicate("=", 72))
