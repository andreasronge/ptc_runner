defmodule PageIndex.Parser do
  @moduledoc """
  Extracts text and structure from SEC 10-K/10-Q PDF documents.

  Uses pdf_extractor (pdfplumber) for text extraction and regex patterns
  to identify the hierarchical structure of SEC filings.
  """

  # Pattern for section headers: "Item 1. Business" or "ITEM 1A. Risk Factors"
  # Must be at start of line (after newline) and followed by content
  @sec_item_pattern ~r/\n(ITEM|Item)\s+(\d+[A-Z]?)[\.\:]\s*([^\n]+)/

  @doc """
  Parses a PDF file and returns a list of sections with their content.
  """
  def parse(pdf_path) do
    with {:ok, pages} <- extract_pages(pdf_path),
         {:ok, sections} <- identify_sections(pages) do
      {:ok, sections}
    end
  end

  @doc """
  Extracts text from each page of the PDF.
  Returns a list of {page_number, text} tuples with 1-based page numbers
  (matching printed PDF page numbers).
  """
  def extract_pages(pdf_path) do
    # Use longer timeout for large PDFs (5 minutes)
    case GenServer.call(PdfExtractor, {:extract_text, [pdf_path, []]}, 300_000) do
      {:ok, pages_map} ->
        # pdf_extractor returns 0-based page numbers; normalize to 1-based
        pages =
          pages_map
          |> Enum.sort_by(fn {page_num, _} -> page_num end)
          |> Enum.map(fn {page_num, text} -> {page_num + 1, text} end)

        {:ok, pages}

      {:error, reason} ->
        {:error, "Failed to extract PDF: #{inspect(reason)}"}
    end
  end

  @doc """
  Identifies SEC Item sections from extracted pages.
  """
  def identify_sections(pages) do
    # Combine all pages with markers
    full_text =
      pages
      |> Enum.map(fn {page_num, text} -> "<<<PAGE_#{page_num}>>>\n#{text}" end)
      |> Enum.join("\n")

    # Find all Item matches
    matches = find_section_matches(full_text)

    # Build sections, keeping only those with substantial content (>500 chars)
    # This filters out TOC entries which are short references
    sections =
      build_sections(matches, full_text, pages)
      |> Enum.filter(fn s -> String.length(s.content) > 500 end)

    {:ok, sections}
  end

  defp find_section_matches(full_text) do
    Regex.scan(@sec_item_pattern, full_text, return: :index)
    |> Enum.zip(Regex.scan(@sec_item_pattern, full_text))
    |> Enum.map(fn {[{start_pos, _} | _], [_full, _item_word, item_num, title]} ->
      page = find_page_for_position(full_text, start_pos)

      %{
        item_num: String.trim(item_num),
        title: clean_title(title),
        start_pos: start_pos,
        start_page: page
      }
    end)
    # Keep first occurrence of each item (skip TOC duplicates)
    |> Enum.uniq_by(fn %{item_num: num} -> String.downcase(num) end)
  end

  defp clean_title(title) do
    title
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    # Remove trailing page numbers
    |> String.replace(~r/\.\s*\d+\s*$/, "")
    |> String.slice(0, 100)
  end

  defp find_page_for_position(full_text, position) do
    text_before = String.slice(full_text, 0, position)

    case Regex.scan(~r/<<<PAGE_(\d+)>>>/, text_before) do
      [] -> 1
      matches -> matches |> List.last() |> Enum.at(1) |> String.to_integer()
    end
  end

  defp build_sections(matches, full_text, pages) do
    matches
    |> Enum.with_index()
    |> Enum.map(fn {match, idx} ->
      next_match = Enum.at(matches, idx + 1)

      end_pos = if next_match, do: next_match.start_pos, else: String.length(full_text)
      end_page = find_end_page(match, next_match, pages)

      content =
        full_text
        |> String.slice(match.start_pos, end_pos - match.start_pos)
        |> String.replace(~r/<<<PAGE_\d+>>>/, "\n")
        |> String.trim()

      %{
        id: "item_#{String.downcase(match.item_num)}",
        item_num: match.item_num,
        title: match.title,
        start_page: match.start_page,
        end_page: end_page,
        content: content
      }
    end)
  end

  defp find_end_page(_match, nil, pages), do: length(pages)

  defp find_end_page(match, next_match, _pages) do
    max(match.start_page, next_match.start_page - 1)
  end

  @doc """
  Returns a simplified tree structure suitable for indexing.
  """
  def to_tree(sections) do
    grouped =
      sections
      |> Enum.group_by(&categorize_item/1)
      |> Enum.map(fn {category, items} ->
        %{
          id: category_id(category),
          title: category,
          children:
            Enum.map(items, fn item ->
              %{
                id: item.id,
                title: "Item #{item.item_num}: #{item.title}",
                start_page: item.start_page,
                end_page: item.end_page,
                content_length: String.length(item.content)
              }
            end)
        }
      end)

    %{id: "root", title: "10-K Annual Report", children: grouped}
  end

  defp categorize_item(%{item_num: num}) do
    case String.upcase(num) do
      "1" -> "Business Overview"
      "1A" -> "Risk Factors"
      "1B" -> "Unresolved Staff Comments"
      n when n in ["2", "3", "4"] -> "Business Operations"
      n when n in ["5", "6"] -> "Market & Stock Information"
      n when n in ["7", "7A"] -> "Management Discussion & Analysis"
      n when n in ["8", "9", "9A", "9B", "9C"] -> "Financial Statements & Controls"
      _ -> "Other Disclosures"
    end
  end

  defp category_id(category) do
    category
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
