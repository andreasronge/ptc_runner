defmodule Mix.Tasks.Meta.Sweep do
  @shortdoc "Run lambda_llm calibration sweep for meta-learner experiments"
  @moduledoc """
  Runs the three-species coevolution at multiple lambda_llm values to find
  the regime where M strategies differentiate.

  ## Usage

      mix meta.sweep                          # Run with defaults
      mix meta.sweep --lambdas 0.0,0.00005,0.0001,0.001
      mix meta.sweep --generations 4          # Outer generations per sweep point
      mix meta.sweep --llm-model openrouter:google/gemini-3.1-flash-lite-preview
      mix meta.sweep --log-dir demo/tmp/sweep

  ## Output

  For each lambda value, prints per-generation M variant metrics and a final
  summary comparing strategies across lambda values.
  """

  use Mix.Task

  alias PtcRunner.Meta.MetaLoop

  @default_lambdas [0.0, 0.00001, 0.00005, 0.0001, 0.001]
  @default_generations 4
  @default_llm_model "gemini-flash-lite"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          lambdas: :string,
          generations: :integer,
          llm_model: :string,
          log_dir: :string,
          llm_mutation_rate: :float,
          m_llm_mutation_rate: :float
        ]
      )

    lambdas = parse_lambdas(opts[:lambdas])
    generations = opts[:generations] || @default_generations
    llm_model = opts[:llm_model] || @default_llm_model
    log_dir = opts[:log_dir] || "demo/tmp/sweep-#{timestamp()}"
    llm_mutation_rate = opts[:llm_mutation_rate] || 0.0
    m_llm_mutation_rate = opts[:m_llm_mutation_rate] || 0.0

    File.mkdir_p!(log_dir)

    # Solver seeds — simple programs that GP can tweak
    solver_seeds = [
      "(count data/products)",
      ~s|(count (filter (fn [p] (> (get p "price") 400)) data/products))|,
      ~s|(count (filter (fn [p] (= (get p "status") "active")) data/products))|
    ]

    IO.puts("=== lambda_llm Calibration Sweep ===")
    IO.puts("Lambda values: #{inspect(lambdas)}")
    IO.puts("Outer generations: #{generations}")
    IO.puts("LLM model: #{inspect(llm_model)}")
    IO.puts("LLM mutation rate: #{llm_mutation_rate}")
    IO.puts("M LLM mutation rate: #{m_llm_mutation_rate}")
    IO.puts("Log dir: #{log_dir}")
    IO.puts("")

    results =
      Enum.map(lambdas, fn lambda ->
        IO.puts("\n#{"=" |> String.duplicate(60)}")
        IO.puts("=== lambda_llm = #{lambda} ===")
        IO.puts("#{"=" |> String.duplicate(60)}\n")

        sweep_log_dir = Path.join(log_dir, "lambda-#{lambda}")

        # Re-seed for each sweep point so they get the same data
        :rand.seed(:exsss, {42, 42, 42})
        ctx = generate_data_context()

        start = System.monotonic_time(:second)

        result =
          MetaLoop.run(
            outer_generations: generations,
            data_context: ctx,
            solver_seeds: solver_seeds,
            log_dir: sweep_log_dir,
            m_llm_mutation_rate: m_llm_mutation_rate,
            eval_config: [
              lambda_llm: lambda,
              llm_model: llm_model,
              llm_mutation_rate: llm_mutation_rate
            ]
          )

        elapsed = System.monotonic_time(:second) - start
        IO.puts("\nlambda=#{lambda} completed in #{elapsed}s")

        %{lambda: lambda, result: result, elapsed_seconds: elapsed}
      end)

    # Print comparison summary
    IO.puts("\n#{"=" |> String.duplicate(60)}")
    IO.puts("=== SWEEP SUMMARY ===")
    IO.puts("#{"=" |> String.duplicate(60)}\n")

    IO.puts(
      String.pad_trailing("lambda", 12) <>
        String.pad_trailing("best_M", 22) <>
        String.pad_trailing("fitness", 10) <>
        String.pad_trailing("solve_rate", 12) <>
        String.pad_trailing("tokens", 10) <>
        String.pad_trailing("tok/solve", 10) <>
        "authors"
    )

    IO.puts(String.duplicate("-", 86))

    Enum.each(results, fn %{lambda: lambda, result: result} ->
      best_m = result.best_m
      eval = Map.get(best_m.metadata, :eval_result, %{})

      IO.puts(
        String.pad_trailing("#{lambda}", 12) <>
          String.pad_trailing(best_m.id, 22) <>
          String.pad_trailing(format_f(best_m.fitness, 4), 10) <>
          String.pad_trailing(format_f(Map.get(eval, :solve_rate, 0.0), 3), 12) <>
          String.pad_trailing("#{Map.get(eval, :total_llm_tokens, 0)}", 10) <>
          String.pad_trailing(format_f(Map.get(eval, :tokens_per_solve, 0.0), 0), 10) <>
          "#{length(result.authors)}"
      )
    end)

    # Write JSON summary
    summary = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      lambdas: lambdas,
      generations: generations,
      llm_model: llm_model,
      results:
        Enum.map(results, fn %{lambda: lambda, result: result} ->
          best_m = result.best_m
          eval = Map.get(best_m.metadata, :eval_result, %{})

          %{
            lambda: lambda,
            best_m_id: best_m.id,
            best_m_fitness: best_m.fitness,
            solve_rate: Map.get(eval, :solve_rate, 0.0),
            total_llm_tokens: Map.get(eval, :total_llm_tokens, 0),
            tokens_per_solve: Map.get(eval, :tokens_per_solve, 0.0),
            hard_solve_rate: Map.get(eval, :hard_solve_rate, 0.0),
            llm_precision: Map.get(eval, :llm_precision, 0.0),
            gp_sufficiency: Map.get(eval, :gp_sufficiency, 0.0),
            author_count: length(result.authors),
            history: result.history
          }
        end)
    }

    summary_path = Path.join(log_dir, "sweep-summary.json")
    File.write!(summary_path, Jason.encode!(summary, pretty: true))
    IO.puts("\nSweep summary written to #{summary_path}")
  end

  defp generate_data_context do
    categories = ["electronics", "clothing", "food", "books", "sports", "home", "toys"]
    statuses = ["active", "discontinued", "out_of_stock"]

    products =
      for i <- 1..500 do
        %{
          "id" => i,
          "name" => "Product #{i}",
          "category" => Enum.random(categories),
          "price" => :rand.uniform(1000) + :rand.uniform(100) / 100,
          "stock" => :rand.uniform(500),
          "status" => Enum.random(statuses)
        }
      end

    order_statuses = ["pending", "shipped", "delivered", "cancelled", "refunded"]

    orders =
      for i <- 1..1000 do
        %{
          "id" => i,
          "product_id" => :rand.uniform(500),
          "quantity" => :rand.uniform(10),
          "total" => :rand.uniform(5000) + :rand.uniform(100) / 100,
          "status" => Enum.random(order_statuses)
        }
      end

    departments = ["engineering", "sales", "marketing", "support", "hr", "finance"]

    employees =
      for i <- 1..200 do
        %{
          "id" => i,
          "name" => "Employee #{i}",
          "department" => Enum.random(departments),
          "salary" => 50_000 + :rand.uniform(150_000)
        }
      end

    expense_categories = ["travel", "equipment", "software", "meals", "office", "training"]

    expenses =
      for i <- 1..800 do
        %{
          "id" => i,
          "employee_id" => :rand.uniform(200),
          "category" => Enum.random(expense_categories),
          "amount" => :rand.uniform(2000) + :rand.uniform(100) / 100
        }
      end

    %{
      "products" => products,
      "orders" => orders,
      "employees" => employees,
      "expenses" => expenses
    }
  end

  defp parse_lambdas(nil), do: @default_lambdas

  defp parse_lambdas(str) do
    str
    |> String.split(",")
    |> Enum.map(fn s -> String.trim(s) |> String.to_float() end)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
    |> String.replace(~r/[:.T]/, "-")
    |> String.slice(0, 19)
  end

  defp format_f(nil, _), do: "nil"
  defp format_f(f, decimals), do: Float.round(f * 1.0, decimals) |> to_string()
end
