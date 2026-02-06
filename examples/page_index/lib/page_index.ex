defmodule PageIndex do
  @moduledoc """
  Hierarchical document retrieval using tree-based indexing.

  PageIndex provides vectorless, reasoning-based RAG by:
  1. Parsing documents into hierarchical structures
  2. Generating LLM summaries for each section
  3. Enabling tree-based navigation for retrieval

  ## Usage

      # Index a document
      {:ok, tree} = PageIndex.index("data/3M_2022_10K.pdf", llm: llm)

      # Save for later use
      PageIndex.save_index(tree, "data/3M_2022_10K_index.json")

      # Load existing index
      {:ok, tree} = PageIndex.load_index("data/3M_2022_10K_index.json")
  """

  alias PageIndex.{Parser, Indexer}

  @cache_table :page_index_pdf_cache

  defdelegate index(pdf_path, opts), to: Indexer
  defdelegate parse(pdf_path), to: Parser

  @doc """
  Ensures the PDF cache table exists.
  Called automatically by get_content, but can be called explicitly.
  """
  def ensure_cache do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:set, :public, :named_table])
    end

    :ok
  end

  @doc """
  Clears the PDF cache for all documents or a specific path.
  """
  def clear_cache(pdf_path \\ nil) do
    if :ets.whereis(@cache_table) != :undefined do
      if pdf_path do
        :ets.delete(@cache_table, pdf_path)
      else
        :ets.delete_all_objects(@cache_table)
      end
    end

    :ok
  end

  @doc """
  Saves an index tree to JSON file.
  """
  def save_index(tree, path) do
    Indexer.save(tree, path)
  end

  @doc """
  Loads an index tree from JSON file.
  """
  def load_index(path) do
    Indexer.load(path)
  end

  @doc """
  Gets content for a specific page range from the PDF.
  Used by retrieval agents to fetch actual content.

  Page numbers are 1-based (matching printed PDF page numbers).
  """
  def get_content(pdf_path, start_page, end_page) do
    case get_cached_pages(pdf_path) do
      {:ok, pages} ->
        content =
          pages
          |> Enum.filter(fn {page_num, _} ->
            page_num >= start_page and page_num <= end_page
          end)
          |> Enum.map(fn {_, text} -> text end)
          |> Enum.join("\n\n")

        {:ok, content}

      error ->
        error
    end
  end

  # Get pages from cache or extract and cache them.
  # Parser.extract_pages returns 1-based page numbers.
  defp get_cached_pages(pdf_path) do
    ensure_cache()

    case :ets.lookup(@cache_table, pdf_path) do
      [{^pdf_path, pages}] ->
        {:ok, pages}

      [] ->
        case Parser.extract_pages(pdf_path) do
          {:ok, pages} ->
            :ets.insert(@cache_table, {pdf_path, pages})
            {:ok, pages}

          error ->
            error
        end
    end
  end

  @doc """
  Prints a tree structure for debugging.
  """
  def print_tree(tree, indent \\ 0) do
    prefix = String.duplicate("  ", indent)
    IO.puts("#{prefix}#{tree.node_id}: #{tree.title}")

    if tree[:summary] do
      summary = String.slice(tree.summary, 0, 60)
      IO.puts("#{prefix}  └─ #{summary}...")
    end

    for child <- Map.get(tree, :children, []) do
      print_tree(child, indent + 1)
    end

    :ok
  end
end
