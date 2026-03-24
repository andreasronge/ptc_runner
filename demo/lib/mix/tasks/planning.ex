defmodule Mix.Tasks.Planning do
  @moduledoc """
  Run planner→executor benchmark experiments.

  ## Usage

      mix planning --conditions=direct,planned,specified --runs=5
      mix planning --conditions=planned --tests=25,26 --verbose
      mix planning --model=haiku --json

  ## Options

    * `--conditions` - Comma-separated: direct, planned, specified (default: all three)
    * `--tests` - Comma-separated test indices (default: all plan cases)
    * `--runs` - Number of runs per test per condition (default: 1)
    * `--model` - Model to use (default: from PTC_DEMO_MODEL env)
    * `--json` - Write JSON report to demo/reports/
    * `--verbose` - Show detailed output
  """

  use Mix.Task

  @valid_conditions ~w(direct planned specified)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _, _} =
      OptionParser.parse(args,
        strict: [
          conditions: :string,
          tests: :string,
          runs: :integer,
          model: :string,
          json: :boolean,
          verbose: :boolean
        ]
      )

    # Parse conditions
    conditions =
      case Keyword.get(parsed, :conditions) do
        nil ->
          [:direct, :planned, :specified]

        names ->
          names
          |> String.split(",")
          |> Enum.map(fn name ->
            if name in @valid_conditions do
              String.to_atom(name)
            else
              Mix.raise(
                "Unknown condition '#{name}'. Available: #{Enum.join(@valid_conditions, ", ")}"
              )
            end
          end)
      end

    # Parse tests (default: plan cases)
    tests =
      case Keyword.get(parsed, :tests) do
        nil ->
          PtcDemo.TestRunner.TestCase.plan_case_indices()

        indices ->
          indices |> String.split(",") |> Enum.map(&String.to_integer/1)
      end

    runs = Keyword.get(parsed, :runs, 1)
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
      PtcDemo.Planning.Runner.run(conditions,
        runs: runs,
        tests: tests,
        model: model,
        verbose: verbose
      )

    # Print report
    PtcDemo.Planning.Report.print_summary(results, conditions)

    # Write JSON if requested
    if write_json do
      reports_dir = Path.join(["demo", "reports"])
      File.mkdir_p!(reports_dir)

      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M")
      filename = "planning_#{timestamp}.json"
      path = Path.join(reports_dir, filename)

      File.write!(path, JSON.encode!(results |> PtcDemo.Planning.Report.to_json(conditions)))
      IO.puts("JSON report written to: #{path}")
    end
  end
end
