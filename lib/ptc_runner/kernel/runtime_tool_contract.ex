defmodule PtcRunner.Kernel.RuntimeToolContract do
  @moduledoc """
  Closed runtime-route vocabulary shared by execution and evidence validation.

  This module describes routes without constructing callbacks or reading run state.
  """

  alias PtcRunner.Kernel.Environment

  @mission_contract_version 1
  @mission_routes [
    {"cap-describe", :capability_description},
    {"cap-list", :capability_list},
    {"runtime-remaining", :remaining},
    {"runtime-usage", :usage}
  ]

  @doc "Returns the versioned mission-route descriptor used in analysis identity."
  @spec mission_contract_descriptor() :: map()
  def mission_contract_descriptor do
    %{
      "version" => @mission_contract_version,
      "routes" => Enum.map(@mission_routes, &elem(&1, 0))
    }
  end

  @doc "Recognizes reserved routes in canonical runtime capability accounting."
  @spec instrumented_name?(:workflow | :mission, binary()) :: boolean()
  def instrumented_name?(environment, name)
      when environment in [:workflow, :mission] and is_binary(name) do
    mission_route? = Enum.any?(@mission_routes, &(elem(&1, 0) == name))

    mission_route? or (environment == :workflow and Environment.reserved_capability_name?(name))
  end

  @doc "Returns mission route names and their closed execution selectors."
  @spec mission_routes() :: [{binary(), atom()}]
  def mission_routes, do: @mission_routes
end
