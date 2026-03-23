defmodule Mix.Tasks.Ablation do
  @moduledoc """
  Run ablation experiments comparing prompt variants.

  ## Usage

      mix ablation --variants=auto,baseline --runs=30 --tests=20,23
      mix ablation --variants=auto,explicit --runs=10 --tests=1,2,3

  ## Options

    * `--variants` - Comma-separated variant names (required). Available:
      Policy variants (natural turn budgets per test):
      - `auto` - current default routing (single_shot/explicit_return)
      Mechanism variants (forced 6-turn budget):
      - `baseline` - auto_return prompt, 6 turns
      - `explicit` - explicit_return prompt, 6 turns
    * `--tests` - Comma-separated test indices (required)
    * `--runs` - Number of runs per test per variant (default: 5)
    * `--model` - Model to use (default: from PTC_DEMO_MODEL env)
    * `--json` - Write JSON report to demo/reports/
    * `--verbose` - Show detailed output
  """

  use Mix.Task

  # Policy variants: use runner-level prompt routing, natural turn budgets per test
  # Mechanism variants: force specific prompt + turn budget via agent_overrides
  @variant_presets %{
    # Policy variants: use runner-level prompt routing, natural turn budgets per test
    "auto" => %{
      name: "auto",
      prompt: :auto
    },
    # Mechanism variants: force specific prompt + turn budget via agent_overrides
    "baseline" => %{
      name: "baseline",
      agent_overrides: [prompt_profile: :auto_return, max_turns: 6]
    },
    "explicit" => %{
      name: "explicit",
      agent_overrides: [prompt_profile: :explicit_return, max_turns: 6]
    }
  }

  @impl Mix.Task
  def run(args) do
    # Start the application
    Mix.Task.run("app.start")

    {parsed, _, _} =
      OptionParser.parse(args,
        strict: [
          variants: :string,
          tests: :string,
          runs: :integer,
          model: :string,
          json: :boolean,
          verbose: :boolean
        ]
      )

    # Parse variants
    variant_names =
      case Keyword.get(parsed, :variants) do
        nil ->
          Mix.raise(
            "--variants is required. Available: #{Map.keys(@variant_presets) |> Enum.join(", ")}"
          )

        names ->
          String.split(names, ",")
      end

    variants =
      Enum.map(variant_names, fn name ->
        case Map.get(@variant_presets, name) do
          nil ->
            Mix.raise(
              "Unknown variant '#{name}'. Available: #{Map.keys(@variant_presets) |> Enum.join(", ")}"
            )

          preset ->
            preset
        end
      end)

    # Parse tests (required)
    tests =
      case Keyword.get(parsed, :tests) do
        nil ->
          Mix.raise("--tests is required (e.g., --tests=1,2,3)")

        indices ->
          indices |> String.split(",") |> Enum.map(&String.to_integer/1)
      end

    runs = Keyword.get(parsed, :runs, 5)
    model = Keyword.get(parsed, :model)
    verbose = Keyword.get(parsed, :verbose, false)
    write_json = Keyword.get(parsed, :json, false)

    # Ensure dotenv and API key
    PtcDemo.CLIBase.load_dotenv()
    PtcDemo.CLIBase.ensure_api_key!()

    # Start agent if needed
    case Process.whereis(PtcDemo.Agent) do
      nil -> PtcDemo.Agent.start_link()
      _pid -> :ok
    end

    if model, do: PtcDemo.Agent.set_model(model)

    # Run the experiment
    results =
      PtcDemo.Ablation.Runner.run(variants,
        runs: runs,
        tests: tests,
        model: model,
        verbose: verbose
      )

    # Print report
    PtcDemo.Ablation.Report.print_summary(results, variants)

    # Write JSON if requested
    if write_json do
      json_data = PtcDemo.Ablation.Report.to_json(results, variants)

      reports_dir = Path.join(["demo", "reports"])
      File.mkdir_p!(reports_dir)

      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M")
      filename = "ablation_#{timestamp}.json"
      path = Path.join(reports_dir, filename)

      File.write!(path, JSON.encode!(json_data))
      IO.puts("JSON report written to: #{path}")
    end
  end
end
