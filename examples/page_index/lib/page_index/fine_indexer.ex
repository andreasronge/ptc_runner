defmodule PageIndex.FineIndexer do
  @moduledoc """
  Builds a fine-grained hierarchical index using TOC parsing.

  Creates a deep tree structure by:
  1. Parsing the document's Table of Contents with LLM
  2. Generating summaries for each section
  3. Building a tree suitable for reasoning-based navigation
  """

  alias PageIndex.TocParser
  alias PtcRunner.SubAgent

  @doc """
  Creates a fine-grained index from a PDF document.

  ## Options

  - `:llm` - Required. The LLM client function
  - `:max_concurrency` - Max parallel summarization calls (default: 5)
  - `:max_content_chars` - Max chars to send to LLM per section (default: 4000)
  - `:doc_title` - Document title for the root node (default: filename without extension)
  """
  def index(pdf_path, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    max_concurrency = Keyword.get(opts, :max_concurrency, 5)
    max_content_chars = Keyword.get(opts, :max_content_chars, 4000)
    doc_title = Keyword.get(opts, :doc_title, Path.basename(pdf_path, ".pdf"))

    IO.puts("Phase 1: Parsing Table of Contents...")

    with {:ok, toc_sections} <- TocParser.parse_toc(pdf_path, llm: llm),
         {:ok, pages} <- extract_pages(pdf_path),
         flat_sections = flatten_sections(toc_sections),
         _ = IO.puts("Found #{length(flat_sections)} sections to summarize"),
         sections_with_content = attach_content(flat_sections, pages),
         {:ok, summaries} <-
           generate_summaries(sections_with_content, llm, max_concurrency, max_content_chars),
         tree <- build_tree(toc_sections, summaries, length(pages), doc_title) do
      {:ok, tree}
    end
  end

  defp extract_pages(pdf_path) do
    PageIndex.Parser.extract_pages(pdf_path)
  end

  # Flatten nested sections for parallel summarization
  defp flatten_sections(sections, parent_path \\ []) do
    Enum.flat_map(sections, fn section ->
      path = parent_path ++ [section["title"]]
      id = generate_id(section, parent_path)

      current = %{
        id: id,
        title: section["title"],
        item_num: section["item_num"],
        start_page: section["start_page"],
        path: path
      }

      children = section["children"] || []
      [current | flatten_sections(children, path)]
    end)
  end

  defp generate_id(section, parent_path) do
    base =
      if section["item_num"] do
        "item_#{String.downcase(section["item_num"])}"
      else
        section["title"]
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "_")
        |> String.trim("_")
      end

    if parent_path == [] do
      base
    else
      parent_id =
        parent_path
        |> List.last()
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "_")

      "#{parent_id}_#{base}"
    end
  end

  # Attach content from pages to each section
  defp attach_content(sections, pages) do
    sorted =
      sections
      |> Enum.filter(& &1.start_page)
      |> Enum.sort_by(& &1.start_page)

    sorted
    |> Enum.with_index()
    |> Enum.map(fn {section, idx} ->
      next_section = Enum.at(sorted, idx + 1)
      end_page = if next_section, do: next_section.start_page - 1, else: length(pages)
      end_page = max(section.start_page, end_page)

      content = extract_content(pages, section.start_page, end_page)
      Map.merge(section, %{end_page: end_page, content: content})
    end)
  end

  defp extract_content(pages, start_page, end_page) do
    pages
    |> Enum.filter(fn {num, _} -> num >= start_page and num <= end_page end)
    |> Enum.map(fn {_, text} -> text end)
    |> Enum.join("\n\n")
    |> String.replace(~r/Table of Contents\n?/, "")
    |> String.trim()
  end

  defp generate_summaries(sections, llm, max_concurrency, max_content_chars) do
    IO.puts("\nPhase 2: Generating summaries for #{length(sections)} sections...")

    summaries =
      sections
      |> Task.async_stream(
        fn section ->
          summary = summarize_section(section, llm, max_content_chars)
          title_short = String.slice(section.title, 0, 40)
          summary_short = String.slice(summary, 0, 50)
          IO.puts("  ✓ #{title_short}: #{summary_short}...")
          {section.id, summary}
        end,
        max_concurrency: max_concurrency,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Map.new()

    {:ok, summaries}
  end

  defp summarize_section(section, llm, max_content_chars) do
    # Skip summarization for very short sections
    if String.length(section.content) < 100 do
      "Brief section - see document for details."
    else
      content = String.slice(section.content, 0, max_content_chars)

      prompt = """
      Summarize this section in 1-2 sentences. Focus on key facts, numbers, and business implications.

      Section: #{section.title}
      Pages: #{section.start_page}-#{section.end_page}

      Content:
      #{content}
      """

      case SubAgent.run(prompt,
             output: :text,
             signature: "{summary :string}",
             llm: llm
           ) do
        {:ok, step} ->
          step.return["summary"]

        {:error, _step} ->
          "Summary unavailable for #{section.title}"
      end
    end
  end

  defp build_tree(toc_sections, summaries, total_pages, doc_title) do
    # Build global page boundaries from flattened sections
    all_start_pages = collect_start_pages(toc_sections) |> Enum.sort()
    page_boundaries = build_page_boundaries(all_start_pages, total_pages)

    children = build_children(toc_sections, summaries, page_boundaries)

    # Build root summary from top-level section titles
    section_titles = Enum.map(toc_sections, & &1["title"]) |> Enum.join(", ")

    %{
      node_id: "root",
      title: doc_title,
      summary: "#{doc_title} containing: #{section_titles}.",
      children: children
    }
  end

  # Collect all start pages from nested structure
  defp collect_start_pages(sections) do
    Enum.flat_map(sections, fn section ->
      children = section["children"] || []
      [section["start_page"] | collect_start_pages(children)]
    end)
  end

  # Build map of start_page -> end_page using global boundaries
  defp build_page_boundaries(sorted_pages, total_pages) do
    sorted_pages
    |> Enum.with_index()
    |> Enum.map(fn {start_page, idx} ->
      next_page = Enum.at(sorted_pages, idx + 1)
      end_page = if next_page, do: next_page - 1, else: total_pages
      {start_page, max(start_page, end_page)}
    end)
    |> Map.new()
  end

  defp build_children(sections, summaries, page_boundaries, parent_path \\ []) do
    sorted = Enum.sort_by(sections, & &1["start_page"])

    Enum.map(sorted, fn section ->
      path = parent_path ++ [section["title"]]
      id = generate_id(section, parent_path)

      # Use global page boundaries
      end_page = Map.get(page_boundaries, section["start_page"], section["start_page"])

      children_sections = section["children"] || []
      children = build_children(children_sections, summaries, page_boundaries, path)

      %{
        node_id: id,
        title: format_title(section),
        summary: Map.get(summaries, id, ""),
        start_page: section["start_page"],
        end_page: end_page,
        children: children
      }
    end)
  end

  defp format_title(section) do
    if section["item_num"] do
      "Item #{section["item_num"]}: #{section["title"]}"
    else
      section["title"]
    end
  end

  @doc """
  Saves the index tree to a JSON file.
  """
  def save(tree, path) do
    json = Jason.encode!(tree, pretty: true)
    File.write!(path, json)
    :ok
  end

  @doc """
  Loads an index tree from a JSON file.
  """
  def load(path) do
    case File.read(path) do
      {:ok, json} -> Jason.decode(json, keys: :atoms)
      error -> error
    end
  end
end
