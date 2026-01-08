defmodule PtcDemo.SearchTool do
  @moduledoc """
  Simulated knowledge base search with pagination.

  Provides a `search/1` function that can be registered as a PTC-Lisp tool,
  enabling multi-turn test scenarios where the LLM must refine searches
  to find specific documents.
  """

  alias PtcDemo.SampleData

  @doc "Search documents. Returns {results, cursor, has_more, total}. Use (get result :results) to extract the list."
  @spec search(map()) :: map()
  def search(args) do
    # Normalize keys - accept both string and atom keys
    args = normalize_keys(args)

    case Map.get(args, "query") do
      nil ->
        %{
          "results" => [],
          "cursor" => nil,
          "has_more" => false,
          "total" => 0,
          "error" => "Missing required 'query' argument"
        }

      query ->
        do_search(query, args)
    end
  end

  @doc "Fetch document by ID. Returns full document map or nil if not found."
  @spec fetch(map()) :: map() | nil
  def fetch(args) do
    args = normalize_keys(args)

    case Map.get(args, "id") do
      nil -> nil
      id -> Enum.find(SampleData.documents(), fn doc -> doc["id"] == id end)
    end
  end

  defp do_search(query, args) do
    limit = Map.get(args, "limit", 5)
    cursor = Map.get(args, "cursor")
    offset = parse_cursor(cursor)

    # Get all documents and filter by query
    documents = SampleData.documents()
    matching = filter_by_query(documents, query)

    # Paginate results
    total = length(matching)
    page = matching |> Enum.drop(offset) |> Enum.take(limit)
    has_more = offset + length(page) < total

    # Return simplified results (not full content)
    results =
      Enum.map(page, fn doc ->
        %{
          "id" => doc["id"],
          "title" => doc["title"],
          "topics" => doc["topics"],
          "department" => doc["department"]
        }
      end)

    next_cursor = if has_more, do: Integer.to_string(offset + limit), else: nil

    %{
      "results" => results,
      "cursor" => next_cursor,
      "has_more" => has_more,
      "total" => total
    }
  end

  # Normalize map keys - convert atoms to strings
  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Parse cursor string to offset integer
  defp parse_cursor(nil), do: 0
  defp parse_cursor(""), do: 0

  defp parse_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  defp parse_cursor(_), do: 0

  # Filter documents by query terms (simple keyword matching)
  defp filter_by_query(documents, query) do
    terms =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)

    Enum.filter(documents, fn doc ->
      searchable = build_searchable_text(doc)
      Enum.all?(terms, fn term -> String.contains?(searchable, term) end)
    end)
  end

  # Build lowercase searchable text from document fields
  defp build_searchable_text(doc) do
    [
      doc["title"] || "",
      Enum.join(doc["topics"] || [], " "),
      doc["content"] || "",
      doc["department"] || ""
    ]
    |> Enum.join(" ")
    |> String.downcase()
  end
end
