defmodule PtcRunner.DocumentationGuidelinesTest do
  use ExUnit.Case, async: true

  doctest_file("docs/guides/documentation-guidelines.md")
end
