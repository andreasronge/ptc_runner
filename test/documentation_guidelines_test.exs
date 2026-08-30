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
        "docs/clojure-conformance-gaps.md"
      ] ++ Path.wildcard("docs/{guides,reference}/*.md")

    for path <- paths do
      refute File.read!(path) =~ ~r/\bElixir\b/i,
             "#{path} explains the public product through its implementation language"
    end
  end

  test "opens every published page with a useful summary" do
    paths =
      published_product_paths()
      |> Enum.reject(&(&1 == "README.md" or File.read!(&1) =~ "<!-- Auto-generated"))

    for path <- paths do
      content = File.read!(path)

      assert content =~ ~r/\A# [^\n]+\n\n[^\n#>`*+-][^\n]*(?:\n(?!\n)[^\n]+)*\n\n/,
             "#{path} must open with a paragraph after its title"

      [_title, body] = String.split(content, "\n\n", parts: 2)
      [opening | _rest] = String.split(body, "\n\n")
      opening = String.replace(opening, "\n", " ")

      assert String.length(opening) <= 160,
             "#{path} opening must fit the site's 160-character description"

      assert String.ends_with?(opening, [".", "?", "!"]),
             "#{path} opening must be a complete sentence"

      refute content =~ ~r/^> \*\*Audience:\*\*/m,
             "#{path} must describe its purpose instead of naming an audience role"
    end
  end

  test "uses plain terminology in published product prose" do
    paths =
      published_product_paths() ++
        Path.wildcard("priv/schemas/*.json") ++
        ["site/index.html", "site/schemas/index.html"]

    for path <- paths do
      content = File.read!(path)
      normalized = String.replace(content, ~r/\s+/, " ")

      refute content =~ ~r/^> \*\*Audience:\*\*/m,
             "#{path} must describe its purpose instead of naming an audience role"

      unless path == "docs/ptc-lisp-specification.md" do
        refute normalized =~ ~r/\b(?:application authors?|operators?)\b/i,
               "#{path} should name the responsible file or address the reader directly"
      end

      refute normalized =~
               ~r/\bcanonical (?:trace|traces|run|runs|event|events|evidence)\b/i,
             "#{path} should say trace or private inspection record"

      refute normalized =~ ~r/\bprovider-free\b/i,
             "#{path} should say whether the workflow needs an API key or provider"
    end
  end

  test "keeps every guide skimmable" do
    for path <- Path.wildcard("docs/guides/*.md") do
      assert File.read!(path) =~ ~r/^## /m,
             "#{path} must use task-oriented section headings"
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
    assert Keyword.has_key?(groups, :Reference)

    # The guide layer is split into explicit reading-order sections that both
    # the HexDocs sidebar and the site generator consume. Every guide extra
    # must belong to one; mix ptc.gen_site_guides enforces the stricter
    # structural rules.
    grouped_guides =
      groups
      |> Keyword.values()
      |> Enum.filter(&is_list/1)
      |> Enum.concat()
      |> Enum.filter(&String.starts_with?(&1, "docs/guides/"))

    guide_extras = Enum.filter(extras, &String.starts_with?(&1, "docs/guides/"))
    assert Enum.sort(grouped_guides) == Enum.sort(guide_extras)
  end

  defp published_product_paths do
    Mix.Project.config()
    |> Keyword.fetch!(:docs)
    |> Keyword.fetch!(:extras)
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.reject(
      &(String.starts_with?(&1, "docs/maintainers/") or
          String.starts_with?(&1, "docs/conformance/"))
    )
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
