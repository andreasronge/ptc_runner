defmodule PageIndex.Retriever do
  @moduledoc """
  Tree-based retrieval using SubAgent with llm_query.

  Two retrieval modes:
  - `retrieve/3` - Agent-based with tool calls to fetch content
  - `retrieve_simple/3` - Score all nodes, fetch top matches
  """

  alias PtcRunner.SubAgent

  @doc """
  Retrieves relevant content using an agent that can fetch sections.

  The agent sees a list of all sections with summaries and can
  call `get-content` to fetch actual page content.
  """
  def retrieve(tree, query, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    pdf_path = Keyword.fetch!(opts, :pdf_path)
    max_turns = Keyword.get(opts, :max_turns, 15)

    # Pre-warm the PDF cache before agent execution
    IO.puts("Pre-loading PDF pages...")
    {:ok, _} = PageIndex.get_content(pdf_path, 1, 1)
    IO.puts("PDF cache ready.")

    # Flatten tree to get all nodes with page ranges
    nodes = flatten_tree(tree)

    # Format sections as a readable list
    sections_text =
      nodes
      |> Enum.map(fn n ->
        summary = String.slice(n.summary || "", 0, 120)
        "• #{n.node_id}: #{n.title} (pages #{n.start_page}-#{n.end_page})\n  #{summary}"
      end)
      |> Enum.join("\n\n")

    # Tool to fetch content by node_id with offset pagination
    get_content = fn args ->
      node_id = args["node_id"] || args[:node_id]
      offset = args["offset"] || args[:offset] || 0

      offset =
        if is_binary(offset),
          do: offset |> String.replace(",", "") |> String.to_integer(),
          else: offset

      node = Enum.find(nodes, fn n -> n.node_id == node_id end)

      if node do
        case PageIndex.get_content(pdf_path, node.start_page, node.end_page) do
          {:ok, full_content} ->
            total_chars = String.length(full_content)
            sliced = String.slice(full_content, offset, 6000)
            returned_chars = String.length(sliced)
            end_offset = offset + returned_chars
            truncated = end_offset < total_chars

            result = %{
              node_id: node_id,
              title: node.title,
              pages: "#{node.start_page}-#{node.end_page}",
              content: sliced,
              total_chars: total_chars,
              offset: offset,
              truncated: truncated
            }

            if truncated do
              Map.put(
                result,
                :hint,
                "Content truncated. Call get-content with offset: #{end_offset} to get more."
              )
            else
              result
            end

          {:error, reason} ->
            %{error: "Failed to fetch: #{inspect(reason)}"}
        end
      else
        %{error: "Node not found: #{node_id}"}
      end
    end

    # Tool to search section content for keywords
    grep_content = make_grep_tool(nodes, pdf_path)

    prompt = """
    Answer the question using the document sections listed below.

    QUESTION: {{query}}

    AVAILABLE SECTIONS:
    #{sections_text}

    INSTRUCTIONS:
    1. Read the summaries and identify 2-4 sections most likely to answer the question
    2. Fetch each relevant section using: (tool/get-content {:node_id "the_node_id"})
    3. Read the fetched content carefully
    3b. PAGINATION: If you are looking for a table or specific data and a fetch result
        shows `truncated: true`, you MUST call get-content again with the same node_id
        and the offset from the hint. Do not guess data from partial tables.
        For large sections, use grep-content first to find where specific data appears,
        then use get-content with the offset.
    4. Synthesize a comprehensive answer using facts from the content
    5. Return your answer with the sources used

    IMPORTANT:
    - Fetch multiple sections if the answer requires information from different parts
    - Use specific numbers and facts from the content
    - Cite which sections your answer came from
    """

    navigator =
      SubAgent.new(
        prompt: prompt,
        signature:
          "(query :string) -> {answer :string, sources [{node_id :string, pages :string}]}",
        tools: %{
          "get-content" =>
            {get_content,
             signature:
               "(node_id :string, offset :int) -> {node_id :string, title :string, pages :string, content :string, total_chars :int, offset :int, truncated :bool, hint :string}",
             description:
               "Fetch content from a document section by ID. Use offset for pagination when truncated is true."},
          "grep-content" =>
            {grep_content,
             signature:
               "(node_id :string, pattern :string) -> {node_id :string, total_chars :int, pattern :string, matches [{offset :int, context :string, hint :string}]}",
             description:
               "Search a section for a keyword or phrase. Returns up to 5 matches with context."}
        },
        max_turns: max_turns,
        timeout: 30_000
      )

    SubAgent.run(navigator, llm: llm, context: %{query: query})
  end

  @doc """
  Simple retrieval that scores all nodes and fetches top matches.
  More predictable but makes more LLM calls for scoring.
  """
  def retrieve_simple(tree, query, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    pdf_path = Keyword.fetch!(opts, :pdf_path)
    top_k = Keyword.get(opts, :top_k, 3)

    nodes = flatten_tree(tree)

    IO.puts("Scoring #{length(nodes)} nodes...")

    scored_nodes =
      nodes
      |> Task.async_stream(
        fn node ->
          score = score_relevance(node, query, llm)
          IO.puts("  #{node.node_id}: #{score}")
          Map.put(node, :score, score)
        end,
        max_concurrency: 5,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(top_k)

    IO.puts("\nTop #{top_k} relevant sections:")

    for node <- scored_nodes do
      IO.puts("  #{node.node_id} (score: #{node.score}): #{node.title}")
    end

    IO.puts("\nFetching content...")

    contents =
      Enum.map(scored_nodes, fn node ->
        {:ok, content} = PageIndex.get_content(pdf_path, node.start_page, node.end_page)

        %{
          node_id: node.node_id,
          title: node.title,
          pages: "#{node.start_page}-#{node.end_page}",
          content: content
        }
      end)

    IO.puts("Generating answer...")
    generate_answer(query, contents, llm)
  end

  defp make_grep_tool(nodes, pdf_path) do
    fn args ->
      query = args["node_id"] || args[:node_id] || ""
      pattern = args["pattern"] || args[:pattern] || ""

      node = Enum.find(nodes, fn n -> n.node_id == query end)

      node =
        node ||
          Enum.max_by(
            nodes,
            fn n ->
              query_lower = String.downcase(query)
              words = String.split(query_lower, ~r/[\s_]+/)

              Enum.count(words, fn w ->
                String.contains?(String.downcase(n.node_id), w) or
                  String.contains?(String.downcase(n.title), w)
              end)
            end,
            fn -> nil end
          )

      if node do
        case PageIndex.get_content(pdf_path, node.start_page, node.end_page) do
          {:ok, content} ->
            matches = find_pattern_matches(content, pattern)

            %{
              node_id: node.node_id,
              total_chars: String.length(content),
              pattern: pattern,
              matches: Enum.take(matches, 5)
            }

          {:error, reason} ->
            %{error: inspect(reason)}
        end
      else
        %{error: "No match for '#{query}'."}
      end
    end
  end

  defp find_pattern_matches(content, pattern) do
    content_lower = String.downcase(content)

    if String.contains?(pattern, "|") or String.contains?(pattern, ".*") do
      find_regex_matches(content, content_lower, pattern)
    else
      pattern_lower = String.downcase(pattern)
      find_all_positions(content, content_lower, pattern_lower, 0, [])
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
            offset: pos,
            context: ctx,
            hint: "Use get-content with offset: #{max(0, pos - 200)} to read around this match."
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
          offset: pos,
          context: ctx,
          hint: "Use get-content with offset: #{max(0, pos - 200)} to read around this match."
        }

        find_all_positions(content, content_lower, pattern, pos + 1, [match | acc])

      :nomatch ->
        Enum.reverse(acc)
    end
  end

  defp flatten_tree(tree, acc \\ []) do
    children = Map.get(tree, :children, [])

    node = %{
      node_id: tree.node_id,
      title: tree.title,
      summary: tree.summary,
      start_page: Map.get(tree, :start_page),
      end_page: Map.get(tree, :end_page)
    }

    acc = if node.start_page, do: [node | acc], else: acc

    Enum.reduce(children, acc, fn child, acc ->
      flatten_tree(child, acc)
    end)
  end

  defp score_relevance(node, query, llm) do
    prompt = """
    Rate how relevant this section is to answering the question.

    Question: #{query}

    Section: #{node.title}
    Summary: #{node.summary}

    Return a score from 0.0 (not relevant) to 1.0 (highly relevant).
    """

    case SubAgent.run(prompt, output: :json, signature: "{score :float}", llm: llm) do
      {:ok, step} -> step.return["score"] || 0.0
      {:error, _} -> 0.0
    end
  end

  defp generate_answer(query, contents, llm) do
    context_text =
      contents
      |> Enum.map(fn c ->
        """
        === #{c.title} (pages #{c.pages}) ===
        #{String.slice(c.content, 0, 4000)}
        """
      end)
      |> Enum.join("\n\n")

    prompt = """
    Answer the following question using ONLY the provided context.
    Cite specific facts and numbers from the sources.

    Question: #{query}

    Context:
    #{context_text}
    """

    case SubAgent.run(prompt,
           output: :json,
           signature: "{answer :string, sources [:string]}",
           llm: llm
         ) do
      {:ok, step} -> {:ok, step.return}
      {:error, step} -> {:error, step.fail}
    end
  end
end
