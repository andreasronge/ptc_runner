defmodule PtcRunner.MixRunAdapter do
  @moduledoc false

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.MixCommandRuntime

  @doc false
  @spec dispatch([binary()]) ::
          {:ok, PtcRunner.Kernel.CommandOutcome.t()}
          | {:error, PtcRunner.Kernel.CommandOutcome.t()}
  def dispatch(args), do: dispatch(args, &MixCommandRuntime.bootstrap/0)

  @doc false
  @spec dispatch([binary()], (-> term())) ::
          {:ok, PtcRunner.Kernel.CommandOutcome.t()}
          | {:error, PtcRunner.Kernel.CommandOutcome.t()}
  def dispatch(args, bootstrap) when is_list(args) and is_function(bootstrap, 0) do
    case bootstrap_safely(bootstrap) do
      :ok -> dispatch_started(args)
      {:error, :command_bootstrap_failed} -> CommandEngine.run_startup_failure()
    end
  end

  def dispatch(_args, _bootstrap), do: CommandEngine.run_startup_failure()

  defp dispatch_started(args) do
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
    options = MixCommandRuntime.options()

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

  defp bootstrap_safely(bootstrap) do
    case bootstrap.() do
      :ok -> :ok
      _failure -> {:error, :command_bootstrap_failed}
    end
  rescue
    _exception -> {:error, :command_bootstrap_failed}
  catch
    _kind, _reason -> {:error, :command_bootstrap_failed}
  end

  defp notify_authorization_url(url) do
    Mix.shell().info("Open this one-time authorization URL:\n#{url}")
    :ok
  end
end
