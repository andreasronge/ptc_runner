defmodule Mix.Tasks.Ptc.Run do
  @shortdoc "Runs one strict PTC Kernel application"
  @moduledoc """
  Runs one V1 Kernel application through the stable shared command boundary.

      mix ptc.run ptc.json
      mix ptc.run ptc.json --input alternate-input.json
      mix ptc.run ptc.json --private-input private-input.json \
        --private-output result.json
      mix ptc.run ptc.json --trace-dir traces --inspect inspection.jsonl
      mix ptc.run ptc.json --output results/answer.json
      mix ptc.run ptc.json --host-config ptc-host.json
      mix ptc.run ptc.json --host-config ptc-host.json --authorize-mcp workspace
      mix ptc.run ptc.json --component-override-descriptor private/candidate.json

  The task prepends the fixed `run` command and delegates parsing, acquisition,
  execution, publication, and outcome projection to
  `PtcRunner.Kernel.CommandEngine`. Its only extension to the stable grammar is
  repeatable `--authorize-mcp NAME`, which opens interactive OAuth for the named
  selected MCP installation during the immediately following run.

  Both successful and failed invocations render the same closed V1 JSON
  envelope. A failed envelope is raised as the `Mix.Error` message so an
  embedding can inspect it without traversing internal failure terms.

  Private values are never rendered. They require `--private-output`; the
  envelope reports only their class and artifact state.
  """
  use Mix.Task

  alias PtcRunner.Dotenv
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRuntime

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    start_core_application!()

    {status, outcome} = dispatch(args)
    envelope = outcome |> CommandOutcome.to_map() |> Jason.encode!()

    if status == :ok do
      Mix.shell().info(envelope)
      outcome
    else
      Mix.raise(envelope)
    end
  end

  defp dispatch(args) do
    case extract_authorizations(args) do
      {:ok, stable_args, targets} ->
        case command_runtime(targets) do
          {:ok, runtime} -> CommandEngine.dispatch(["run" | stable_args], runtime)
          {:error, :invalid_command_runtime} -> invalid_arguments_outcome()
        end

      :error ->
        invalid_arguments_outcome()
    end
  end

  defp command_runtime(targets) do
    options = [
      provider_application_mode: provider_application_mode(),
      environment_setup: &load_dotenv/0
    ]

    options =
      case targets do
        [] ->
          options

        [_target | _rest] ->
          options ++
            [authorization_targets: targets, authorization_notifier: &notify_authorization_url/1]
      end

    CommandRuntime.new(options)
  end

  defp extract_authorizations(args), do: extract_authorizations(args, [], [])

  defp extract_authorizations([], stable, targets),
    do: {:ok, Enum.reverse(stable), Enum.reverse(targets)}

  defp extract_authorizations(["--" | rest], stable, targets),
    do: {:ok, Enum.reverse(stable, ["--" | rest]), Enum.reverse(targets)}

  defp extract_authorizations(["--authorize-mcp", name | rest], stable, targets)
       when is_binary(name) and name != "" do
    if String.starts_with?(name, "--"),
      do: :error,
      else: extract_authorizations(rest, stable, [name | targets])
  end

  defp extract_authorizations(["--authorize-mcp=" <> name | rest], stable, targets)
       when name != "",
       do: extract_authorizations(rest, stable, [name | targets])

  defp extract_authorizations(["--authorize-mcp" | _rest], _stable, _targets), do: :error

  defp extract_authorizations([argument | rest], stable, targets),
    do: extract_authorizations(rest, [argument | stable], targets)

  defp invalid_arguments_outcome,
    do: CommandEngine.dispatch(["run", "--authorize-mcp"])

  defp start_core_application! do
    case Application.ensure_all_started(:ptc_runner) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("could not start PtcRunner: #{inspect(reason)}")
    end
  end

  defp notify_authorization_url(url) do
    Mix.shell().info("Open this one-time authorization URL:\n#{url}")
    :ok
  end

  defp provider_application_mode do
    if :req_llm in started_applications(), do: :host_owned, else: :command_vm
  end

  defp started_applications,
    do: Application.started_applications() |> Enum.map(&elem(&1, 0))

  defp load_dotenv do
    Dotenv.load()
  rescue
    _exception -> {:error, :dotenv_unavailable}
  catch
    _kind, _reason -> {:error, :dotenv_unavailable}
  end
end
