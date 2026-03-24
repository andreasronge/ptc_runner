# Benchmark Experiments
#
# Exp 1: Slice breakdown — report single_shot vs explicit_return by category
# Exp 2: Per-turn metrics — turns on pass, tokens/pass, budget exhaustion
# Exp 3: Fisher exact test — statistical significance of pass rate differences
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

# --- Per-turn metrics helpers ---

defmodule PerTurnMetrics do
  @doc "Extract per-turn metrics from a list of test results that include a step field."
  def compute(results) do
    passed = Enum.filter(results, & &1.passed)
    failed = Enum.reject(results, & &1.passed)

    # Mean turns on pass (how efficient is the variant?)
    turns_on_pass =
      passed
      |> Enum.map(fn r -> get_turns_count(r) end)
      |> Enum.reject(&is_nil/1)

    mean_turns_on_pass =
      if turns_on_pass != [], do: Enum.sum(turns_on_pass) / length(turns_on_pass), else: nil

    # Tokens per successful run
    tokens_on_pass =
      passed
      |> Enum.map(fn r -> get_total_tokens(r) end)
      |> Enum.reject(&is_nil/1)

    mean_tokens_on_pass =
      if tokens_on_pass != [], do: Enum.sum(tokens_on_pass) / length(tokens_on_pass), else: nil

    # Budget exhaustion rate (max_turns_exceeded failures / total)
    budget_exhausted =
      Enum.count(failed, fn r ->
        error = r[:error] || ""
        String.contains?(error, "MaxTurnsExceeded") or String.contains?(error, "max_turns")
      end)

    total = length(results)
    budget_exhaustion_rate = if total > 0, do: budget_exhausted / total * 100, else: 0.0

    # First-turn validity (did turn 1 produce a parseable program?)
    first_turn_valid =
      results
      |> Enum.map(fn r -> first_turn_has_program?(r) end)
      |> Enum.reject(&is_nil/1)

    first_turn_validity =
      if first_turn_valid != [] do
        Enum.count(first_turn_valid, & &1) / length(first_turn_valid) * 100
      else
        nil
      end

    # Salvage rate (of runs with errors in any turn, how many still passed?)
    runs_with_errors =
      Enum.filter(results, fn r ->
        turns = get_turns(r)
        turns != nil and Enum.any?(turns, fn t -> not t.success? end)
      end)

    salvage_rate =
      if runs_with_errors != [] do
        Enum.count(runs_with_errors, & &1.passed) / length(runs_with_errors) * 100
      else
        nil
      end

    %{
      mean_turns_on_pass: mean_turns_on_pass,
      mean_tokens_on_pass: mean_tokens_on_pass,
      budget_exhaustion_rate: budget_exhaustion_rate,
      first_turn_validity: first_turn_validity,
      salvage_rate: salvage_rate,
      total: total,
      passed: length(passed)
    }
  end

  defp get_turns_count(r) do
    case r[:step] do
      %{usage: %{turns: turns}} when is_integer(turns) -> turns
      %{turns: turns} when is_list(turns) -> length(turns)
      _ -> r[:attempts]
    end
  end

  defp get_total_tokens(r) do
    case r[:step] do
      %{usage: %{total_tokens: tokens}} when is_integer(tokens) and tokens > 0 -> tokens
      _ -> nil
    end
  end

  defp get_turns(r) do
    case r[:step] do
      %{turns: turns} when is_list(turns) -> turns
      _ -> nil
    end
  end

  defp first_turn_has_program?(r) do
    case get_turns(r) do
      [first | _] -> first.program != nil
      _ -> nil
    end
  end
end

# --- Fisher exact test (one-sided) ---

defmodule FisherExact do
  @doc """
  Two-sided Fisher exact test for 2×2 contingency table.
  Returns p-value. Uses hypergeometric distribution.

  Table:  [[a, b], [c, d]]
    a = variant1 pass, b = variant1 fail
    c = variant2 pass, d = variant2 fail
  """
  def p_value(a, b, c, d) do
    # For small tables, compute exact probability via hypergeometric
    # p = C(a+b,a) * C(c+d,c) / C(n,a+c) where n = a+b+c+d
    n = a + b + c + d
    observed_p = hypergeometric_pmf(a, b, c, d, n)

    # Two-sided: sum probabilities of all tables as extreme or more extreme
    # Walk all possible values of a (0..min(a+b, a+c))
    max_a = min(a + b, a + c)

    0..max_a
    |> Enum.map(fn a_i ->
      b_i = a + b - a_i
      c_i = a + c - a_i
      d_i = d + b - b_i

      if b_i >= 0 and c_i >= 0 and d_i >= 0 do
        hypergeometric_pmf(a_i, b_i, c_i, d_i, n)
      else
        0.0
      end
    end)
    |> Enum.filter(fn p -> p <= observed_p * 1.0000001 end)
    |> Enum.sum()
    |> min(1.0)
  end

  defp hypergeometric_pmf(a, b, c, d, n) do
    # log-space to avoid overflow: log(C(a+b,a)) + log(C(c+d,c)) - log(C(n,a+c))
    log_p = log_comb(a + b, a) + log_comb(c + d, c) - log_comb(n, a + c)
    :math.exp(log_p)
  end

  defp log_comb(n, k) when k < 0 or k > n, do: -1.0e300
  defp log_comb(_n, 0), do: 0.0
  defp log_comb(n, k), do: log_factorial(n) - log_factorial(k) - log_factorial(n - k)

  defp log_factorial(0), do: 0.0

  defp log_factorial(n) when n > 0,
    do: Enum.reduce(1..n, 0.0, fn i, acc -> acc + :math.log(i) end)

  @doc "Wilson score 95% confidence interval for a proportion."
  def wilson_interval(passed, total) when total > 0 do
    z = 1.96
    p_hat = passed / total
    denom = 1 + z * z / total
    center = (p_hat + z * z / (2 * total)) / denom
    spread = z * :math.sqrt((p_hat * (1 - p_hat) + z * z / (4 * total)) / total) / denom
    {max(0.0, center - spread), min(1.0, center + spread)}
  end

  def wilson_interval(_passed, 0), do: {0.0, 1.0}
end

# --- Failure taxonomy classifier ---

defmodule FailureTaxonomy do
  @doc "Classify a failed test result into a failure category."
  def classify(result) do
    error = result[:error] || ""
    attempts = result[:attempts] || 0

    cond do
      # Premature answer: model answered on first attempt with wrong value
      # (not a runtime error, not a type mismatch — just wrong answer on turn 1)
      premature_answer?(result) ->
        :premature_answer

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

  # A premature answer is when the model:
  # 1. Answered on turn 1 (attempts == 1)
  # 2. Got the wrong value (not a runtime error or type mismatch)
  # 3. The test required multiple turns (exploration-heavy)
  # This indicates the model answered without inspecting tool output.
  defp premature_answer?(result) do
    error = result[:error] || ""
    attempts = result[:attempts] || 0

    wrong_value =
      (String.contains?(error, "Expected") and String.contains?(error, "got")) or
        (String.contains?(error, "Expected keys") and String.contains?(error, "missing"))

    not_runtime = not String.contains?(error, "Error:")
    first_attempt = attempts == 1

    wrong_value and not_runtime and first_attempt
  end

  @doc "Human-readable label for a failure category."
  def label(:premature_answer), do: "PREMATURE ANSWER (wrong on turn 1)"
  def label(:parse_error), do: "Parse/syntax error"
  def label(:max_turns_exceeded), do: "Max turns exceeded"
  def label(:control_flow), do: "Control flow (return+println)"
  def label(:shadow_builtin), do: "Cannot shadow builtin"
  def label(:runtime_error), do: "Runtime error in generated code"
  def label(:wrong_keys), do: "Wrong map keys"
  def label(:wrong_value), do: "Wrong value (after exploration)"
  def label(:timeout), do: "Timeout"
  def label(:type_mismatch), do: "Type mismatch"
  def label(:no_result), do: "No result returned"
  def label(:query_failed), do: "Query/LLM failure"
  def label(:other), do: "Other/unclassified"
end

# --- Run benchmarks ---

prompts = [:single_shot, :explicit_return]

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
# EXPERIMENT 2: Per-Turn Metrics
# ═══════════════════════════════════════════════════════════════

IO.puts("\n\n" <> String.duplicate("=", 70))
IO.puts("EXPERIMENT 2: Per-Turn Metrics")
IO.puts(String.duplicate("=", 70))

IO.puts(
  "\n  " <>
    String.pad_trailing("Prompt", 16) <>
    String.pad_leading("Turns/Pass", 12) <>
    String.pad_leading("Tokens/Pass", 13) <>
    String.pad_leading("Budget%", 9) <>
    String.pad_leading("T1 Valid%", 11) <>
    String.pad_leading("Salvage%", 10)
)

IO.puts("  " <> String.duplicate("-", 71))

for {prompt, summary} <- all_results do
  metrics = PerTurnMetrics.compute(summary.results)

  turns_str =
    if metrics.mean_turns_on_pass,
      do: :erlang.float_to_binary(metrics.mean_turns_on_pass, decimals: 2),
      else: "-"

  tokens_str =
    if metrics.mean_tokens_on_pass,
      do: "#{round(metrics.mean_tokens_on_pass)}",
      else: "-"

  budget_str = :erlang.float_to_binary(metrics.budget_exhaustion_rate, decimals: 1) <> "%"

  t1_str =
    if metrics.first_turn_validity,
      do: :erlang.float_to_binary(metrics.first_turn_validity, decimals: 1) <> "%",
      else: "-"

  salvage_str =
    if metrics.salvage_rate,
      do: :erlang.float_to_binary(metrics.salvage_rate, decimals: 1) <> "%",
      else: "n/a"

  IO.puts(
    "  " <>
      String.pad_trailing("#{prompt}", 16) <>
      String.pad_leading(turns_str, 12) <>
      String.pad_leading(tokens_str, 13) <>
      String.pad_leading(budget_str, 9) <>
      String.pad_leading(t1_str, 11) <>
      String.pad_leading(salvage_str, 10)
  )
end

# Per-slice turn metrics
IO.puts("\n  Per-slice mean turns on pass:")

for {slice_name, indices} <- slices do
  IO.write("    #{slice_name}: ")

  for {prompt, summary} <- all_results do
    slice_results = Enum.filter(summary.results, fn r -> MapSet.member?(indices, r.index) end)
    metrics = PerTurnMetrics.compute(slice_results)

    turns_str =
      if metrics.mean_turns_on_pass,
        do: :erlang.float_to_binary(metrics.mean_turns_on_pass, decimals: 2),
        else: "-"

    IO.write("#{prompt}=#{turns_str}  ")
  end

  IO.puts("")
end

# ═══════════════════════════════════════════════════════════════
# EXPERIMENT 3: Statistical Significance (Fisher Exact + Wilson CI)
# ═══════════════════════════════════════════════════════════════

IO.puts("\n\n" <> String.duplicate("=", 70))
IO.puts("EXPERIMENT 3: Statistical Significance")
IO.puts(String.duplicate("=", 70))

[{prompt_a, summary_a}, {prompt_b, summary_b}] = all_results

pass_a = summary_a.passed
fail_a = summary_a.failed
pass_b = summary_b.passed
fail_b = summary_b.failed
total_a = pass_a + fail_a
total_b = pass_b + fail_b

rate_a = Float.round(pass_a / total_a * 100, 1)
rate_b = Float.round(pass_b / total_b * 100, 1)

{lo_a, hi_a} = FisherExact.wilson_interval(pass_a, total_a)
{lo_b, hi_b} = FisherExact.wilson_interval(pass_b, total_b)

p = FisherExact.p_value(pass_a, fail_a, pass_b, fail_b)

IO.puts(
  "\n  #{prompt_a}: #{rate_a}% (#{pass_a}/#{total_a})  95% CI: [#{Float.round(lo_a * 100, 1)}%, #{Float.round(hi_a * 100, 1)}%]"
)

IO.puts(
  "  #{prompt_b}: #{rate_b}% (#{pass_b}/#{total_b})  95% CI: [#{Float.round(lo_b * 100, 1)}%, #{Float.round(hi_b * 100, 1)}%]"
)

IO.puts("\n  Fisher exact p-value: #{Float.round(p, 4)}")

significance =
  cond do
    p < 0.01 -> "SIGNIFICANT (p < 0.01) — strong evidence of a real difference"
    p < 0.05 -> "SIGNIFICANT (p < 0.05) — moderate evidence of a real difference"
    p < 0.10 -> "MARGINAL (p < 0.10) — weak evidence, consider more runs"
    p < 0.20 -> "NOT SIGNIFICANT (p < 0.20) — no meaningful signal at this sample size"
    true -> "NOT SIGNIFICANT — difference is likely noise"
  end

IO.puts("  Interpretation: #{significance}")

# Overlap check
ci_overlap = lo_a <= hi_b and lo_b <= hi_a

if ci_overlap do
  IO.puts("  Note: Confidence intervals overlap — difference may not be real")
else
  IO.puts("  Note: Confidence intervals do NOT overlap — difference is likely real")
end

# Sample size guidance
IO.puts("\n  Sample size context (#{total_a} observations per variant):")
IO.puts("    Detectable difference at this N: ~#{round(200 / :math.sqrt(total_a))}pp")
IO.puts("    For 10pp detection: need ~400 observations per variant")
IO.puts("    For 5pp detection:  need ~1500 observations per variant")

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
      String.pad_trailing("single_shot", 12) <>
      String.pad_trailing("explicit_ret", 12) <>
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
