defmodule PtcRunner.TestSupport.AgentFixtures do
  @moduledoc false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.MissionEnvironment

  def replay_alias_route(alias_name, default?, capability) do
    %{
      alias: alias_name,
      source: "llm_replay",
      installation_revision: alias_name <> "-v1",
      default?: default?,
      capability: capability,
      max_calls: nil
    }
  end

  def replay_alias_router(chosen_capability, other_capability) do
    LLMRouter.new([
      replay_alias_route("chosen", true, chosen_capability),
      replay_alias_route("other", false, other_capability)
    ])
  end

  def live_alias_route(alias_name, default?, capability, max_calls, opts \\ []) do
    %{
      alias: alias_name,
      source: "llm",
      installation_revision: alias_name <> "-v1",
      default?: default?,
      capability: capability,
      max_calls: max_calls,
      output_tokens: 4_096,
      reservation_bound: fn _request, _tariff ->
        {:ok, %{total_tokens: 4_096, cost: nil}}
      end
    }
    |> Map.merge(Map.new(opts))
  end

  def mission_with_source(namespace, body) do
    source = "(ns #{namespace})\n#{body}\n"

    with {:ok, component} <- Component.new(id: namespace, source: source, origin: "test"),
         {:ok, bundle} <- Kernel.compile_bundle([component]) do
      MissionEnvironment.new(bundle: bundle)
    end
  end
end
