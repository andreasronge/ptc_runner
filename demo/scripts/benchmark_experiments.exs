# Benchmark Experiments 1 & 7
#
# Exp 1: Slice breakdown — report auto_return vs multi_turn by category
# Exp 7: Failure taxonomy — categorize every failure by root cause
#
# Usage:
#   cd demo && mix run scripts/benchmark_experiments.exs
#   RUNS=5 mix run scripts/benchmark_experiments.exs
#   MODEL=gemini-flash mix run scripts/benchmark_experiments.exs

alias PtcDemo.{CLIBase, LispTestRunner}
alias PtcDemo.TestRunner.TestCase

CLIBase.load_dotenv()
CLIBase.ensure_api_key!()

# Short aliases for common models
model_aliases = %{
  "gemini-lite" => "openrouter:google/gemini-3.1-flash-lite-preview",
  "gemini-flash" => "openrouter:google/gemini-2.5-flash",
  "haiku" => "openrouter:anthropic/claude-3.5-haiku"
}

model_input = System.get_env("MODEL") || "gemini-lite"
model = Map.get(model_aliases, model_input, model_input)
runs = String.to_integer(System.get_env("RUNS") || "3")

IO.puts("=== Benchmark Experiments 1 & 7 ===")
IO.puts("Model: #{model}")
IO.puts("Runs:  #{runs}\n")

# --- Categorize test cases by slice ---

# Build the full test case list with indices (same order as test runner)
all_cases =
  (TestCase.common_test_cases() ++
     TestCase.lisp_specific_cases() ++
     TestCase.multi_turn_cases() ++
     TestCase.plan_cases())
  |> Enum.with_index(1)

single_shot_indices =
  all_cases
  |> Enum.filter(fn {tc, _i} -> Map.get(tc, :max_turns, 1) == 1 end)
  |> Enum.map(fn {_tc, i} -> i end)
  |> MapSet.new()

plan_indices =
  all_cases
  |> Enum.filter(fn {tc, _i} -> Map.has_key?(tc, :plan) end)
  |> Enum.map(fn {_tc, i} -> i end)
  |> MapSet.new()

multi_turn_indices =
  all_cases
  |> Enum.filter(fn {tc, i} ->
    Map.get(tc, :max_turns, 1) > 1 and not MapSet.member?(plan_indices, i)
  end)
  |> Enum.map(fn {_tc, i} -> i end)
  |> MapSet.new()

IO.puts(
  "Slices: #{MapSet.size(single_shot_indices)} single-shot, #{MapSet.size(multi_turn_indices)} multi-turn, #{MapSet.size(plan_indices)} plan\n"
)

# --- Failure taxonomy classifier ---

defmodule FailureTaxonomy do
  @doc "Classify a failed test result into a failure category."
  def classify(result) do
    error = result[:error] || ""
    trace = result[:trace]
    all_programs = result[:all_programs] || []

    cond do
      # Parse/syntax errors
      String.contains?(error, "parse") or String.contains?(error, "Parse") or
          String.contains?(error, "syntax") ->
        :parse_error

      # Max turns exceeded
      String.contains?(error, "MaxTurnsExceeded") or
          String.contains?(error, "max_turns") ->
        :max_turns_exceeded

      # Control flow mistakes (return + println same turn, etc.)
      String.contains?(error, "return") and String.contains?(error, "println") ->
        :control_flow

      # Cannot shadow builtin
      String.contains?(error, "cannot_shadow_builtin") ->
        :shadow_builtin

      # Type/runtime errors in generated code
      String.contains?(error, "type_error") or
        String.contains?(error, "execution_error") or
        String.contains?(error, "Undefined variable") or
          String.contains?(error, "Error:") ->
        :runtime_error

      # Wrong key names (has the right structure/values but wrong keys)
      String.contains?(error, "Expected keys") or
          String.contains?(error, "missing") ->
        :wrong_keys

      # Wrong value (right type, wrong answer)
      String.contains?(error, "Expected") and
          (String.contains?(error, "got") or String.contains?(error, "Got")) ->
        :wrong_value

      # Timeout
      String.contains?(error, "timeout") or String.contains?(error, "Timeout") ->
        :timeout

      # Signature/type mismatch
      String.contains?(error, "Wrong type") ->
        :type_mismatch

      # No result returned
      String.contains?(error, "No result") ->
        :no_result

      # Query failed (LLM error, etc.)
      String.contains?(error, "Query failed") ->
        :query_failed

      # Catch-all
      true ->
        :other
    end
  end

  @doc "Human-readable label for a failure category."
  def label(:parse_error), do: "Parse/syntax error"
  def label(:max_turns_exceeded), do: "Max turns exceeded"
  def label(:control_flow), do: "Control flow (return+println)"
  def label(:shadow_builtin), do: "Cannot shadow builtin"
  def label(:runtime_error), do: "Runtime error in generated code"
  def label(:wrong_keys), do: "Wrong map keys"
  def label(:wrong_value), do: "Wrong value/threshold"
  def label(:timeout), do: "Timeout"
  def label(:type_mismatch), do: "Type mismatch"
  def label(:no_result), do: "No result returned"
  def label(:query_failed), do: "Query/LLM failure"
  def label(:other), do: "Other/unclassified"
end

# --- Run benchmarks ---

prompts = [:multi_turn, :auto_return]

all_results =
  Enum.map(prompts, fn prompt ->
    IO.puts("--- Running #{prompt} (#{runs} runs) ---")

    summary =
      LispTestRunner.run_all(
        prompt: prompt,
        model: model,
        runs: runs,
        verbose: false
      )

    IO.puts("  #{summary.passed}/#{summary.total} passed\n")
    {prompt, summary}
  end)

# ═══════════════════════════════════════════════════════════════
# EXPERIMENT 1: Slice Breakdown
# ═══════════════════════════════════════════════════════════════

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("EXPERIMENT 1: Slice Breakdown")
IO.puts(String.duplicate("=", 70))

slices = [
  {"Single-shot", single_shot_indices},
  {"Multi-turn (no plan)", multi_turn_indices},
  {"Plan mode", plan_indices}
]

for {slice_name, indices} <- slices do
  IO.puts("\n  #{slice_name} (#{MapSet.size(indices)} tests × #{runs} runs):")

  header =
    "    " <>
      String.pad_trailing("Prompt", 16) <>
      String.pad_leading("Pass", 10) <>
      String.pad_leading("Rate", 8) <>
      String.pad_leading("Fails", 8)

  IO.puts(header)
  IO.puts("    " <> String.duplicate("-", 42))

  for {prompt, summary} <- all_results do
    slice_results =
      Enum.filter(summary.results, fn r -> MapSet.member?(indices, r.index) end)

    passed = Enum.count(slice_results, & &1.passed)
    failed = Enum.count(slice_results, &(!&1.passed))
    total = length(slice_results)
    rate = if total > 0, do: Float.round(passed / total * 100, 1), else: 0.0

    IO.puts(
      "    " <>
        String.pad_trailing("#{prompt}", 16) <>
        String.pad_leading("#{passed}/#{total}", 10) <>
        String.pad_leading("#{rate}%", 8) <>
        String.pad_leading("#{failed}", 8)
    )
  end
end

# ═══════════════════════════════════════════════════════════════
# EXPERIMENT 7: Failure Taxonomy
# ═══════════════════════════════════════════════════════════════

IO.puts("\n\n" <> String.duplicate("=", 70))
IO.puts("EXPERIMENT 7: Failure Taxonomy")
IO.puts(String.duplicate("=", 70))

for {prompt, summary} <- all_results do
  failures = Enum.reject(summary.results, & &1.passed)

  IO.puts("\n  #{prompt} — #{length(failures)} failures across #{runs} runs:")

  if failures == [] do
    IO.puts("    (none)")
  else
    # Classify and group
    classified =
      failures
      |> Enum.map(fn r -> {FailureTaxonomy.classify(r), r} end)
      |> Enum.group_by(fn {cat, _r} -> cat end, fn {_cat, r} -> r end)
      |> Enum.sort_by(fn {_cat, rs} -> -length(rs) end)

    for {category, results} <- classified do
      IO.puts("    #{FailureTaxonomy.label(category)}: #{length(results)}")

      for r <- Enum.take(results, 3) do
        error_preview = String.slice(r.error || "?", 0, 60)
        IO.puts("      ##{r.index}: #{error_preview}")
      end

      if length(results) > 3 do
        IO.puts("      ... +#{length(results) - 3} more")
      end
    end
  end
end

# ═══════════════════════════════════════════════════════════════
# Per-test delta (paired comparison)
# ═══════════════════════════════════════════════════════════════

IO.puts("\n\n" <> String.duplicate("=", 70))
IO.puts("PER-TEST COMPARISON (tests that differ between modes)")
IO.puts(String.duplicate("=", 70))

[{_mt_prompt, mt_summary}, {_ar_prompt, ar_summary}] = all_results

# Group results by test index across runs
mt_by_index = Enum.group_by(mt_summary.results, & &1.index)
ar_by_index = Enum.group_by(ar_summary.results, & &1.index)

all_indices = MapSet.union(MapSet.new(Map.keys(mt_by_index)), MapSet.new(Map.keys(ar_by_index)))

diffs =
  all_indices
  |> Enum.sort()
  |> Enum.map(fn idx ->
    mt_results = Map.get(mt_by_index, idx, [])
    ar_results = Map.get(ar_by_index, idx, [])
    mt_pass = Enum.count(mt_results, & &1.passed)
    ar_pass = Enum.count(ar_results, & &1.passed)
    mt_total = length(mt_results)
    ar_total = length(ar_results)
    desc = (List.first(mt_results) || List.first(ar_results))[:description] || "?"

    slice =
      cond do
        MapSet.member?(plan_indices, idx) -> "plan"
        MapSet.member?(multi_turn_indices, idx) -> "multi"
        true -> "single"
      end

    {idx, slice, desc, mt_pass, mt_total, ar_pass, ar_total}
  end)
  |> Enum.filter(fn {_idx, _slice, _desc, mt_pass, mt_total, ar_pass, ar_total} ->
    # Show tests where pass rates differ
    mt_total > 0 and ar_total > 0 and mt_pass / mt_total != ar_pass / ar_total
  end)

if diffs == [] do
  IO.puts("\n  No per-test differences found (identical results).")
else
  IO.puts(
    "\n  " <>
      String.pad_trailing("#", 4) <>
      String.pad_trailing("Slice", 8) <>
      String.pad_trailing("multi_turn", 12) <>
      String.pad_trailing("auto_return", 12) <>
      "Description"
  )

  IO.puts("  " <> String.duplicate("-", 70))

  for {idx, slice, desc, mt_pass, mt_total, ar_pass, ar_total} <- diffs do
    mt_str = "#{mt_pass}/#{mt_total}"
    ar_str = "#{ar_pass}/#{ar_total}"
    delta = if ar_pass / ar_total > mt_pass / mt_total, do: " ✓", else: " ✗"

    IO.puts(
      "  " <>
        String.pad_trailing("#{idx}", 4) <>
        String.pad_trailing(slice, 8) <>
        String.pad_trailing(mt_str, 12) <>
        String.pad_trailing(ar_str <> delta, 12) <>
        String.slice(desc, 0, 40)
    )
  end
end

IO.puts("\nDone.")
