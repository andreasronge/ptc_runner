defmodule PtcRunner.PromptLoaderTest do
  use ExUnit.Case, async: true

  doctest PtcRunner.PromptLoader

  alias PtcRunner.PromptLoader

  describe "extract_content/1" do
    test "extracts content between markers" do
      input = """
      <!-- metadata here -->
      <!-- PTC_PROMPT_START -->
      This is the prompt content.
      Multiple lines supported.
      <!-- PTC_PROMPT_END -->
      <!-- after content -->
      """

      assert PromptLoader.extract_content(input) ==
               "This is the prompt content.\nMultiple lines supported."
    end

    test "handles only start marker (no end marker)" do
      input = """
      before
      <!-- PTC_PROMPT_START -->
      prompt content here
      """

      assert PromptLoader.extract_content(input) == "prompt content here"
    end

    test "returns trimmed content when no markers present" do
      input = "  just plain content  \n\n"
      assert PromptLoader.extract_content(input) == "just plain content"
    end

    test "handles empty content between markers" do
      input = "before<!-- PTC_PROMPT_START --><!-- PTC_PROMPT_END -->after"
      assert PromptLoader.extract_content(input) == ""
    end
  end

  describe "extract_with_header/1" do
    test "returns header and content as tuple" do
      input = """
      <!-- version: 2 -->
      <!-- date: 2025-01-15 -->
      <!-- PTC_PROMPT_START -->
      The prompt content.
      <!-- PTC_PROMPT_END -->
      after
      """

      {header, content} = PromptLoader.extract_with_header(input)

      assert header =~ "version: 2"
      assert header =~ "date: 2025-01-15"
      assert content == "The prompt content."
    end

    test "returns original as header when no markers" do
      input = "no markers here"
      {header, content} = PromptLoader.extract_with_header(input)

      assert header == "no markers here"
      assert content == "no markers here"
    end

    test "handles only start marker (no end)" do
      input = "header text<!-- PTC_PROMPT_START -->content"
      {header, content} = PromptLoader.extract_with_header(input)

      assert header == "header text"
      assert content == "content"
    end
  end
end
