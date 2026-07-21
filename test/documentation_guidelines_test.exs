defmodule PtcRunner.DocumentationGuidelinesTest do
  use ExUnit.Case, async: true

  doctest_file("docs/guides/documentation-guidelines.md")

  test "publishes the signature syntax reference" do
    extras = Mix.Project.config() |> Keyword.fetch!(:docs) |> Keyword.fetch!(:extras)

    assert "docs/signature-syntax.md" in extras
  end
end
