defmodule PtcRunner.Kernel.CommandWarningTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandWarning

  test "model_uncataloged is closed, public, and deterministic" do
    assert {:ok, warning} =
             CommandWarning.model_uncataloged("writer", "openrouter:future/model")

    assert CommandWarning.to_map(warning) == %{
             "code" => "model_uncataloged",
             "message" => CommandWarning.message(),
             "provider" => "writer",
             "model" => "openrouter:future/model"
           }

    assert CommandWarning.valid?(warning)
    assert CommandWarning.valid_map?(CommandWarning.to_map(warning))
    refute CommandWarning.valid_map?(Map.put(CommandWarning.to_map(warning), "detail", "private"))
  end

  test "sorting deduplicates warnings by their closed identity" do
    {:ok, hidden} = CommandWarning.model_uncataloged("writer", nil)
    {:ok, public} = CommandWarning.model_uncataloged("writer", "openrouter:future/model")

    assert CommandWarning.sort([public, hidden, public]) == [hidden, public]
  end

  test "rejects invalid public identities" do
    assert :error = CommandWarning.model_uncataloged("Writer", "openrouter:future/model")
    assert :error = CommandWarning.model_uncataloged("writer", "")
    assert :error = CommandWarning.model_uncataloged("writer", String.duplicate("x", 257))
  end
end
