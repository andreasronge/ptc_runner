defmodule Mix.Tasks.Ptc.VerifyDocsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ptc.VerifyDocs

  @tag :tmp_dir
  test "rejects nested Markdown that ExDoc would alias to another README", %{tmp_dir: dir} do
    root_readme = Path.join(dir, "README.md")
    guide = Path.join(dir, "docs/guide.md")
    example_readme = Path.join(dir, "examples/sample/README.md")
    File.mkdir_p!(Path.dirname(guide))
    File.mkdir_p!(Path.dirname(example_readme))
    File.write!(root_readme, "# Root\n")
    File.write!(example_readme, "# Example\n")
    File.write!(guide, "[example](../examples/sample/README.md)\n")

    assert [error] = VerifyDocs.source_errors([root_readme, guide], dir)
    assert error =~ "unpublished Markdown"

    assert VerifyDocs.source_errors([root_readme, guide, example_readme], dir) != []
  end

  @tag :tmp_dir
  test "rejects reference-style links that ExDoc would alias", %{tmp_dir: dir} do
    root_readme = Path.join(dir, "README.md")
    guide = Path.join(dir, "docs/guide.md")
    example_readme = Path.join(dir, "examples/sample/README.md")
    File.mkdir_p!(Path.dirname(guide))
    File.mkdir_p!(Path.dirname(example_readme))
    File.write!(root_readme, "# Root\n")
    File.write!(example_readme, "# Example\n")
    File.write!(guide, "[example][sample]\n\n[sample]: ../examples/sample/README.md\n")

    assert [error] = VerifyDocs.source_errors([root_readme, guide], dir)
    assert error =~ "unpublished Markdown"

    assert VerifyDocs.source_errors([root_readme, guide, example_readme], dir) != []
  end

  @tag :tmp_dir
  test "rejects standalone links indented into code blocks", %{tmp_dir: dir} do
    guide = Path.join(dir, "guide.md")
    File.write!(guide, "Read the\n    [guide](other.md)\n")

    assert [error] = VerifyDocs.source_errors([guide], dir)
    assert error =~ "indents a Markdown link as a code block"
  end

  @tag :tmp_dir
  test "allows indented links in fenced examples and list content", %{tmp_dir: dir} do
    guide = Path.join(dir, "guide.md")

    File.write!(
      guide,
      """
      ```markdown
          [displayed](https://example.com)
      ```

      - Nested link

          [nested](https://example.com)
      """
    )

    assert VerifyDocs.source_errors([guide], dir) == []
  end

  @tag :tmp_dir
  test "requires the content indentation of wide ordered-list markers", %{tmp_dir: dir} do
    guide = Path.join(dir, "guide.md")
    File.write!(guide, "100. Item\n\n    [broken](https://example.com)\n")

    assert [error] = VerifyDocs.source_errors([guide], dir)
    assert error =~ "indents a Markdown link as a code block"
  end

  @tag :tmp_dir
  test "checks rendered targets, containment, and anchors inside main", %{tmp_dir: dir} do
    docs = Path.join(dir, "doc")
    File.mkdir_p!(docs)

    File.write!(
      Path.join(docs, "index.html"),
      ~s(<main><a href="page.html#present">ok</a><a href="../source.json">bad</a></main>)
    )

    File.write!(Path.join(docs, "page.html"), ~s(<main><h2 id="present">Page</h2></main>))

    assert [error] = VerifyDocs.rendered_errors(docs)
    assert error =~ "escapes the rendered docs root"

    File.write!(
      Path.join(docs, "index.html"),
      ~s(<main><a href="page.html#missing">bad anchor</a></main>)
    )

    assert [error] = VerifyDocs.rendered_errors(docs)
    assert error =~ "missing anchor"
  end
end
