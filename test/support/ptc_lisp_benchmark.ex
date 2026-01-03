defmodule PtcRunner.TestSupport.PtcLispBenchmark do
  @moduledoc """
  Benchmarking utility for evaluating LLM generation of PTC-Lisp programs.

  This is Phase 1 of the PTC-Lisp evaluation plan: testing whether LLMs can
  reliably generate valid PTC-Lisp syntax.

  ## Usage

      # Run from project root:
      MIX_ENV=test mix run -e 'PtcRunner.TestSupport.PtcLispBenchmark.run()'

      # Or with custom config:
      MIX_ENV=test mix run -e '
        PtcRunner.TestSupport.PtcLispBenchmark.run(
          models: ["openrouter:google/gemini-2.5-flash"],
          iterations: 1
        )
      '

  ## Output

  Results are saved to `priv/ptc_lisp_benchmark/` with timestamp.
  """

  alias PtcRunner.Lisp.Prompts

  @generator_models [
    "openrouter:google/gemini-2.5-flash",
    "openrouter:deepseek/deepseek-v3.2"
  ]

  @judge_model "openrouter:openai/gpt-5.1-codex-mini"

  @default_iterations 3
  @timeout 60_000

  # Pricing per 1M tokens
  @pricing %{
    "gemini-2.5-flash" => {0.30, 2.50},
    "deepseek-v3.2" => {0.27, 0.40},
    "claude-haiku-4.5" => {0.80, 4.00},
    "gpt-5.1-codex-mini" => {0.25, 2.0}
  }

  # Build prompt at runtime using the official API
  defp ptc_lisp_prompt do
    """
    You are generating PTC-Lisp programs. PTC-Lisp is a minimal Clojure subset for data transformation.

    #{Prompts.get(:single_shot)}

    IMPORTANT:
    - Respond with ONLY the PTC-Lisp code, no explanation or markdown formatting.
    """
  end

  @judge_system_prompt """
  You are a strict syntax validator for PTC-Lisp, a minimal Clojure subset.

  Your task: Determine if the given code is syntactically valid PTC-Lisp according to the specification below.

  #{File.read!("docs/ptc-lisp-specification.md")}

  ## COMMON INVALID PATTERNS (reject these):

  1. `where` predicate without operator:
     - INVALID: `(where :active true)` or `(where :field value)`
     - VALID: `(where :active = true)` or `(where :active)` for truthy check

  2. 3-arity comparisons (Clojure range syntax not supported):
     - INVALID: `(<= 100 x 500)` or `(< 0 n 10)`
     - VALID: `(and (>= x 100) (<= x 500))`

  3. Destructuring in `fn` parameters (only supported in `let`):
     - INVALID: `(fn [{:keys [a b]}] ...)`
     - VALID: `(fn [item] (let [{:keys [a b]} item] ...))`

  4. Using `and`/`or` for filtering predicates (use combinators):
     - INVALID: `(filter #(and (> (:price %) 100) (< (:price %) 500)) items)`
     - VALID: `(filter (all-of (where :price > 100) (where :price < 500)) items)`

  ## Response Format:
  Respond with ONLY a JSON object (no markdown):
  {"valid": true/false, "errors": ["error1", "error2"] or []}

  If valid, errors should be empty array.
  If invalid, list specific syntax errors found. Be strict!
  """

  # Test scenarios with varying difficulty
  defp test_scenarios do
    [
      # Level 1: Simple (basic operations)
      %{
        name: "simple_filter",
        level: 1,
        task: "Filter products where price is greater than 100",
        context_description:
          "ctx/products contains a list of products with :name and :price fields"
      },
      %{
        name: "simple_count",
        level: 1,
        task: "Count the number of active users",
        context_description:
          "ctx/users contains a list of users with :name and :active (boolean) fields"
      },

      # Level 2: Medium (pipelines, multiple operations)
      %{
        name: "pipeline_filter_sort",
        level: 2,
        task:
          "Get the top 5 highest-paid employees (filter salary > 50000, sort by salary descending, take 5)",
        context_description:
          "ctx/employees contains a list with :name, :department, and :salary fields"
      },
      %{
        name: "aggregate_sum",
        level: 2,
        task: "Calculate the total amount of all completed orders",
        context_description: "ctx/orders contains a list with :id, :amount, and :status fields"
      },

      # Level 3: Hard (predicates, combinators, conditionals)
      %{
        name: "predicate_combinator",
        level: 3,
        task:
          "Find all products that are either in the 'electronics' category OR cost more than 500, but exclude any that are out of stock",
        context_description:
          "ctx/products has :name, :category, :price, and :in_stock (boolean) fields"
      },
      %{
        name: "conditional_logic",
        level: 3,
        task:
          "Categorize each order as 'small' (amount < 100), 'medium' (100-500), or 'large' (> 500). Return a list of maps with :id and :size",
        context_description: "ctx/orders contains a list with :id and :amount fields"
      },

      # Level 4: Complex (tool calls, memory, closures)
      %{
        name: "tool_call_transform",
        level: 4,
        task:
          "Fetch users from the 'get-users' tool, filter to only premium tier, and return their emails",
        context_description:
          "The 'get-users' tool returns users with :name, :email, and :tier fields"
      },
      %{
        name: "memory_contract",
        level: 4,
        task:
          "Fetch orders from 'get-orders' tool, store the high-value orders (amount > 1000) in memory as :high_value_orders, and return just the count as the result",
        context_description:
          "The 'get-orders' tool returns orders with :id, :amount, and :customer fields"
      },

      # Level 5: Edge cases (tests for common LLM mistakes)
      %{
        name: "edge_truthy_check",
        level: 5,
        task: "Filter to only active users (where :active is true)",
        context_description:
          "ctx/users contains a list of users with :name, :email, and :active (boolean) fields. Note: Use explicit equality check with operator."
      },
      %{
        name: "edge_range_check",
        level: 5,
        task: "Find all products with price between 100 and 500 (inclusive on both ends)",
        context_description:
          "ctx/products contains a list with :name and :price fields. Note: PTC-Lisp only supports 2-arity comparisons, not 3-arity range syntax."
      },
      %{
        name: "edge_multi_field_extract",
        level: 5,
        task: "Extract :id and :name from each order into a new list of maps",
        context_description:
          "ctx/orders contains a list with :id, :name, :amount, and :status fields. Note: If using fn, destructuring must be in let bindings, not fn parameters."
      }
    ]
  end

  @doc """
  Run the benchmark with the given options.

  ## Options
    - `:models` - List of generator model identifiers (default: gemini + deepseek)
    - `:judge` - Judge model identifier (default: claude-haiku-4.5)
    - `:iterations` - Number of times to run each test (default: 3)
    - `:scenarios` - List of scenario names to run, or :all (default: :all)
    - `:dry_run` - If true, just print what would be done without API calls (default: false)
  """
  def run(opts \\ []) do
    models = Keyword.get(opts, :models, @generator_models)
    judge = Keyword.get(opts, :judge, @judge_model)
    iterations = Keyword.get(opts, :iterations, @default_iterations)
    scenario_filter = Keyword.get(opts, :scenarios, :all)
    dry_run = Keyword.get(opts, :dry_run, false)

    scenarios =
      case scenario_filter do
        :all -> test_scenarios()
        names when is_list(names) -> Enum.filter(test_scenarios(), &(&1.name in names))
      end

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.slice(0, 15)
    output_dir = Path.join(["priv", "ptc_lisp_benchmark", timestamp])
    File.mkdir_p!(output_dir)

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("PTC-LISP GENERATION BENCHMARK - Phase 1 Evaluation")
    IO.puts(String.duplicate("=", 70))
    IO.puts("Generator models: #{Enum.join(models, ", ")}")
    IO.puts("Judge model: #{judge}")
    IO.puts("Scenarios: #{length(scenarios)}")
    IO.puts("Iterations: #{iterations}")
    IO.puts("Total generations: #{length(models) * length(scenarios) * iterations}")
    IO.puts("Output directory: #{output_dir}")
    if dry_run, do: IO.puts("Mode: DRY RUN (no API calls)")
    IO.puts(String.duplicate("=", 70) <> "\n")

    if dry_run do
      print_dry_run(models, judge, scenarios, iterations)
      :dry_run
    else
      results =
        for model <- models do
          IO.puts("\n>>> Testing generator: #{model}")
          IO.puts(String.duplicate("-", 50))

          model_results =
            for scenario <- scenarios do
              scenario_results =
                for i <- 1..iterations do
                  run_single_test(model, judge, scenario, i)
                end

              %{
                scenario_name: scenario.name,
                level: scenario.level,
                results: scenario_results,
                valid_count: Enum.count(scenario_results, & &1.valid),
                total_cost: sum_costs(scenario_results)
              }
            end

          %{
            model: model,
            scenarios: model_results,
            total_valid: Enum.sum(Enum.map(model_results, & &1.valid_count)),
            total_tests: length(scenarios) * iterations,
            total_cost: Enum.sum(Enum.map(model_results, & &1.total_cost))
          }
        end

      # Save all generated programs
      save_results(results, output_dir)

      # Print report
      print_report(results, iterations, output_dir)

      results
    end
  end

  @level_descriptions %{
    1 => "Simple",
    2 => "Pipeline",
    3 => "Predicates",
    4 => "Tool + Memory",
    5 => "Edge Cases"
  }

  defp print_dry_run(models, judge, scenarios, iterations) do
    # Group scenarios by level
    by_level = Enum.group_by(scenarios, & &1.level) |> Enum.sort_by(fn {level, _} -> level end)

    IO.puts("## Scenarios by Level\n")

    for {level, level_scenarios} <- by_level do
      level_desc = Map.get(@level_descriptions, level, "Unknown")
      IO.puts("  Level #{level} (#{level_desc}) - #{length(level_scenarios)} scenarios:")

      for s <- level_scenarios do
        # Clean up task description for display (truncate if too long)
        task_short = String.slice(s.task, 0, 60)
        task_short = if String.length(s.task) > 60, do: task_short <> "...", else: task_short
        IO.puts("    • #{s.name}: #{task_short}")
      end

      IO.puts("")
    end

    # Execution plan
    IO.puts("## Execution Plan\n")

    for model <- models do
      model_short = model |> String.split("/") |> List.last()
      calls = length(scenarios) * iterations
      IO.puts("  #{String.pad_trailing(model_short, 20)} #{calls} generation calls")
    end

    judge_short = judge |> String.split("/") |> List.last()
    total_gen_calls = length(models) * length(scenarios) * iterations
    IO.puts("  #{String.pad_trailing(judge_short, 20)} #{total_gen_calls} judge calls")

    IO.puts("\n  Total API calls: #{total_gen_calls * 2}")

    # Cost estimate
    IO.puts("\n## Cost Estimate\n")
    {gen_cost, judge_cost} = estimate_costs(models, judge, scenarios, iterations)
    total_cost = gen_cost + judge_cost

    IO.puts("  Generators: $#{format_cost(gen_cost)}")
    IO.puts("  Judge:      $#{format_cost(judge_cost)}")
    IO.puts("  ─────────────────")
    IO.puts("  Total:      $#{format_cost(total_cost)}")

    IO.puts("\n✓ Dry run complete. Remove dry_run: true to execute.")
  end

  defp estimate_costs(models, judge, scenarios, iterations) do
    # Estimate tokens (rough approximations)
    # ~4.6KB prompt
    gen_input_tokens = 1200
    # typical generated code
    gen_output_tokens = 150
    # ~55KB spec
    judge_input_tokens = 14_000
    # JSON response
    judge_output_tokens = 50

    gen_calls_per_model = length(scenarios) * iterations
    total_judge_calls = length(models) * gen_calls_per_model

    gen_cost =
      Enum.reduce(models, 0.0, fn model, acc ->
        model_suffix = model |> String.split("/") |> List.last()

        case Map.get(@pricing, model_suffix) do
          {input_price, output_price} ->
            input_cost = gen_calls_per_model * gen_input_tokens / 1_000_000 * input_price
            output_cost = gen_calls_per_model * gen_output_tokens / 1_000_000 * output_price
            acc + input_cost + output_cost

          nil ->
            acc
        end
      end)

    judge_suffix = judge |> String.split("/") |> List.last()

    judge_cost =
      case Map.get(@pricing, judge_suffix) do
        {input_price, output_price} ->
          input_cost = total_judge_calls * judge_input_tokens / 1_000_000 * input_price
          output_cost = total_judge_calls * judge_output_tokens / 1_000_000 * output_price
          input_cost + output_cost

        nil ->
          0.0
      end

    {gen_cost, judge_cost}
  end

  defp run_single_test(generator_model, judge_model, scenario, iteration) do
    IO.write("  #{scenario.name} [L#{scenario.level}] ##{iteration}: ")

    start_time = System.monotonic_time(:millisecond)

    try do
      # Step 1: Generate PTC-Lisp program
      prompt = build_generation_prompt(scenario)

      {:ok, gen_response} =
        ReqLLM.generate_text(generator_model, prompt,
          system_prompt: ptc_lisp_prompt(),
          receive_timeout: @timeout
        )

      generated_code = gen_response |> ReqLLM.Response.text() |> clean_response()
      gen_cost = get_cost(gen_response.usage, generator_model)

      # Step 2: Judge validity with Claude
      judge_prompt = "Validate this PTC-Lisp code:\n\n```\n#{generated_code}\n```"

      {:ok, judge_response} =
        ReqLLM.generate_text(judge_model, judge_prompt,
          system_prompt: @judge_system_prompt,
          receive_timeout: @timeout
        )

      judge_text = judge_response |> ReqLLM.Response.text() |> clean_response()
      judge_cost = get_cost(judge_response.usage, judge_model)

      # Parse judge response
      {valid, errors} = parse_judge_response(judge_text)

      duration = System.monotonic_time(:millisecond) - start_time
      total_cost = gen_cost + judge_cost

      if valid do
        IO.puts("✓ VALID (#{duration}ms, $#{format_cost(total_cost)})")
      else
        IO.puts("✗ INVALID (#{duration}ms)")
        IO.puts("    Errors: #{Enum.join(errors, "; ")}")
      end

      %{
        valid: valid,
        errors: errors,
        generated_code: generated_code,
        judge_response: judge_text,
        gen_cost: gen_cost,
        judge_cost: judge_cost,
        duration_ms: duration
      }
    rescue
      e ->
        duration = System.monotonic_time(:millisecond) - start_time
        IO.puts("✗ ERROR (#{duration}ms)")
        IO.puts("    #{Exception.message(e)}")

        %{
          valid: false,
          errors: ["Exception: #{Exception.message(e)}"],
          generated_code: nil,
          judge_response: nil,
          gen_cost: 0,
          judge_cost: 0,
          duration_ms: duration
        }
    end
  end

  defp build_generation_prompt(scenario) do
    """
    Task: #{scenario.task}

    Context: #{scenario.context_description}

    Write a PTC-Lisp program to accomplish this task.
    """
  end

  defp clean_response(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```(?:clojure|lisp|json)?\s*/i, "")
    |> String.replace(~r/\s*```$/i, "")
    |> String.trim()
  end

  defp parse_judge_response(text) do
    # Try to parse as JSON
    case Jason.decode(text) do
      {:ok, %{"valid" => valid, "errors" => errors}} ->
        {valid == true, errors}

      {:ok, %{"valid" => valid}} ->
        {valid == true, []}

      _ ->
        # Fallback: look for valid/invalid keywords
        cond do
          String.contains?(String.downcase(text), "\"valid\": true") -> {true, []}
          String.contains?(String.downcase(text), "\"valid\":true") -> {true, []}
          true -> {false, ["Could not parse judge response: #{String.slice(text, 0, 100)}"]}
        end
    end
  end

  defp get_cost(usage, model) do
    model_suffix = model |> String.split("/") |> List.last() |> String.split(":") |> List.last()

    case Map.get(@pricing, model_suffix) do
      {input_price, output_price} ->
        input_tokens = Map.get(usage, :input_tokens, 0)
        output_tokens = Map.get(usage, :output_tokens, 0)
        input_tokens / 1_000_000 * input_price + output_tokens / 1_000_000 * output_price

      nil ->
        # Try to get from usage directly
        Map.get(usage, :total_cost, 0.0)
    end
  end

  defp sum_costs(results) do
    Enum.sum(Enum.map(results, fn r -> (r.gen_cost || 0) + (r.judge_cost || 0) end))
  end

  defp format_cost(cost) when is_float(cost), do: :erlang.float_to_binary(cost, decimals: 6)
  defp format_cost(cost) when is_integer(cost), do: "#{cost}.000000"

  defp save_results(results, output_dir) do
    # Save full results as JSON
    results_file = Path.join(output_dir, "results.json")

    json_results =
      Enum.map(results, fn model_result ->
        %{
          model: model_result.model,
          total_valid: model_result.total_valid,
          total_tests: model_result.total_tests,
          total_cost: model_result.total_cost,
          scenarios:
            Enum.map(model_result.scenarios, fn s ->
              %{
                name: s.scenario_name,
                level: s.level,
                valid_count: s.valid_count,
                results:
                  Enum.map(s.results, fn r ->
                    %{
                      valid: r.valid,
                      errors: r.errors,
                      generated_code: r.generated_code,
                      duration_ms: r.duration_ms
                    }
                  end)
              }
            end)
        }
      end)

    File.write!(results_file, Jason.encode!(json_results, pretty: true))
    IO.puts("\nResults saved to: #{results_file}")

    # Save individual programs for easy review
    for model_result <- results do
      model_name = model_result.model |> String.split("/") |> List.last()
      model_dir = Path.join(output_dir, model_name)
      File.mkdir_p!(model_dir)

      for scenario_result <- model_result.scenarios do
        for {result, i} <- Enum.with_index(scenario_result.results, 1) do
          if result.generated_code do
            filename = "#{scenario_result.scenario_name}_#{i}.clj"
            filepath = Path.join(model_dir, filename)

            content = """
            ;; Scenario: #{scenario_result.scenario_name}
            ;; Level: #{scenario_result.level}
            ;; Iteration: #{i}
            ;; Valid: #{result.valid}
            ;; Errors: #{inspect(result.errors)}
            ;; Duration: #{result.duration_ms}ms

            #{result.generated_code}
            """

            File.write!(filepath, content)
          end
        end
      end
    end
  end

  defp print_report(results, iterations, output_dir) do
    IO.puts("\n\n" <> String.duplicate("=", 70))
    IO.puts("BENCHMARK REPORT")
    IO.puts(String.duplicate("=", 70))

    # Summary table
    IO.puts("\n## Summary by Model\n")
    IO.puts("| Model | Valid Rate | Total Cost |")
    IO.puts("|-------|------------|------------|")

    for r <- results do
      model_short = r.model |> String.split("/") |> List.last()
      valid_rate = Float.round(r.total_valid / r.total_tests * 100, 1)

      IO.puts(
        "| #{model_short} | #{valid_rate}% (#{r.total_valid}/#{r.total_tests}) | $#{format_cost(r.total_cost)} |"
      )
    end

    # By difficulty level
    IO.puts("\n## Valid Rate by Difficulty Level\n")

    model_headers = Enum.map_join(results, " | ", &(&1.model |> String.split("/") |> List.last()))
    IO.puts("| Level | #{model_headers} |")

    IO.puts("|-------|#{String.duplicate("------|", length(results))}")

    for level <- 1..5 do
      row =
        for r <- results do
          level_scenarios = Enum.filter(r.scenarios, &(&1.level == level))
          valid = Enum.sum(Enum.map(level_scenarios, & &1.valid_count))
          total = length(level_scenarios) * iterations
          if total > 0, do: "#{valid}/#{total}", else: "-"
        end

      IO.puts("| L#{level} | #{Enum.join(row, " | ")} |")
    end

    # Per-scenario breakdown
    IO.puts("\n## Valid Rate by Scenario (#{iterations} iterations each)\n")

    scenario_names = results |> hd() |> Map.get(:scenarios) |> Enum.map(& &1.scenario_name)

    header = [
      "Scenario" | Enum.map(results, fn r -> r.model |> String.split("/") |> List.last() end)
    ]

    IO.puts("| #{Enum.join(header, " | ")} |")
    IO.puts("|#{String.duplicate("---|", length(header))}")

    for scenario_name <- scenario_names do
      row =
        for r <- results do
          scenario_result = Enum.find(r.scenarios, &(&1.scenario_name == scenario_name))
          "#{scenario_result.valid_count}/#{iterations}"
        end

      IO.puts("| #{scenario_name} | #{Enum.join(row, " | ")} |")
    end

    # Error patterns
    print_error_patterns(results)

    # Total cost
    total_cost = Enum.sum(Enum.map(results, & &1.total_cost))
    IO.puts("\n## Total Cost: $#{format_cost(total_cost)}")

    # Success criteria check
    IO.puts("\n## Evaluation Criteria")

    overall_rate =
      Enum.sum(Enum.map(results, & &1.total_valid)) /
        Enum.sum(Enum.map(results, & &1.total_tests)) * 100

    if overall_rate >= 90 do
      IO.puts("✓ PASS: #{Float.round(overall_rate, 1)}% valid (target: >90%)")
    else
      IO.puts("✗ FAIL: #{Float.round(overall_rate, 1)}% valid (target: >90%)")
    end

    IO.puts("\nFull results saved to: #{output_dir}")
    IO.puts("")
  end

  defp print_error_patterns(results) do
    IO.puts("\n## Common Error Patterns\n")

    all_errors =
      results
      |> Enum.flat_map(& &1.scenarios)
      |> Enum.flat_map(& &1.results)
      |> Enum.flat_map(& &1.errors)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, count} -> -count end)
      |> Enum.take(10)

    if Enum.empty?(all_errors) do
      IO.puts("No errors recorded.")
    else
      for {error, count} <- all_errors do
        IO.puts("- (#{count}x) #{String.slice(error, 0, 80)}")
      end
    end
  end
end
