defmodule Mix.Tasks.Alma.Run do
  @moduledoc """
  Runs the ALMA meta-learning loop with tracing enabled.

  ## Usage

      mix alma.run [options]

  ## Options

    * `--iterations` - number of evolutionary iterations (default: 5)
    * `--episodes` - tasks per collection/deployment phase (default: 3)
    * `--rooms` - rooms per GraphWorld environment (default: 6)
    * `--seed` - random seed for reproducibility (default: 42)
    * `--deploy-seeds` - number of seed offsets for deployment scoring (default: 3)
    * `--family` - family seed for shared topology (default: same as seed)
    * `--no-family` - disable family mode (legacy single-seed behavior)
    * `--env` - environment to use: "graph_world" (default) or "alfworld"
    * `--model` - LLM model for task execution (default: "bedrock:haiku")
    * `--meta-model` - LLM model for meta agent and analyst (default: same as --model)
    * `--embed-model` - embedding model for VectorStore similarity (default: "embed" → ollama:nomic-embed-text)
    * `--no-embed` - disable real embeddings, use n-gram fallback
    * `--no-trace` - disable trace output
    * `--quiet` - disable verbose output
    * `--python` - Python executable path for ALFWorld (default: "python3")
    * `--alfworld-data` - ALFWorld data directory (default: "~/.cache/alfworld/")

  ## Examples

      mix alma.run
      mix alma.run --iterations 3 --episodes 5
      mix alma.run --model bedrock:sonnet --iterations 2
  """

  use Mix.Task

  @shortdoc "Run the ALMA meta-learning loop"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          iterations: :integer,
          episodes: :integer,
          rooms: :integer,
          seed: :integer,
          family: :integer,
          no_family: :boolean,
          deploy_seeds: :integer,
          env: :string,
          model: :string,
          meta_model: :string,
          embed_model: :string,
          no_embed: :boolean,
          no_trace: :boolean,
          quiet: :boolean,
          python: :string,
          alfworld_data: :string
        ]
      )

    env_module =
      case Keyword.get(opts, :env, "graph_world") do
        "graph_world" -> Alma.Environments.GraphWorld
        "alfworld" -> Alma.Environments.ALFWorld
        other -> Mix.raise("Unknown environment: #{other}. Use graph_world or alfworld.")
      end

    model = Keyword.get(opts, :model, "bedrock:haiku")
    meta_model = Keyword.get(opts, :meta_model)

    embed_model =
      cond do
        Keyword.get(opts, :no_embed, false) -> nil
        Keyword.has_key?(opts, :embed_model) -> Keyword.get(opts, :embed_model)
        true -> "embed"
      end

    trace = !Keyword.get(opts, :no_trace, false)
    verbose = !Keyword.get(opts, :quiet, false)

    deploy_seeds = Keyword.get(opts, :deploy_seeds, 3)
    seed = Keyword.get(opts, :seed, 42)

    family =
      cond do
        Keyword.get(opts, :no_family, false) -> nil
        Keyword.has_key?(opts, :family) -> Keyword.get(opts, :family)
        true -> seed
      end

    alma_opts =
      [
        llm: with_retry(LLMClient.callback(model)),
        environment: env_module,
        iterations: Keyword.get(opts, :iterations, 5),
        episodes: Keyword.get(opts, :episodes, 3),
        rooms: Keyword.get(opts, :rooms, 8),
        seed: seed,
        family: family,
        deploy_seeds: deploy_seeds,
        verbose: verbose,
        trace: trace
      ] ++
        if(meta_model, do: [meta_llm: with_retry(LLMClient.callback(meta_model))], else: []) ++
        if(embed_model, do: [embed_model: LLMClient.resolve!(embed_model)], else: []) ++
        if(Keyword.has_key?(opts, :python),
          do: [python: Keyword.get(opts, :python)],
          else: []
        ) ++
        if(Keyword.has_key?(opts, :alfworld_data),
          do: [alfworld_data: Keyword.get(opts, :alfworld_data)],
          else: []
        )

    env_name = Keyword.get(opts, :env, "graph_world")

    Mix.shell().info(
      "Starting ALMA with #{model}" <>
        if(meta_model, do: " (meta: #{meta_model})", else: "") <>
        if(embed_model, do: " (embed: #{embed_model})", else: "")
    )

    Mix.shell().info("  environment: #{env_name}")
    Mix.shell().info("  iterations: #{alma_opts[:iterations]}")
    Mix.shell().info("  episodes: #{alma_opts[:episodes]}")
    Mix.shell().info("  rooms: #{alma_opts[:rooms]}")
    Mix.shell().info("  seed: #{alma_opts[:seed]}")
    Mix.shell().info("  family: #{inspect(alma_opts[:family])}")
    Mix.shell().info("  deploy_seeds: #{deploy_seeds}")
    Mix.shell().info("  embed_model: #{embed_model || "n-gram"}")
    Mix.shell().info("  trace: #{trace}\n")

    case Alma.run(alma_opts) do
      {archive, trace_path} when is_binary(trace_path) ->
        best = Alma.Archive.best(archive)
        Mix.shell().info("\nTrace written to: #{trace_path}")

        if best do
          Mix.shell().info("Best design: #{best.design.name} (score: #{best.score})")
        end

      archive ->
        best = Alma.Archive.best(archive)

        if best do
          Mix.shell().info("\nBest design: #{best.design.name} (score: #{best.score})")
        end
    end
  end

  defp with_retry(callback, max_retries \\ 3) do
    fn req ->
      Enum.reduce_while(0..max_retries, nil, fn attempt, _acc ->
        case callback.(req) do
          {:ok, result} ->
            {:halt, {:ok, result}}

          {:error, %{status: 429} = error} when attempt < max_retries ->
            delay = :timer.seconds(1) * (attempt + 1)
            IO.write("[429 retry #{attempt + 1}/#{max_retries}, waiting #{div(delay, 1000)}s]")
            Process.sleep(delay)
            {:cont, {:error, error}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end
end
