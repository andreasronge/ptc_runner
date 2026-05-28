defmodule PtcRunnerMcp.RootUpstreamRuntime do
  @moduledoc false

  alias PtcRunner.Upstream.Runtime
  alias PtcRunnerMcp.Credentials

  @name __MODULE__

  def name, do: @name

  def configured? do
    case Process.whereis(@name) do
      pid when is_pid(pid) -> true
      nil -> false
    end
  end

  def runtime do
    case Process.whereis(@name) do
      pid when is_pid(pid) -> pid
      nil -> nil
    end
  end

  def catalog_text do
    case runtime() do
      nil -> ""
      runtime -> Runtime.catalog_text(runtime)
    end
  end

  def register_redaction_secrets(secrets) when is_list(secrets) do
    Credentials.register_redaction_secrets(secrets)
  end
end
