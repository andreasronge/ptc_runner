defmodule PtcRunner.Meta.MetaLoop do
  @moduledoc """
  Three-species coevolution loop: Authors + MetaLearners (M) + Solvers.

  Authors generate problems at the difficulty frontier. M variants compete
  to select the best mutation strategy (GP operators + LLM mutation).
  Solvers are the inner population evolved by each M variant.

  Each outer generation:
  1. Authors generate problems from data context
  2. Each M variant runs the inner evolution loop on Author problems
  3. Authors scored by difficulty calibration: -abs(success_rate - 0.5)
  4. M scored by solve_rate - lambda * llm_tokens
  5. Both populations mutated and selected
  """

  alias PtcRunner.Evolve.{Individual, Operators}
  alias PtcRunner.Meta.{Author, MetaEvaluator, MetaLearner, Seeds}

  @type config :: %{
          outer_generations: pos_integer(),
          m_mu: pos_integer(),
          m_lambda: pos_integer(),
          author_mu: pos_integer(),
          author_lambda: pos_integer(),
          tournament_size: pos_integer(),
          elitism: pos_integer(),
          data_context: map(),
          solver_seeds: [String.t()],
          log_dir: String.t() | nil,
          eval_config: keyword()
        }

  @default_config %{
    outer_generations: 8,
    m_mu: 4,
    m_lambda: 4,
    author_mu: 4,
    author_lambda: 2,
    tournament_size: 2,
    elitism: 2,
    data_context: %{},
    solver_seeds: [],
    log_dir: nil,
    eval_config: [],
    m_llm_mutation_rate: 0.0,
    m_crossover_rate: 0.5,
    parallel: true,
    task_timeout: 120_000
  }

  @doc """
  Run the three-species coevolution loop.

  Evolves Authors (problem generators) and M variants (operator selectors)
  simultaneously. Returns the best M, best Authors, and generation history.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    config = Map.merge(@default_config, Map.new(opts))
    log_dir = config.log_dir

    if log_dir, do: File.mkdir_p!(log_dir)

    # Initialize populations
    m_population = Seeds.seeds()
    anchor_authors = Seeds.author_seeds()
    evolved_authors = []

    IO.puts("=== Three-Species Coevolution ===")
    IO.puts("M variants: mu=#{config.m_mu}, lambda=#{config.m_lambda}")
    IO.puts("Authors: #{length(anchor_authors)} anchors + evolving pool")
    IO.puts("Outer generations: #{config.outer_generations}")
    IO.puts("")

    # Generate initial problems from anchor Authors
    all_authors = anchor_authors ++ evolved_authors
    {problems, all_authors} = generate_problems(all_authors, config)
    IO.puts("Initial problems: #{length(problems)} (from #{length(all_authors)} Authors)")

    # Evaluate initial M population
    m_population = evaluate_m_population(m_population, problems, config)
    all_authors = score_authors(all_authors, m_population)

    initial_summary = gen_summary(0, m_population, all_authors)
    log_generation(0, m_population, all_authors, log_dir)
    print_summary(initial_summary)

    # Split back: anchors keep their scores, evolved pool is empty initially
    anchor_authors = Enum.filter(all_authors, fn a -> a.id in anchor_ids(anchor_authors) end)
    evolved_authors = Enum.reject(all_authors, fn a -> a.id in anchor_ids(anchor_authors) end)

    # Coevolution loop
    {final_m, final_anchors, final_evolved, history} =
      Enum.reduce(
        1..config.outer_generations,
        {m_population, anchor_authors, evolved_authors, [initial_summary]},
        fn gen, {m_pop, anchors, evolved, hist} ->
          # --- Evolve Authors: mutate from ALL authors (anchors + evolved) ---
          all_auth = anchors ++ evolved

          author_children =
            1..config.author_lambda
            |> Enum.map(fn _ -> tournament_select(all_auth, config.tournament_size, :author) end)
            |> Enum.map(fn a -> Author.mutate(a, config.data_context) end)
            |> Enum.reject(&is_nil/1)
            |> Enum.map(fn {:ok, a} -> %{a | generation: gen} end)

          # Combine: anchors always present + evolved pool + new children
          all_authors_this_gen = anchors ++ evolved ++ author_children
          {problems, all_authors_this_gen} = generate_problems(all_authors_this_gen, config)

          # --- Evolve M (crossover + mutation) ---
          m_children =
            reproduce_m(m_pop, config)
            |> Enum.map(fn m -> %{m | generation: gen} end)

          all_m = m_pop ++ m_children
          all_m = evaluate_m_population(all_m, problems, config)

          # --- Score all Authors ---
          all_authors_this_gen = score_authors(all_authors_this_gen, all_m)

          # --- Select M survivors ---
          new_m = select_survivors(all_m, config.m_mu, config.elitism, :m)

          # --- Author selection: anchors always survive, select among evolved ---
          anchor_ids_set = anchor_ids(anchor_authors)
          new_anchors = Enum.filter(all_authors_this_gen, fn a -> a.id in anchor_ids_set end)

          evolvable = Enum.reject(all_authors_this_gen, fn a -> a.id in anchor_ids_set end)
          new_evolved = select_survivors(evolvable, config.author_mu, config.elitism, :author)

          all_surviving_authors = new_anchors ++ new_evolved
          summary = gen_summary(gen, new_m, all_surviving_authors)
          log_generation(gen, new_m, all_surviving_authors, log_dir)
          print_summary(summary)

          {new_m, new_anchors, new_evolved, hist ++ [summary]}
        end
      )

    all_final_authors = final_anchors ++ final_evolved
    best_m = Enum.max_by(final_m, fn m -> m.fitness || -999.0 end)

    IO.puts("\n=== Best MetaLearner ===")
    IO.puts("ID: #{best_m.id}")
    IO.puts("Fitness: #{inspect(best_m.fitness)}")
    IO.puts("Source:\n#{best_m.source}")

    IO.puts("\n=== Surviving Authors ===")

    Enum.each(all_final_authors, fn a ->
      IO.puts(
        "  #{a.id}: fitness=#{inspect(a.fitness && Float.round(a.fitness, 3))} type=#{a.output_type}"
      )
    end)

    if log_dir do
      summary = %{
        best_m_id: best_m.id,
        best_m_fitness: best_m.fitness,
        best_m_source: best_m.source,
        authors:
          Enum.map(all_final_authors, fn a ->
            %{id: a.id, fitness: a.fitness, source: a.source}
          end),
        history: history
      }

      File.write!(Path.join(log_dir, "summary.json"), Jason.encode!(summary, pretty: true))
    end

    %{
      best_m: best_m,
      m_population: final_m,
      authors: all_final_authors,
      history: history
    }
  end

  # Generate problems from Author programs, filtering out broken Authors
  defp generate_problems(authors, config) do
    gen_fn = fn author ->
      case Author.generate_problem(author, config.data_context) do
        {:ok, problem} -> {:ok, author, problem}
        {:error, _} -> {:error, author}
      end
    end

    results =
      if Map.get(config, :parallel, true) do
        authors
        |> Task.async_stream(gen_fn,
          max_concurrency: length(authors),
          timeout: 5_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, _} -> {:error, nil}
        end)
      else
        Enum.map(authors, gen_fn)
      end

    valid_authors =
      Enum.flat_map(results, fn
        {:ok, author, _} -> [author]
        {:error, _} -> []
      end)

    problems =
      Enum.flat_map(results, fn
        {:ok, _, problem} -> [problem]
        {:error, _} -> []
      end)

    {problems, valid_authors}
  end

  # Evaluate all M variants against the current problem set
  defp evaluate_m_population(m_pop, problems, config) do
    eval_opts =
      Keyword.merge(config.eval_config,
        problems: problems,
        seeds: config.solver_seeds,
        parallel: Map.get(config, :parallel, true),
        task_timeout: Map.get(config, :task_timeout, 120_000)
      )

    evaluate_fn = fn m ->
      start = System.monotonic_time(:millisecond)
      result = MetaEvaluator.evaluate(m, eval_opts)
      elapsed = System.monotonic_time(:millisecond) - start
      IO.puts("  M #{m.id}: fitness=#{format_float(result.fitness, 3)} (#{elapsed}ms)")
      %{m | fitness: result.fitness, metadata: Map.put(m.metadata, :eval_result, result)}
    end

    # Sequential M evaluation — parallel causes Finch connection pool exhaustion
    # when multiple M variants fire LLM calls simultaneously. The LLM call cap
    # (max_llm_calls_per_problem) keeps individual M eval fast enough.
    Enum.map(m_pop, evaluate_fn)
  end

  # Score Authors based on how well M variants solved their problems
  defp score_authors(authors, m_population) do
    # Collect per-problem solve rates across all M variants
    problem_solve_rates =
      m_population
      |> Enum.flat_map(fn m ->
        case get_in(m.metadata, [:eval_result, :per_problem]) do
          nil -> []
          per_problem -> per_problem
        end
      end)
      |> Enum.group_by(& &1.problem)
      |> Map.new(fn {name, results} ->
        solved = Enum.count(results, & &1.solved)
        total = length(results)
        rate = if total > 0, do: solved / total, else: 0.0
        {name, rate}
      end)

    Enum.map(authors, fn author ->
      problem_name = "author-#{author.id}"
      success_rate = Map.get(problem_solve_rates, problem_name, 0.0)
      node_count = Individual.node_count(author.ast)
      fitness = Author.compute_fitness(success_rate, node_count)

      %{
        author
        | fitness: fitness,
          metadata: Map.put(author.metadata, :success_rate, success_rate)
      }
    end)
  end

  defp anchor_ids(authors) do
    MapSet.new(Enum.map(authors, & &1.id))
  end

  defp select_survivors(population, mu, elitism, _type) do
    sorted = Enum.sort_by(population, fn x -> x.fitness || -999.0 end, :desc)
    elite = Enum.take(sorted, elitism)
    rest = Enum.drop(sorted, elitism)
    remaining = Enum.take(rest, mu - elitism)
    elite ++ remaining
  end

  defp reproduce_m(m_pop, config) do
    crossover_rate = Map.get(config, :m_crossover_rate, 0.5)

    Enum.map(1..config.m_lambda, fn _ ->
      if :rand.uniform() < crossover_rate and length(m_pop) >= 2 do
        parent_a = tournament_select(m_pop, config.tournament_size, :m)
        parent_b = tournament_select(m_pop, config.tournament_size, :m)
        crossover_m(parent_a, parent_b) || mutate_m(parent_a, config)
      else
        parent = tournament_select(m_pop, config.tournament_size, :m)
        mutate_m(parent, config)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp mutate_m(%MetaLearner{source: source, id: parent_id} = m, config) do
    llm_model = get_in(config, [:eval_config]) |> get_llm_model()
    m_llm_rate = Map.get(config, :m_llm_mutation_rate, 0.0)

    # Occasionally use LLM to mutate M if a model is configured
    if llm_model != nil and :rand.uniform() < m_llm_rate do
      llm_mutate_m(m, llm_model, config)
    else
      gp_mutate_m(source, parent_id)
    end
  end

  @doc false
  # Branch-level crossover between two M variants.
  # Extracts cond branches from both parents and interleaves them.
  # Always ends with an :else branch from one parent.
  def crossover_m(%MetaLearner{} = a, %MetaLearner{} = b) do
    with {:ok, branches_a} <- extract_cond_branches(a.ast),
         {:ok, branches_b} <- extract_cond_branches(b.ast) do
      # Separate :else branches from regular branches
      {regular_a, else_a} = split_else_branch(branches_a)
      {regular_b, else_b} = split_else_branch(branches_b)

      # Interleave: randomly sample from both parents
      all_regular = regular_a ++ regular_b
      shuffled = Enum.shuffle(all_regular)

      # Take a subset (between min and max of parent branch counts)
      min_branches = max(1, min(length(regular_a), length(regular_b)))
      max_branches = length(regular_a) + length(regular_b)
      take_count = min_branches + :rand.uniform(max(1, max_branches - min_branches)) - 1
      selected = Enum.take(shuffled, take_count)

      # Pick :else from either parent
      else_branch = if :rand.uniform() < 0.5, do: else_a, else: else_b

      # Rebuild the (fn [fv] (cond ...)) AST
      cond_items =
        Enum.flat_map(selected, fn {condition, result} -> [condition, result] end) ++
          else_branch

      new_ast =
        {:list,
         [
           {:symbol, :fn},
           {:vector, [{:symbol, :fv}]},
           {:list, [{:symbol, :cond} | cond_items]}
         ]}

      new_source = Operators.format_ast(new_ast)

      case MetaLearner.from_source(new_source,
             parent_id: "#{a.id}+#{b.id}",
             metadata: %{operator: :crossover_m, parents: [a.id, b.id]}
           ) do
        {:ok, new_m} ->
          IO.write("X")
          new_m

        {:error, _} ->
          nil
      end
    else
      _ -> nil
    end
  end

  # Extract cond branches as [{condition_ast, result_ast}] pairs from M's AST.
  # M structure: (fn [fv] (cond condition1 result1 condition2 result2 ... :else resultN))
  defp extract_cond_branches(
         {:list, [{:symbol, :fn}, {:vector, _}, {:list, [{:symbol, :cond} | body]}]}
       ) do
    branches = pair_cond_body(body)
    if branches == [], do: {:error, :no_branches}, else: {:ok, branches}
  end

  defp extract_cond_branches(_), do: {:error, :not_a_cond_fn}

  defp pair_cond_body([]), do: []

  defp pair_cond_body([condition, result | rest]),
    do: [{condition, result} | pair_cond_body(rest)]

  defp pair_cond_body([_single]), do: []

  # Split the :else branch from regular branches
  defp split_else_branch(branches) do
    {else_branches, regular} =
      Enum.split_with(branches, fn {condition, _result} -> condition == {:keyword, :else} end)

    else_part =
      case else_branches do
        [{_cond, result} | _] -> [{:keyword, :else}, result]
        [] -> [{:keyword, :else}, {:keyword, :point_mutation}]
      end

    {regular, else_part}
  end

  defp gp_mutate_m(source, parent_id) do
    case Individual.from_source(source, parent_ids: [parent_id]) do
      {:ok, ind} ->
        case Operators.mutate(ind) do
          {:ok, mutated_ind} ->
            case MetaLearner.from_source(mutated_ind.source,
                   parent_id: parent_id,
                   metadata: mutated_ind.metadata
                 ) do
              {:ok, new_m} -> new_m
              {:error, _} -> nil
            end

          {:error, _} ->
            nil
        end

      {:error, _} ->
        nil
    end
  end

  defp llm_mutate_m(%MetaLearner{source: source, id: parent_id} = m, llm_model, _config) do
    eval = Map.get(m.metadata, :eval_result, %{})
    solve_rate = Map.get(eval, :solve_rate, 0.0)
    tokens = Map.get(eval, :total_llm_tokens, 0)
    gp_suf = Map.get(eval, :gp_sufficiency, 0.0)

    prompt = """
    You are improving a meta-learner M — a PTC-Lisp function that selects mutation operators
    for an inner GP evolution loop. M takes a failure vector and returns an operator keyword.

    Current M program:
    #{source}

    Performance: solve_rate=#{Float.round(solve_rate, 3)}, llm_tokens=#{tokens}, gp_sufficiency=#{Float.round(gp_suf, 2)}

    Strategy diagnosis:
    #{diagnose_m_strategy(eval)}

    Valid operators M can return:
    :point_mutation — tweak a literal value (number, string)
    :arg_swap — swap arguments of a function call
    :wrap_form — wrap a subtree in a function call
    :subtree_delete — replace a subtree with a simple value
    :subtree_dup — copy one subtree over another
    :crossover — swap subtrees between two programs
    :llm_mutation — call LLM to rewrite the program (expensive but creative)

    Failure vector fields available via (get fv :field):
    :compile_error (bool) — program failed to parse
    :timeout (bool) — sandbox timeout
    :wrong_type (bool) — output type mismatch
    :partial_score (0.0-1.0) — how close to correct
    :size_bloat (bool) — program too large
    :no_improvement (bool) — no fitness gain over parent
    :node_count (int) — AST size of the program
    :has_join_pattern (bool) — program uses set+contains? pattern

    Improve M's operator selection strategy. Return ONLY the improved (fn [fv] ...) program.
    No explanation. No markdown fences.
    """

    request = %{
      system:
        "You write PTC-Lisp operator selection functions. " <>
          "Return ONLY valid PTC-Lisp (fn [fv] (cond ...)) code.",
      messages: [%{role: :user, content: prompt}]
    }

    case PtcRunner.LLM.call(llm_model, request) do
      {:ok, %{content: content}} ->
        new_source = clean_llm_source(content)

        case MetaLearner.from_source(new_source,
               parent_id: parent_id,
               metadata: %{operator: :llm_m_mutation}
             ) do
          {:ok, new_m} ->
            IO.write("M*")
            new_m

          {:error, _} ->
            IO.write("Mx")
            gp_mutate_m(source, parent_id)
        end

      {:error, _} ->
        IO.write("Mx")
        gp_mutate_m(source, parent_id)
    end
  end

  defp diagnose_m_strategy(eval) do
    solve_rate = Map.get(eval, :solve_rate, 0.0)
    gp_suf = Map.get(eval, :gp_sufficiency, 0.0)
    tokens = Map.get(eval, :total_llm_tokens, 0)
    hard_rate = Map.get(eval, :hard_solve_rate, 0.0)

    cond do
      solve_rate < 0.2 ->
        "Very low solve rate. M needs to try more aggressive operators or use :llm_mutation for hard problems."

      solve_rate > 0.8 and tokens > 10_000 ->
        "High solve rate but too many LLM tokens. M should reserve :llm_mutation for problems where GP fails."

      hard_rate < 0.1 and solve_rate > 0.3 ->
        "Solves easy problems but fails hard ones (cross-dataset joins). M should use :llm_mutation when :has_join_pattern is false and score is low."

      gp_suf > 0.9 ->
        "Almost all solves from GP. M could achieve more by using :llm_mutation on structural problems."

      true ->
        "Mixed performance. Look for patterns in which failures respond to which operators."
    end
  end

  defp clean_llm_source(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```[\w]*\n?/, "")
    |> String.replace(~r/\n?```\s*$/, "")
    |> String.trim()
  end

  defp get_llm_model(nil), do: nil

  defp get_llm_model(eval_config) when is_list(eval_config) do
    Keyword.get(eval_config, :llm_model)
  end

  defp get_llm_model(_), do: nil

  defp tournament_select(population, tournament_size, _type) do
    population
    |> Enum.take_random(min(tournament_size, length(population)))
    |> Enum.max_by(fn x -> x.fitness || -999.0 end)
  end

  defp gen_summary(gen, m_population, author_population) do
    m_fitnesses = m_population |> Enum.map(& &1.fitness) |> Enum.reject(&is_nil/1)
    a_fitnesses = author_population |> Enum.map(& &1.fitness) |> Enum.reject(&is_nil/1)

    m_eval_results =
      Enum.map(m_population, fn m -> Map.get(m.metadata, :eval_result, %{}) end)

    m_tokens =
      Enum.map(m_eval_results, fn r -> Map.get(r, :total_llm_tokens, 0) end)

    author_rates =
      author_population
      |> Enum.map(fn a -> Map.get(a.metadata, :success_rate, 0.0) end)

    # Aggregate measurement metrics across M variants
    avg_tokens_per_solve = safe_avg(m_eval_results, :tokens_per_solve)
    avg_hard_solve_rate = safe_avg(m_eval_results, :hard_solve_rate)
    avg_llm_precision = safe_avg(m_eval_results, :llm_precision)
    avg_gp_sufficiency = safe_avg(m_eval_results, :gp_sufficiency)
    total_llm_calls = Enum.sum(Enum.map(m_eval_results, &Map.get(&1, :llm_call_count, 0)))

    # Per-M variant detail for logging (compute entropy once per variant)
    m_variants =
      Enum.map(m_population, fn m ->
        eval = Map.get(m.metadata, :eval_result, %{})

        entropy =
          case Map.get(eval, :operator_counts) do
            nil -> 0.0
            counts -> MetaEvaluator.operator_entropy(counts)
          end

        %{
          id: m.id,
          fitness: m.fitness,
          solve_rate: Map.get(eval, :solve_rate, 0.0),
          tokens: Map.get(eval, :total_llm_tokens, 0),
          tokens_per_solve: Map.get(eval, :tokens_per_solve, 0.0),
          hard_solve_rate: Map.get(eval, :hard_solve_rate, 0.0),
          llm_precision: Map.get(eval, :llm_precision, 0.0),
          gp_sufficiency: Map.get(eval, :gp_sufficiency, 0.0),
          llm_calls: Map.get(eval, :llm_call_count, 0),
          entropy: entropy
        }
      end)

    avg_entropy =
      if m_variants == [],
        do: 0.0,
        else: Enum.sum(Enum.map(m_variants, & &1.entropy)) / length(m_variants)

    %{
      generation: gen,
      m_best_fitness: if(m_fitnesses == [], do: 0.0, else: Enum.max(m_fitnesses)),
      m_avg_fitness:
        if(m_fitnesses == [], do: 0.0, else: Enum.sum(m_fitnesses) / length(m_fitnesses)),
      m_avg_tokens: if(m_tokens == [], do: 0, else: Enum.sum(m_tokens) / length(m_tokens)),
      author_count: length(author_population),
      author_avg_fitness:
        if(a_fitnesses == [], do: 0.0, else: Enum.sum(a_fitnesses) / length(a_fitnesses)),
      author_avg_success_rate:
        if(author_rates == [], do: 0.0, else: Enum.sum(author_rates) / length(author_rates)),
      # Measurement metrics (Phase A.6)
      avg_tokens_per_solve: avg_tokens_per_solve,
      avg_hard_solve_rate: avg_hard_solve_rate,
      avg_llm_precision: avg_llm_precision,
      avg_gp_sufficiency: avg_gp_sufficiency,
      avg_operator_entropy: avg_entropy,
      total_llm_calls: total_llm_calls,
      m_variants: m_variants
    }
  end

  defp safe_avg(eval_results, key) do
    values = Enum.map(eval_results, &Map.get(&1, key, 0.0))
    if values == [], do: 0.0, else: Enum.sum(values) / length(values)
  end

  defp print_summary(s) do
    IO.puts(
      "Gen #{String.pad_leading(Integer.to_string(s.generation), 3)}: " <>
        "M best=#{Float.round(s.m_best_fitness, 3)} avg=#{Float.round(s.m_avg_fitness, 3)} " <>
        "tokens=#{round(s.m_avg_tokens)} tok/solve=#{Float.round(s.avg_tokens_per_solve, 0)} " <>
        "llm_prec=#{Float.round(s.avg_llm_precision, 2)} " <>
        "gp_suf=#{Float.round(s.avg_gp_sufficiency, 2)} | " <>
        "Authors(#{s.author_count}) avg_rate=#{Float.round(s.author_avg_success_rate, 2)} " <>
        "avg_fit=#{Float.round(s.author_avg_fitness, 3)}"
    )

    # Print per-M variant detail
    Enum.each(s.m_variants, fn v ->
      IO.puts(
        "  #{String.pad_trailing(v.id, 20)} " <>
          "fit=#{format_float(v.fitness, 3)} " <>
          "solve=#{format_float(v.solve_rate, 2)} " <>
          "tok=#{v.tokens} " <>
          "tok/s=#{format_float(v.tokens_per_solve, 0)} " <>
          "llm=#{v.llm_calls} " <>
          "ent=#{format_float(v.entropy, 2)}"
      )
    end)
  end

  defp format_float(nil, _decimals), do: "nil"
  defp format_float(f, decimals), do: Float.round(f * 1.0, decimals) |> to_string()

  defp log_generation(_gen, _m_pop, _auth_pop, nil), do: :ok

  defp log_generation(gen, m_pop, auth_pop, log_dir) do
    gen_dir =
      Path.join(log_dir, "outer-gen-#{String.pad_leading(Integer.to_string(gen), 3, "0")}")

    File.mkdir_p!(gen_dir)

    Enum.each(m_pop, fn m ->
      data = %{
        type: "meta_learner",
        id: m.id,
        source: m.source,
        generation: m.generation,
        fitness: m.fitness,
        eval_result: Map.get(m.metadata, :eval_result)
      }

      File.write!(Path.join(gen_dir, "m-#{m.id}.json"), Jason.encode!(data, pretty: true))
    end)

    Enum.each(auth_pop, fn a ->
      data = %{
        type: "author",
        id: a.id,
        source: a.source,
        generation: a.generation,
        fitness: a.fitness,
        output_type: a.output_type,
        success_rate: Map.get(a.metadata, :success_rate)
      }

      File.write!(Path.join(gen_dir, "a-#{a.id}.json"), Jason.encode!(data, pretty: true))
    end)
  end
end
