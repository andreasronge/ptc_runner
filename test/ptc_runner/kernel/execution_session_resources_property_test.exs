defmodule PtcRunner.Kernel.ExecutionSessionResourcesPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PtcRunner.Kernel.ExecutionSessionResources

  @resources [:worker, :session, :listener, :registry, :memory, :sinks, :prepared, :authority]

  property "re-entered release emits each initially held resource at most once" do
    check all(
            initially_held <- resource_set(),
            requests <-
              StreamData.list_of(StreamData.list_of(resource(), max_length: length(@resources)),
                max_length: 10
              )
          ) do
      {_remaining, released} =
        Enum.reduce(requests, {ExecutionSessionResources.new(initially_held), []}, fn request,
                                                                                      {held,
                                                                                       effects} ->
          {next, emitted} = ExecutionSessionResources.release(held, request)
          {next, effects ++ emitted}
        end)

      assert released == Enum.uniq(released)
      assert MapSet.subset?(MapSet.new(released), MapSet.new(initially_held))
    end
  end

  property "release preserves request order and removes exactly the requested held resources" do
    check all(
            initially_held <- resource_set(),
            requested <- StreamData.list_of(resource(), max_length: length(@resources) * 2)
          ) do
      held = ExecutionSessionResources.new(initially_held)
      {remaining, released} = ExecutionSessionResources.release(held, requested)

      expected_released =
        requested
        |> Enum.uniq()
        |> Enum.filter(&MapSet.member?(held, &1))

      assert released == expected_released
      assert remaining == MapSet.difference(held, MapSet.new(requested))
    end
  end

  test "forgotten resources are transferred rather than released" do
    held =
      @resources
      |> ExecutionSessionResources.new()
      |> ExecutionSessionResources.forget(:sinks)
      |> ExecutionSessionResources.forget(:authority)

    {remaining, released} = ExecutionSessionResources.release(held, @resources)

    assert remaining == MapSet.new()
    assert released == @resources -- [:sinks, :authority]
  end

  defp resource, do: StreamData.member_of(@resources)

  defp resource_set do
    StreamData.map(
      StreamData.list_of(resource(), max_length: length(@resources) * 2),
      &Enum.uniq/1
    )
  end
end
