defmodule PageIndex.DocumentTools do
  @moduledoc """
  Shared helpers for document tree navigation, section fetching, and text search.

  Used by all retriever implementations to avoid duplicating tool and tree logic.
  """

  @doc """
  Flattens a document tree into a list of leaf nodes with page ranges.

  Only includes nodes that have a `start_page` value.
  """
  def flatten_tree(tree, acc \\ []) do
    children = Map.get(tree, :children, [])

    node = %{
      node_id: tree.node_id,
      title: tree.title,
      summary: tree.summary,
      start_page: Map.get(tree, :start_page),
      end_page: Map.get(tree, :end_page)
    }

    updated_acc = if node.start_page, do: [node | acc], else: acc

    Enum.reduce(children, updated_acc, fn child, child_acc ->
      flatten_tree(child, child_acc)
    end)
  end

  @doc """
  Formats nodes as a compact summary string for inclusion in LLM prompts.

  Each line: `node_id: title (p.start-end) - summary_prefix`
  """
  def format_sections(nodes) do
    nodes
    |> Enum.map(fn n ->
      summary = String.slice(n.summary || "", 0, 80)
      "#{n.node_id}: #{n.title} (p.#{n.start_page}-#{n.end_page}) - #{summary}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Builds a fetch_section tool function with fuzzy node matching and pagination.

  Returns content in `chunk_size`-char chunks (default 5000). When truncated,
  includes a hint with the offset for the next chunk.
  """
  def make_fetch_tool(nodes, pdf_path, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 5000)

    fn args ->
      query = args["node_id"] || args[:node_id] || ""
      offset = parse_offset(args["offset"] || args[:offset] || 0)

      case find_node(nodes, query) do
        {:ok, node} ->
          case PageIndex.get_content(pdf_path, node.start_page, node.end_page) do
            {:ok, full_content} ->
              total_chars = String.length(full_content)
              sliced = String.slice(full_content, offset, chunk_size)
              returned_chars = String.length(sliced)
              end_offset = offset + returned_chars
              truncated = end_offset < total_chars

              result = %{
                "node_id" => node.node_id,
                "title" => node.title,
                "pages" => "#{node.start_page}-#{node.end_page}",
                "content" => sliced,
                "total_chars" => total_chars,
                "offset" => offset,
                "truncated" => truncated
              }

              if truncated do
                Map.put(
                  result,
                  "hint",
                  "Content truncated. Use fetch_section with offset: #{end_offset} to get more."
                )
              else
                result
              end

            {:error, reason} ->
              %{"error" => inspect(reason)}
          end

        {:error, suggestions} ->
          %{"error" => "No match for '#{query}'. Try: #{suggestions}"}
      end
    end
  end

  @doc """
  Builds a grep_section tool function with fuzzy node matching.

  Supports literal text search and regex patterns (pipe-delimited OR, `.*`).
  Returns up to 5 matches with context and offset hints.
  """
  def make_grep_tool(nodes, pdf_path) do
    fn args ->
      query = args["node_id"] || args[:node_id] || ""
      pattern = args["pattern"] || args[:pattern] || ""

      case find_node(nodes, query) do
        {:ok, node} ->
          case PageIndex.get_content(pdf_path, node.start_page, node.end_page) do
            {:ok, content} ->
              matches = find_pattern_matches(content, pattern)

              %{
                "node_id" => node.node_id,
                "total_chars" => String.length(content),
                "pattern" => pattern,
                "matches" => Enum.take(matches, 5)
              }

            {:error, reason} ->
              %{"error" => inspect(reason)}
          end

        {:error, suggestions} ->
          %{"error" => "No match for '#{query}'. Try: #{suggestions}"}
      end
    end
  end

  @doc """
  Finds a node by exact ID match or fuzzy word matching.

  Returns `{:ok, node}` or `{:error, suggestions}`.
  """
  def find_node(nodes, query) do
    node = Enum.find(nodes, fn n -> n.node_id == query end)
    node = node || find_best_match(nodes, query)

    if node do
      {:ok, node}
    else
      {:error, suggest_sections(nodes, query)}
    end
  end

  @doc """
  Searches content for a pattern (literal or regex) and returns match positions with context.
  """
  def find_pattern_matches(content, pattern) do
    content_lower = String.downcase(content)

    if String.contains?(pattern, "|") or String.contains?(pattern, ".*") do
      find_regex_matches(content, content_lower, pattern)
    else
      pattern_lower = String.downcase(pattern)
      find_all_positions(content, content_lower, pattern_lower, 0, [])
    end
  end

  # --- Private helpers ---

  defp parse_offset(offset) when is_binary(offset) do
    offset |> String.replace(",", "") |> String.to_integer()
  end

  defp parse_offset(offset) when is_integer(offset), do: offset
  defp parse_offset(offset) when is_float(offset), do: round(offset)

  defp find_best_match(nodes, query) do
    query_lower = String.downcase(query)
    query_words = String.split(query_lower, ~r/[\s_]+/)

    nodes
    |> Enum.map(fn node ->
      title_lower = String.downcase(node.title)
      id_lower = String.downcase(node.node_id)

      score =
        Enum.count(query_words, fn word ->
          String.contains?(title_lower, word) or String.contains?(id_lower, word)
        end)

      {node, score}
    end)
    |> Enum.filter(fn {_, score} -> score > 0 end)
    |> Enum.max_by(fn {_, score} -> score end, fn -> nil end)
    |> then(fn
      {node, _score} -> node
      nil -> nil
    end)
  end

  defp suggest_sections(nodes, query) do
    query_lower = String.downcase(query)

    suggestions =
      nodes
      |> Enum.filter(fn n ->
        String.contains?(String.downcase(n.title), query_lower) or
          String.contains?(String.downcase(n.node_id), query_lower)
      end)
      |> Enum.take(3)
      |> Enum.map(& &1.node_id)
      |> Enum.join(", ")

    if suggestions == "" do
      nodes |> Enum.take(5) |> Enum.map(& &1.node_id) |> Enum.join(", ")
    else
      suggestions
    end
  end

  defp find_regex_matches(content, content_lower, pattern) do
    case Regex.compile(String.downcase(pattern), "i") do
      {:ok, regex} ->
        Regex.scan(regex, content_lower, return: :index)
        |> Enum.map(fn [{pos, _len} | _] ->
          ctx_start = max(0, pos - 40)
          ctx = String.slice(content, ctx_start, 120)

          %{
            "offset" => pos,
            "context" => ctx,
            "hint" =>
              "Use fetch_section with offset: #{max(0, pos - 200)} to read around this match."
          }
        end)

      {:error, _} ->
        find_all_positions(content, content_lower, String.downcase(pattern), 0, [])
    end
  end

  defp find_all_positions(_content, content_lower, _pattern, start, acc)
       when start >= byte_size(content_lower) do
    Enum.reverse(acc)
  end

  defp find_all_positions(content, content_lower, pattern, start, acc) do
    case :binary.match(content_lower, pattern, scope: {start, byte_size(content_lower) - start}) do
      {pos, _len} ->
        ctx_start = max(0, pos - 40)
        ctx = String.slice(content, ctx_start, 120)

        match = %{
          "offset" => pos,
          "context" => ctx,
          "hint" =>
            "Use fetch_section with offset: #{max(0, pos - 200)} to read around this match."
        }

        find_all_positions(content, content_lower, pattern, pos + 1, [match | acc])

      :nomatch ->
        Enum.reverse(acc)
    end
  end
end
