defmodule PtcRunner.PromptLoader do
  @moduledoc """
  Compile-time utilities for loading prompt templates from files.

  Extracts content between `<!-- PTC_PROMPT_START -->` and `<!-- PTC_PROMPT_END -->` markers.
  If markers are not found, returns the trimmed full content.

  ## Examples

      # Basic extraction
      content = File.read!("priv/prompts/my-prompt.md")
      prompt = PtcRunner.PromptLoader.extract_content(content)

      # With header (for metadata parsing)
      {header, content} = PtcRunner.PromptLoader.extract_with_header(content)
  """

  @start_marker "<!-- PTC_PROMPT_START -->"
  @end_marker "<!-- PTC_PROMPT_END -->"

  @doc """
  Extract prompt content from file content string.

  Returns content between markers, or trimmed full content if markers not found.

  ## Examples

      iex> PtcRunner.PromptLoader.extract_content("before<!-- PTC_PROMPT_START -->content<!-- PTC_PROMPT_END -->after")
      "content"

      iex> PtcRunner.PromptLoader.extract_content("<!-- PTC_PROMPT_START -->only start marker")
      "only start marker"

      iex> PtcRunner.PromptLoader.extract_content("  no markers  ")
      "no markers"
  """
  @spec extract_content(String.t()) :: String.t()
  def extract_content(file_content) do
    case String.split(file_content, @start_marker) do
      [_before, after_start] -> extract_between_markers(after_start)
      _ -> String.trim(file_content)
    end
  end

  @doc """
  Extract prompt content with metadata header.

  Returns `{header, content}` tuple where header is text before the start marker.
  Used by `LanguageSpec` for version metadata parsing.

  ## Examples

      iex> PtcRunner.PromptLoader.extract_with_header("header<!-- PTC_PROMPT_START -->content<!-- PTC_PROMPT_END -->after")
      {"header", "content"}

      iex> PtcRunner.PromptLoader.extract_with_header("header<!-- PTC_PROMPT_START -->only start")
      {"header", "only start"}

      iex> PtcRunner.PromptLoader.extract_with_header("  no markers  ")
      {"  no markers  ", "no markers"}
  """
  @spec extract_with_header(String.t()) :: {String.t(), String.t()}
  def extract_with_header(file_content) do
    case String.split(file_content, @start_marker) do
      [before, after_start] -> {before, extract_between_markers(after_start)}
      _ -> {file_content, String.trim(file_content)}
    end
  end

  # Extracts content between start marker and end marker (or to EOF if no end marker).
  defp extract_between_markers(after_start) do
    case String.split(after_start, @end_marker) do
      [prompt_text, _after_end] -> String.trim(prompt_text)
      _ -> String.trim(after_start)
    end
  end
end
