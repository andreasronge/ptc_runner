defmodule Mix.Tasks.Ptc.GenSiteGuidesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ptc.GenSiteGuides
  alias PtcRunner.SiteGuides.MarkdownHTML

  defp keep_href(href), do: href

  describe "MarkdownHTML.render!/3" do
    test "renders a guide with deduplicated GitHub-style heading anchors" do
      rendered =
        MarkdownHTML.render!(
          """
          # A Title

          Intro paragraph with `1 < 2 & so on`.

          ## Limits

          ## Limits
          """,
          "example.md",
          &keep_href/1
        )

      assert rendered.title == "A Title"
      assert rendered.description == "Intro paragraph with 1 < 2 & so on."
      assert rendered.html =~ ~s(<h2 id="limits">)
      assert rendered.html =~ ~s(<h2 id="limits-1">)
      assert rendered.html =~ "1 &lt; 2 &amp; so on"
    end

    test "passes every href through the rewriter exactly as written" do
      rendered =
        MarkdownHTML.render!(
          "# T\n\nSee [the guide](other.md#part).\n",
          "example.md",
          fn "other.md#part" -> "/guides/other/#part" end
        )

      assert rendered.html =~ ~s(<a href="/guides/other/#part">the guide</a>)
    end

    test "wraps tables so wide ones scroll instead of breaking the page" do
      rendered =
        MarkdownHTML.render!(
          "# T\n\n| A | B |\n| - | - |\n| 1 | 2 |\n",
          "example.md",
          &keep_href/1
        )

      assert rendered.html =~ ~s(<div class="table-wrap"><table)
    end

    test "refuses a guide that does not open with a title" do
      assert_raise ArgumentError, ~r/first Markdown element must be a # title/, fn ->
        MarkdownHTML.render!("Just a paragraph.\n", "example.md", &keep_href/1)
      end
    end

    test "refuses Markdown outside the whitelist instead of rendering it wrong" do
      assert_raise ArgumentError, ~r/unsupported element/, fn ->
        MarkdownHTML.render!("# T\n\n![alt](image.png)\n", "example.md", &keep_href/1)
      end
    end
  end

  describe "rewrite_link/3" do
    @slugs %{"docs/guides/other.md" => "/guides/other/"}

    test "a published page becomes a site link, keeping the fragment" do
      assert GenSiteGuides.rewrite_link("other.md#part", "docs/guides/here.md", @slugs) ==
               "/guides/other/#part"
    end

    test "an unpublished repository file becomes a GitHub link" do
      assert GenSiteGuides.rewrite_link(
               "../maintainers/kernel.md",
               "docs/guides/here.md",
               @slugs
             ) ==
               "https://github.com/andreasronge/ptc_runner/blob/main/docs/maintainers/kernel.md"
    end

    test "a repository directory becomes a GitHub tree link" do
      assert GenSiteGuides.rewrite_link("../../examples", "docs/guides/here.md", @slugs) ==
               "https://github.com/andreasronge/ptc_runner/tree/main/examples"
    end

    test "external and fragment-only targets pass through unchanged" do
      assert GenSiteGuides.rewrite_link("https://hex.pm", "docs/guides/here.md", @slugs) ==
               "https://hex.pm"

      assert GenSiteGuides.rewrite_link("#local", "docs/guides/here.md", @slugs) == "#local"
    end

    test "a missing repository target fails the run instead of shipping a dead link" do
      assert_raise Mix.Error, ~r/missing repository target/, fn ->
        GenSiteGuides.rewrite_link("no-such-guide.md", "docs/guides/here.md", @slugs)
      end
    end
  end

  test "the committed site guide pages are current" do
    GenSiteGuides.run(["--check"])
  end
end
