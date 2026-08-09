defmodule PtcRunner.StandaloneCommandRuntime do
  @moduledoc false

  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandRuntime

  @doc false
  @spec bootstrap(CommandArguments.t()) ::
          {:ok, CommandRuntime.t()} | {:error, :command_bootstrap_failed}
  def bootstrap(%CommandArguments{}) do
    case Application.ensure_all_started(:ptc_runner) do
      {:ok, _started} -> {:ok, CommandRuntime.standalone()}
      {:error, _reason} -> {:error, :command_bootstrap_failed}
    end
  rescue
    _exception -> {:error, :command_bootstrap_failed}
  catch
    _kind, _reason -> {:error, :command_bootstrap_failed}
  end

  def bootstrap(_arguments), do: {:error, :command_bootstrap_failed}
end
