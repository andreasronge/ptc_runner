defmodule DocsGuideTest do
  use ExUnit.Case, async: true

  doctest_file("docs/guide.md")
end
