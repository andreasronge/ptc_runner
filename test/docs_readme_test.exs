defmodule DocsReadmeTest do
  use ExUnit.Case, async: true

  doctest_file("docs/README.md")
end
