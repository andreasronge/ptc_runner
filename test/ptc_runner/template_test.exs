defmodule PtcRunner.TemplateTest do
  use ExUnit.Case, async: true

  doctest PtcRunner.Template

  alias PtcRunner.Template

  test "struct has expected fields" do
    template = %Template{template: "test", placeholders: []}

    assert template.template == "test"
    assert template.placeholders == []
  end
end
