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
    eval_config: []
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

          # --- Evolve M ---
          m_parents =
            Enum.map(1..config.m_lambda, fn _ ->
              tournament_select(m_pop, config.tournament_size, :m)
            end)

          m_children =
            m_parents
            |> Enum.map(&mutate_m/1)
            |> Enum.reject(&is_nil/1)
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
    results =
      Enum.map(authors, fn author ->
        case Author.generate_problem(author, config.data_context) do
          {:ok, problem} -> {:ok, author, problem}
          {:error, _} -> {:error, author}
        end
      end)

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
        seeds: config.solver_seeds
      )

    Enum.map(m_pop, fn m ->
      result = MetaEvaluator.evaluate(m, eval_opts)
      %{m | fitness: result.fitness, metadata: Map.put(m.metadata, :eval_result, result)}
    end)
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

  defp mutate_m(%MetaLearner{source: source, id: parent_id}) do
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

  defp tournament_select(population, tournament_size, _type) do
    population
    |> Enum.take_random(min(tournament_size, length(population)))
    |> Enum.max_by(fn x -> x.fitness || -999.0 end)
  end

  defp gen_summary(gen, m_population, author_population) do
    m_fitnesses = m_population |> Enum.map(& &1.fitness) |> Enum.reject(&is_nil/1)
    a_fitnesses = author_population |> Enum.map(& &1.fitness) |> Enum.reject(&is_nil/1)

    m_tokens =
      m_population
      |> Enum.map(fn m -> get_in(m.metadata, [:eval_result, :total_llm_tokens]) || 0 end)

    author_rates =
      author_population
      |> Enum.map(fn a -> Map.get(a.metadata, :success_rate, 0.0) end)

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
        if(author_rates == [], do: 0.0, else: Enum.sum(author_rates) / length(author_rates))
    }
  end

  defp print_summary(s) do
    IO.puts(
      "Gen #{String.pad_leading(Integer.to_string(s.generation), 3)}: " <>
        "M best=#{Float.round(s.m_best_fitness, 3)} avg=#{Float.round(s.m_avg_fitness, 3)} " <>
        "tokens=#{round(s.m_avg_tokens)} | " <>
        "Authors(#{s.author_count}) avg_rate=#{Float.round(s.author_avg_success_rate, 2)} " <>
        "avg_fit=#{Float.round(s.author_avg_fitness, 3)}"
    )
  end

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
