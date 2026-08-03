defmodule PtcRunner.TestSupport.ProviderSessionFixture do
  @moduledoc false

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar

  def start(resources, %Limits{} = limits) when is_list(resources) do
    {:ok, session} = ProviderSession.start(limits)

    resources
    |> Enum.reverse()
    |> Enum.each(fn close ->
      {:ok, registrar} = ProviderSession.open_registrar(session)
      :ok = ResourceRegistrar.activate(registrar)
      :ok = ResourceRegistrar.commit(registrar, close)
    end)

    session
  end
end
