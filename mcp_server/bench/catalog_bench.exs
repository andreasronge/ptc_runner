# Catalog exposure benchmark: description size and tools/list latency.
#
# Measures rendered description size (characters) and rendering latency
# at 10, 30, 50, 100, and 200 tools for both inline and lazy modes.
# Outputs a markdown table suitable for pasting into a PR comment to
# justify or revise the default threshold values.
#
# Spec: `Plans/ptc-runner-mcp-catalog-exposure.md` §13.
#
# §13 coverage:
#   Covered here: description size (chars), rendering latency (median/p99).
#   Deferred (require real model/API access): approximate token cost,
#   first-shot program correctness, failure modes in lazy mode.
#
# Usage (from repo root):
#
#   mix run mcp_server/bench/catalog_bench.exs
#   mix run mcp_server/bench/catalog_bench.exs --runs=100
#   mix run mcp_server/bench/catalog_bench.exs --out=catalog_bench_report.md

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [runs: :integer, out: :string, help: :boolean],
    aliases: [h: :help, n: :runs, o: :out]
  )

if Keyword.get(opts, :help, false) do
  IO.puts("""
  Usage:
    mix run mcp_server/bench/catalog_bench.exs [options]

  Options:
    --runs=N     Number of iterations per measurement (default: 50)
    --out=PATH   Write markdown report to file
    -h, --help   Show this help
  """)

  System.halt(0)
end

runs = Keyword.get(opts, :runs, 50)
out_path = Keyword.get(opts, :out)

alias PtcRunnerMcp.{CatalogConfig, CatalogDescription}

defmodule CatalogBench.Helpers do
  @moduledoc false

  def make_entries(tool_count, servers \\ 3) do
    per_server = div(tool_count, servers)
    remainder = rem(tool_count, servers)

    Enum.map(1..servers, fn i ->
      count = if i <= remainder, do: per_server + 1, else: per_server

      %{
        name: "server_#{i}",
        tools: make_tools(count, "server_#{i}"),
        metadata: %{
          description: "Test server #{i} for benchmarking catalog rendering",
          capabilities: ["capability_a", "capability_b"]
        }
      }
    end)
  end

  defp make_tools(count, server_name) do
    Enum.map(1..max(count, 0), fn i ->
      %{
        name: "#{server_name}_tool_#{i}",
        description:
          "Performs operation #{i} on #{server_name} resources. " <>
            "Accepts standard parameters and returns structured results.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query"},
            "limit" => %{"type" => "integer", "description" => "Max results"}
          },
          "required" => ["query"]
        }
      }
    end)
  end

  def measure_us(fun, runs) do
    times =
      Enum.map(1..runs, fn _ ->
        {time_us, _result} = :timer.tc(fun)
        time_us
      end)

    sorted = Enum.sort(times)
    median = Enum.at(sorted, div(length(sorted), 2))
    p99 = Enum.at(sorted, trunc(length(sorted) * 0.99))
    mean = div(Enum.sum(times), length(times))

    %{median_us: median, p99_us: p99, mean_us: mean}
  end
end

alias CatalogBench.Helpers

tool_counts = [10, 30, 50, 100, 200]

inline_config = Map.put(CatalogConfig.defaults(), :catalog_mode, :inline)
lazy_config = Map.put(CatalogConfig.defaults(), :catalog_mode, :lazy)

IO.puts("\nCatalog Exposure Benchmark (#{runs} runs per measurement)")
IO.puts(String.duplicate("=", 60))

results =
  Enum.map(tool_counts, fn count ->
    entries = Helpers.make_entries(count)

    inline_text = CatalogDescription.render_for_entries(entries, inline_config)
    lazy_text = CatalogDescription.render_for_entries(entries, lazy_config)

    inline_chars = if inline_text, do: String.length(inline_text), else: 0
    lazy_chars = if lazy_text, do: String.length(lazy_text), else: 0

    inline_timing =
      Helpers.measure_us(
        fn -> CatalogDescription.render_for_entries(entries, inline_config) end,
        runs
      )

    lazy_timing =
      Helpers.measure_us(
        fn -> CatalogDescription.render_for_entries(entries, lazy_config) end,
        runs
      )

    auto_config = CatalogConfig.defaults()
    auto_text = CatalogDescription.render_for_entries(entries, auto_config)

    auto_mode =
      if auto_text && String.contains?(auto_text, "catalog/search-tools"),
        do: "lazy",
        else: "inline"

    %{
      tools: count,
      inline_chars: inline_chars,
      lazy_chars: lazy_chars,
      inline_median_us: inline_timing.median_us,
      inline_p99_us: inline_timing.p99_us,
      lazy_median_us: lazy_timing.median_us,
      lazy_p99_us: lazy_timing.p99_us,
      auto_mode: auto_mode
    }
  end)

size_rows =
  Enum.map_join(results, "\n", fn r ->
    "| #{r.tools} | #{r.inline_chars} | #{r.lazy_chars} | #{r.auto_mode} |"
  end)

latency_rows =
  Enum.map_join(results, "\n", fn r ->
    "| #{r.tools} | #{r.inline_median_us} | #{r.inline_p99_us} | #{r.lazy_median_us} | #{r.lazy_p99_us} |"
  end)

threshold_rows =
  Enum.map_join(results, "\n", fn r ->
    threshold_note =
      cond do
        r.tools > 40 -> "Over tool threshold (#{r.tools} > 40)"
        r.inline_chars > 12_000 -> "Over char threshold (#{r.inline_chars} > 12000)"
        true -> "Under both thresholds"
      end

    "- **#{r.tools} tools**: #{threshold_note}. Auto selects **#{r.auto_mode}**. " <>
      "Inline: #{r.inline_chars} chars, lazy: #{r.lazy_chars} chars."
  end)

report =
  """
  ## Catalog Description Size

  | Tools | Inline (chars) | Lazy (chars) | Auto mode |
  |------:|---------------:|-------------:|-----------|
  #{size_rows}

  ## Rendering Latency

  | Tools | Inline median (µs) | Inline p99 (µs) | Lazy median (µs) | Lazy p99 (µs) |
  |------:|--------------------:|----------------:|------------------:|---------------:|
  #{latency_rows}

  ## Threshold Analysis

  Default thresholds: `catalog_inline_max_chars=12000`, `catalog_inline_max_tools=40`.

  #{threshold_rows}
  """
  |> String.trim_leading()

IO.puts(report)

if out_path do
  File.write!(out_path, report)
  IO.puts("Report written to #{out_path}")
end
