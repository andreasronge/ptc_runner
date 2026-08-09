defmodule PtcRunner.MixCommandRuntime do
  @moduledoc false

  alias PtcRunner.Dotenv

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
end
