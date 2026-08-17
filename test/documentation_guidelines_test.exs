defmodule PtcRunner.DocumentationGuidelinesTest do
  use ExUnit.Case, async: true

  doctest_file("docs/maintainers/documentation.md")

  test "publishes the signature syntax reference" do
    extras = Mix.Project.config() |> Keyword.fetch!(:docs) |> Keyword.fetch!(:extras)

    assert "docs/signature-syntax.md" in extras
  end

  test "keeps public product prose implementation neutral" do
    paths =
      [
        "README.md",
        "docs/signature-syntax.md",
        "docs/ptc-lisp-specification.md",
        "docs/clojure-conformance-gaps.md",
        "docs/trace-log-contract.md"
      ] ++ Path.wildcard("docs/{guides,reference}/*.md")

    for path <- paths do
      refute File.read!(path) =~ ~r/\bElixir\b/i,
             "#{path} explains the public product through its implementation language"
    end
  end

  test "declares the audience of every hand-written documentation page" do
    paths =
      Path.wildcard("docs/{guides,installation,reference}/*.md") ++
        Path.wildcard("docs/maintainers/**/*.md")

    for path <- paths do
      assert File.read!(path) =~ ~r/^> \*\*Audience:\*\*/m,
             "#{path} must start with a visible audience declaration"
    end
  end

  test "publishes installation, guide, and reference layers separately" do
    docs = Mix.Project.config() |> Keyword.fetch!(:docs)
    extras = Keyword.fetch!(docs, :extras)
    groups = Keyword.fetch!(docs, :groups_for_extras)

    assert Enum.any?(extras, &String.starts_with?(&1, "docs/installation/"))
    assert Enum.any?(extras, &String.starts_with?(&1, "docs/guides/"))
    assert Enum.any?(extras, &String.starts_with?(&1, "docs/reference/"))
    assert Keyword.has_key?(groups, :Installation)
    assert Keyword.has_key?(groups, :Guides)
    assert Keyword.has_key?(groups, :Reference)
  end

  test "uses canonical anchors for conformance gaps" do
    specification = File.read!("docs/ptc-lisp-specification.md")

    assert specification =~ "clojure-conformance-gaps.md#div-15-no-multi-arity-fn-defn"
    assert specification =~ "clojure-conformance-gaps.md#div-16-no-pre-post-conditions-in-defn"

    assert specification =~
             "clojure-conformance-gaps.md#gap-s08-even-odd-handle-floats-gracefully"

    assert specification =~
             "clojure-conformance-gaps.md#div-18-parse-long-parse-double-parse-boolean-return-nil-for-non-string-input"
  end
end
