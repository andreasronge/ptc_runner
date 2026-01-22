defmodule PtcRunner.Mustache do
  @moduledoc """
  Standalone Mustache template parser and expander.

  Supports a subset of Mustache spec:
  - Simple variables: `{{name}}`
  - Dot notation: `{{user.name}}`
  - Current element: `{{.}}`
  - Comments: `{{! comment }}`
  - Sections (lists): `{{#items}}...{{/items}}`
  - Sections (maps/context push): `{{#user}}...{{/user}}`
  - Inverted sections: `{{^items}}...{{/items}}`
  - Standalone tag whitespace control

  No dependencies on other PtcRunner modules.

  ## Examples

      iex> {:ok, ast} = PtcRunner.Mustache.parse("Hello {{name}}")
      iex> PtcRunner.Mustache.expand(ast, %{name: "Alice"})
      {:ok, "Hello Alice"}

      iex> PtcRunner.Mustache.render("{{#items}}- {{name}}\\n{{/items}}", %{items: [%{name: "A"}, %{name: "B"}]})
      {:ok, "- A\\n- B\\n"}

  """

  @default_max_depth 20

  @typedoc "Location in the template"
  @type location :: %{line: pos_integer(), col: pos_integer()}

  @typedoc "AST node types"
  @type ast_node ::
          {:text, String.t()}
          | {:variable, path :: [String.t()], loc :: location()}
          | {:current, loc :: location()}
          | {:comment, String.t(), loc :: location()}
          | {:section, name :: String.t(), inner :: ast(), loc :: location()}
          | {:inverted_section, name :: String.t(), inner :: ast(), loc :: location()}

  @typedoc "Abstract syntax tree"
  @type ast :: [ast_node()]

  @typedoc "Variable info for extraction"
  @type variable_info :: %{
          type: :simple | :section | :inverted_section,
          path: [String.t()],
          fields: [variable_info()] | nil,
          loc: location()
        }

  @typedoc "Options for expand/3 and render/3"
  @type option :: {:max_depth, pos_integer()}

  @doc """
  Parse template string into AST.

  Returns `{:ok, ast}` on success or `{:error, message}` on parse errors.

  ## Examples

      iex> PtcRunner.Mustache.parse("Hello {{name}}")
      {:ok, [{:text, "Hello "}, {:variable, ["name"], %{line: 1, col: 7}}]}

      iex> PtcRunner.Mustache.parse("{{#items}}{{/items}}")
      {:ok, [{:section, "items", [], %{line: 1, col: 1}}]}

      iex> PtcRunner.Mustache.parse("{{#items}}")
      {:error, "unclosed section 'items' opened at line 1, col 1"}

  """
  @spec parse(String.t()) :: {:ok, ast()} | {:error, String.t()}
  def parse(template) when is_binary(template) do
    case tokenize(template) do
      {:ok, tokens} ->
        parse_tokens(tokens, [])

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Expand AST with context map.

  Returns `{:ok, string}` on success or `{:error, reason}` on expansion errors.

  ## Options

  - `:max_depth` - Maximum recursion depth (default: 20)

  ## Examples

      iex> {:ok, ast} = PtcRunner.Mustache.parse("Hello {{name}}")
      iex> PtcRunner.Mustache.expand(ast, %{name: "World"})
      {:ok, "Hello World"}

      iex> {:ok, ast} = PtcRunner.Mustache.parse("{{.}}")
      iex> {:error, {:dot_on_map, _, _}} = PtcRunner.Mustache.expand(ast, %{}, [])
      {:error, {:dot_on_map, %{line: 1, col: 1}, "{{.}} requires scalar value, got map on line 1, col 1. Use {{.field}} or pre-format the data."}}

  """
  @spec expand(ast(), map(), [option()]) :: {:ok, String.t()} | {:error, term()}
  def expand(ast, context, opts \\ []) when is_list(ast) and is_map(context) do
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    normalized = normalize_context(context)

    expand_nodes(ast, [normalized], max_depth, 0)
  end

  @doc """
  Convenience: parse and expand in one call.

  ## Examples

      iex> PtcRunner.Mustache.render("Hello {{name}}", %{name: "Alice"})
      {:ok, "Hello Alice"}

      iex> PtcRunner.Mustache.render("{{#items}}{{name}} {{/items}}", %{items: [%{name: "A"}, %{name: "B"}]})
      {:ok, "A B "}

  """
  @spec render(String.t(), map(), [option()]) :: {:ok, String.t()} | {:error, term()}
  def render(template, context, opts \\ []) when is_binary(template) and is_map(context) do
    case parse(template) do
      {:ok, ast} -> expand(ast, context, opts)
      {:error, _} = error -> error
    end
  end

  @doc """
  Extract all variables from AST for validation.

  Returns a list of variable info maps including location and type.

  ## Examples

      iex> {:ok, ast} = PtcRunner.Mustache.parse("{{name}} {{user.email}}")
      iex> PtcRunner.Mustache.extract_variables(ast)
      [
        %{type: :simple, path: ["name"], fields: nil, loc: %{line: 1, col: 1}},
        %{type: :simple, path: ["user", "email"], fields: nil, loc: %{line: 1, col: 10}}
      ]

  """
  @spec extract_variables(ast()) :: [variable_info()]
  def extract_variables(ast) when is_list(ast) do
    extract_from_nodes(ast, [])
  end

  # ---------------------------------------------------------------------------
  # Tokenizer
  # ---------------------------------------------------------------------------

  defp tokenize(template) do
    tokenize(template, 0, 1, 1, [])
  end

  defp tokenize(template, pos, line, col, acc) do
    if pos >= byte_size(template) do
      {:ok, Enum.reverse(acc)}
    else
      case binary_part(template, pos, min(2, byte_size(template) - pos)) do
        "{{" ->
          tokenize_tag(template, pos, line, col, acc)

        _ ->
          tokenize_text(template, pos, line, col, acc)
      end
    end
  end

  defp tokenize_text(template, pos, line, col, acc) do
    {text, end_pos, end_line, end_col} = read_until_tag_start(template, pos, line, col)

    if text == "" do
      tokenize(template, end_pos, end_line, end_col, acc)
    else
      token = {:text, text, %{line: line, col: col}}
      tokenize(template, end_pos, end_line, end_col, [token | acc])
    end
  end

  defp read_until_tag_start(template, pos, line, col) do
    read_until_tag_start(template, pos, line, col, [])
  end

  defp read_until_tag_start(template, pos, line, col, acc) when pos >= byte_size(template) do
    {IO.iodata_to_binary(Enum.reverse(acc)), pos, line, col}
  end

  defp read_until_tag_start(template, pos, line, col, acc) do
    case binary_part(template, pos, min(2, byte_size(template) - pos)) do
      "{{" ->
        {IO.iodata_to_binary(Enum.reverse(acc)), pos, line, col}

      _ ->
        <<c::utf8>> = binary_part(template, pos, 1)
        char = <<c::utf8>>

        {new_line, new_col} =
          if char == "\n" do
            {line + 1, 1}
          else
            {line, col + 1}
          end

        read_until_tag_start(template, pos + 1, new_line, new_col, [char | acc])
    end
  end

  defp tokenize_tag(template, pos, line, col, acc) do
    tag_loc = %{line: line, col: col}
    # Skip {{
    tag_start = pos + 2
    new_col = col + 2

    case find_close_braces(template, tag_start) do
      {:ok, content, close_pos} ->
        # Determine tag type based on first char
        {tag_type, name} = parse_tag_content(content)

        # Update line/col for content
        {content_end_line, content_end_col} = track_position(content, line, new_col)
        # Skip }}
        final_col = content_end_col + 2
        final_pos = close_pos + 2

        case tag_type do
          :empty_variable ->
            {:error, "empty variable name at line #{line}, col #{col}"}

          :empty_section ->
            {:error, "empty section name at line #{line}, col #{col}"}

          _ ->
            token =
              case tag_type do
                :comment -> {:comment, name, tag_loc}
                :section_open -> {:section_open, name, tag_loc}
                :inverted_open -> {:inverted_open, name, tag_loc}
                :section_close -> {:section_close, name, tag_loc}
                :variable -> {:variable, name, tag_loc}
              end

            tokenize(template, final_pos, content_end_line, final_col, [token | acc])
        end

      :error ->
        {:error, "unclosed tag at line #{line}, col #{col}"}
    end
  end

  defp find_close_braces(template, pos) do
    find_close_braces(template, pos, [])
  end

  defp find_close_braces(template, pos, _acc) when pos >= byte_size(template) do
    :error
  end

  defp find_close_braces(template, pos, acc) do
    case binary_part(template, pos, min(2, byte_size(template) - pos)) do
      "}}" ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc)), pos}

      _ ->
        char = binary_part(template, pos, 1)
        find_close_braces(template, pos + 1, [char | acc])
    end
  end

  defp parse_tag_content(content) do
    trimmed = String.trim(content)

    cond do
      String.starts_with?(trimmed, "!") ->
        # Keep content after ! (including leading space but not the !)
        # Find position after the ! in the trimmed version, map back to original
        after_bang =
          case String.split(content, "!", parts: 2) do
            [_before, rest] -> rest
            _ -> ""
          end

        {:comment, after_bang}

      String.starts_with?(trimmed, "#") ->
        name = String.trim(String.slice(trimmed, 1..-1//1))

        if name == "" do
          {:empty_section, nil}
        else
          {:section_open, name}
        end

      String.starts_with?(trimmed, "^") ->
        name = String.trim(String.slice(trimmed, 1..-1//1))

        if name == "" do
          {:empty_section, nil}
        else
          {:inverted_open, name}
        end

      String.starts_with?(trimmed, "/") ->
        {:section_close, String.trim(String.slice(trimmed, 1..-1//1))}

      trimmed == "" ->
        {:empty_variable, nil}

      true ->
        {:variable, trimmed}
    end
  end

  defp track_position(content, line, col) do
    content
    |> String.graphemes()
    |> Enum.reduce({line, col}, fn char, {l, c} ->
      if char == "\n", do: {l + 1, 1}, else: {l, c + 1}
    end)
  end

  # ---------------------------------------------------------------------------
  # Parser (tokens -> AST)
  # ---------------------------------------------------------------------------

  defp parse_tokens([], acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp parse_tokens([{:text, text, _loc} | rest], acc) do
    parse_tokens(rest, [{:text, text} | acc])
  end

  defp parse_tokens([{:comment, content, loc} | rest], acc) do
    # Check for standalone whitespace
    {rest, acc} = handle_standalone_token(rest, acc)
    parse_tokens(rest, [{:comment, content, loc} | acc])
  end

  defp parse_tokens([{:variable, ".", loc} | rest], acc) do
    parse_tokens(rest, [{:current, loc} | acc])
  end

  defp parse_tokens([{:variable, name, loc} | rest], acc) do
    path = String.split(name, ".")
    parse_tokens(rest, [{:variable, path, loc} | acc])
  end

  defp parse_tokens([{:section_open, name, loc} | rest], acc) do
    # Check for standalone whitespace
    {rest, acc} = handle_standalone_token(rest, acc)

    case parse_section(rest, name, loc, []) do
      {:ok, inner, remaining} ->
        # Check for standalone whitespace after close
        {remaining, _acc2} = handle_standalone_token(remaining, [])
        parse_tokens(remaining, [{:section, name, inner, loc} | acc])

      {:error, _} = error ->
        error
    end
  end

  defp parse_tokens([{:inverted_open, name, loc} | rest], acc) do
    # Check for standalone whitespace
    {rest, acc} = handle_standalone_token(rest, acc)

    case parse_section(rest, name, loc, []) do
      {:ok, inner, remaining} ->
        # Check for standalone whitespace after close
        {remaining, _acc2} = handle_standalone_token(remaining, [])
        parse_tokens(remaining, [{:inverted_section, name, inner, loc} | acc])

      {:error, _} = error ->
        error
    end
  end

  defp parse_tokens([{:section_close, name, loc} | _rest], _acc) do
    {:error, "closing tag '#{name}' without opening section at line #{loc.line}, col #{loc.col}"}
  end

  defp parse_section([], name, loc, _acc) do
    {:error, "unclosed section '#{name}' opened at line #{loc.line}, col #{loc.col}"}
  end

  defp parse_section([{:section_close, close_name, close_loc} | rest], name, _open_loc, acc) do
    if close_name != name do
      {:error,
       "mismatched section at line #{close_loc.line}, col #{close_loc.col}: expected '#{name}', got '#{close_name}'"}
    else
      {:ok, Enum.reverse(acc), rest}
    end
  end

  defp parse_section([{:text, text, _loc} | rest], name, open_loc, acc) do
    parse_section(rest, name, open_loc, [{:text, text} | acc])
  end

  defp parse_section([{:comment, content, loc} | rest], name, open_loc, acc) do
    {rest, acc} = handle_standalone_token(rest, acc)
    parse_section(rest, name, open_loc, [{:comment, content, loc} | acc])
  end

  defp parse_section([{:variable, ".", loc} | rest], name, open_loc, acc) do
    parse_section(rest, name, open_loc, [{:current, loc} | acc])
  end

  defp parse_section([{:variable, var_name, loc} | rest], name, open_loc, acc) do
    path = String.split(var_name, ".")
    parse_section(rest, name, open_loc, [{:variable, path, loc} | acc])
  end

  defp parse_section([{:section_open, inner_name, inner_loc} | rest], name, open_loc, acc) do
    {rest, acc} = handle_standalone_token(rest, acc)

    case parse_section(rest, inner_name, inner_loc, []) do
      {:ok, inner, remaining} ->
        {remaining, _acc2} = handle_standalone_token(remaining, [])
        parse_section(remaining, name, open_loc, [{:section, inner_name, inner, inner_loc} | acc])

      {:error, _} = error ->
        error
    end
  end

  defp parse_section([{:inverted_open, inner_name, inner_loc} | rest], name, open_loc, acc) do
    {rest, acc} = handle_standalone_token(rest, acc)

    case parse_section(rest, inner_name, inner_loc, []) do
      {:ok, inner, remaining} ->
        {remaining, _acc2} = handle_standalone_token(remaining, [])

        parse_section(
          remaining,
          name,
          open_loc,
          [{:inverted_section, inner_name, inner, inner_loc} | acc]
        )

      {:error, _} = error ->
        error
    end
  end

  # Handle standalone tag whitespace control
  # Per Mustache spec: when a tag appears alone on a line, strip the entire line
  defp handle_standalone_token(tokens, acc) do
    # Check if the previous text ends with only whitespace since last newline
    # and the next text starts with only whitespace until newline
    case {acc, tokens} do
      {[{:text, prev_text} | rest_acc], [{:text, next_text, loc} | rest_tokens]} ->
        case {strip_trailing_ws_on_line(prev_text), strip_leading_ws_to_newline(next_text)} do
          {{true, new_prev}, {true, new_next}} ->
            # Standalone - strip whitespace
            new_acc =
              if new_prev == "" do
                rest_acc
              else
                [{:text, new_prev} | rest_acc]
              end

            new_tokens =
              if new_next == "" do
                rest_tokens
              else
                [{:text, new_next, loc} | rest_tokens]
              end

            {new_tokens, new_acc}

          _ ->
            # Not standalone
            {tokens, acc}
        end

      {[], [{:text, next_text, loc} | rest_tokens]} ->
        # At start of template
        case strip_leading_ws_to_newline(next_text) do
          {true, new_next} ->
            new_tokens =
              if new_next == "" do
                rest_tokens
              else
                [{:text, new_next, loc} | rest_tokens]
              end

            {new_tokens, []}

          {false, _} ->
            {tokens, acc}
        end

      {[{:text, prev_text} | rest_acc], []} ->
        # At end of template
        case strip_trailing_ws_on_line(prev_text) do
          {true, new_prev} ->
            new_acc =
              if new_prev == "" do
                rest_acc
              else
                [{:text, new_prev} | rest_acc]
              end

            {[], new_acc}

          {false, _} ->
            {tokens, acc}
        end

      _ ->
        {tokens, acc}
    end
  end

  # Returns {true, new_text} if text ends with whitespace-only since last newline (or start)
  # The returned new_text is everything up to and including the last newline before the whitespace
  defp strip_trailing_ws_on_line(text) do
    # Match: (content ending with newline OR empty) followed by (only whitespace)
    # Regex: everything up to last newline, then only whitespace
    case Regex.run(~r/^(.*\n)([ \t]*)$/s, text) do
      [_, prefix, _ws] ->
        # Text ends with newline followed by optional whitespace
        {true, prefix}

      _ ->
        # Check if entire text is just whitespace (for start of file case)
        if Regex.match?(~r/^[ \t]*$/, text) do
          {true, ""}
        else
          {false, text}
        end
    end
  end

  # Returns {true, new_text} if text starts with whitespace followed by newline (or EOF)
  defp strip_leading_ws_to_newline(text) do
    case Regex.run(~r/^([ \t]*)\r?\n(.*)$/s, text) do
      [_, _ws, rest] ->
        {true, rest}

      _ ->
        # Check if entire text is just whitespace
        if Regex.match?(~r/^[ \t]*$/, text) do
          {true, ""}
        else
          {false, text}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Expander Implementation
  # ---------------------------------------------------------------------------

  defp expand_nodes([], _context_stack, _max_depth, _depth) do
    {:ok, ""}
  end

  defp expand_nodes(nodes, context_stack, max_depth, depth) do
    expand_nodes(nodes, context_stack, max_depth, depth, [])
  end

  defp expand_nodes([], _context_stack, _max_depth, _depth, acc) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp expand_nodes([node | rest], context_stack, max_depth, depth, acc) do
    case expand_node(node, context_stack, max_depth, depth) do
      {:ok, text} ->
        expand_nodes(rest, context_stack, max_depth, depth, [text | acc])

      {:error, _} = error ->
        error
    end
  end

  defp expand_node({:text, text}, _context_stack, _max_depth, _depth) do
    {:ok, text}
  end

  defp expand_node({:comment, _content, _loc}, _context_stack, _max_depth, _depth) do
    {:ok, ""}
  end

  defp expand_node({:variable, path, loc}, context_stack, _max_depth, _depth) do
    path_str = Enum.join(path, ".")

    case resolve_path(path, context_stack) do
      {:ok, value} when is_binary(value) or is_number(value) or is_atom(value) ->
        {:ok, to_string(value)}

      {:ok, value} when is_map(value) ->
        {:error,
         {:non_scalar_variable, loc,
          "{{#{path_str}}} resolved to map on line #{loc.line}, col #{loc.col}. " <>
            "Use a section {{##{path_str}}} or access a specific field."}}

      {:ok, value} when is_list(value) ->
        {:error,
         {:non_scalar_variable, loc,
          "{{#{path_str}}} resolved to list on line #{loc.line}, col #{loc.col}. " <>
            "Use a section {{##{path_str}}} to iterate."}}

      :not_found ->
        {:error, {:missing_key, path_str, loc}}
    end
  end

  defp expand_node({:current, loc}, context_stack, _max_depth, _depth) do
    # Context stack is always non-empty (starts with root context)
    [current | _] = context_stack

    cond do
      is_map(current) ->
        {:error,
         {:dot_on_map, loc,
          "{{.}} requires scalar value, got map on line #{loc.line}, col #{loc.col}. Use {{.field}} or pre-format the data."}}

      is_list(current) ->
        {:error,
         {:dot_on_list, loc,
          "{{.}} requires scalar value, got list on line #{loc.line}, col #{loc.col}. Use {{.field}} or pre-format the data."}}

      true ->
        {:ok, to_string(current)}
    end
  end

  defp expand_node({:section, name, inner, loc}, context_stack, max_depth, depth) do
    if depth >= max_depth do
      {:error,
       {:max_depth_exceeded, loc,
        "max depth (#{max_depth}) exceeded at line #{loc.line}, col #{loc.col}"}}
    else
      case resolve_path([name], context_stack) do
        {:ok, value} ->
          expand_section_value(value, inner, context_stack, max_depth, depth + 1, loc)

        :not_found ->
          # Missing key treated as falsy - section not rendered
          {:ok, ""}
      end
    end
  end

  defp expand_node({:inverted_section, name, inner, loc}, context_stack, max_depth, depth) do
    if depth >= max_depth do
      {:error,
       {:max_depth_exceeded, loc,
        "max depth (#{max_depth}) exceeded at line #{loc.line}, col #{loc.col}"}}
    else
      case resolve_path([name], context_stack) do
        {:ok, value} ->
          if falsy?(value) do
            expand_nodes(inner, context_stack, max_depth, depth + 1)
          else
            {:ok, ""}
          end

        :not_found ->
          # Missing key is falsy - inverted section renders
          expand_nodes(inner, context_stack, max_depth, depth + 1)
      end
    end
  end

  defp expand_section_value(value, inner, context_stack, max_depth, depth, _loc)
       when is_list(value) do
    if value == [] do
      {:ok, ""}
    else
      results =
        Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
          normalized_item =
            if is_map(item) do
              normalize_context(item)
            else
              item
            end

          case expand_nodes(inner, [normalized_item | context_stack], max_depth, depth) do
            {:ok, text} -> {:cont, {:ok, [text | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      case results do
        {:ok, texts} -> {:ok, texts |> Enum.reverse() |> IO.iodata_to_binary()}
        {:error, _} = error -> error
      end
    end
  end

  defp expand_section_value(value, inner, context_stack, max_depth, depth, _loc)
       when is_map(value) do
    normalized = normalize_context(value)
    expand_nodes(inner, [normalized | context_stack], max_depth, depth)
  end

  defp expand_section_value(value, inner, context_stack, max_depth, depth, _loc) do
    # Scalar value - truthy check
    if falsy?(value) do
      {:ok, ""}
    else
      expand_nodes(inner, context_stack, max_depth, depth)
    end
  end

  defp falsy?(nil), do: true
  defp falsy?(false), do: true
  defp falsy?([]), do: true
  defp falsy?(""), do: true
  defp falsy?(_), do: false

  defp resolve_path(path, context_stack) do
    # Try each context in the stack, starting from innermost
    Enum.find_value(context_stack, :not_found, fn context ->
      case get_path(context, path) do
        {:ok, _} = result -> result
        :not_found -> nil
      end
    end)
  end

  defp get_path(context, []) do
    {:ok, context}
  end

  defp get_path(context, [key | rest]) when is_map(context) do
    case Map.fetch(context, key) do
      {:ok, value} -> get_path(value, rest)
      :error -> :not_found
    end
  end

  defp get_path(_context, _path) do
    :not_found
  end

  defp normalize_context(ctx) when is_map(ctx) do
    Map.new(ctx, fn {k, v} -> {to_string(k), normalize_value(v)} end)
  end

  defp normalize_value(value) when is_map(value) do
    normalize_context(value)
  end

  defp normalize_value(value) when is_list(value) do
    Enum.map(value, &normalize_value/1)
  end

  defp normalize_value(value), do: value

  # ---------------------------------------------------------------------------
  # Variable Extraction
  # ---------------------------------------------------------------------------

  defp extract_from_nodes([], acc) do
    Enum.reverse(acc)
  end

  defp extract_from_nodes([node | rest], acc) do
    new_acc = extract_from_node(node, acc)
    extract_from_nodes(rest, new_acc)
  end

  defp extract_from_node({:text, _}, acc), do: acc
  defp extract_from_node({:comment, _, _}, acc), do: acc

  defp extract_from_node({:variable, path, loc}, acc) do
    [%{type: :simple, path: path, fields: nil, loc: loc} | acc]
  end

  defp extract_from_node({:current, loc}, acc) do
    [%{type: :simple, path: ["."], fields: nil, loc: loc} | acc]
  end

  defp extract_from_node({:section, name, inner, loc}, acc) do
    inner_vars = extract_from_nodes(inner, [])
    [%{type: :section, path: [name], fields: inner_vars, loc: loc} | acc]
  end

  defp extract_from_node({:inverted_section, name, inner, loc}, acc) do
    inner_vars = extract_from_nodes(inner, [])
    [%{type: :inverted_section, path: [name], fields: inner_vars, loc: loc} | acc]
  end
end
