defmodule PtcRunner.Kernel.ProjectionErrorTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ProjectionError

  test "unknown projection failures retain a neutral classification" do
    assert ProjectionError.kind({:future_projection_failure, [:value]}) == :projection_error
  end
end
