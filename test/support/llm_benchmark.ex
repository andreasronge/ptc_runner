defmodule PtcRunner.TestSupport.LLMBenchmark do
  @moduledoc """
  Benchmarking utility for comparing LLM models on PTC E2E tests.

  See `docs/llm-testing.md` for detailed documentation, benchmark results,
  and configuration options.

  ## Usage

      # Run from project root:
      MIX_ENV=test mix run -e 'PtcRunner.TestSupport.LLMBenchmark.run()'

      # Or with custom config:
      MIX_ENV=test mix run -e '
        PtcRunner.TestSupport.LLMBenchmark.run(
          models: ["openrouter:google/gemini-2.5-flash"],
          iterations: 5
        )
      '
  """

  @default_models [
    "openrouter:google/gemini-2.5-flash",
    "openrouter:deepseek/deepseek-v3.2",
    "openrouter:moonshotai/kimi-linear-48b-a3b-instruct"
  ]

  @default_iterations 3
  @timeout 60_000

  # Fallback pricing per 1M tokens (used when provider doesn't report cost)
  # Format: model_suffix => {input_price, output_price}
  @default_pricing %{
    "gemini-2.5-flash" => {0.30, 2.50},
    "deepseek-v3.2" => {0.27, 0.40},
    "kimi-linear-48b-a3b-instruct" => {0.50, 0.60}
  }

  # Test case definitions (validators defined as functions below)
  defp test_cases do
    [
      %{
        name: "filter_gt",
        task: "Filter products where price is greater than 10",
        input: [
          %{"name" => "Apple", "price" => 5},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Laptop", "price" => 999}
        ],
        validator: :filter_gt
      },
      %{
        name: "sum_prices",
        task: "Calculate the sum of all prices",
        input: [
          %{"name" => "Apple", "price" => 5},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Laptop", "price" => 999}
        ],
        validator: :sum_prices
      },
      %{
        name: "filter_and_count",
        task: "Filter products where price > 10, then count them",
        input: [
          %{"name" => "Apple", "price" => 5},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Laptop", "price" => 999}
        ],
        validator: :filter_and_count
      },
      %{
        name: "max_by",
        task: "Find the employee who has been employed the longest (highest years_employed)",
        input: [
          %{"name" => "Alice", "years_employed" => 3},
          %{"name" => "Bob", "years_employed" => 7},
          %{"name" => "Carol", "years_employed" => 5}
        ],
        validator: :max_by
      },
      %{
        name: "min_by",
        task: "Find the cheapest product (lowest price)",
        input: [
          %{"name" => "Laptop", "price" => 999},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Phone", "price" => 599}
        ],
        validator: :min_by
      },
      %{
        name: "pluck_names",
        task: "Get all product names as a list (extract name field from each item)",
        input: [
          %{"name" => "Apple", "price" => 5},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Laptop", "price" => 999}
        ],
        validator: :pluck_names
      },
      %{
        name: "sort_by",
        task: "Sort products by price from lowest to highest",
        input: [
          %{"name" => "Laptop", "price" => 999},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Phone", "price" => 599}
        ],
        validator: :sort_by
      },
      # Harder tests below
      %{
        name: "sort_desc_first",
        task: "Get the most expensive product (sort by price descending, take first)",
        input: [
          %{"name" => "Book", "price" => 15},
          %{"name" => "Laptop", "price" => 999},
          %{"name" => "Phone", "price" => 599}
        ],
        validator: :sort_desc_first
      },
      %{
        name: "filter_sort_first",
        task:
          "Find the cheapest product that costs more than 100 (filter price > 100, sort by price, take first)",
        input: [
          %{"name" => "Book", "price" => 15},
          %{"name" => "Laptop", "price" => 999},
          %{"name" => "Phone", "price" => 599},
          %{"name" => "Tablet", "price" => 299}
        ],
        validator: :filter_sort_first
      },
      %{
        name: "max_value_vs_row",
        task: "What is the highest salary? Return just the number.",
        input: [
          %{"name" => "Alice", "salary" => 50_000},
          %{"name" => "Bob", "salary" => 75_000},
          %{"name" => "Carol", "salary" => 60_000}
        ],
        validator: :max_value
      },
      %{
        name: "nested_get",
        task: "Get the city from the user's address (path: user -> address -> city)",
        input: %{
          "user" => %{
            "name" => "Alice",
            "address" => %{"city" => "Stockholm", "country" => "Sweden"}
          }
        },
        validator: :nested_get
      }
    ]
  end

  # Validators
  defp validate(:filter_gt, result) do
    is_list(result) and length(result) == 2 and
      Enum.all?(result, fn item -> item["price"] > 10 end)
  end

  defp validate(:sum_prices, result), do: result == 1019

  defp validate(:filter_and_count, result), do: result == 2

  defp validate(:max_by, result) do
    is_map(result) and result["name"] == "Bob" and result["years_employed"] == 7
  end

  defp validate(:min_by, result) do
    is_map(result) and result["name"] == "Book" and result["price"] == 15
  end

  defp validate(:pluck_names, result) do
    is_list(result) and Enum.sort(result) == ["Apple", "Book", "Laptop"]
  end

  defp validate(:sort_by, result) do
    is_list(result) and Enum.map(result, & &1["price"]) == [15, 599, 999]
  end

  # Harder test validators
  defp validate(:sort_desc_first, result) do
    is_map(result) and result["name"] == "Laptop" and result["price"] == 999
  end

  defp validate(:filter_sort_first, result) do
    is_map(result) and result["name"] == "Tablet" and result["price"] == 299
  end

  defp validate(:max_value, result) do
    result == 75_000
  end

  defp validate(:nested_get, result) do
    result == "Stockholm"
  end

  @doc """
  Run the benchmark with the given options.

  ## Options
    - `:models` - List of model identifiers (default: 3 models)
    - `:iterations` - Number of times to run each test (default: 3)
    - `:tests` - List of test names to run, or :all (default: :all)
    - `:pricing` - Custom pricing map, e.g. %{"model-name" => {input_per_1m, output_per_1m}}
  """
  def run(opts \\ []) do
    models = Keyword.get(opts, :models, @default_models)
    iterations = Keyword.get(opts, :iterations, @default_iterations)
    test_filter = Keyword.get(opts, :tests, :all)
    custom_pricing = Keyword.get(opts, :pricing, %{})
    pricing = Map.merge(@default_pricing, custom_pricing)

    tests =
      case test_filter do
        :all -> test_cases()
        names when is_list(names) -> Enum.filter(test_cases(), &(&1.name in names))
      end

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("LLM BENCHMARK - Text Mode E2E Tests")
    IO.puts(String.duplicate("=", 70))
    IO.puts("Models: #{length(models)}")
    IO.puts("Tests per model: #{length(tests)}")
    IO.puts("Iterations: #{iterations}")
    IO.puts("Total API calls: #{length(models) * length(tests) * iterations}")
    IO.puts(String.duplicate("=", 70) <> "\n")

    results =
      for model <- models do
        IO.puts("\n>>> Testing model: #{model}")
        IO.puts(String.duplicate("-", 50))

        model_results =
          for test <- tests do
            test_results =
              for i <- 1..iterations do
                run_single_test(model, test, i, pricing)
              end

            %{
              test_name: test.name,
              results: test_results,
              pass_count: Enum.count(test_results, & &1.passed),
              total_cost: Enum.sum(Enum.map(test_results, & &1.cost))
            }
          end

        %{
          model: model,
          tests: model_results,
          total_passes: Enum.sum(Enum.map(model_results, & &1.pass_count)),
          total_tests: length(tests) * iterations,
          total_cost: Enum.sum(Enum.map(model_results, & &1.total_cost))
        }
      end

    print_report(results, iterations)
    results
  end

  defp run_single_test(model, test, iteration, pricing) do
    IO.write("  #{test.name} ##{iteration}: ")

    start_time = System.monotonic_time(:millisecond)

    try do
      # Generate program
      prompt = build_prompt(test.task)
      {:ok, response} = ReqLLM.generate_text(model, prompt, receive_timeout: @timeout)

      text = ReqLLM.Response.text(response)
      usage = response.usage
      cost = get_cost(usage, model, pricing)
      cleaned = clean_response(text)

      # Parse and run
      case PtcRunner.Json.run(cleaned, context: %{"input" => test.input}) do
        {:ok, result, _metrics, _memory} ->
          passed = validate(test.validator, result)
          duration = System.monotonic_time(:millisecond) - start_time

          if passed do
            IO.puts("✓ PASS (#{duration}ms, $#{format_cost(cost)})")
          else
            IO.puts("✗ FAIL - wrong result (#{duration}ms)")
            IO.puts("    Expected validation to pass, got: #{inspect(result, limit: 50)}")
          end

          %{
            passed: passed,
            cost: cost,
            duration_ms: duration,
            error: nil,
            generated: cleaned
          }

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - start_time
          IO.puts("✗ FAIL - execution error (#{duration}ms)")
          IO.puts("    Error: #{inspect(reason)}")
          IO.puts("    Generated: #{String.slice(cleaned, 0, 80)}...")

          %{
            passed: false,
            cost: cost,
            duration_ms: duration,
            error: {:execution_error, reason},
            generated: cleaned
          }
      end
    rescue
      e ->
        duration = System.monotonic_time(:millisecond) - start_time
        IO.puts("✗ FAIL - exception (#{duration}ms)")
        IO.puts("    #{Exception.message(e)}")

        %{
          passed: false,
          cost: 0,
          duration_ms: duration,
          error: {:exception, Exception.message(e)},
          generated: nil
        }
    end
  end

  defp build_prompt(task) do
    """
    You are generating a PTC (Programmatic Tool Calling) program.

    #{PtcRunner.Schema.to_prompt()}

    Task: #{task}

    IMPORTANT: The input data is available via {"op": "load", "name": "input"}.

    Respond with ONLY valid JSON, no explanation or markdown formatting.
    """
  end

  defp clean_response(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```json\s*/i, "")
    |> String.replace(~r/^```\s*/i, "")
    |> String.replace(~r/\s*```$/i, "")
    |> String.trim()
  end

  defp format_cost(cost) when is_float(cost) do
    :erlang.float_to_binary(cost, decimals: 6)
  end

  defp format_cost(cost) when is_integer(cost) do
    "#{cost}.000000"
  end

  defp get_cost(usage, model, pricing) do
    case Map.get(usage, :total_cost) do
      nil -> calculate_cost(usage, model, pricing)
      0 -> calculate_cost(usage, model, pricing)
      cost when cost == 0.0 -> calculate_cost(usage, model, pricing)
      cost -> cost
    end
  end

  defp calculate_cost(usage, model, pricing) do
    model_suffix = model |> String.split("/") |> List.last()

    case Map.get(pricing, model_suffix) do
      {input_price, output_price} ->
        input_tokens = Map.get(usage, :input_tokens, 0)
        output_tokens = Map.get(usage, :output_tokens, 0)
        input_tokens / 1_000_000 * input_price + output_tokens / 1_000_000 * output_price

      nil ->
        0.0
    end
  end

  defp print_report(results, iterations) do
    IO.puts("\n\n" <> String.duplicate("=", 70))
    IO.puts("BENCHMARK REPORT")
    IO.puts(String.duplicate("=", 70))

    # Summary table
    IO.puts("\n## Summary by Model\n")
    IO.puts("| Model | Pass Rate | Total Cost |")
    IO.puts("|-------|-----------|------------|")

    for r <- results do
      model_short = r.model |> String.split("/") |> List.last()
      pass_rate = Float.round(r.total_passes / r.total_tests * 100, 1)

      IO.puts(
        "| #{model_short} | #{pass_rate}% (#{r.total_passes}/#{r.total_tests}) | $#{format_cost(r.total_cost)} |"
      )
    end

    # Per-test breakdown
    IO.puts("\n## Pass Rate by Test (#{iterations} iterations each)\n")

    test_names = results |> hd() |> Map.get(:tests) |> Enum.map(& &1.test_name)
    header = ["Test" | Enum.map(results, fn r -> r.model |> String.split("/") |> List.last() end)]
    IO.puts("| #{Enum.join(header, " | ")} |")
    IO.puts("|#{String.duplicate("---|", length(header))}")

    for test_name <- test_names do
      row =
        for r <- results do
          test_result = Enum.find(r.tests, &(&1.test_name == test_name))
          "#{test_result.pass_count}/#{iterations}"
        end

      IO.puts("| #{test_name} | #{Enum.join(row, " | ")} |")
    end

    # Total cost
    total_cost = Enum.sum(Enum.map(results, & &1.total_cost))
    IO.puts("\n## Total Cost: $#{format_cost(total_cost)}")
    IO.puts("")
  end
end
