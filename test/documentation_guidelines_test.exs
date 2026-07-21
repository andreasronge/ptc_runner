defmodule PtcRunner.DocumentationGuidelinesTest do
  use ExUnit.Case, async: true

  doctest_file("docs/guides/documentation-guidelines.md")

  test "publishes the signature syntax reference" do
    extras = Mix.Project.config() |> Keyword.fetch!(:docs) |> Keyword.fetch!(:extras)

    assert "docs/signature-syntax.md" in extras
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
