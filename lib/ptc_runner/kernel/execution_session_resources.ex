defmodule PtcRunner.Kernel.ExecutionSessionResources do
  @moduledoc false

  @type resource ::
          :worker | :session | :listener | :registry | :memory | :sinks | :prepared | :authority
  @type t :: MapSet.t(resource())

  @doc false
  @spec new([resource()]) :: t()
  def new(resources), do: MapSet.new(resources)

  @doc false
  @spec hold(t(), resource() | [resource()]) :: t()
  def hold(resources, held) when is_list(held), do: Enum.reduce(held, resources, &hold(&2, &1))
  def hold(resources, held), do: MapSet.put(resources, held)

  @doc false
  @spec forget(t(), resource()) :: t()
  def forget(resources, resource), do: MapSet.delete(resources, resource)

  @doc false
  @spec release(t(), [resource()]) :: {t(), [resource()]}
  def release(resources, requested) do
    requested
    |> Enum.reduce({resources, []}, fn resource, {held, released} ->
      if MapSet.member?(held, resource),
        do: {MapSet.delete(held, resource), [resource | released]},
        else: {held, released}
    end)
    |> then(fn {held, released} -> {held, Enum.reverse(released)} end)
  end
end
