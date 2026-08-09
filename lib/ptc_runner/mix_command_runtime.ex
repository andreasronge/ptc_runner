defmodule PtcRunner.MixCommandRuntime do
  @moduledoc false

  alias PtcRunner.Dotenv
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandRuntime

  @doc false
  @spec bootstrap(CommandArguments.t()) ::
          {:ok, CommandRuntime.t()} | {:error, :command_bootstrap_failed}
  def bootstrap(%CommandArguments{} = arguments) do
    with :ok <- bootstrap(), do: runtime(arguments)
  end

  def bootstrap(_arguments), do: {:error, :command_bootstrap_failed}

  @doc false
  @spec bootstrap() :: :ok | {:error, :command_bootstrap_failed}
  def bootstrap do
    Mix.Task.run("app.config")

    case Application.ensure_all_started(:ptc_runner) do
      {:ok, _started} -> :ok
      {:error, _reason} -> {:error, :command_bootstrap_failed}
    end
  rescue
    _exception -> {:error, :command_bootstrap_failed}
  catch
    _kind, _reason -> {:error, :command_bootstrap_failed}
  end

  @doc false
  @spec options() :: keyword()
  def options do
    [
      provider_application_mode: provider_application_mode(),
      environment_setup: &load_dotenv/0
    ]
  end

  @doc false
  @spec runtime(CommandArguments.t()) ::
          {:ok, CommandRuntime.t()} | {:error, :command_bootstrap_failed}
  def runtime(%CommandArguments{} = arguments) do
    targets = Keyword.get_values(arguments.frontend_options, :authorize_mcp)

    runtime_options =
      case targets do
        [] ->
          options()

        [_target | _rest] ->
          options() ++
            [authorization_targets: targets, authorization_notifier: &notify_authorization_url/1]
      end

    case CommandRuntime.new(runtime_options) do
      {:ok, runtime} -> {:ok, runtime}
      {:error, :invalid_command_runtime} -> {:error, :command_bootstrap_failed}
    end
  end

  def runtime(_arguments), do: {:error, :command_bootstrap_failed}

  defp provider_application_mode do
    applications = Application.started_applications() |> Enum.map(&elem(&1, 0))
    if :req_llm in applications, do: :host_owned, else: :command_vm
  end

  defp load_dotenv do
    Dotenv.load()
  rescue
    _exception -> {:error, :dotenv_unavailable}
  catch
    _kind, _reason -> {:error, :dotenv_unavailable}
  end

  defp notify_authorization_url(url) do
    Mix.shell().info("Open this one-time authorization URL:\n#{url}")
    :ok
  end
end
