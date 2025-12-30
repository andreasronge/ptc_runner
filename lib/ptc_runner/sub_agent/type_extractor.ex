defmodule PtcRunner.SubAgent.TypeExtractor do
  @moduledoc """
  Extract signature and description from Elixir function @spec and @doc.

  Converts Elixir type specifications to PTC signature format for automatic
  tool definition. Extraction requires compiled documentation and only works
  for named functions (not anonymous).

  ## Limitations

  - Requires docs to be compiled (not available in releases without `--docs`)
  - Only works for named functions (not anonymous)
  - @spec conversion is best-effort; explicit signatures are more precise
  - Unsupported types fall back to `:any` with warning

  ## Examples

      # Function with @doc and @spec
      defmodule MyApp do
        @doc "Search for items matching query"
        @spec search(String.t(), integer()) :: [map()]
        def search(query, limit), do: []
      end

      iex> PtcRunner.SubAgent.TypeExtractor.extract(&MyApp.search/2)
      {:ok, {"(query :string, limit :int) -> [:map]", "Search for items matching query"}}

      # Anonymous function - cannot extract
      iex> PtcRunner.SubAgent.TypeExtractor.extract(fn x -> x end)
      {:ok, {nil, nil}}

  """

  require Logger

  @doc """
  Extract signature and description from a function reference.

  Returns `{:ok, {signature, description}}` where both may be `nil` if extraction
  is not possible. Never returns an error - falls back to `{nil, nil}` when
  extraction fails.

  ## Examples

      iex> PtcRunner.SubAgent.TypeExtractor.extract(&String.upcase/1)
      {:ok, {signature, description}} when is_binary(signature) or is_nil(signature)

  """
  @spec extract(function()) :: {:ok, {String.t() | nil, String.t() | nil}}
  def extract(fun) when is_function(fun) do
    info = Function.info(fun)

    case {Keyword.get(info, :module), Keyword.get(info, :name), Keyword.get(info, :arity)} do
      {module, name, arity} when not is_nil(module) and not is_nil(name) and not is_nil(arity) ->
        extract_from_module(module, name, arity)

      _ ->
        # Anonymous function or unable to get info
        {:ok, {nil, nil}}
    end
  end

  # Extract @doc and @spec from a module/function/arity triple
  defp extract_from_module(module, name, arity) do
    signature_string = extract_signature_string(module, name, arity)
    signature = extract_signature(module, name, arity, signature_string)
    description = extract_description(module, name, arity)
    {:ok, {signature, description}}
  rescue
    # Handle any errors during extraction gracefully
    e ->
      Logger.warning(
        "TypeExtractor failed for #{inspect(module)}.#{name}/#{arity}: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:ok, {nil, nil}}
  end

  # Extract signature string from docs (e.g., "add(a, b)")
  defp extract_signature_string(module, name, arity) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _beam_lang, _format, _module_doc, _metadata, docs} ->
        find_signature_string(docs, name, arity)

      {:error, _reason} ->
        nil
    end
  end

  # Find the signature string for a specific function
  defp find_signature_string(docs, name, arity) do
    case Enum.find(docs, fn
           {{:function, ^name, ^arity}, _anno, _signature, _doc, _metadata} -> true
           _ -> false
         end) do
      {{:function, ^name, ^arity}, _anno, [signature_string | _], _doc, _metadata} ->
        signature_string

      _ ->
        nil
    end
  end

  # Extract @doc attribute
  defp extract_description(module, name, arity) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _beam_lang, _format, _module_doc, _metadata, docs} ->
        find_doc(docs, name, arity)

      {:error, _reason} ->
        nil
    end
  end

  # Find the specific function's @doc in the docs list
  defp find_doc(docs, name, arity) do
    case Enum.find(docs, fn
           {{:function, ^name, ^arity}, _anno, _signature, doc, _metadata} -> doc != :none
           _ -> false
         end) do
      {{:function, ^name, ^arity}, _anno, _signature, %{"en" => doc_string}, _metadata} ->
        # Extract first line or first sentence as description
        extract_first_line(doc_string)

      {{:function, ^name, ^arity}, _anno, _signature, doc_string, _metadata}
      when is_binary(doc_string) ->
        extract_first_line(doc_string)

      _ ->
        nil
    end
  end

  # Extract first meaningful line from doc string
  defp extract_first_line(doc) when is_binary(doc) do
    doc
    |> String.trim()
    |> String.split("\n")
    |> Enum.find(&(String.trim(&1) != ""))
    |> case do
      nil -> nil
      line -> String.trim(line)
    end
  end

  # Extract @spec and convert to signature format
  defp extract_signature(module, name, arity, signature_string) do
    case Code.Typespec.fetch_specs(module) do
      {:ok, specs} ->
        find_and_convert_spec(specs, name, arity, signature_string)

      :error ->
        nil
    end
  end

  # Find the matching spec and convert it
  defp find_and_convert_spec(specs, name, arity, signature_string) do
    # Find all specs for this function name (any arity)
    matching_specs =
      Enum.filter(specs, fn
        {{^name, _}, _spec_list} -> true
        _ -> false
      end)

    case matching_specs do
      [] ->
        nil

      matches ->
        # Sort by arity (descending) and pick the highest arity spec
        {_name_arity, spec_list} =
          matches
          |> Enum.sort_by(fn {{_name, spec_arity}, _} -> spec_arity end, :desc)
          |> Enum.fetch!(0)

        convert_spec_to_signature(spec_list, name, arity, signature_string)
    end
  end

  # Convert Elixir typespec to PTC signature format
  defp convert_spec_to_signature([spec | _rest], _name, _arity, signature_string) do
    case spec do
      {:type, _line, :fun, [{:type, _line2, :product, params}, return_type]} ->
        # Standard function spec: (params) -> return
        param_sig = convert_params(params, signature_string)
        return_sig = convert_type(return_type)
        "(#{param_sig}) -> #{return_sig}"

      {:type, _line, :fun, [return_type]} ->
        # No-arg function: () -> return
        return_sig = convert_type(return_type)
        "() -> #{return_sig}"

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # Convert parameter list to signature format
  defp convert_params(params, signature_string) when is_list(params) do
    param_names = parse_signature_params(signature_string)

    params
    |> Enum.with_index()
    |> Enum.map_join(", ", fn {param, idx} ->
      type = convert_type(param)
      name = Enum.at(param_names, idx) || "arg#{idx}"
      "#{name} #{type}"
    end)
  end

  # Parse parameter names from signature string like "add(a, b)" or "search(query, limit)"
  defp parse_signature_params(nil), do: []

  defp parse_signature_params(signature_string) do
    # Extract content between parentheses
    case Regex.run(~r/\(([^)]*)\)/, signature_string) do
      [_, params_str] ->
        # Split by comma and extract parameter names
        params_str
        |> String.split(",")
        |> Enum.map(fn param ->
          param
          |> String.trim()
          # Remove default values like "limit \\ 10"
          |> String.split("\\")
          |> List.first()
          |> String.trim()
        end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  # Convert Elixir type to Signature type
  # Based on type-coercion-matrix.md mapping
  defp convert_type({:type, _line, :binary, []}) do
    ":string"
  end

  defp convert_type({:user_type, _line, :t, []}) do
    # String.t() is represented as {:user_type, _, :t, []} in the local module context
    ":string"
  end

  defp convert_type({:remote_type, _line, [{:atom, _, String}, {:atom, _, :t}, []]}) do
    ":string"
  end

  defp convert_type({:type, _line, :integer, []}) do
    ":int"
  end

  defp convert_type({:type, _line, :non_neg_integer, []}) do
    ":int"
  end

  defp convert_type({:type, _line, :pos_integer, []}) do
    ":int"
  end

  defp convert_type({:type, _line, :float, []}) do
    ":float"
  end

  defp convert_type({:type, _line, :number, []}) do
    ":float"
  end

  defp convert_type({:type, _line, :boolean, []}) do
    ":bool"
  end

  defp convert_type({:type, _line, :atom, []}) do
    ":keyword"
  end

  defp convert_type({:type, _line, :map, :any}) do
    ":map"
  end

  defp convert_type({:type, _line, :map, _fields}) do
    # For now, treat structured maps as :map
    # TODO: Could expand to {field :type} format
    ":map"
  end

  defp convert_type({:type, _line, :list, [element_type]}) do
    type = convert_type(element_type)
    "[#{type}]"
  end

  defp convert_type({:type, _line, :list, []}) do
    "[:any]"
  end

  defp convert_type({:type, _line, :any, []}) do
    ":any"
  end

  defp convert_type({:type, _line, :term, []}) do
    ":any"
  end

  # Handle union types - for now, fall back to :any with warning
  defp convert_type({:type, _line, :union, _types}) do
    Logger.debug("TypeExtractor: union types not yet supported, falling back to :any")
    ":any"
  end

  # Handle tuple types - convert to list for now
  defp convert_type({:type, _line, :tuple, _elements}) do
    Logger.debug("TypeExtractor: tuple types converted to :any")
    ":any"
  end

  # Handle DateTime and other special types
  defp convert_type({:remote_type, _line, [{:atom, _, DateTime}, {:atom, _, :t}, []]}) do
    ":string"
  end

  defp convert_type({:remote_type, _line, [{:atom, _, Date}, {:atom, _, :t}, []]}) do
    ":string"
  end

  defp convert_type({:remote_type, _line, [{:atom, _, Time}, {:atom, _, :t}, []]}) do
    ":string"
  end

  defp convert_type({:remote_type, _line, [{:atom, _, NaiveDateTime}, {:atom, _, :t}, []]}) do
    ":string"
  end

  # Unsupported types - fall back to :any
  defp convert_type(_other) do
    Logger.debug("TypeExtractor: unsupported type, falling back to :any")
    ":any"
  end
end
