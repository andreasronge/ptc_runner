defmodule PtcRunner.PromptTest do
  use ExUnit.Case, async: true

  doctest PtcRunner.Prompt

  alias PtcRunner.Prompt

  test "struct has expected fields" do
    prompt = %Prompt{template: "test", placeholders: []}

    assert prompt.template == "test"
    assert prompt.placeholders == []
  end
end
