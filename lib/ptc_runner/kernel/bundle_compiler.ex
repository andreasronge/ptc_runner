defmodule PtcRunner.Kernel.BundleCompiler do
  @moduledoc """
  Internal implementation of `PtcRunner.Kernel.compile_bundle/1`.

  It bounds the closed component set, resolves its component-ID dependency DAG
  deterministically, compiles the combined prelude in a bounded worker, limits
  diagnostics and artifact size, and seals the resulting bundle.
  """

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CompileDiagnostic
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.ErrorSpan
  alias PtcRunner.Lisp.Prelude.ValidationError

  @max_components 128
  @max_edges 512
  @max_source_bytes 2_000_000
  @compile_timeout_ms 5_000
  @compile_heap_words 8_000_000
  @span_timeout_ms 1_000
  @span_heap_words 2_000_000
  @max_span_locator_bytes 4_096
  @max_artifact_bytes 4_000_000
  @max_diagnostic_bytes 65_536
  @public_compile_reasons [:parse_error, :unbound_var, :duplicate_ref, :unknown_namespace]

  @spec compile([Component.t()]) :: {:ok, FrozenBundle.t()} | {:error, map()}
  @doc "Compiles and attests a bounded closed component set."
  def compile(components) when is_list(components) do
    with :ok <- bounded_components(components) do
      compile_bounded(components, System.monotonic_time(:millisecond) + @compile_timeout_ms)
    end
  end

  def compile(_components), do: {:error, %{reason: :invalid_components}}

  @doc false
  @spec compile_named(map(), integer(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, {map(), [Component.t()]}}
  def compile_named(missions, deadline_ms, initial_bytes, max_bytes)
      when is_map(missions) and is_integer(deadline_ms) and is_integer(initial_bytes) and
             initial_bytes >= 0 and is_integer(max_bytes) and max_bytes > 0 do
    Enum.reduce_while(
      missions |> Enum.sort_by(&elem(&1, 0)),
      {:ok, %{}, initial_bytes},
      fn {name, %{components: components}}, {:ok, bundles, bytes} ->
        result = if components == [], do: {:ok, nil}, else: compile(components, deadline_ms)

        case result do
          {:ok, bundle} ->
            next_bytes = bytes + if(is_nil(bundle), do: 0, else: :erlang.external_size(bundle))

            if next_bytes <= max_bytes,
              do: {:cont, {:ok, Map.put(bundles, name, bundle), next_bytes}},
              else: {:halt, {:error, {%{reason: :bundle_limit_exceeded}, components}}}

          {:error, failure} ->
            {:halt, {:error, {failure, components}}}
        end
      end
    )
    |> case do
      {:ok, bundles, _bytes} -> {:ok, bundles}
      {:error, {_failure, _components}} = error -> error
    end
  end

  @doc false
  def compile(components, deadline_ms) when is_list(components) and is_integer(deadline_ms) do
    with :ok <- bounded_components(components) do
      compile_bounded(
        components,
        min(deadline_ms, System.monotonic_time(:millisecond) + @compile_timeout_ms)
      )
    end
  end

  defp compile_bounded(components, deadline_ms) do
    timeout_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    if timeout_ms == 0 do
      {:error, %{reason: :bundle_compile_timeout}}
    else
      case BoundedWorker.run(
             fn ->
               components
               |> compile_unconfined()
               |> enforce_result(@max_artifact_bytes, @max_diagnostic_bytes)
             end,
             timeout_ms: timeout_ms,
             max_heap_words: @compile_heap_words
           ) do
        {:ok, result} -> finalize_failure_span(result, components, deadline_ms)
        {:error, :timeout} -> {:error, %{reason: :bundle_compile_timeout}}
        {:error, :heap_exceeded} -> {:error, %{reason: :bundle_compile_heap_exceeded}}
        {:error, :worker_failed} -> {:error, %{reason: :bundle_compile_failed}}
      end
    end
  end

  defp compile_unconfined(components) do
    with {:ok, components} <- validate_components(components),
         {:ok, by_id} <- unique_ids(components),
         :ok <- dependencies_exist(by_id),
         {:ok, ordered} <- topological_order(by_id),
         {:ok, compiled} <- describe_ordered(ordered),
         {:ok, prelude} <- compile_prelude(ordered, compiled),
         {:ok, hash} <- FrozenBundle.identity(compiled) do
      bundle = %FrozenBundle{
        components: compiled,
        component_ids: Enum.map(compiled, & &1.id),
        hash: hash,
        prelude: prelude
      }

      {:ok, FrozenBundle.seal(bundle)}
    end
  end

  @doc false
  @spec enforce_result({:ok, term()} | {:error, term()}, pos_integer(), pos_integer()) ::
          {:ok, term()} | {:error, map()}
  def enforce_result({:ok, bundle}, max_artifact_bytes, _max_diagnostic_bytes) do
    if :erlang.external_size(bundle) <= max_artifact_bytes,
      do: {:ok, bundle},
      else: {:error, %{reason: :bundle_artifact_exceeded}}
  end

  def enforce_result({:error, diagnostic} = error, _max_artifact_bytes, max_diagnostic_bytes) do
    if :erlang.external_size(diagnostic) <= max_diagnostic_bytes,
      do: error,
      else: {:error, %{reason: :bundle_diagnostic_exceeded}}
  end

  defp bounded_components(components) do
    bounded_components(components, 0, 0, 0)
  end

  defp bounded_components([], _count, _source_bytes, _edges), do: :ok

  defp bounded_components(_components, count, _source_bytes, _edges)
       when count >= @max_components,
       do: {:error, %{reason: :bundle_limit_exceeded}}

  defp bounded_components(
         [%Component{source: source, dependencies: dependencies} | rest],
         count,
         source_bytes,
         edges
       )
       when is_binary(source) and is_list(dependencies) do
    next_source_bytes = source_bytes + byte_size(source)

    with true <- next_source_bytes <= @max_source_bytes,
         {:ok, next_edges} <- bounded_edge_count(dependencies, edges) do
      bounded_components(rest, count + 1, next_source_bytes, next_edges)
    else
      false -> {:error, %{reason: :bundle_limit_exceeded}}
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  defp bounded_components(_components, _count, _source_bytes, _edges),
    do: {:error, %{reason: :invalid_components}}

  defp bounded_edge_count([], edges), do: {:ok, edges}

  defp bounded_edge_count(_dependencies, edges) when edges >= @max_edges,
    do: {:error, :bundle_limit_exceeded}

  defp bounded_edge_count([_dependency | rest], edges),
    do: bounded_edge_count(rest, edges + 1)

  defp bounded_edge_count(_improper, _edges), do: {:error, :invalid_components}

  defp validate_components(components) do
    Enum.reduce_while(components, {:ok, []}, fn component, {:ok, validated} ->
      case validate_component(component) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | validated]}}
        {:error, _reason} -> {:halt, {:error, %{reason: :invalid_components}}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp validate_component(%Component{} = component) do
    Component.new(
      id: component.id,
      source: component.source,
      dependencies: component.dependencies,
      origin: component.origin
    )
  end

  defp validate_component(_component), do: {:error, :invalid_component}

  defp unique_ids(components) do
    Enum.reduce_while(components, {:ok, %{}}, fn %Component{id: id} = component, {:ok, by_id} ->
      if Map.has_key?(by_id, id),
        do: {:halt, {:error, %{reason: :duplicate_component_id, id: id}}},
        else: {:cont, {:ok, Map.put(by_id, id, component)}}
    end)
  end

  defp dependencies_exist(by_id) do
    case Enum.find(Map.values(by_id), fn component ->
           Enum.any?(component.dependencies, &(not Map.has_key?(by_id, &1)))
         end) do
      nil -> :ok
      component -> {:error, %{reason: :missing_component_dependency, id: component.id}}
    end
  end

  defp topological_order(by_id) do
    do_topological_order(by_id, %{}, [])
  end

  defp do_topological_order(by_id, resolved, ordered) do
    if map_size(by_id) == map_size(resolved) do
      {:ok, Enum.reverse(ordered)}
    else
      ready =
        by_id
        |> Map.values()
        |> Enum.reject(&Map.has_key?(resolved, &1.id))
        |> Enum.filter(fn component ->
          Enum.all?(component.dependencies, &Map.has_key?(resolved, &1))
        end)
        |> Enum.sort_by(& &1.id)

      case ready do
        [] ->
          {:error, %{reason: :component_cycle}}

        [component | _] ->
          do_topological_order(by_id, Map.put(resolved, component.id, true), [component | ordered])
      end
    end
  end

  defp describe_ordered(components) do
    Enum.reduce_while(components, {:ok, []}, fn component, {:ok, compiled} ->
      with {:ok, namespaces} <- component_namespaces(component.source),
           dependencies = dependency_components(compiled, component.dependencies),
           namespace_deps =
             Map.new(namespaces, &{&1, dependency_namespaces(dependencies)}),
           {:ok, prelude} <-
             Compiler.compile_unlocated(component.source,
               deps: Enum.map(dependencies, & &1.prelude),
               namespace_deps: namespace_deps
             ) do
        entry = %{
          id: component.id,
          dependencies: component.dependencies,
          origin: component.origin,
          source_hash: source_hash(component.source),
          namespaces: namespaces,
          prelude: prelude
        }

        {:cont, {:ok, [entry | compiled]}}
      else
        {:error, error} ->
          {:halt,
           {:error,
            %{
              reason: :component_compile_error,
              id: component.id,
              compile_reason: compile_reason(error),
              compile_details: compile_details(error),
              details: error_message(error),
              span_locator: span_locator(error)
            }}}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  defp dependency_components(compiled, dependency_ids) do
    compiled
    |> Enum.filter(&(&1.id in dependency_ids))
    |> Enum.sort_by(& &1.id)
  end

  defp dependency_namespaces(components) do
    components
    |> Enum.flat_map(& &1.namespaces)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp compile_prelude(components, compiled) do
    namespace_deps = namespace_dependencies(compiled)
    source = Enum.map_join(components, "\n", & &1.source)

    Compiler.compile_unlocated(source, namespace_deps: namespace_deps)
    |> case do
      {:ok, prelude} ->
        metadata =
          Enum.map(compiled, fn component ->
            Map.take(component, [:id, :origin, :source_hash, :namespaces])
          end)

        {:ok, %{prelude | metadata: Map.put(prelude.metadata, :components, metadata)}}

      {:error, error} ->
        {:error,
         %{
           reason: :bundle_compile_error,
           compile_reason: compile_reason(error),
           details: error_message(error)
         }}
    end
  end

  defp namespace_dependencies(components) do
    by_id = Map.new(components, &{&1.id, &1})

    components
    |> Enum.flat_map(fn component ->
      dependency_namespaces =
        component.dependencies
        |> Enum.flat_map(&Map.fetch!(by_id, &1).namespaces)
        |> Enum.uniq()
        |> Enum.sort()

      Enum.map(component.namespaces, &{&1, dependency_namespaces})
    end)
    |> Map.new()
  end

  defp component_namespaces(source) do
    case Parser.parse_with_position(source) do
      {:ok, ast} ->
        namespaces = ast |> top_level_forms() |> Enum.flat_map(&namespace_form/1) |> Enum.uniq()

        if namespaces == [],
          do: {:error, "component declares no namespace"},
          else: {:ok, namespaces}

      {:error, {:parse_error, message, position}} ->
        {:error, ValidationError.new(:parse_error, message, span: parse_position_span(position))}
    end
  end

  defp parse_position_span(position) when is_integer(position) and position >= 0,
    do: {position, 0}

  defp parse_position_span(_position), do: nil

  defp top_level_forms({:program, forms}), do: forms
  defp top_level_forms(form), do: [form]

  defp namespace_form({:list, [{:symbol, name}, {:symbol, namespace} | _metadata]})
       when name in [:ns, "ns"],
       do: [to_string(namespace)]

  defp namespace_form(_form), do: []

  defp source_hash(source),
    do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  defp error_message(%{message: message}) when is_binary(message),
    do: String.slice(message, 0, 4_096)

  defp error_message(error), do: inspect(error, limit: 10, printable_limit: 4_096)

  # Only reasons with fixed, catalog-owned public projections cross the bundle
  # boundary. Every other compiler reason deliberately retains the generic
  # compile-failure classification.
  defp compile_reason(%ValidationError{reason: reason}) when reason in @public_compile_reasons,
    do: reason

  defp compile_reason(%{reason: reason}) when reason in @public_compile_reasons, do: reason
  defp compile_reason(_error), do: nil

  defp compile_details(%ValidationError{reason: reason, details: details}) do
    case CompileDiagnostic.bounded_details(reason, details) do
      {:ok, bounded} -> bounded
      :error -> nil
    end
  end

  defp compile_details(_error), do: nil

  # The locator crosses the diagnostic-size gate before being consumed. Strip
  # the source-derived message and bound the remaining namespace/ref strings so
  # this private payload cannot displace the primary compile classification.
  # A form index is sufficient on its own; otherwise an oversized locator is
  # dropped and the public failure keeps its null span.
  defp span_locator(%ValidationError{} = error) do
    locator = %{error | message: "", details: nil}

    cond do
      :erlang.external_size(locator) <= @max_span_locator_bytes ->
        locator

      is_integer(error.form_index) ->
        %{locator | namespace: nil, ref: nil}

      true ->
        nil
    end
  end

  defp span_locator(_error), do: nil

  # Span attribution is optional diagnostic work, so it runs only after the
  # bounded compilation result is final. A costly scan can therefore lose its
  # span, but it cannot turn a compile error into a timeout or heap failure.
  defp finalize_failure_span(
         {:error, %{reason: :component_compile_error, id: id, span_locator: locator} = failure},
         components,
         deadline_ms
       ) do
    source =
      case Enum.find(components, &match?(%Component{id: ^id}, &1)) do
        %Component{source: source} when is_binary(source) -> source
        _missing -> nil
      end

    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    span = resolve_failure_span(locator, source, min(@span_timeout_ms, remaining_ms))

    {:error,
     failure
     |> Map.delete(:span_locator)
     |> Map.put(:span, span)}
  end

  defp finalize_failure_span(result, _components, _deadline_ms), do: result

  defp resolve_failure_span(%ValidationError{}, _source, 0), do: nil

  defp resolve_failure_span(%ValidationError{} = error, source, timeout_ms)
       when is_binary(source) and timeout_ms > 0 do
    case BoundedWorker.run(fn -> ErrorSpan.resolve(error, source) end,
           timeout_ms: timeout_ms,
           max_heap_words: @span_heap_words
         ) do
      {:ok, resolved} -> failure_span(resolved, source)
      {:error, _reason} -> nil
    end
  end

  defp resolve_failure_span(_error, _source, _timeout_ms), do: nil

  # The byte range of the top-level form the compiler blamed, in the exclusive
  # end-offset form command diagnostics carry. Bounded against the component's
  # own source so a diagnostic can never claim a range the source cannot hold;
  # anything unlocatable stays `nil`, exactly as before.
  defp failure_span(%ValidationError{span: {offset, length}}, source)
       when is_binary(source) and offset >= 0 and length >= 0 and
              offset + length <= byte_size(source),
       do: %{start_byte: offset, end_byte: offset + length}

  defp failure_span(_error, _source), do: nil
end
