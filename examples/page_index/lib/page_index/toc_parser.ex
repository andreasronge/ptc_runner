defmodule PageIndex.TocParser do
  @moduledoc """
  Extracts and parses Table of Contents from PDF documents using LLM.

  Uses a two-phase approach:
  1. Extract TOC pages from the document
  2. Use LLM to parse TOC into hierarchical structure
  """

  alias PtcRunner.SubAgent

  @doc """
  Extracts hierarchical TOC structure from a PDF document.

  Returns a tree structure with nested sections and page numbers.
  """
  def parse_toc(pdf_path, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)

    with {:ok, toc_text} <- extract_toc_pages(pdf_path),
         {:ok, structure} <- parse_with_llm(toc_text, llm) do
      {:ok, structure}
    end
  end

  @doc """
  Extracts the Table of Contents pages from a PDF.
  Looks for pages that contain TOC-like content (items with page numbers).
  """
  def extract_toc_pages(pdf_path) do
    case GenServer.call(PdfExtractor, {:extract_text, [pdf_path, []]}, 300_000) do
      {:ok, pages_map} ->
        # Get first 5 pages (TOC is usually at the beginning)
        toc_text =
          pages_map
          |> Enum.sort_by(fn {num, _} -> num end)
          |> Enum.take(5)
          |> Enum.filter(fn {_num, text} ->
            # Check if page looks like TOC (has "ITEM" and page numbers)
            String.contains?(text, "ITEM") and
            Regex.match?(~r/\d+\s*$/, text)
          end)
          |> Enum.map(fn {num, text} -> "=== PAGE #{num} ===\n#{text}" end)
          |> Enum.join("\n\n")

        if String.length(toc_text) > 100 do
          {:ok, toc_text}
        else
          {:error, :no_toc_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Uses LLM to parse TOC text into hierarchical JSON structure.
  """
  def parse_with_llm(toc_text, llm) do
    prompt = """
    Parse this Table of Contents into a hierarchical JSON structure.

    Extract ALL sections and subsections with their page numbers.
    Preserve the hierarchy - subsections should be nested under their parent sections.

    TABLE OF CONTENTS:
    #{toc_text}

    Return a JSON array of sections. Each section has:
    - title: The section title (e.g., "Business" not "ITEM 1 Business")
    - item_num: The item number if applicable (e.g., "1", "1A", "7") or null for subsections
    - start_page: The page number where this section starts
    - children: Array of subsections (same structure, recursive)

    Example structure:
    [
      {
        "title": "Business",
        "item_num": "1",
        "start_page": 4,
        "children": []
      },
      {
        "title": "Management's Discussion and Analysis",
        "item_num": "7",
        "start_page": 19,
        "children": [
          {"title": "Overview", "item_num": null, "start_page": 19, "children": []},
          {"title": "Results of Operations", "item_num": null, "start_page": 27, "children": []}
        ]
      }
    ]

    Important:
    - Include ALL items from PART I, II, III, IV
    - Include subsections for Item 7 (MD&A sections)
    - Include subsections for Item 8 (Financial Statements, Notes 1-19)
    - Page numbers should be integers
    """

    case SubAgent.run(prompt,
           output: :json,
           signature: "{sections [:map]}",
           llm: llm
         ) do
      {:ok, step} ->
        sections = step.return["sections"]
        {:ok, sections}

      {:error, step} ->
        {:error, step.fail}
    end
  end

  @doc """
  Builds full tree from parsed TOC, calculating end pages.
  """
  def build_tree(sections, total_pages) do
    # Flatten to get all sections with their start pages
    all_sections = flatten_with_path(sections, [])

    # Sort by start page to calculate end pages
    sorted = Enum.sort_by(all_sections, fn {section, _path} -> section["start_page"] end)

    # Calculate end pages (next section's start - 1)
    sections_with_end = calculate_end_pages(sorted, total_pages)

    # Rebuild tree structure
    rebuild_tree(sections, sections_with_end)
  end

  defp flatten_with_path(sections, path) when is_list(sections) do
    Enum.flat_map(sections, fn section ->
      current_path = path ++ [section["title"]]
      children = section["children"] || []
      [{section, current_path} | flatten_with_path(children, current_path)]
    end)
  end

  defp calculate_end_pages(sorted_sections, total_pages) do
    sorted_sections
    |> Enum.with_index()
    |> Enum.map(fn {{section, path}, idx} ->
      next_section = Enum.at(sorted_sections, idx + 1)
      end_page = if next_section do
        {next, _} = next_section
        max(section["start_page"], next["start_page"] - 1)
      else
        total_pages
      end
      {section["title"], %{start_page: section["start_page"], end_page: end_page, path: path}}
    end)
    |> Map.new()
  end

  defp rebuild_tree(sections, page_info) do
    Enum.map(sections, fn section ->
      info = Map.get(page_info, section["title"], %{start_page: 1, end_page: 1})
      children = section["children"] || []

      %{
        title: section["title"],
        item_num: section["item_num"],
        start_page: info.start_page,
        end_page: info.end_page,
        children: rebuild_tree(children, page_info)
      }
    end)
  end
end
