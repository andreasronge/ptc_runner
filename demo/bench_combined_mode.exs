# Benchmark: native-only vs combined-mode (text + ptc_lisp_execute) on a
# large-result workload.
#
# Demonstrates the value-prop of combined mode: when a tool returns more
# data than the model can comfortably consume natively, the
# preview-and-escalate-to-PTC path should produce a faster / cheaper /
# smaller-context run than the pure-native path.
#
# Workload: a `search_logs/1` tool returns N rows shaped as
#   %{id, timestamp, message}. The LLM is asked an aggregate question
# ("How many entries mention 'error'?"). The native-only path has to
# slurp every row into the model context. The combined-mode path sees a
# metadata preview and escalates to ptc_lisp_execute, which counts the
# rows from the cached full result without round-tripping them through
# the LLM.
#
# Usage:
#   mix run demo/bench_combined_mode.exs                # default N=1000
#   mix run demo/bench_combined_mode.exs 5000           # N=5000
#   mix run demo/bench_combined_mode.exs --n=10000 --model=haiku
#   mix run demo/bench_combined_mode.exs --runs=3
#   mix run demo/bench_combined_mode.exs --csv          # also emit CSV
#
# Exits with a skip-message (status 0) if no API key is set.

alias PtcRunner.SubAgent

PtcDemo.CLIBase.load_dotenv()

# ---------------------------------------------------------------------------
# CLI parsing — accept positional N or --n=N, plus --model / --runs / --csv.
# ---------------------------------------------------------------------------

{opts, positional, _} =
  OptionParser.parse(System.argv(),
    strict: [n: :integer, model: :string, runs: :integer, csv: :boolean]
  )

n =
  cond do
    is_integer(opts[:n]) -> opts[:n]
    match?([_ | _], positional) -> positional |> hd() |> String.to_integer()
    true -> 1000
  end

model = opts[:model] || "gemini-flash-lite"
runs = opts[:runs] || 1
emit_csv? = opts[:csv] == true

# ---------------------------------------------------------------------------
# Skip-with-message if no API key (matches demo/ pattern).
# ---------------------------------------------------------------------------

has_key? =
  System.get_env("OPENROUTER_API_KEY") || System.get_env("ANTHROPIC_API_KEY") ||
    System.get_env("OPENAI_API_KEY")

unless has_key? do
  IO.puts("""

  SKIP: no API key found.

  Set OPENROUTER_API_KEY (recommended for this benchmark — gemini-flash-lite
  default model is OpenRouter-only) or ANTHROPIC_API_KEY / OPENAI_API_KEY,
  then re-run:

    OPENROUTER_API_KEY=sk-or-v1-... mix run demo/bench_combined_mode.exs

  """)

  System.halt(0)
end

# ---------------------------------------------------------------------------
# Synthetic dataset + tool. Deterministic for reproducibility.
# ---------------------------------------------------------------------------

base_ts = ~U[2026-05-06 00:00:00Z]

# Roughly 10% of rows mention "error", giving the LLM a non-trivial answer.
rows =
  for i <- 1..n do
    msg =
      cond do
        rem(i, 10) == 0 -> "service degraded: error code 42 in worker pool"
        rem(i, 7) == 0 -> "warning: queue depth above threshold"
        true -> "info: request handled in #{rem(i, 50) + 1}ms"
      end

    %{
      "id" => i,
      "timestamp" => DateTime.add(base_ts, i, :second) |> DateTime.to_iso8601(),
      "message" => msg
    }
  end

search_logs = fn _args ->
  # Args ignored — we always return the full corpus for both runs so the
  # only variable is HOW the corpus reaches (or doesn't reach) the model.
  rows
end

prompt =
  "Use the search_logs tool to fetch recent log entries (any query, e.g. \"recent\"), " <>
    "then answer: how many entries contain the word \"error\" in their message? " <>
    "Reply with a single integer."

# ---------------------------------------------------------------------------
# Per-run measurement helper. Wraps the LLM callback so we can:
#   - count LLM requests (turns) reliably across providers
#   - capture the byte size of each tool-result message the LLM saw
# ---------------------------------------------------------------------------

run_once = fn label, agent ->
  parent = self()
  base_llm = PtcRunner.LLM.callback(model)

  wrapped_llm = fn input ->
    # Each :tool message in `input.messages` is a tool result the LLM has
    # been shown by the runtime. Sum their byte sizes — for native-only
    # this is the full JSON-encoded result; for combined-mode this is
    # the metadata preview (or the ptc_lisp_execute response, which is
    # also small). Send it back to the parent process for aggregation.
    tool_bytes =
      input.messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.map(fn m ->
        case m.content do
          c when is_binary(c) -> byte_size(c)
          other -> other |> inspect() |> byte_size()
        end
      end)
      |> Enum.sum()

    send(parent, {:llm_call, tool_bytes})
    base_llm.(input)
  end

  t0 = System.monotonic_time(:millisecond)
  result = SubAgent.run(agent, llm: wrapped_llm)
  wall_ms = System.monotonic_time(:millisecond) - t0

  # Drain accumulated llm_call messages.
  {llm_calls, max_tool_bytes} =
    Stream.unfold(0, fn count ->
      receive do
        {:llm_call, bytes} -> {{count + 1, bytes}, count + 1}
      after
        0 -> nil
      end
    end)
    |> Enum.reduce({0, 0}, fn {calls, bytes}, {_, max_b} ->
      {calls, max(max_b, bytes)}
    end)

  step =
    case result do
      {:ok, s} -> s
      {:error, s} -> s
    end

  ok? = match?({:ok, _}, result)

  in_tok = (step.usage && Map.get(step.usage, :input_tokens)) || 0
  out_tok = (step.usage && Map.get(step.usage, :output_tokens)) || 0
  llm_requests = (step.usage && Map.get(step.usage, :llm_requests)) || llm_calls
  turns = if step.turns, do: length(step.turns), else: llm_requests

  %{
    label: label,
    ok?: ok?,
    wall_ms: wall_ms,
    in_tok: in_tok,
    out_tok: out_tok,
    llm_requests: llm_requests,
    turns: turns,
    tool_bytes: max_tool_bytes,
    return: step.return,
    fail: step.fail
  }
end

# ---------------------------------------------------------------------------
# Build the two agents.
# ---------------------------------------------------------------------------

native_only_agent = fn ->
  SubAgent.new(
    prompt: prompt,
    output: :text,
    max_turns: 4,
    tools: %{
      "search_logs" =>
        {search_logs,
         signature: "(query :string) -> [:any]",
         description: "Search log entries. Returns a list of log rows.",
         expose: :native,
         cache: false}
    }
  )
end

combined_mode_agent = fn ->
  SubAgent.new(
    prompt: prompt,
    output: :text,
    ptc_transport: :tool_call,
    max_turns: 6,
    tools: %{
      "search_logs" =>
        {search_logs,
         signature: "(query :string) -> [:any]",
         description: "Search log entries. Returns a list of log rows.",
         expose: :both,
         cache: true,
         native_result: [preview: :metadata]}
    }
  )
end

# ---------------------------------------------------------------------------
# Run the benchmark. Per-mode N runs; report per-run rows + averages.
# ---------------------------------------------------------------------------

IO.puts("\nBenchmark: combined mode vs native-only")
IO.puts("=======================================")
IO.puts("Model:    #{model}")
IO.puts("Rows (N): #{n}")
IO.puts("Runs:     #{runs}")
IO.puts("")

modes = [
  {"native-only", native_only_agent},
  {"combined", combined_mode_agent}
]

all_results =
  for {label, agent_builder} <- modes,
      run_idx <- 1..runs do
    IO.write("  running #{String.pad_trailing(label, 12)} run #{run_idx}/#{runs} ... ")
    r = run_once.(label, agent_builder.())

    status =
      cond do
        r.ok? -> "ok"
        r.fail -> "fail (#{inspect(r.fail.reason || r.fail.message)})"
        true -> "fail"
      end

    IO.puts("#{status} in #{r.wall_ms}ms (#{r.turns} turns, #{r.tool_bytes}B tool)")
    Map.put(r, :run, run_idx)
  end

# Group by mode and average.
mean = fn xs -> if xs == [], do: 0.0, else: Enum.sum(xs) / length(xs) end

aggregates =
  all_results
  |> Enum.group_by(& &1.label)
  |> Enum.map(fn {label, rs} ->
    %{
      label: label,
      pass: Enum.count(rs, & &1.ok?),
      runs: length(rs),
      wall_ms: round(mean.(Enum.map(rs, & &1.wall_ms))),
      in_tok: round(mean.(Enum.map(rs, & &1.in_tok))),
      out_tok: round(mean.(Enum.map(rs, & &1.out_tok))),
      turns: Float.round(mean.(Enum.map(rs, & &1.turns)), 1),
      llm_requests: Float.round(mean.(Enum.map(rs, & &1.llm_requests)), 1),
      tool_bytes: round(mean.(Enum.map(rs, & &1.tool_bytes)))
    }
  end)
  # Stable order: native-only first, combined second.
  |> Enum.sort_by(fn a -> if a.label == "native-only", do: 0, else: 1 end)

# ---------------------------------------------------------------------------
# Markdown table for paste-into-PR.
# ---------------------------------------------------------------------------

IO.puts("\nResults (N=#{n}, model=#{model}, runs=#{runs}):\n")

IO.puts(
  "| Mode             | Pass | Wall (ms) | LLM in | LLM out | Turns | Tool result bytes |"
)

IO.puts(
  "| ---------------- | ---- | --------- | ------ | ------- | ----- | ----------------- |"
)

for a <- aggregates do
  IO.puts(
    "| " <>
      String.pad_trailing(a.label, 16) <>
      " | " <>
      String.pad_trailing("#{a.pass}/#{a.runs}", 4) <>
      " | " <>
      String.pad_trailing(Integer.to_string(a.wall_ms), 9) <>
      " | " <>
      String.pad_trailing(Integer.to_string(a.in_tok), 6) <>
      " | " <>
      String.pad_trailing(Integer.to_string(a.out_tok), 7) <>
      " | " <>
      String.pad_trailing(:erlang.float_to_binary(a.turns, decimals: 1), 5) <>
      " | " <>
      String.pad_trailing(Integer.to_string(a.tool_bytes), 17) <>
      " |"
  )
end

# ---------------------------------------------------------------------------
# Optional CSV (one line per individual run, machine-friendly).
# ---------------------------------------------------------------------------

if emit_csv? do
  IO.puts("\n--- CSV ---")
  IO.puts("mode,run,ok,wall_ms,in_tok,out_tok,turns,llm_requests,tool_bytes")

  for r <- all_results do
    IO.puts(
      "#{r.label},#{r.run},#{r.ok?},#{r.wall_ms},#{r.in_tok},#{r.out_tok},#{r.turns},#{r.llm_requests},#{r.tool_bytes}"
    )
  end
end

# ---------------------------------------------------------------------------
# Interpretation paragraph.
# ---------------------------------------------------------------------------

native = Enum.find(aggregates, &(&1.label == "native-only"))
combined = Enum.find(aggregates, &(&1.label == "combined"))

IO.puts("\nInterpretation:\n")

if native && combined do
  bytes_delta = native.tool_bytes - combined.tool_bytes
  in_tok_delta = native.in_tok - combined.in_tok
  wall_delta = combined.wall_ms - native.wall_ms

  bytes_summary =
    if bytes_delta > 0 do
      "Combined mode shrank the tool-result content seen by the LLM by " <>
        "#{bytes_delta} bytes (#{native.tool_bytes} -> #{combined.tool_bytes}); " <>
        "the full result stayed in the runtime cache."
    else
      "Combined mode did NOT shrink the tool-result content seen by the LLM " <>
        "(#{native.tool_bytes} vs #{combined.tool_bytes}). For N=#{n} the native " <>
        "result may already be small enough that escalation does not help."
    end

  in_tok_summary =
    cond do
      in_tok_delta > 0 ->
        "Input-token cost dropped by #{in_tok_delta} tokens on average " <>
          "(#{native.in_tok} -> #{combined.in_tok})."

      in_tok_delta < 0 ->
        "Input-token cost grew by #{-in_tok_delta} tokens on average " <>
          "(#{native.in_tok} -> #{combined.in_tok}) — the extra turn / system-prompt " <>
          "card overhead outweighed the preview savings at N=#{n}."

      true ->
        "Input-token cost was unchanged."
    end

  wall_summary =
    cond do
      wall_delta < 0 ->
        "Wall time improved by #{-wall_delta}ms (#{native.wall_ms}ms -> #{combined.wall_ms}ms)."

      wall_delta > 0 ->
        "Wall time was #{wall_delta}ms slower for combined mode " <>
          "(#{native.wall_ms}ms -> #{combined.wall_ms}ms). The extra LLM turn " <>
          "(preview -> ptc_lisp_execute -> text) costs round-trips that only pay " <>
          "off once N is large enough that the native context cost dominates."

      true ->
        "Wall time was unchanged."
    end

  turn_summary =
    "Turns: native-only=#{native.turns} vs combined=#{combined.turns}. Combined " <>
      "mode pays one extra turn (preview seen, then ptc_lisp_execute) in exchange " <>
      "for the model never having to read raw rows."

  IO.puts("  - " <> bytes_summary)
  IO.puts("  - " <> in_tok_summary)
  IO.puts("  - " <> wall_summary)
  IO.puts("  - " <> turn_summary)

  IO.puts("""

  Guidance for users picking a path:
    Combined mode wins on input-token spend and context-pressure as N grows.
    For small N the extra turn can make it slower in wall time. Choose
    combined mode when raw tool results would push the model toward its
    context window or when token spend dominates run cost; choose native-only
    when results are reliably small and an extra round-trip is unaffordable.
  """)
else
  IO.puts("  (could not compute deltas — at least one mode produced no aggregates)")
end
