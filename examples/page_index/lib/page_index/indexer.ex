defmodule PageIndex.Indexer do
  @moduledoc """
  Builds a hierarchical index of a document with LLM-generated summaries.

  The indexer:
  1. Parses the PDF to extract sections
  2. Generates concise summaries for each section using an LLM
  3. Builds a tree structure suitable for navigation
  """

  alias PageIndex.Parser
  alias PtcRunner.SubAgent

  @doc """
  Indexes a PDF document and returns a tree with summaries.

  ## Options

  - `:llm` - Required. The LLM client function
  - `:max_concurrency` - Max parallel summarization calls (default: 5)
  - `:max_content_chars` - Max chars to send to LLM per section (default: 8000)
  - `:doc_title` - Document title for the root node (default: filename without extension)

  ## Example

      llm = fn messages, _opts -> LlmClient.chat(messages, model: "gpt-4o-mini") end
      {:ok, tree} = PageIndex.Indexer.index("data/3M_2022_10K.pdf", llm: llm)
  """
  def index(pdf_path, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    max_concurrency = Keyword.get(opts, :max_concurrency, 5)
    max_content_chars = Keyword.get(opts, :max_content_chars, 8000)
    doc_title = Keyword.get(opts, :doc_title, Path.basename(pdf_path, ".pdf"))

    with {:ok, sections} <- Parser.parse(pdf_path),
         {:ok, summaries} <- generate_summaries(sections, llm, max_concurrency, max_content_chars),
         tree <- build_tree(sections, summaries, doc_title) do
      {:ok, tree}
    end
  end

  @doc """
  Generates summaries for all sections in parallel.
  """
  def generate_summaries(sections, llm, max_concurrency, max_content_chars) do
    IO.puts("Generating summaries for #{length(sections)} sections...")

    summaries =
      sections
      |> Task.async_stream(
        fn section ->
          summary = summarize_section(section, llm, max_content_chars)
          IO.puts("  ✓ #{section.id}: #{String.slice(summary, 0, 60)}...")
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
    # Truncate content if too long
    content =
      if String.length(section.content) > max_content_chars do
        String.slice(section.content, 0, max_content_chars) <> "\n[... truncated]"
      else
        section.content
      end

    prompt = """
    Summarize this document section in 1-2 sentences.
    Focus on key facts, metrics, and business implications.

    Section: Item #{section.item_num} - #{section.title}
    Pages: #{section.start_page}-#{section.end_page}

    Content:
    #{content}
    """

    case SubAgent.run(prompt,
           output: :json,
           signature: "{summary :string}",
           llm: llm
         ) do
      {:ok, step} ->
        step.return["summary"]

      {:error, step} ->
        IO.puts("    Error for #{section.id}: #{inspect(step.fail)}")
        "Summary unavailable for #{section.title}"
    end
  end

  @doc """
  Builds the final tree structure with summaries attached.
  """
  def build_tree(sections, summaries, doc_title \\ "Document") do
    # Group sections by category
    grouped =
      sections
      |> Enum.group_by(&categorize_item/1)
      |> Enum.sort_by(fn {cat, _} -> category_order(cat) end)
      |> Enum.map(fn {category, items} ->
        children =
          items
          |> Enum.sort_by(& &1.start_page)
          |> Enum.map(fn item ->
            %{
              node_id: item.id,
              title: "Item #{item.item_num}: #{item.title}",
              summary: Map.get(summaries, item.id, ""),
              start_page: item.start_page,
              end_page: item.end_page,
              children: []
            }
          end)

        # Category summary is combination of children summaries
        cat_summary =
          children
          |> Enum.map(& &1.summary)
          |> Enum.join(" ")
          |> String.slice(0, 200)

        %{
          node_id: category_id(category),
          title: category,
          summary: cat_summary,
          children: children
        }
      end)

    # Build root summary from category names
    category_names = Enum.map(grouped, & &1.title) |> Enum.join(", ")

    %{
      node_id: "root",
      title: doc_title,
      summary: "#{doc_title} containing: #{category_names}.",
      children: grouped
    }
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

  defp category_order(category) do
    case category do
      "Business Overview" -> 1
      "Risk Factors" -> 2
      "Unresolved Staff Comments" -> 3
      "Business Operations" -> 4
      "Market & Stock Information" -> 5
      "Management Discussion & Analysis" -> 6
      "Financial Statements & Controls" -> 7
      _ -> 99
    end
  end

  defp category_id(category) do
    category
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
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
