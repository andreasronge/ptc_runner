defmodule PtcRunner.Kernel.DocumentationLinksTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.DocumentationLinks

  @names %{
    "docs/reference/cli.md" => "cli",
    "docs/guides/quickstart.md" => "quickstart"
  }

  test "a link to a served page becomes the command that serves it" do
    source = """
    See the [command-line reference](../reference/cli.md) for the exit codes,
    and [Quickstart](quickstart.md#run-without-a-credential) to start.
    """

    assert {:ok, rewritten} =
             DocumentationLinks.rewrite(source, "docs/guides/getting-started.md", @names)

    assert rewritten == """
           See the command-line reference (`ptc docs cli`) for the exit codes,
           and Quickstart (`ptc docs quickstart`) to start.
           """
  end

  test "link text that wraps across lines is still rewritten" do
    source = "Continue with [Use a\nmodel](../reference/cli.md).\n"

    assert {:ok, rewritten} =
             DocumentationLinks.rewrite(source, "docs/guides/quickstart.md", @names)

    assert rewritten == "Continue with Use a\nmodel (`ptc docs cli`).\n"
  end

  test "absolute and same-page links are left exactly as written" do
    source = """
    See [the site](https://ptc-runner.dev/) and [Purpose](#purpose).
    """

    assert {:ok, ^source} =
             DocumentationLinks.rewrite(source, "docs/reference/cli.md", @names)
  end

  test "a fenced example keeps its link syntax" do
    source = """
    Markdown links look like this:

    ```markdown
    [command-line reference](../reference/cli.md)
    ```
    """

    assert {:ok, ^source} =
             DocumentationLinks.rewrite(source, "docs/guides/getting-started.md", @names)
  end

  test "a tilde-fenced example keeps its link syntax" do
    source = """
    Markdown links look like this:

    ~~~markdown
    [command-line reference](../reference/cli.md)
    ~~~
    """

    assert {:ok, ^source} =
             DocumentationLinks.rewrite(source, "docs/guides/getting-started.md", @names)
  end

  test "an inline code span keeps its link syntax" do
    source = "Write `[text](../reference/cli.md)` to link a page.\n"

    assert {:ok, ^source} =
             DocumentationLinks.rewrite(source, "docs/guides/getting-started.md", @names)
  end

  test "a titled destination is rewritten like any other" do
    source = ~s|See [the CLI](../reference/cli.md "Command-line reference") first.\n|

    assert {:ok, rewritten} =
             DocumentationLinks.rewrite(source, "docs/guides/getting-started.md", @names)

    assert rewritten == "See the CLI (`ptc docs cli`) first.\n"
  end

  test "a reference-style definition with a relative destination is reported" do
    source = """
    See [the guide][guide].

    [guide]: ../maintainers/embedding.md
    """

    assert {:error, ["../maintainers/embedding.md"]} =
             DocumentationLinks.rewrite(source, "docs/guides/quickstart.md", @names)
  end

  test "a stray bracket cannot let link text swallow the prose before it" do
    source = """
    the byte range, for example `at main.clj bytes
    [45,58)`. More prose follows here.

    See [the CLI](../reference/cli.md) for the rest.
    """

    assert {:ok, rewritten} =
             DocumentationLinks.rewrite(source, "docs/guides/getting-started.md", @names)

    assert rewritten == """
           the byte range, for example `at main.clj bytes
           [45,58)`. More prose follows here.

           See the CLI (`ptc docs cli`) for the rest.
           """
  end

  test "a link to a document nothing serves is reported by its resolved path" do
    source = """
    Documented under [Embedding](../maintainers/embedding.md#materialize) and
    [Kernel](../maintainers/kernel.md).
    """

    assert {:error, unresolved} =
             DocumentationLinks.rewrite(source, "docs/guides/quickstart.md", @names)

    assert unresolved == ["docs/maintainers/embedding.md", "docs/maintainers/kernel.md"]
  end

  test "an image is reported rather than rewritten into a command" do
    source = "![architecture](assets/architecture.png)\n"

    assert {:error, ["assets/architecture.png"]} =
             DocumentationLinks.rewrite(source, "docs/maintainers/kernel.md", @names)
  end
end
