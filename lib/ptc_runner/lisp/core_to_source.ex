defmodule PtcRunner.Lisp.CoreToSource do
  @moduledoc """
  Convert Core AST (the analyzed/desugared representation) back to PTC-Lisp source strings.

  This is distinct from `PtcRunner.Lisp.Formatter` which handles raw parser AST.
  CoreToSource works with the intermediate representation produced by the analyzer
  and stored inside closures.

  ## Use Cases

  - Serializing capture-free closures for archive persistence
  - Novelty comparison between memory designs
  - Debugging Core AST output
  """

  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.Analyze.Patterns
  alias PtcRunner.Lisp.ClosureCapture
  alias PtcRunner.Lisp.CoreAST
  alias PtcRunner.Lisp.FastParser
  alias PtcRunner.Lisp.Format.SymbolRef
  alias PtcRunner.Lisp.Formatter
  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Java.Primitive, as: JavaPrimitive
  alias PtcRunner.Lisp.Java.Surface, as: JavaSurface
  alias PtcRunner.Lisp.Java.Time.Duration, as: JavaDuration
  alias PtcRunner.Lisp.Java.Time.Instant, as: JavaInstant
  alias PtcRunner.Lisp.Java.Time.LocalDate, as: JavaLocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.SourceAtoms

  @prelude_semantic_metadata [
    :prelude_contract,
    :prelude_internal,
    :prelude_ns,
    :prelude_ref,
    :prelude_tool_refs
  ]
  @internal_temporary_prefix <<0, "__ptc_">>
  @serialized_temporary_prefix "__ptc_serialized_"

  @doc """
  Convert a Core AST node to a PTC-Lisp source string.

  ## Examples

      iex> PtcRunner.Lisp.CoreToSource.format({:var, :x})
      "x"

      iex> PtcRunner.Lisp.CoreToSource.format({:string, "hello"})
      ~S("hello")

      iex> PtcRunner.Lisp.CoreToSource.format({:call, {:var, :+}, [1, 2]})
      "(+ 1 2)"
  """
  @spec format(term()) :: String.t()
  def format(value), do: value |> encode_internal_temporaries() |> do_format()

  @spec do_format(term()) :: String.t()

  # Literals
  defp do_format(nil), do: "nil"
  defp do_format(true), do: "true"
  defp do_format(false), do: "false"
  defp do_format(n) when is_integer(n), do: Integer.to_string(n)

  defp do_format(n) when is_float(n) do
    :erlang.float_to_binary(n, [:short])
  end

  defp do_format(:infinity), do: "##Inf"
  defp do_format(:negative_infinity), do: "##-Inf"
  defp do_format(:nan), do: "##NaN"
  defp do_format(keyword) when is_atom(keyword), do: ":#{keyword}"

  defp do_format({:string, s}), do: ~s("#{escape_string(s)}")
  defp do_format({:keyword, k}), do: ":#{k}"

  # Delegate {:literal, v} to Formatter (used for compile-time constants)
  defp do_format({:literal, v}), do: Formatter.format(v)

  # Raw runtime values (from step.memory, not Core AST)
  defp do_format(%LispKeyword{name: name} = keyword) do
    if LispKeyword.valid?(keyword), do: ":#{name}", else: raise(ArgumentError, "invalid keyword")
  end

  defp do_format(%SymbolRef{name: name} = symbol_ref) do
    if SymbolRef.valid?(symbol_ref),
      do: "'#{name}",
      else: raise(ArgumentError, "invalid symbol reference")
  end

  defp do_format(s) when is_binary(s), do: ~s("#{escape_string(s)}")
  defp do_format(list) when is_list(list), do: "[#{format_list(list)}]"

  defp do_format(%MapSet{map: map}) when is_map(map),
    do: "\#{#{map |> Map.keys() |> format_list()}}"

  defp do_format(map) when is_map(map) and not is_struct(map) do
    inner =
      Enum.map_join(map, " ", fn {k, v} -> "#{format_map_key(k)} #{do_format(v)}" end)

    "{#{inner}}"
  end

  # Variables and data access
  defp do_format({:var, name}), do: to_string(name)
  defp do_format({:symbol_ref, name}) when is_binary(name), do: "'#{name}"
  defp do_format({:data, key}), do: "data/#{key}"
  defp do_format({:runtime_callable, namespace, name}), do: "#{namespace}/#{name}"
  defp do_format({:prelude_ref, ref}), do: ref

  defp do_format({:prelude_call, ref, arguments}) do
    "(#{ref} #{format_list(arguments)})"
  end

  defp do_format({:java_ref, reference_id}), do: java_reference_source(reference_id)
  defp do_format({:java_field, reference_id}), do: java_reference_source(reference_id)

  defp do_format({tag, reference_id, arguments}) when tag in [:java_static, :java_new] do
    "(#{java_reference_source(reference_id)} #{format_list(arguments)})"
  end

  defp do_format({:java_instance, reference_id, receiver, arguments}) do
    {:ok, reference} = JavaSurface.fetch_reference(reference_id)
    {:ok, class} = JavaSurface.fetch_class(reference.class_id)
    "(#{class.name}/#{reference.member} #{format_list([receiver | arguments])})"
  end

  defp do_format({:java_dot, member_family_id, receiver, arguments}) do
    {:ok, source} = JavaSurface.member_family_source(member_family_id)
    "(#{source} #{format_list([receiver | arguments])})"
  end

  # Collections
  defp do_format({:vector, elems}) do
    "[#{format_list(elems)}]"
  end

  defp do_format({:map, pairs}) do
    inner =
      Enum.map_join(pairs, " ", fn {k, v} -> "#{do_format(k)} #{do_format(v)}" end)

    "{#{inner}}"
  end

  defp do_format({:set, elems}) do
    "\#{#{format_list(elems)}}"
  end

  # Let bindings
  defp do_format({:let, bindings, body}) do
    bindings_str =
      Enum.map_join(bindings, " ", fn {:binding, pattern, value} ->
        "#{format_pattern(pattern)} #{do_format(value)}"
      end)

    "(let [#{bindings_str}] #{do_format(body)})"
  end

  # Anonymous function
  defp do_format({:fn, params, body}) do
    "(fn [#{format_params(params)}] #{do_format(body)})"
  end

  defp do_format({:fn, name, params, body}) do
    "(fn #{name} [#{format_params(params)}] #{do_format(body)})"
  end

  # Loop with tail recursion
  defp do_format({:loop, bindings, body}) do
    bindings_str =
      Enum.map_join(bindings, " ", fn {:binding, pattern, value} ->
        "#{format_pattern(pattern)} #{do_format(value)}"
      end)

    "(loop [#{bindings_str}] #{do_format(body)})"
  end

  # Function call
  defp do_format({:call, {:var, name}, args}) do
    "(#{name} #{format_list(args)})"
  end

  defp do_format({:call, target, args}) do
    "(#{do_format(target)} #{format_list(args)})"
  end

  # Tool call
  defp do_format({:tool_call, name, args}) do
    "(tool/#{name} #{format_list(args)})"
  end

  # Definitions retain the only source-representable metadata: a docstring.
  defp do_format({tag, name, value, metadata}) when tag in [:def, :defonce] do
    "(#{tag} #{name}#{definition_metadata_source!(metadata)} #{do_format(value)})"
  end

  # Control flow
  defp do_format({:if, condition, then_branch, else_branch}) do
    "(if #{do_format(condition)} #{do_format(then_branch)} #{do_format(else_branch)})"
  end

  defp do_format({:do, exprs}) do
    "(do #{format_list(exprs)})"
  end

  defp do_format({:and, exprs}) do
    "(and #{format_list(exprs)})"
  end

  defp do_format({:or, exprs}) do
    "(or #{format_list(exprs)})"
  end

  # Control signals
  defp do_format({:return, value}) do
    "(return #{do_format(value)})"
  end

  defp do_format({:fail, value}) do
    "(fail #{do_format(value)})"
  end

  # Recur
  defp do_format({:recur, args}) do
    "(recur #{format_list(args)})"
  end

  # Turn history
  defp do_format({:turn_history, n}) when n in 1..3, do: "*#{n}"

  # Parallel operations
  defp do_format({:pmap, fn_expr, coll_exprs}) do
    "(pmap #{do_format(fn_expr)} #{format_list(coll_exprs)})"
  end

  defp do_format({:pcalls, fn_exprs}) do
    "(pcalls #{format_list(fn_exprs)})"
  end

  # Juxt
  defp do_format({:juxt, fns}) do
    "(juxt #{format_list(fns)})"
  end

  # --- Closure serialization ---

  @doc """
  Serialize a closure tuple to PTC-Lisp source string.

  Rejects closures that reference captured lexical state. Named closures retain
  their self binding, and attached-prelude exports serialize as their public
  reference so hydration restores isolation and contracts. Docstrings are
  rejected because a function expression has no source position for them;
  `export_namespace/1` preserves them on the surrounding `def`. Unreferenced
  diagnostic environment, history, and metadata fields are not emitted.

  ## Examples

      iex> closure = {:closure, [{:var, "x"}], {:call, {:var, :+}, [{:var, "x"}, 1]}, %{}, [], %{}}
      iex> PtcRunner.Lisp.CoreToSource.serialize_closure(closure)
      {:ok, "(fn [x] (+ x 1))"}
  """
  @spec serialize_closure(term()) :: {:ok, String.t()} | {:error, export_error()}
  def serialize_closure({:closure, _params, _body, _env, _history, _meta} = closure) do
    path = [{:binding, "__closure__"}]

    with :ok <- reject_expression_only_metadata(closure, path),
         {:ok, source_ast} <- closure_source_ast(closure, path),
         :ok <- find_source_name(closure, path),
         :ok <- find_java_value(source_ast, path),
         do: safe_format(source_ast, path)
  end

  def serialize_closure(value),
    do: {:error, {:non_exportable_source_value, [{:binding, "__closure__"}], value}}

  @doc """
  Serialize all closures in a memory namespace to source strings.

  Returns a map of `{name => source_string}` for each closure value in memory.
  Non-closure values are skipped.

  ## Examples

      iex> memory = %{"f" => {:closure, [{:var, "x"}], {:var, "x"}, %{}, [], %{}}, "count" => 5}
      iex> PtcRunner.Lisp.CoreToSource.serialize_namespace(memory)
      {:ok, %{"f" => "(fn [x] x)"}}
  """
  @spec serialize_namespace(map()) :: {:ok, map()} | {:error, export_error()}
  def serialize_namespace(%{__struct__: module}),
    do: {:error, {:non_exportable_namespace, module}}

  def serialize_namespace(memory) when is_map(memory) and not is_struct(memory) do
    closures =
      Enum.filter(memory, fn {key, value} ->
        not internal_key?(key) and match?({:closure, _, _, _, _, _}, value)
      end)

    with :ok <- validate_exportable_memory(closures),
         :ok <- validate_expression_only_metadata(closures) do
      closures
      |> Enum.reduce_while({:ok, %{}}, fn
        {key, {:closure, _params, _body, _env, _history, _metadata} = closure},
        {:ok, serialized} ->
          path = [{:binding, source_name(key)}]

          with {:ok, source_ast} <- closure_source_ast(closure, path),
               {:ok, source} <- safe_format(source_ast, path) do
            {:cont, {:ok, Map.put(serialized, key, source)}}
          else
            {:error, _reason} = error -> {:halt, error}
          end
      end)
    end
  end

  @doc """
  Export an entire memory namespace as PTC-Lisp source.

  Serializes all entries — closures become `(def name (fn [...] ...))`,
  non-closure values become `(def name value)`. Multiple top-level forms
  are emitted without a `do` wrapper (the parser handles them natively).

  ## Examples

      iex> memory = %{"x" => 5, "f" => {:closure, [{:var, "n"}], {:call, {:var, :+}, [{:var, "n"}, 1]}, %{}, [], %{}}}
      iex> {:ok, source} = PtcRunner.Lisp.CoreToSource.export_namespace(memory)
      iex> source =~ "def x"
      true
      iex> source =~ "def f"
      true
  """
  @type export_error ::
          {:non_exportable_java_value, list(), atom()}
          | {:non_exportable_source_name, list(), atom(), term()}
          | {:non_exportable_source_value, list(), term()}
          | {:non_exportable_source_collision, list(), :identifier | :map | :set}
          | {:non_exportable_binding_collision, String.t()}
          | {:non_exportable_closure_capture, list(), [String.t()]}
          | {:non_exportable_dependency_cycle, [String.t()]}
          | {:non_exportable_closure_metadata, list(), [atom()]}
          | {:non_exportable_namespace, module()}

  @spec export_namespace(map()) :: {:ok, String.t()} | {:error, export_error()}
  def export_namespace(%{__struct__: module}), do: {:error, {:non_exportable_namespace, module}}

  def export_namespace(memory) when is_map(memory) and not is_struct(memory) do
    with :ok <- validate_exportable_memory(memory) do
      entries =
        memory
        |> Enum.reject(fn {k, _v} -> internal_key?(k) end)
        |> Enum.to_list()

      with {:ok, sorted_entries} <- topo_sort_entries(entries) do
        render_entries(sorted_entries)
      end
    end
  end

  defp render_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, rendered} ->
      path = [{:binding, source_name(key)}]

      case render_entry(key, value, path) do
        {:ok, source} -> {:cont, {:ok, [source | rendered]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, rendered |> Enum.reverse() |> Enum.join("\n")}
      {:error, _reason} = error -> error
    end
  end

  defp render_entry(
         key,
         {:closure, _params, _body, _env, _history, metadata} = closure,
         path
       ) do
    with {:ok, source_ast} <- closure_source_ast(closure, path),
         {:ok, source} <- safe_format(source_ast, path),
         {:ok, docstring} <- closure_docstring_source(metadata, path) do
      case docstring do
        nil -> {:ok, "(def #{key} #{source})"}
        docstring -> {:ok, "(def #{key} #{docstring} #{source})"}
      end
    end
  end

  defp render_entry(key, value, path) do
    with {:ok, source} <- safe_format(value, path),
         do: {:ok, "(def #{key} #{source})"}
  end

  defp closure_source_ast(
         {:closure, params, body, _env, _history, metadata},
         path
       )
       when is_map(metadata) do
    semantic_metadata = Enum.filter(@prelude_semantic_metadata, &Map.has_key?(metadata, &1))

    result =
      cond do
        Map.has_key?(metadata, :prelude_ref) ->
          {:ok, {:prelude_ref, Map.fetch!(metadata, :prelude_ref)}}

        semantic_metadata != [] ->
          {:error, {:non_exportable_closure_metadata, path, Enum.sort(semantic_metadata)}}

        Map.has_key?(metadata, :fn_name) ->
          {:ok, {:fn, Map.fetch!(metadata, :fn_name), params, body}}

        true ->
          {:ok, {:fn, params, body}}
      end

    case result do
      {:ok, source_ast} -> {:ok, encode_internal_temporaries(source_ast)}
      {:error, _reason} = error -> error
    end
  end

  defp closure_source_ast(closure, path),
    do: {:error, {:non_exportable_source_value, path, closure}}

  defp validate_expression_only_metadata(entries) do
    Enum.reduce_while(entries, :ok, fn
      {key, {:closure, _params, _body, _env, _history, _metadata} = closure}, :ok ->
        case reject_expression_only_metadata(closure, [{:binding, source_name(key)}]) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  defp reject_expression_only_metadata(
         {:closure, _params, _body, _env, _history, metadata},
         path
       )
       when is_map(metadata) do
    if Map.has_key?(metadata, :docstring),
      do: {:error, {:non_exportable_closure_metadata, path, [:docstring]}},
      else: :ok
  end

  defp reject_expression_only_metadata(closure, path),
    do: {:error, {:non_exportable_source_value, path, closure}}

  defp closure_docstring_source(metadata, path) when is_map(metadata) do
    case Map.fetch(metadata, :docstring) do
      :error ->
        {:ok, nil}

      {:ok, docstring} when is_binary(docstring) ->
        safe_format({:string, docstring}, path ++ [:docstring])

      {:ok, _invalid} ->
        {:error, {:non_exportable_closure_metadata, path, [:docstring]}}
    end
  end

  defp definition_metadata_source!(metadata) when map_size(metadata) == 0, do: ""

  defp definition_metadata_source!(%{docstring: docstring} = metadata)
       when map_size(metadata) == 1 and is_binary(docstring),
       do: " " <> do_format({:string, docstring})

  defp definition_metadata_source!(_metadata),
    do: raise(ArgumentError, "definition metadata has no lossless source form")

  defp safe_format(value, path) do
    {:ok, do_format(value)}
  rescue
    _exception -> {:error, {:non_exportable_source_value, path, value}}
  end

  defp safe_format_map_key(value, path) do
    {:ok, format_map_key(value)}
  rescue
    _exception -> {:error, {:non_exportable_source_value, path, value}}
  end

  defp validate_exportable_memory(memory) do
    entries = Enum.reject(memory, fn {key, _value} -> internal_key?(key) end)

    with :ok <- validate_binding_keys(entries),
         :ok <- validate_unique_binding_names(entries),
         :ok <- validate_binding_identities(entries) do
      Enum.reduce_while(entries, :ok, fn {key, value}, :ok ->
        with {:ok, binding} <- validate_source_name(key, :binding, [{:binding, key}]),
             path = [{:binding, binding}],
             :ok <- find_exportable_source_value(value, path),
             :ok <- find_exportable_java_value(value, path) do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp find_exportable_source_value(
         {:closure, _params, _body, _env, _history, _metadata} = closure,
         path
       ),
       do: find_source_name(closure, path)

  defp find_exportable_source_value(value, path), do: find_runtime_source_value(value, path)

  defp find_exportable_java_value(
         {:closure, _params, _body, _env, _history, _metadata} = closure,
         path
       ) do
    with {:ok, source_ast} <- closure_source_ast(closure, path),
         do: find_java_value(source_ast, path)
  end

  defp find_exportable_java_value(value, path), do: find_java_value(value, path)

  defp find_runtime_source_value({:symbol_ref, _name} = symbol_ref, path),
    do: find_source_name(symbol_ref, path)

  defp find_runtime_source_value(value, path) when is_tuple(value),
    do: {:error, {:non_exportable_source_value, path, value}}

  defp find_runtime_source_value(value, path) when is_list(value),
    do: find_runtime_source_list(value, path)

  defp find_runtime_source_value(%MapSet{} = value, path) do
    with {:ok, values} <- map_set_items(value, path),
         :ok <- find_runtime_source_list(values, path),
         do: validate_unique_source_forms(values, path, :set)
  end

  defp find_runtime_source_value(value, path) when is_map(value) and not is_struct(value) do
    pairs = Enum.to_list(value)

    with :ok <-
           pairs
           |> Enum.with_index()
           |> Enum.reduce_while(:ok, fn {{key, item}, index}, :ok ->
             with :ok <- find_runtime_map_key(key, path ++ [{:map_key, index}]),
                  :ok <- find_runtime_source_value(item, path ++ [{:map_value, index}]) do
               {:cont, :ok}
             else
               {:error, _reason} = error -> {:halt, error}
             end
           end),
         do: validate_unique_source_forms(Enum.map(pairs, &elem(&1, 0)), path, :map)
  end

  defp find_runtime_source_value(value, _path)
       when value in [nil, true, false, :infinity, :negative_infinity, :nan],
       do: :ok

  defp find_runtime_source_value(value, path) when is_atom(value),
    do: validate_atom_keyword(value, path)

  defp find_runtime_source_value(value, path), do: find_source_name(value, path)

  defp find_runtime_map_key(key, _path) when is_binary(key), do: :ok

  defp find_runtime_map_key(key, _path)
       when key in [nil, true, false, :infinity, :negative_infinity, :nan],
       do: :ok

  defp find_runtime_map_key(key, path) when is_atom(key),
    do: validate_atom_keyword(key, path)

  defp find_runtime_map_key(key, path), do: find_runtime_source_value(key, path)

  defp find_runtime_source_list(values, path) do
    if proper_list?(values) do
      values
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
        case find_runtime_source_value(value, path ++ [{:index, index}]) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, {:non_exportable_source_value, path, values}}
    end
  end

  defp validate_binding_keys(entries) do
    Enum.reduce_while(entries, :ok, fn {key, _value}, :ok ->
      path = [{:binding, key}]

      case validate_source_name(key, :binding, path) do
        {:ok, _binding} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_binding_identities(entries) do
    Enum.reduce_while(entries, :ok, fn {key, _value}, :ok ->
      case validate_reader_identifier_identity(key, [{:binding, key}]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_unique_binding_names(entries) do
    Enum.reduce_while(entries, MapSet.new(), fn {key, _value}, names ->
      name = source_name(key)

      if MapSet.member?(names, name),
        do: {:halt, {:error, {:non_exportable_binding_collision, name}}},
        else: {:cont, MapSet.put(names, name)}
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp find_source_name({:symbol_ref, name}, path),
    do: validate_qualified_source_name(name, :symbol_ref, path)

  # Literal payloads are runtime values, not executable AST. Tuples have no
  # lossless literal source form here and must not be dispatched through the
  # Core-AST clauses below.
  defp find_source_name({:literal, value} = literal, path) when is_tuple(value),
    do: {:error, {:non_exportable_source_value, path, literal}}

  defp find_source_name({:literal, value}, path),
    do: find_runtime_source_value(value, path ++ [:literal])

  defp find_source_name({:symbol, name}, path),
    do: validate_qualified_source_name(name, :symbol, path)

  defp find_source_name({:quoted_symbol, name}, path),
    do: validate_qualified_source_name(name, :quoted_symbol, path)

  defp find_source_name({:ns_symbol, namespace, name}, path),
    do: validate_qualified_parts(namespace, name, :namespaced_symbol, path)

  defp find_source_name({:var, name}, path),
    do: validate_variable_name(name, path)

  defp find_source_name({:data, name}, path),
    do: validate_qualified_parts("data", name, :data, path)

  defp find_source_name({:runtime_callable, namespace, name}, path),
    do: validate_qualified_parts(namespace, name, :runtime_callable, path)

  defp find_source_name({:prelude_ref, ref}, path),
    do: validate_prelude_ref(ref, :prelude_ref, path)

  defp find_source_name({:prelude_call, ref, arguments}, path) when is_list(arguments) do
    with :ok <- validate_prelude_ref(ref, :prelude_call, path),
         do: find_source_list(arguments, path ++ [:prelude_arguments])
  end

  defp find_source_name({:turn_history, n}, _path) when n in 1..3, do: :ok

  defp find_source_name({:turn_history, n}, path),
    do: {:error, {:non_exportable_source_name, path, :turn_history, n}}

  defp find_source_name({:string, value}, _path) when is_binary(value), do: :ok

  defp find_source_name({:keyword, name}, path) when is_atom(name),
    do: validate_atom_keyword(name, path)

  defp find_source_name({:keyword, name} = keyword, path) when is_binary(name) do
    if SourceAtoms.intern(name) == name,
      do: validate_keyword_name(name, path),
      else: {:error, {:non_exportable_source_value, path, keyword}}
  end

  defp find_source_name({:keyword, name}, path),
    do: {:error, {:non_exportable_source_name, path, :keyword, name}}

  defp find_source_name({:set, values}, path) when is_list(values) do
    with :ok <- find_source_list(values, path ++ [{:index, 1}]),
         do: validate_unique_source_forms(values, path, :set)
  end

  defp find_source_name({tag, values}, path)
       when tag in [:vector, :do, :and, :or, :recur, :pcalls, :juxt] and is_list(values),
       do: find_source_list(values, path ++ [{:index, 1}])

  defp find_source_name({:map, pairs}, path) when is_list(pairs) do
    with :ok <- find_source_list(pairs, path ++ [{:index, 1}]),
         do: validate_unique_source_forms(Enum.map(pairs, &elem(&1, 0)), path, :map)
  end

  defp find_source_name({:call, target, arguments}, path) when is_list(arguments) do
    with :ok <- find_source_name(target, path ++ [{:index, 1}]),
         do: find_source_list(arguments, path ++ [{:index, 2}])
  end

  defp find_source_name({:if, condition, then_branch, else_branch}, path) do
    with :ok <- find_source_name(condition, path ++ [{:index, 1}]),
         :ok <- find_source_name(then_branch, path ++ [{:index, 2}]),
         do: find_source_name(else_branch, path ++ [{:index, 3}])
  end

  defp find_source_name({tag, value}, path) when tag in [:return, :fail],
    do: find_source_name(value, path ++ [{:index, 1}])

  defp find_source_name({:pmap, function, collections}, path) when is_list(collections) do
    with :ok <- find_source_name(function, path ++ [{:index, 1}]),
         do: find_source_list(collections, path ++ [{:index, 2}])
  end

  defp find_source_name({tag, _reference_id, arguments}, path)
       when tag in [:java_static, :java_new] and is_list(arguments),
       do: find_source_list(arguments, path ++ [{:index, 2}])

  defp find_source_name({tag, _reference_id}, _path)
       when tag in [:java_field, :java_ref],
       do: :ok

  defp find_source_name({:java_instance, _reference_id, receiver, arguments}, path)
       when is_list(arguments) do
    with :ok <- find_source_name(receiver, path ++ [{:index, 2}]),
         do: find_source_list(arguments, path ++ [{:index, 3}])
  end

  defp find_source_name({:java_dot, _member_family_id, receiver, arguments}, path)
       when is_list(arguments) do
    with :ok <- find_source_name(receiver, path ++ [{:index, 2}]),
         do: find_source_list(arguments, path ++ [{:index, 3}])
  end

  defp find_source_name({:tool_call, name, args}, path) do
    with :ok <- validate_qualified_parts("tool", name, :tool, path) do
      find_source_list(args, path ++ [{:tool_args, to_string(name)}])
    end
  end

  defp find_source_name({tag, name, value, _metadata}, path) when tag in [:def, :defonce] do
    with {:ok, binding} <- validate_source_name(name, :binding, path) do
      find_source_name(value, path ++ [{tag, binding}])
    end
  end

  defp find_source_name({:binding, pattern, value}, path) do
    with :ok <- find_pattern_source_name(pattern, path ++ [:pattern]),
         do: find_source_name(value, path ++ [:value])
  end

  defp find_source_name({:fn, params, body}, path) do
    with :ok <- validate_pattern_params(params, path ++ [:params]),
         do: find_source_name(body, path ++ [:body])
  end

  defp find_source_name({:fn, name, params, body}, path) do
    with {:ok, _binding} <- validate_source_name(name, :binding, path ++ [:name]),
         :ok <- validate_pattern_params(params, path ++ [:params]),
         do: find_source_name(body, path ++ [:body])
  end

  defp find_source_name({tag, bindings, body}, path)
       when tag in [:let, :loop] and is_list(bindings) do
    with :ok <- find_source_list(bindings, path ++ [:bindings]),
         do: find_source_name(body, path ++ [:body])
  end

  defp find_source_name({:destructure, _shape} = pattern, path),
    do: find_pattern_source_name(pattern, path)

  # A closure that references captured state cannot be reconstructed from
  # source. Named functions retain their self name. A public prelude export is
  # reconstructed from its public reference; other prelude-semantic metadata
  # has no lossless source form and is rejected.
  defp find_source_name(
         {:closure, params, body, _env, _history, _metadata} = closure,
         path
       ) do
    with {:ok, source_ast} <- closure_source_ast(closure, path) do
      find_closure_source_name(source_ast, closure, params, body, path)
    end
  end

  defp find_source_name(%LispKeyword{name: name} = keyword, path) do
    if LispKeyword.valid?(keyword) and SourceAtoms.intern(name) == name,
      do: validate_keyword_name(name, path),
      else: {:error, {:non_exportable_source_value, path, keyword}}
  end

  defp find_source_name(%SymbolRef{name: name} = symbol_ref, path) do
    if SymbolRef.valid?(symbol_ref),
      do: validate_qualified_source_name(name, :symbol_ref, path),
      else: {:error, {:non_exportable_source_value, path, symbol_ref}}
  end

  defp find_source_name(value, _path)
       when value in [nil, true, false, :infinity, :negative_infinity, :nan],
       do: :ok

  defp find_source_name(value, path) when is_atom(value),
    do: validate_atom_keyword(value, path)

  defp find_source_name(value, path) when is_list(value),
    do: find_source_list(value, path)

  defp find_source_name(%MapSet{} = value, path) do
    with {:ok, values} <- map_set_items(value, path),
         :ok <- find_source_list(values, path),
         do: validate_unique_source_forms(values, path, :set)
  end

  defp find_source_name(value, path) when is_tuple(value),
    do: value |> Tuple.to_list() |> find_source_list(path)

  defp find_source_name(value, path) when is_map(value) and not is_struct(value) do
    pairs = Enum.to_list(value)

    with :ok <-
           pairs
           |> Enum.with_index()
           |> Enum.reduce_while(:ok, fn {{key, item}, index}, :ok ->
             with :ok <- find_formatted_map_key(key, path ++ [{:map_key, index}]),
                  :ok <- find_source_name(item, path ++ [{:map_value, index}]) do
               {:cont, :ok}
             else
               {:error, _reason} = error -> {:halt, error}
             end
           end),
         do: validate_unique_source_forms(Enum.map(pairs, &elem(&1, 0)), path, :map)
  end

  defp find_source_name(_value, _path), do: :ok

  defp find_closure_source_name(source_ast, closure, params, body, path) do
    case validate_core_ast(source_ast, path) do
      :ok ->
        find_valid_closure_source_name(source_ast, closure, params, body, path)

      {:error, _reason} = structural_error ->
        preserve_closure_source_name_error(params, body, path, structural_error)
    end
  end

  defp find_valid_closure_source_name(
         {:prelude_ref, _ref} = source_ast,
         _closure,
         _params,
         _body,
         path
       ),
       do: find_source_name(source_ast, path)

  defp find_valid_closure_source_name(source_ast, closure, _params, _body, path) do
    {params, body} = serialized_closure_parts(source_ast)

    with :ok <- validate_identifier_source_collisions(source_ast, path),
         :ok <- validate_closure_capture(closure, path),
         :ok <- validate_pattern_params(params, path ++ [:closure_params]),
         do: find_source_name(body, path ++ [:closure_body])
  end

  defp serialized_closure_parts({:fn, params, body}), do: {params, body}
  defp serialized_closure_parts({:fn, _name, params, body}), do: {params, body}

  # Analyzer temporaries use a NUL-prefixed binary namespace that source cannot
  # author, so they cannot collide with user bindings and never allocate atoms.
  # Before exporting a closure, alpha-rename those variables to fresh legal
  # identifiers while avoiding every textual value already present in its AST.
  defp encode_internal_temporaries(source_ast) do
    {temporary_names, used_names} = collect_temporary_names(source_ast)

    {renames, _used_names, _next_index} =
      Enum.reduce(temporary_names, {%{}, used_names, 0}, fn name, {renames, used, index} ->
        {encoded, next_index} = next_serialized_temporary(used, index)
        {Map.put(renames, name, encoded), MapSet.put(used, encoded), next_index}
      end)

    rewrite_internal_temporaries(source_ast, renames)
  end

  defp collect_temporary_names(source_ast) do
    {names, _seen, used} = collect_temporary_names(source_ast, {[], MapSet.new(), MapSet.new()})
    {Enum.reverse(names), used}
  end

  defp collect_temporary_names({:var, name}, {names, seen, used})
       when is_binary(name) do
    if String.starts_with?(name, @internal_temporary_prefix) do
      if MapSet.member?(seen, name),
        do: {names, seen, used},
        else: {[name | names], MapSet.put(seen, name), used}
    else
      {names, seen, MapSet.put(used, name)}
    end
  end

  defp collect_temporary_names({:literal, _value}, accumulator), do: accumulator

  defp collect_temporary_names(value, {names, seen, used})
       when is_atom(value) or is_binary(value),
       do: {names, seen, MapSet.put(used, to_string(value))}

  defp collect_temporary_names(value, accumulator) when is_list(value),
    do: Enum.reduce(value, accumulator, &collect_temporary_names/2)

  defp collect_temporary_names(value, accumulator) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.reduce(accumulator, &collect_temporary_names/2)

  defp collect_temporary_names(_value, accumulator), do: accumulator

  defp next_serialized_temporary(used_names, index) do
    candidate = @serialized_temporary_prefix <> Integer.to_string(index)

    if MapSet.member?(used_names, candidate),
      do: next_serialized_temporary(used_names, index + 1),
      else: {candidate, index + 1}
  end

  defp rewrite_internal_temporaries({:var, name}, renames) when is_binary(name),
    do: {:var, Map.get(renames, name, name)}

  defp rewrite_internal_temporaries({:literal, _value} = literal, _renames), do: literal

  defp rewrite_internal_temporaries(value, renames) when is_list(value),
    do: Enum.map(value, &rewrite_internal_temporaries(&1, renames))

  defp rewrite_internal_temporaries(value, renames) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&rewrite_internal_temporaries(&1, renames))
    |> List.to_tuple()
  end

  defp rewrite_internal_temporaries(value, _renames), do: value

  defp preserve_closure_source_name_error(params, body, path, structural_error) do
    candidate =
      try do
        with :ok <- validate_pattern_params(params, path ++ [:closure_params]),
             do: find_source_name(body, path ++ [:closure_body])
      rescue
        _exception -> structural_error
      end

    case candidate do
      {:error, {:non_exportable_source_name, _path, _kind, _value}} = error -> error
      _other -> structural_error
    end
  end

  defp validate_core_ast(ast, path) do
    case CoreAST.validate(ast) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:non_exportable_source_value, path, ast}}
    end
  end

  defp find_pattern_source_name({:var, name}, path),
    do: validate_source_name_only(name, :binding, path)

  defp find_pattern_source_name({:destructure, {:keys, keys, defaults}}, path)
       when is_list(keys) and is_list(defaults) do
    with :ok <- validate_binding_names(keys, path ++ [:keys]),
         do: validate_pattern_defaults(defaults, path ++ [:defaults])
  end

  defp find_pattern_source_name({:destructure, {:map, keys, renames, defaults}}, path)
       when is_list(keys) and is_list(renames) and is_list(defaults) do
    with :ok <- validate_binding_names(keys, path ++ [:keys]),
         :ok <- validate_pattern_renames(renames, path ++ [:renames]),
         do: validate_pattern_defaults(defaults, path ++ [:defaults])
  end

  defp find_pattern_source_name({:destructure, {:as, name, inner}}, path) do
    with {:ok, _binding} <- validate_source_name(name, :binding, path ++ [:as]),
         do: find_pattern_source_name(inner, path ++ [:pattern])
  end

  defp find_pattern_source_name({:destructure, {:seq, patterns}}, path)
       when is_list(patterns),
       do: find_pattern_list(patterns, path ++ [:sequence])

  defp find_pattern_source_name({:destructure, {:seq_rest, leading, rest}}, path)
       when is_list(leading) do
    with :ok <- find_pattern_list(leading, path ++ [:leading]),
         do: find_pattern_source_name(rest, path ++ [:rest])
  end

  defp find_pattern_source_name(malformed, path),
    do: {:error, {:non_exportable_source_name, path, :pattern, malformed}}

  defp validate_pattern_params(params, path) when is_list(params),
    do: find_pattern_list(params, path)

  defp validate_pattern_params({:variadic, leading, rest}, path) when is_list(leading) do
    with :ok <- find_pattern_list(leading, path ++ [:leading]),
         do: find_pattern_source_name(rest, path ++ [:rest])
  end

  defp validate_pattern_params(malformed, path),
    do: {:error, {:non_exportable_source_name, path, :params, malformed}}

  defp find_pattern_list(patterns, path) do
    patterns
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {pattern, index}, :ok ->
      case find_pattern_source_name(pattern, path ++ [{:index, index}]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_binding_names(names, path) do
    names
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {name, index}, :ok ->
      case validate_source_name(name, :binding, path ++ [{:index, index}]) do
        {:ok, _binding} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_pattern_defaults(defaults, path) do
    defaults
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {{name, value}, index}, :ok ->
        with {:ok, _binding} <-
               validate_source_name(name, :binding, path ++ [{:default, index}]),
             :ok <- find_source_name(value, path ++ [{:default_value, index}]) do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      {_malformed, index}, :ok ->
        {:halt, {:error, {:non_exportable_source_name, path, :default, index}}}
    end)
  end

  defp validate_pattern_renames(renames, path) do
    renames
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {{local, source_key}, index}, :ok ->
        with :ok <- find_pattern_source_name(local, path ++ [{:local, index}]),
             :ok <- validate_pattern_source_key(source_key, path ++ [{:source_key, index}]) do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      {_malformed, index}, :ok ->
        {:halt, {:error, {:non_exportable_source_name, path, :rename, index}}}
    end)
  end

  # Binary source keys are emitted as escaped string literals. Atom-backed
  # source keys are emitted as keywords and therefore need keyword validation.
  defp validate_pattern_source_key(key, _path) when is_binary(key), do: :ok

  defp validate_pattern_source_key(key, path) when is_atom(key),
    do: validate_atom_keyword(key, path)

  defp validate_pattern_source_key(key, path), do: validate_keyword_name(key, path)

  defp find_formatted_map_key(key, _path) when is_binary(key), do: :ok

  defp find_formatted_map_key(key, _path)
       when key in [nil, true, false, :infinity, :negative_infinity, :nan],
       do: :ok

  defp find_formatted_map_key(key, path) when is_atom(key),
    do: validate_atom_keyword(key, path)

  defp find_formatted_map_key(%LispKeyword{} = key, path), do: find_source_name(key, path)
  defp find_formatted_map_key(key, path), do: find_source_name(key, path)

  defp find_source_list(values, path) when is_list(values) do
    if proper_list?(values) do
      values
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
        case find_source_name(value, path ++ [{:index, index}]) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, {:non_exportable_source_value, path, values}}
    end
  end

  defp find_source_list(value, path),
    do: {:error, {:non_exportable_source_value, path, value}}

  defp validate_source_name(name, kind, path) when is_atom(name) or is_binary(name) do
    source = to_string(name)

    if SymbolRef.valid_name?(source) and (source == "/" or not String.contains?(source, "/")) and
         (kind != :binding or
            (reader_binding_name?(source) and Patterns.validate_binding_name(name) == :ok)) do
      {:ok, source}
    else
      {:error, {:non_exportable_source_name, path, kind, source}}
    end
  end

  defp validate_source_name(name, kind, path),
    do: {:error, {:non_exportable_source_name, path, kind, name}}

  defp reader_binding_name?(source) do
    reader_symbol_name?(source)
  end

  defp reader_symbol_name?(source) do
    case FastParser.parse(source) do
      {:ok, {:symbol, parsed}} -> to_string(parsed) == source
      _other -> false
    end
  end

  defp validate_variable_name(name, path) when is_atom(name) or is_binary(name) do
    source = to_string(name)

    if SymbolRef.valid_name?(source) and reader_variable_name?(source),
      do: :ok,
      else: {:error, {:non_exportable_source_name, path, :var, source}}
  end

  defp validate_variable_name(name, path),
    do: {:error, {:non_exportable_source_name, path, :var, name}}

  defp reader_variable_name?(source) do
    with {:ok, raw_ast} <- FastParser.parse(source),
         {:ok, {:var, parsed}} <- Analyze.analyze(raw_ast) do
      to_string(parsed) == source
    else
      _other -> false
    end
  end

  defp validate_source_name_only(name, kind, path) do
    case validate_source_name(name, kind, path) do
      {:ok, _source} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_identifier_source_collisions(ast, path) do
    case collect_identifier_source_names(ast, %{}, MapSet.new(), path) do
      {:ok, _seen} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp collect_identifier_source_names({:var, name}, seen, scope, path) do
    with :ok <- validate_free_identifier_identity(name, scope, path),
         do: put_identifier_source_name(name, seen, path)
  end

  # Literal payloads are runtime values, not executable Core AST. Their source
  # representation is validated later by find_source_name/2.
  defp collect_identifier_source_names({:literal, _value}, seen, _scope, _path),
    do: {:ok, seen}

  defp collect_identifier_source_names({:fn, params, body}, seen, scope, path) do
    with {:ok, seen, inner_scope} <-
           bind_identifier_params(params, seen, scope, path ++ [:params]),
         do: collect_identifier_source_names(body, seen, inner_scope, path ++ [:body])
  end

  defp collect_identifier_source_names({:fn, name, params, body}, seen, scope, path) do
    with {:ok, seen, inner_scope} <-
           bind_identifier_name(name, seen, scope, path ++ [:name]),
         {:ok, seen, inner_scope} <-
           bind_identifier_params(params, seen, inner_scope, path ++ [:params]),
         do: collect_identifier_source_names(body, seen, inner_scope, path ++ [:body])
  end

  defp collect_identifier_source_names({tag, bindings, body}, seen, scope, path)
       when tag in [:let, :loop] do
    with {:ok, seen, inner_scope} <-
           collect_identifier_bindings(bindings, seen, scope, path ++ [:bindings]),
         do: collect_identifier_source_names(body, seen, inner_scope, path ++ [:body])
  end

  defp collect_identifier_source_names({tag, name, value, _metadata}, seen, scope, path)
       when tag in [:def, :defonce] do
    with :ok <- validate_reader_identifier_identity(name, path ++ [:name]),
         {:ok, seen} <- put_identifier_source_name(name, seen, path ++ [:name]),
         do: collect_identifier_source_names(value, seen, scope, path ++ [:value])
  end

  defp collect_identifier_source_names(values, seen, scope, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, seen}, fn {value, index}, {:ok, acc} ->
      case collect_identifier_source_names(value, acc, scope, path ++ [{:index, index}]) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp collect_identifier_source_names(value, seen, scope, path) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> collect_identifier_source_names(seen, scope, path)
  end

  defp collect_identifier_source_names(value, seen, scope, path)
       when is_map(value) and not is_struct(value) do
    value
    |> Map.values()
    |> collect_identifier_source_names(seen, scope, path)
  end

  defp collect_identifier_source_names(_value, seen, _scope, _path), do: {:ok, seen}

  defp collect_identifier_bindings(bindings, seen, scope, path) do
    bindings
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, seen, scope}, fn
      {{:binding, pattern, value}, index}, {:ok, acc, inner_scope} ->
        with {:ok, acc} <-
               collect_identifier_source_names(
                 value,
                 acc,
                 inner_scope,
                 path ++ [{:index, index}, :value]
               ),
             {:ok, acc, inner_scope} <-
               bind_identifier_pattern(
                 pattern,
                 acc,
                 inner_scope,
                 path ++ [{:index, index}, :pattern]
               ) do
          {:cont, {:ok, acc, inner_scope}}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      {_malformed, _index}, _acc ->
        {:halt, {:error, {:non_exportable_source_value, path, bindings}}}
    end)
  end

  defp bind_identifier_params(params, seen, scope, path) when is_list(params),
    do: bind_identifier_patterns(params, seen, scope, path)

  defp bind_identifier_params({:variadic, leading, rest}, seen, scope, path) do
    with {:ok, seen, scope} <-
           bind_identifier_patterns(leading, seen, scope, path ++ [:leading]),
         do: bind_identifier_pattern(rest, seen, scope, path ++ [:rest])
  end

  defp bind_identifier_pattern({:var, name}, seen, scope, path),
    do: bind_identifier_name(name, seen, scope, path)

  defp bind_identifier_pattern(
         {:destructure, {:keys, keys, defaults}},
         seen,
         scope,
         path
       ) do
    with :ok <- validate_reader_identifier_names(keys, path ++ [:keys]),
         {:ok, seen, scope} <-
           bind_bare_identifier_names(keys, seen, scope, path ++ [:keys]),
         {:ok, seen} <- record_default_identifier_names(defaults, seen, path ++ [:defaults]),
         do: {:ok, seen, scope}
  end

  defp bind_identifier_pattern(
         {:destructure, {:map, keys, renames, defaults}},
         seen,
         scope,
         path
       ) do
    with :ok <- validate_reader_identifier_names(keys, path ++ [:keys]),
         {:ok, seen, scope} <-
           bind_bare_identifier_names(keys, seen, scope, path ++ [:keys]),
         {:ok, seen, scope} <-
           bind_renamed_identifier_patterns(renames, seen, scope, path ++ [:renames]),
         {:ok, seen} <- record_default_identifier_names(defaults, seen, path ++ [:defaults]),
         do: {:ok, seen, scope}
  end

  defp bind_identifier_pattern(
         {:destructure, {:as, name, inner}},
         seen,
         scope,
         path
       ) do
    with {:ok, seen, scope} <- bind_identifier_name(name, seen, scope, path ++ [:as]),
         do: bind_identifier_pattern(inner, seen, scope, path ++ [:pattern])
  end

  defp bind_identifier_pattern({:destructure, {:seq, patterns}}, seen, scope, path),
    do: bind_identifier_patterns(patterns, seen, scope, path ++ [:sequence])

  defp bind_identifier_pattern(
         {:destructure, {:seq_rest, leading, rest}},
         seen,
         scope,
         path
       ) do
    with {:ok, seen, scope} <-
           bind_identifier_patterns(leading, seen, scope, path ++ [:leading]),
         do: bind_identifier_pattern(rest, seen, scope, path ++ [:rest])
  end

  defp bind_identifier_pattern(_pattern, seen, scope, _path), do: {:ok, seen, scope}

  defp bind_identifier_patterns(patterns, seen, scope, path) do
    patterns
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, seen, scope}, fn {pattern, index}, {:ok, acc, inner_scope} ->
      case bind_identifier_pattern(
             pattern,
             acc,
             inner_scope,
             path ++ [{:index, index}]
           ) do
        {:ok, acc, inner_scope} -> {:cont, {:ok, acc, inner_scope}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp bind_renamed_identifier_patterns(renames, seen, scope, path) do
    renames
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, seen, scope}, fn
      {{pattern, _source_key}, index}, {:ok, acc, inner_scope} ->
        case bind_identifier_pattern(
               pattern,
               acc,
               inner_scope,
               path ++ [{:index, index}]
             ) do
          {:ok, acc, inner_scope} -> {:cont, {:ok, acc, inner_scope}}
          {:error, _reason} = error -> {:halt, error}
        end

      {_malformed, _index}, _acc ->
        {:halt, {:error, {:non_exportable_source_value, path, renames}}}
    end)
  end

  defp bind_bare_identifier_names(names, seen, scope, path) do
    names
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, seen, scope}, fn {name, index}, {:ok, acc, inner_scope} ->
      case bind_identifier_name(name, acc, inner_scope, path ++ [{:index, index}]) do
        {:ok, acc, inner_scope} -> {:cont, {:ok, acc, inner_scope}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp record_default_identifier_names(defaults, seen, path) do
    defaults
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, seen}, fn {{name, _value}, index}, {:ok, acc} ->
      case put_identifier_source_name(name, acc, path ++ [{:default, index}]) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp bind_identifier_name(name, seen, scope, path) do
    with {:ok, seen} <- put_identifier_source_name(name, seen, path),
         do: {:ok, seen, MapSet.put(scope, to_string(name))}
  end

  defp validate_free_identifier_identity(name, scope, path) do
    if MapSet.member?(scope, to_string(name)),
      do: :ok,
      else: validate_reader_identifier_identity(name, path)
  end

  defp validate_reader_identifier_identity(name, path)
       when is_atom(name) or is_binary(name) do
    if SourceAtoms.intern(to_string(name)) == name,
      do: :ok,
      else: {:error, {:non_exportable_source_value, path, name}}
  end

  defp validate_reader_identifier_identity(name, path),
    do: {:error, {:non_exportable_source_value, path, name}}

  defp validate_reader_identifier_names(names, path) do
    names
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {name, index}, :ok ->
      case validate_reader_identifier_identity(name, path ++ [{:index, index}]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp put_identifier_source_name(name, seen, path)
       when is_atom(name) or is_binary(name) do
    source = to_string(name)

    case Map.fetch(seen, source) do
      :error ->
        {:ok, Map.put(seen, source, name)}

      {:ok, existing} when existing === name ->
        {:ok, seen}

      {:ok, _existing} ->
        {:error, {:non_exportable_source_collision, path, :identifier}}
    end
  end

  defp put_identifier_source_name(_name, seen, _path), do: {:ok, seen}

  defp validate_qualified_source_name(name, kind, path) when is_atom(name) or is_binary(name) do
    source = to_string(name)

    if SymbolRef.valid_name?(source),
      do: :ok,
      else: {:error, {:non_exportable_source_name, path, kind, source}}
  end

  defp validate_qualified_source_name(name, kind, path),
    do: {:error, {:non_exportable_source_name, path, kind, name}}

  defp validate_prelude_ref(ref, kind, path) do
    if CoreAST.valid_prelude_ref?(ref),
      do: :ok,
      else: {:error, {:non_exportable_source_name, path, kind, ref}}
  end

  defp validate_qualified_parts(namespace, name, kind, path)
       when (is_atom(namespace) or is_binary(namespace)) and (is_atom(name) or is_binary(name)) do
    namespace = to_string(namespace)
    name = to_string(name)

    case FastParser.parse(namespace <> "/" <> name) do
      {:ok, {:ns_symbol, parsed_namespace, parsed_name}} ->
        if to_string(parsed_namespace) == namespace and to_string(parsed_name) == name,
          do: :ok,
          else: {:error, {:non_exportable_source_name, path, kind, name}}

      _other ->
        {:error, {:non_exportable_source_name, path, kind, name}}
    end
  end

  defp validate_qualified_parts(_namespace, name, kind, path),
    do: {:error, {:non_exportable_source_name, path, kind, name}}

  defp validate_keyword_name(name, path) when is_atom(name) or is_binary(name) do
    source = to_string(name)

    if LispKeyword.valid_name?(source),
      do: :ok,
      else: {:error, {:non_exportable_source_name, path, :keyword, source}}
  end

  defp validate_keyword_name(name, path),
    do: {:error, {:non_exportable_source_name, path, :keyword, name}}

  defp validate_atom_keyword(keyword, path) do
    if SourceAtoms.intern(Atom.to_string(keyword)) == keyword,
      do: validate_keyword_name(keyword, path),
      else: {:error, {:non_exportable_source_value, path, keyword}}
  end

  defp find_java_value(%{__struct__: JavaCallable} = callable, path),
    do: {:error, {:non_exportable_java_value, path, Map.get(callable, :reference_id)}}

  defp find_java_value(%{__struct__: JavaPrimitive} = primitive, path),
    do: {:error, {:non_exportable_java_value, path, Map.get(primitive, :kind)}}

  defp find_java_value(%{__struct__: JavaLocalDate}, path),
    do: {:error, {:non_exportable_java_value, path, :local_date}}

  defp find_java_value(%{__struct__: JavaInstant}, path),
    do: {:error, {:non_exportable_java_value, path, :instant}}

  defp find_java_value(%{__struct__: JavaDuration}, path),
    do: {:error, {:non_exportable_java_value, path, :duration}}

  defp find_java_value(%{__struct__: JavaDate}, path),
    do: {:error, {:non_exportable_java_value, path, :date}}

  defp find_java_value(value, path) when is_list(value), do: find_java_list(value, path)

  defp find_java_value(value, path) when is_tuple(value) do
    value |> Tuple.to_list() |> find_java_list(path)
  end

  defp find_java_value(%MapSet{} = value, path) do
    with {:ok, values} <- map_set_items(value, path),
         do: find_java_list(values, path)
  end

  defp find_java_value(value, path) when is_struct(value) do
    value
    |> Map.from_struct()
    |> Enum.reduce_while(:ok, fn {field, item}, :ok ->
      case find_java_value(item, path ++ [{:struct_field, field}]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp find_java_value(value, path) when is_map(value) and not is_struct(value) do
    value
    |> Enum.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{key, item}, index}, :ok ->
      with :ok <- find_java_value(key, path ++ [{:map_key, index}]),
           :ok <- find_java_value(item, path ++ [{:map_value, index}]) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp find_java_value(_value, _path), do: :ok

  defp map_set_items(%MapSet{map: map} = value, path) when is_map(map) do
    values = Map.keys(map)

    if map_size(value) == 2 and MapSet.new(values) == value,
      do: {:ok, values},
      else: {:error, {:non_exportable_source_value, path, value}}
  end

  defp map_set_items(value, path),
    do: {:error, {:non_exportable_source_value, path, value}}

  defp validate_unique_source_forms(values, path, collection) do
    Enum.reduce_while(values, {:ok, MapSet.new()}, fn value, {:ok, seen} ->
      formatter = if collection == :map, do: &safe_format_map_key/2, else: &safe_format/2

      case formatter.(value, path) do
        {:ok, source} ->
          if MapSet.member?(seen, source),
            do: {:halt, {:error, {:non_exportable_source_collision, path, collection}}},
            else: {:cont, {:ok, MapSet.put(seen, source)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp find_java_list(values, path) do
    if proper_list?(values) do
      values
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
        case find_java_value(value, path ++ [{:index, index}]) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, {:non_exportable_source_value, path, values}}
    end
  end

  defp validate_closure_capture({:closure, params, body, env, _history, metadata}, path)
       when is_map(env) and is_map(metadata) do
    referenced = ClosureCapture.referenced_vars(body, params)

    captured =
      env
      |> Map.keys()
      |> Enum.flat_map(fn
        name when is_atom(name) or is_binary(name) -> [to_string(name)]
        _other -> []
      end)
      |> MapSet.new()
      |> MapSet.intersection(referenced)
      |> Enum.sort()

    if captured == [],
      do: validate_captured_locals(metadata, path),
      else: {:error, {:non_exportable_closure_capture, path, captured}}
  end

  defp validate_closure_capture(closure, path),
    do: {:error, {:non_exportable_source_value, path, closure}}

  defp validate_captured_locals(%{captured_locals: %MapSet{} = captured_locals}, path) do
    case map_set_items(captured_locals, path) do
      {:ok, []} -> :ok
      _other -> {:error, {:non_exportable_closure_metadata, path, [:captured_locals]}}
    end
  end

  defp validate_captured_locals(metadata, path) do
    if Map.has_key?(metadata, :captured_locals),
      do: {:error, {:non_exportable_closure_metadata, path, [:captured_locals]}},
      else: :ok
  end

  # Topological sort: non-closures first, then closures ordered by dependencies.
  defp topo_sort_entries(entries) do
    {non_closures, closures} =
      Enum.split_with(entries, fn {_k, v} -> !match?({:closure, _, _, _, _, _}, v) end)

    ns_keys = MapSet.new(Enum.map(entries, fn {k, _} -> source_name(k) end))

    # Build dependency graph: closure -> set of namespace keys it references
    deps =
      Map.new(closures, fn {k, {:closure, _params, _body, _env, _h, _m} = closure} ->
        refs =
          closure
          |> closure_dependency_ast()
          |> PtcRunner.Lisp.undefined_vars(MapSet.new())
          |> MapSet.new()

        {k, refs |> MapSet.intersection(ns_keys) |> MapSet.delete(source_name(k))}
      end)

    visited = MapSet.new(non_closures, fn {key, _value} -> source_name(key) end)

    with {:ok, sorted_closures} <- topo_sort(closures, deps, [], visited) do
      {:ok, non_closures ++ sorted_closures}
    end
  end

  defp closure_dependency_ast(closure) do
    case closure_source_ast(closure, [{:binding, "__dependency__"}]) do
      {:ok, source_ast} -> source_ast
      {:error, _reason} -> nil
    end
  end

  defp topo_sort([], _deps, acc, _visited), do: {:ok, Enum.reverse(acc)}

  defp topo_sort(remaining, deps, acc, visited) do
    # Find entries with no unvisited dependencies
    {ready, blocked} =
      Enum.split_with(remaining, fn {k, _v} ->
        Map.get(deps, k, MapSet.new()) |> MapSet.subset?(visited)
      end)

    case ready do
      [] ->
        cycle =
          remaining
          |> Enum.map(fn {key, _value} -> source_name(key) end)
          |> Enum.sort()

        {:error, {:non_exportable_dependency_cycle, cycle}}

      _ ->
        new_visited =
          Enum.reduce(ready, visited, fn {k, _}, vs -> MapSet.put(vs, source_name(k)) end)

        topo_sort(blocked, deps, Enum.reverse(ready) ++ acc, new_visited)
    end
  end

  defp source_name(name) when is_atom(name), do: Atom.to_string(name)
  defp source_name(name) when is_binary(name), do: name

  defp java_reference_source(reference_id) do
    case JavaSurface.fetch_reference(reference_id) do
      {:ok, %{kind: :instance, class_id: class_id, member: member}} ->
        {:ok, class} = JavaSurface.fetch_class(class_id)
        "#{class.name}/#{member}"

      {:ok, %{spellings: [source | _]}} ->
        source

      _ ->
        raise ArgumentError, "unknown Java reference #{inspect(reference_id)}"
    end
  end

  defp internal_key?(key) when is_atom(key) do
    name = Atom.to_string(key)
    String.starts_with?(name, "__ptc_")
  end

  defp internal_key?(key) when is_binary(key) do
    String.starts_with?(key, "__ptc_")
  end

  defp internal_key?(_), do: false

  # --- Helpers ---

  defp format_list(elems) do
    Enum.map_join(elems, " ", &format/1)
  end

  defp format_params(params) when is_list(params) do
    Enum.map_join(params, " ", &format_pattern/1)
  end

  defp format_params({:variadic, leading, rest_pattern}) do
    leading_str = Enum.map_join(leading, " ", &format_pattern/1)

    if leading_str == "" do
      "& #{format_pattern(rest_pattern)}"
    else
      "#{leading_str} & #{format_pattern(rest_pattern)}"
    end
  end

  defp format_pattern({:var, name}), do: to_string(name)

  defp format_pattern({:destructure, {:keys, keys, defaults}}) do
    format_map_pattern(keys, [], defaults, nil)
  end

  defp format_pattern({:destructure, {:map, keys, renames, defaults}}) do
    format_map_pattern(keys, renames, defaults, nil)
  end

  defp format_pattern({:destructure, {:as, name, {:destructure, {:keys, keys, defaults}}}}) do
    format_map_pattern(keys, [], defaults, name)
  end

  defp format_pattern(
         {:destructure, {:as, name, {:destructure, {:map, keys, renames, defaults}}}}
       ) do
    format_map_pattern(keys, renames, defaults, name)
  end

  defp format_pattern({:destructure, {:as, _name, _inner}}) do
    raise ArgumentError, "invalid :as destructuring target"
  end

  defp format_pattern({:destructure, {:seq, patterns}}) do
    "[#{Enum.map_join(patterns, " ", &format_pattern/1)}]"
  end

  defp format_pattern({:destructure, {:seq_rest, leading, rest}}) do
    leading_str = Enum.map_join(leading, " ", &format_pattern/1)
    "[#{leading_str} & #{format_pattern(rest)}]"
  end

  defp format_map_pattern(keys, renames, defaults, as_name) do
    keys_str =
      case keys do
        [] -> ""
        _ -> ":keys [#{Enum.map_join(keys, " ", &to_string/1)}]"
      end

    renames_str =
      Enum.map_join(renames, " ", fn
        {local, key} when is_binary(key) ->
          "#{format_pattern(local)} \"#{escape_string(key)}\""

        {local, key} ->
          "#{format_pattern(local)} :#{key}"
      end)

    defaults_str =
      case defaults do
        [] ->
          ""

        _ ->
          entries = Enum.map_join(defaults, " ", fn {k, v} -> "#{k} #{do_format(v)}" end)
          ":or {#{entries}}"
      end

    as_str = if is_nil(as_name), do: "", else: ":as #{as_name}"

    inner =
      [keys_str, renames_str, defaults_str, as_str]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    "{#{inner}}"
  end

  # Runtime map keys: strings stay as strings, literal-valued atoms keep their
  # literal spelling, and ordinary atoms become keywords.
  defp format_map_key(k) when is_binary(k), do: ~s("#{escape_string(k)}")

  defp format_map_key(k)
       when k in [nil, true, false, :infinity, :negative_infinity, :nan],
       do: do_format(k)

  defp format_map_key(k) when is_atom(k), do: ":#{k}"
  defp format_map_key(%LispKeyword{name: name}), do: ":#{name}"
  defp format_map_key(k), do: do_format(k)

  defp escape_string(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
    |> String.replace("\r", "\\r")
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false
end
