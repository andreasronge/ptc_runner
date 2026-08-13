defmodule PtcRunner.StandaloneCommandRuntime do
  @moduledoc false

  alias PtcRunner.Dotenv
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandRuntime

  @doc false
  @spec bootstrap(CommandArguments.t()) ::
          {:ok, CommandRuntime.t()} | {:error, :command_bootstrap_failed}
  def bootstrap(%CommandArguments{} = arguments) do
    case Application.ensure_all_started(:ptc_runner) do
      {:ok, _started} -> runtime(arguments)
      {:error, _reason} -> {:error, :command_bootstrap_failed}
    end
  rescue
    _exception -> {:error, :command_bootstrap_failed}
  catch
    _kind, _reason -> {:error, :command_bootstrap_failed}
  end

  def bootstrap(_arguments), do: {:error, :command_bootstrap_failed}

  defp runtime(arguments) do
    options =
      [provider_application_mode: :command_vm] ++
        Dotenv.environment_setup_option(arguments.frontend_options)

    case CommandRuntime.new(options) do
      {:ok, runtime} -> {:ok, runtime}
      {:error, :invalid_command_runtime} -> {:error, :command_bootstrap_failed}
    end
  end
end
