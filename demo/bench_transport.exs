# Quick sanity test: compare ptc_transport :content vs :tool_call
#
# Usage:
#   mix run bench_transport.exs                    # all queries (basic + tool), 1 run
#   mix run bench_transport.exs --runs=5           # repeat each cell 5x
#   mix run bench_transport.exs --only=tool        # tool-using only
#   mix run bench_transport.exs --only=basic       # in-memory only
#   mix run bench_transport.exs --model=haiku      # override model

alias PtcDemo.{SampleData, SearchTool}
alias PtcRunner.SubAgent

PtcDemo.CLIBase.load_dotenv()

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [model: :string, only: :string, runs: :integer]
  )

model = opts[:model] || "gemini-flash-lite"
only = opts[:only]
runs = opts[:runs] || 1

datasets = %{
  "products" => SampleData.products(),
  "orders" => SampleData.orders(),
  "employees" => SampleData.employees(),
  "expenses" => SampleData.expenses()
}

context_descriptions = SampleData.context_descriptions()

tools = %{
  "search" => &SearchTool.search/1,
  "fetch" => &SearchTool.fetch/1
}

basic_queries = [
  %{
    label: "count products",
    q: "How many products are there?",
    signature: "(question :string) -> :int",
    max_turns: 3,
    tools: false,
    check: fn v -> v == 500 end
  },
  %{
    label: "delivered orders",
    q: "How many orders have status 'delivered'?",
    signature: "(question :string) -> :int",
    max_turns: 3,
    tools: false,
    check: fn v -> is_integer(v) and v >= 0 end
  },
  %{
    label: "engineering salary",
    q: "What is the total salary for the engineering department?",
    signature: "(question :string) -> :float",
    max_turns: 3,
    tools: false,
    check: fn v -> is_number(v) and v > 0 end
  }
]

tool_queries = [
  %{
    label: "search+pmap fetch",
    q:
      "Search for 'security' policies, then fetch the full content for ALL found documents in parallel. " <>
        "Return a list of the full content of these documents.",
    signature: "(question :string) -> [:any]",
    max_turns: 3,
    tools: true,
    check: fn v -> is_list(v) and length(v) > 0 end
  },
  %{
    label: "find WFH+reimb doc",
    q:
      "Use the search tool to find the policy document that covers BOTH 'remote work' AND 'expense reimbursement'. " <>
        "Return the document title.",
    signature: "(question :string) -> :string",
    max_turns: 6,
    tools: true,
    check: fn v -> v == "Policy WFH-2024-REIMB" end
  },
  %{
    label: "cert reimb (decoy)",
    q:
      "Find the policy document about reimbursement for professional certifications. " <>
        "Search for relevant documents, then fetch the content of candidates to find " <>
        "the one specifically about certification reimbursement (not training budget). " <>
        "Return the document ID.",
    signature: "(question :string) -> :string",
    max_turns: 6,
    tools: true,
    check: fn v -> v == "DOC-020" end
  },
  %{
    label: "ergonomics doc",
    q:
      "Fetch documents DOC-001 and DOC-002. Compare their content. " <>
        "Which one mentions 'ergonomics'? Return its document ID.",
    signature: "(question :string) -> :string",
    max_turns: 4,
    tools: true,
    check: fn v -> v == "DOC-002" end
  }
]

queries =
  case only do
    "tool" -> tool_queries
    "basic" -> basic_queries
    _ -> basic_queries ++ tool_queries
  end

run_once = fn transport, q ->
  agent =
    SubAgent.new(
      name: "bench_#{transport}",
      prompt: q.q,
      signature: q.signature,
      max_turns: q.max_turns,
      tools: if(q.tools, do: tools, else: %{}),
      context_descriptions: context_descriptions,
      ptc_transport: transport
    )

  t0 = System.monotonic_time(:millisecond)
  result = SubAgent.run(agent, llm: model, context: datasets)
  dt = System.monotonic_time(:millisecond) - t0

  {ok?, step, err} =
    case result do
      {:ok, s} -> {q.check.(s.return), s, nil}
      {:error, s} -> {false, s, (s.fail && (s.fail.reason || s.fail.message)) || :unknown}
    end

  %{
    ok: ok?,
    turns: length(step.turns || []),
    in_tok: get_in(step.usage, [:input_tokens]) || 0,
    out_tok: get_in(step.usage, [:output_tokens]) || 0,
    ms: dt,
    err: err
  }
end

mean = fn xs -> if xs == [], do: 0.0, else: Enum.sum(xs) / length(xs) end

IO.puts("\nModel: #{model}   Runs per cell: #{runs}\n")

# Header (averages, with pass count)
IO.puts(
  "query                  transport   pass    turns    ms       in_tok    out_tok"
)

IO.puts(String.duplicate("-", 80))

# Run all cells; report aggregated stats per (query, transport)
cells =
  for query <- queries, transport <- [:content, :tool_call] do
    IO.write("  running #{query.label} / #{transport} ")

    runs_data =
      for i <- 1..runs do
        IO.write(".")
        r = run_once.(transport, query)
        if not r.ok, do: IO.write("✗"), else: IO.write("")
        _ = i
        r
      end

    IO.puts("")

    pass = Enum.count(runs_data, & &1.ok)
    turns_avg = mean.(Enum.map(runs_data, & &1.turns))
    ms_avg = mean.(Enum.map(runs_data, & &1.ms))
    in_avg = mean.(Enum.map(runs_data, & &1.in_tok))
    out_avg = mean.(Enum.map(runs_data, & &1.out_tok))
    ms_min = Enum.map(runs_data, & &1.ms) |> Enum.min()
    ms_max = Enum.map(runs_data, & &1.ms) |> Enum.max()

    %{
      label: query.label,
      transport: transport,
      pass: pass,
      runs: runs,
      turns_avg: turns_avg,
      ms_avg: ms_avg,
      ms_min: ms_min,
      ms_max: ms_max,
      in_avg: in_avg,
      out_avg: out_avg,
      runs_data: runs_data
    }
  end

IO.puts("")

IO.puts(
  "query                  transport   pass    turns    ms (avg, min-max)       in_tok    out_tok"
)

IO.puts(String.duplicate("-", 100))

Enum.each(cells, fn c ->
  IO.puts(
    String.pad_trailing(c.label, 22) <>
      " " <>
      String.pad_trailing(to_string(c.transport), 11) <>
      " " <>
      String.pad_trailing("#{c.pass}/#{c.runs}", 7) <>
      " " <>
      String.pad_trailing(:erlang.float_to_binary(c.turns_avg, decimals: 1), 8) <>
      " " <>
      String.pad_trailing(
        "#{round(c.ms_avg)} (#{c.ms_min}-#{c.ms_max})",
        23
      ) <>
      " " <>
      String.pad_trailing(Integer.to_string(round(c.in_avg)), 9) <>
      " " <>
      String.pad_trailing(Integer.to_string(round(c.out_avg)), 9)
  )
end)

# Per-query delta (tool_call vs content)
IO.puts("\nPer-query delta (tool_call - content, averages):")

cells
|> Enum.group_by(& &1.label)
|> Enum.each(fn {label, rows} ->
  c = Enum.find(rows, &(&1.transport == :content))
  tc = Enum.find(rows, &(&1.transport == :tool_call))

  IO.puts(
    "  " <>
      String.pad_trailing(label, 22) <>
      " pass: #{c.pass}/#{c.runs}->#{tc.pass}/#{tc.runs}  " <>
      "turns: #{:erlang.float_to_binary(c.turns_avg, decimals: 1)}->#{:erlang.float_to_binary(tc.turns_avg, decimals: 1)}  " <>
      "ms: #{round(c.ms_avg)}->#{round(tc.ms_avg)} (Δ#{round(tc.ms_avg - c.ms_avg)})  " <>
      "in_tok: #{round(c.in_avg)}->#{round(tc.in_avg)}  " <>
      "out_tok: #{round(c.out_avg)}->#{round(tc.out_avg)}"
  )
end)

# Aggregate across all queries
agg = fn cells, t ->
  rows = Enum.filter(cells, &(&1.transport == t))
  pass = Enum.sum(Enum.map(rows, & &1.pass))
  total_runs = Enum.sum(Enum.map(rows, & &1.runs))
  ms_total = Enum.sum(Enum.map(rows, &(&1.ms_avg * &1.runs)))
  in_total = Enum.sum(Enum.map(rows, &(&1.in_avg * &1.runs)))
  out_total = Enum.sum(Enum.map(rows, &(&1.out_avg * &1.runs)))

  {pass, total_runs, round(ms_total), round(in_total), round(out_total)}
end

{c_pass, c_runs, c_ms, c_in, c_out} = agg.(cells, :content)
{tc_pass, tc_runs, tc_ms, tc_in, tc_out} = agg.(cells, :tool_call)

IO.puts("\nAggregate over #{length(queries)} queries × #{runs} runs:")
IO.puts("  :content    #{c_pass}/#{c_runs} pass   total #{c_ms}ms   in_tok=#{c_in}   out_tok=#{c_out}")
IO.puts("  :tool_call  #{tc_pass}/#{tc_runs} pass   total #{tc_ms}ms   in_tok=#{tc_in}   out_tok=#{tc_out}")
