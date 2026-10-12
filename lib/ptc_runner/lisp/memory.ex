defmodule PtcRunner.Lisp.Memory do
  @moduledoc false
  alias PtcRunner.Lisp.{ExternalizedCollision, Format, RuntimeCallable, SourceAtoms}

  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Effects
  alias PtcRunner.Lisp.Program

  alias PtcRunner.Lisp.Env.Builtin, as: EnvBuiltin
  alias PtcRunner.Lisp.Format.Var
  alias PtcRunner.Lisp.Java.Project, as: JavaProject
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Result, as: Step

  alias PtcRunner.Lisp.ErrorFormat
  alias PtcRunner.Lisp.Signature

  @projection_error_public_field_fallbacks [
    signature: nil,
    usage: nil,
    turns: nil,
    trace_id: nil,
    parent_trace_id: nil,
    name: nil,
    field_descriptions: nil,
    failure_origin: nil,
    return_origin: nil,
    prints: [],
    tool_calls: [],
    pmap_calls: [],
    child_traces: [],
    child_steps: [],
    messages: nil,
    prompt: nil,
    original_prompt: nil,
    tools: nil,
    prelude_trace: nil,
    prelude_calls: nil,
    prelude_call_counts: %{}
  ]

  def project_boundary_value(value, boundary) when boundary in [:public, :kernel_json] do
    with {:ok, projected_java} <- JavaProject.project(value, boundary),
         projected = externalize_lisp_values(projected_java, boundary),
         :ok <- validate_externalized_symbol_refs(projected),
         :ok <- validate_projection_collisions(projected, boundary) do
      {:ok, projected}
    end
  end

  def project_native_result({tag, %Step{} = step}) when tag in [:ok, :error] do
    case externalize_memory(step.memory) do
      memory when is_map(memory) ->
        public_result({tag, %{step | memory: memory}})

      {:error, {:java_projection_error, reason}} ->
        {:error, java_projection_error_step(%{step | memory: %{}}, reason)}

      {:error, {:symbol_ref_projection_error, reason}} ->
        {:error, symbol_projection_error_step(%{step | memory: %{}}, reason)}

      {:error, {:lisp_value_projection_error, reason}} ->
        {:error, symbol_projection_error_step(%{step | memory: %{}}, reason)}
    end
  end

  def externalize_memory(memory) when is_map(memory) do
    case JavaProject.project(memory, :public) do
      {:ok, projected} ->
        with externalized <-
               projected
               |> Enum.reject(fn {_k, v} -> match?(%PtcRunner.Lisp.RuntimeCallable{}, v) end)
               |> externalize_memory_entries(),
             :ok <- validate_externalized_symbol_refs(externalized) do
          externalized
        else
          {:error, {:invalid_keyword, _path} = reason} ->
            {:error, {:lisp_value_projection_error, reason}}

          {:error, reason} ->
            {:error, {:symbol_ref_projection_error, reason}}
        end

      {:error, reason} ->
        {:error, {:java_projection_error, reason}}
    end
  end

  def public_result({tag, %Step{} = step}) when tag in [:ok, :error] do
    case project_public_step(step) do
      {:ok, projected} ->
        public_step = externalize_public_step(projected)

        case validate_externalized_symbol_refs(public_step) do
          :ok -> {tag, public_step}
          {:error, reason} -> {:error, symbol_projection_error_step(public_step, reason)}
        end

      {:error, reason} ->
        {:error, java_projection_error_step(step, reason)}
    end
  end

  defp project_public_step(%Step{} = step) do
    step
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.reduce_while({:ok, step}, fn field, {:ok, projected_step} ->
      boundary = if field == :memory, do: :continuation, else: :public

      case JavaProject.project(Map.fetch!(projected_step, field), boundary) do
        {:ok, value} -> {:cont, {:ok, Map.put(projected_step, field, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp externalize_public_step(%Step{} = step) do
    step
    |> Map.from_struct()
    |> Enum.reduce(step, fn
      {:memory, _memory}, projected_step ->
        projected_step

      {field, value}, projected_step ->
        Map.put(projected_step, field, externalize_lisp_values(value))
    end)
  end

  def java_projection_error_step(%Step{} = step, reason) do
    details = %{projection_error: inspect(reason, limit: 10)}

    projection_error_step(
      step,
      :java_projection_error,
      "Java value could not be projected at the public boundary",
      details
    )
  end

  def symbol_projection_error_step(%Step{} = step, reason) do
    projection_error_step(
      step,
      elem(reason, 0),
      ErrorFormat.format_error(reason),
      ErrorFormat.error_details(reason)
    )
  end

  defp projection_error_step(%Step{} = step, reason, message, details) do
    safe_step =
      Enum.reduce(
        @projection_error_public_field_fallbacks,
        %{
          step
          | return: nil,
            fail: %{reason: reason, message: message, details: details},
            memory: safely_project_error_field(step.memory, :continuation, %{})
        },
        fn {field, fallback}, projected_step ->
          Map.put(
            projected_step,
            field,
            safely_project_error_field(Map.fetch!(step, field), :public, fallback)
          )
        end
      )

    case validate_externalized_symbol_refs(safe_step) do
      :ok -> safe_step
      {:error, _projection_reason} -> Step.error(reason, message, %{}, details)
    end
  end

  def validate_externalized_symbol_refs(value) do
    case Format.internalize_symbol_refs(value) do
      {:ok, _validated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp safely_project_error_field(value, boundary, fallback) do
    with {:ok, projected} <- JavaProject.project(value, boundary),
         externalized = maybe_externalize_error_field(projected, boundary),
         :ok <- validate_externalized_symbol_refs(externalized) do
      externalized
    else
      {:error, _reason} -> fallback
    end
  end

  defp maybe_externalize_error_field(value, :public), do: externalize_lisp_values(value)
  defp maybe_externalize_error_field(value, :continuation), do: value

  def apply_memory_contract(value, precision, %EvalContext{} = ctx, preserve_runtime_callables) do
    effects = Effects.chronological(ctx.effects)
    reversed_tool_calls = effects.tool_calls
    reversed_pmap_calls = effects.pmap_calls

    # Extract child_trace_ids from both direct tool calls and pmap/pcalls
    tool_child_traces =
      reversed_tool_calls
      |> Enum.filter(&Map.has_key?(&1, :child_trace_id))
      |> Enum.map(& &1.child_trace_id)

    pmap_child_traces =
      reversed_pmap_calls
      |> Enum.flat_map(& &1.child_trace_ids)

    child_traces = tool_child_traces ++ pmap_child_traces

    # Extract child_steps from tool calls and pmap/pcalls
    tool_child_steps =
      reversed_tool_calls
      |> Enum.filter(&Map.has_key?(&1, :child_step))
      |> Enum.map(& &1.child_step)

    pmap_child_steps =
      reversed_pmap_calls
      |> Enum.flat_map(&Map.get(&1, :child_steps, []))

    child_steps = tool_child_steps ++ pmap_child_steps

    # Strip child_step/child_steps from tool/pmap_calls to avoid double storage
    cleaned_tool_calls = Enum.map(reversed_tool_calls, &Map.delete(&1, :child_step))
    cleaned_pmap_calls = Enum.map(reversed_pmap_calls, &Map.delete(&1, :child_steps))

    %Step{
      return: round_floats(value, precision),
      fail: nil,
      memory: native_memory(ctx.user_ns, preserve_runtime_callables),
      signature: nil,
      usage: nil,
      turns: nil,
      failure_origin: ctx.failure_origin,
      return_origin: ctx.return_origin,
      prints: effects.prints,
      tool_calls: cleaned_tool_calls,
      pmap_calls: cleaned_pmap_calls,
      prelude_call_counts: effects.prelude_call_counts,
      child_traces: child_traces,
      child_steps: child_steps
    }
  end

  defp native_memory(memory, preserve_runtime_callables) when is_map(memory) do
    memory
    |> Enum.reject(fn {_k, v} ->
      not preserve_runtime_callables and match?(%RuntimeCallable{}, v)
    end)
    |> Map.new(fn {k, v} -> {k, native_memory_value(v, preserve_runtime_callables)} end)
  end

  defp native_memory_value(%RuntimeCallable{} = callable, true), do: callable

  defp native_memory_value(%RuntimeCallable{} = callable, false),
    do: RuntimeCallable.label(callable)

  defp native_memory_value(value, preserve_runtime_callables) when is_list(value) do
    Enum.map(value, &native_memory_value(&1, preserve_runtime_callables))
  end

  defp native_memory_value(value, preserve_runtime_callables)
       when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} ->
      {native_memory_value(k, preserve_runtime_callables),
       native_memory_value(v, preserve_runtime_callables)}
    end)
  end

  defp native_memory_value({:__ptc_return__, inner}, preserve_runtime_callables),
    do: {:__ptc_return__, native_memory_value(inner, preserve_runtime_callables)}

  defp native_memory_value({:__ptc_fail__, inner}, preserve_runtime_callables),
    do: {:__ptc_fail__, native_memory_value(inner, preserve_runtime_callables)}

  defp native_memory_value({:juxt_fn, fns}, _preserve_runtime_callables) when is_list(fns) do
    {:juxt_fn, Enum.map(fns, &native_memory_value(&1, true))}
  end

  defp native_memory_value({:partial_fn, f, fixed}, _preserve_runtime_callables)
       when is_list(fixed) do
    {:partial_fn, native_memory_value(f, true), Enum.map(fixed, &native_memory_value(&1, true))}
  end

  defp native_memory_value({:comp_fn, fns}, _preserve_runtime_callables) when is_list(fns) do
    {:comp_fn, Enum.map(fns, &native_memory_value(&1, true))}
  end

  defp native_memory_value({:complement_fn, f}, _preserve_runtime_callables) do
    {:complement_fn, native_memory_value(f, true)}
  end

  defp native_memory_value({:constantly_fn, value}, _preserve_runtime_callables) do
    {:constantly_fn, native_memory_value(value, true)}
  end

  defp native_memory_value({:every_pred_fn, preds}, _preserve_runtime_callables)
       when is_list(preds) do
    {:every_pred_fn, Enum.map(preds, &native_memory_value(&1, true))}
  end

  defp native_memory_value({:some_fn, fns}, _preserve_runtime_callables) when is_list(fns) do
    {:some_fn, Enum.map(fns, &native_memory_value(&1, true))}
  end

  defp native_memory_value({:fnil_fn, f, default}, _preserve_runtime_callables) do
    {:fnil_fn, native_memory_value(f, true), native_memory_value(default, true)}
  end

  defp native_memory_value(
         {:closure, _params, _body, _env, _turn_history, _metadata} = closure,
         _preserve_runtime_callables
       ),
       do: closure

  defp native_memory_value(%MapSet{} = set, preserve_runtime_callables) do
    set
    |> Enum.map(&native_memory_value(&1, preserve_runtime_callables))
    |> MapSet.new()
  end

  defp native_memory_value(value, _preserve_runtime_callables), do: value

  # Round floats recursively in nested structures
  defp round_floats(value, nil), do: value

  defp round_floats(value, precision) when is_float(value) do
    Float.round(value, precision)
  end

  defp round_floats(value, precision) when is_list(value) do
    Enum.map(value, &round_floats(&1, precision))
  end

  defp round_floats(value, precision) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {k, round_floats(v, precision)} end)
  end

  # Handle sentinel tuples for return/fail signals
  defp round_floats({:__ptc_return__, inner}, precision) do
    {:__ptc_return__, round_floats(inner, precision)}
  end

  defp round_floats({:__ptc_fail__, inner}, precision) do
    {:__ptc_fail__, round_floats(inner, precision)}
  end

  defp round_floats(value, _precision), do: value

  # Collapse runtime keyword structs deterministically: `SourceAtoms.intern/1`
  # yields the bounded atom for vocabulary names and the plain binary for
  # everything else. This never consults the global atom table, so the
  # externalized representation no longer depends on VM state (#964), and it
  # matches the parser's canonicalization and the string-keyed component
  # signature boundary.
  def externalize_lisp_values(value, boundary \\ :public)

  def externalize_lisp_values(%Program{} = program, boundary) do
    externalize_lisp_values(
      %{program?: true, byte_size: program.byte_size, digest: program.digest},
      boundary
    )
  end

  def externalize_lisp_values(%Step{memory: memory} = step, _boundary) when is_map(memory),
    do: project_native_result({:ok, step}) |> elem(1)

  def externalize_lisp_values(%Step{} = step, _boundary),
    do: public_result({:ok, %{step | memory: externalize_lisp_values(step.memory)}}) |> elem(1)

  def externalize_lisp_values(%{__struct__: LispKeyword} = keyword, :kernel_json) do
    if LispKeyword.valid?(keyword), do: keyword.name, else: keyword
  end

  def externalize_lisp_values(%{__struct__: LispKeyword} = keyword, :public) do
    if LispKeyword.valid?(keyword), do: SourceAtoms.intern(keyword.name), else: keyword
  end

  def externalize_lisp_values(
        {:closure, _params, _body, _env, _turn_history, _metadata},
        _boundary
      ),
      do: %Format.Fn{params: "..."}

  def externalize_lisp_values(%EnvBuiltin{}, _boundary), do: %Format.Builtin{}

  def externalize_lisp_values(%RuntimeCallable{} = callable, _boundary) do
    RuntimeCallable.label(callable)
  end

  def externalize_lisp_values(value, _boundary) when is_function(value),
    do: %Format.Fn{params: "..."}

  def externalize_lisp_values(%Var{name: name} = var, _boundary) when is_binary(name) do
    %{var | name: SourceAtoms.intern(name)}
  end

  def externalize_lisp_values({:var, name}, _boundary) when is_binary(name),
    do: %Var{name: SourceAtoms.intern(name)}

  def externalize_lisp_values({:var, name}, _boundary) when is_atom(name),
    do: %Var{name: name}

  def externalize_lisp_values({:symbol_ref, name}, _boundary) when is_binary(name),
    do: %Format.SymbolRef{name: name}

  def externalize_lisp_values({:__ptc_return__, inner}, boundary) do
    {:__ptc_return__, externalize_lisp_values(inner, boundary)}
  end

  def externalize_lisp_values({:__ptc_fail__, inner}, boundary) do
    {:__ptc_fail__, externalize_lisp_values(inner, boundary)}
  end

  def externalize_lisp_values({:normal, function}, _boundary) when is_function(function),
    do: %Format.Builtin{}

  # Context-dispatched builtins (`println`, `apply`, the introspection forms).
  # Without this the raw binding tuple escapes as the step's return value.
  def externalize_lisp_values({:special, name}, _boundary) when is_atom(name),
    do: %Format.Builtin{}

  def externalize_lisp_values({:variadic, function, _identity}, _boundary)
      when is_function(function),
      do: %Format.Builtin{}

  def externalize_lisp_values({:variadic_nonempty, name, function}, _boundary)
      when is_atom(name) and is_function(function),
      do: %Format.Builtin{}

  def externalize_lisp_values({:multi_arity, name, functions}, _boundary)
      when is_atom(name) and is_tuple(functions),
      do: %Format.Builtin{}

  def externalize_lisp_values({:collect, function}, _boundary) when is_function(function),
    do: %Format.Fn{params: "..."}

  def externalize_lisp_values({:juxt_fn, _fns}, _boundary), do: %Format.Fn{params: "..."}

  def externalize_lisp_values({:partial_fn, _f, _fixed}, _boundary),
    do: %Format.Fn{params: "..."}

  def externalize_lisp_values({:comp_fn, _fns}, _boundary), do: %Format.Fn{params: "..."}

  def externalize_lisp_values({:complement_fn, _f}, _boundary),
    do: %Format.Fn{params: "..."}

  def externalize_lisp_values({:constantly_fn, _value}, _boundary),
    do: %Format.Fn{params: "..."}

  def externalize_lisp_values({:every_pred_fn, _preds}, _boundary),
    do: %Format.Fn{params: "..."}

  def externalize_lisp_values({:some_fn, _fns}, _boundary), do: %Format.Fn{params: "..."}

  def externalize_lisp_values({:fnil_fn, _f, _default}, _boundary),
    do: %Format.Fn{params: "..."}

  def externalize_lisp_values(value, boundary) when is_list(value) do
    Enum.map(value, &externalize_lisp_values(&1, boundary))
  end

  def externalize_lisp_values(%MapSet{} = set, boundary) do
    items = Enum.map(set, &externalize_lisp_values(&1, boundary))
    frequencies = Enum.frequencies(items)
    next_ordinal = next_collision_ordinal(items, :set)

    items
    |> Enum.map_reduce(next_ordinal, fn item, ordinal ->
      if Map.fetch!(frequencies, item) > 1 do
        {%ExternalizedCollision{collection: :set, value: item, ordinal: ordinal}, ordinal + 1}
      else
        {item, ordinal}
      end
    end)
    |> elem(0)
    |> MapSet.new()
  end

  def externalize_lisp_values(value, boundary) when is_map(value) and not is_struct(value) do
    pairs =
      Enum.map(value, fn {key, item} ->
        externalized_key = externalize_lisp_values(key, boundary)
        display_key = if match?(%LispKeyword{}, key), do: key, else: externalized_key
        {externalized_key, display_key, externalize_lisp_values(item, boundary)}
      end)

    rebuild_externalized_map(pairs)
  end

  def externalize_lisp_values(value, boundary) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&externalize_lisp_values(&1, boundary))
    |> List.to_tuple()
  end

  def externalize_lisp_values(value, boundary) when is_struct(value) do
    fields =
      value
      |> Map.from_struct()
      |> Map.new(fn {field, item} -> {field, externalize_lisp_values(item, boundary)} end)

    struct(value.__struct__, fields)
  end

  def externalize_lisp_values(atom, :kernel_json) when is_atom(atom) do
    if LispKeyword.keyword?(atom), do: Atom.to_string(atom), else: atom
  end

  def externalize_lisp_values(value, _boundary), do: value

  defp next_collision_ordinal(values, collection) do
    values
    |> Enum.reduce(-1, fn
      %ExternalizedCollision{collection: ^collection, ordinal: ordinal}, highest
      when is_integer(ordinal) and ordinal >= 0 ->
        max(ordinal, highest)

      _value, highest ->
        highest
    end)
    |> Kernel.+(1)
  end

  defp validate_projection_collisions(_value, :public), do: :ok

  defp validate_projection_collisions(value, :kernel_json) do
    case projection_collision(value, []) do
      nil -> :ok
      {path, collection} -> {:error, {:public_projection_collision, path, collection}}
    end
  end

  defp projection_collision(%ExternalizedCollision{collection: collection}, path),
    do: {Enum.reverse(path), collection}

  defp projection_collision(value, path) when is_list(value) do
    find_projection_collision(value, path, :list)
  end

  defp projection_collision(value, path) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> find_projection_collision(path, :tuple)
  end

  defp projection_collision(%MapSet{} = set, path) do
    items = MapSet.to_list(set)

    if encoded_projection_collision?(items, &Jason.encode(&1, maps: :strict)) do
      {Enum.reverse(path), :set}
    else
      find_projection_collision(items, path, :set)
    end
  end

  defp projection_collision(value, path) when is_struct(value) do
    value
    |> Map.from_struct()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(nil, fn {field, item}, nil ->
      case projection_collision(item, [{:struct_field, field} | path]) do
        nil -> {:cont, nil}
        collision -> {:halt, collision}
      end
    end)
  end

  defp projection_collision(value, path) when is_map(value) and not is_struct(value) do
    entries = Map.to_list(value)

    if encoded_projection_collision?(entries, fn {key, _item} ->
         Jason.encode(%{key => nil}, maps: :strict)
       end) do
      {Enum.reverse(path), :map}
    else
      Enum.with_index(entries)
      |> Enum.reduce_while(nil, fn {{key, item}, index}, nil ->
        case projection_collision(key, [{:map_key, index} | path]) ||
               projection_collision(item, [{:map_value, index} | path]) do
          nil -> {:cont, nil}
          collision -> {:halt, collision}
        end
      end)
    end
  end

  defp projection_collision(_value, _path), do: nil

  defp find_projection_collision(values, path, collection) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(nil, fn {item, index}, nil ->
      case projection_collision(item, [{collection, index} | path]) do
        nil -> {:cont, nil}
        collision -> {:halt, collision}
      end
    end)
  end

  defp encoded_projection_collision?(values, encoder) do
    identities =
      Enum.flat_map(values, fn value ->
        case encoder.(value) do
          {:ok, encoded} -> [encoded]
          {:error, _reason} -> []
        end
      end)

    length(identities) != MapSet.size(MapSet.new(identities))
  end

  # Memory keys are `def`-bound variable names. The evaluator stores their
  # canonical binary spelling regardless of the parser's bounded internal atom
  # representation.
  defp externalize_memory_entries(entries) do
    pairs =
      Enum.map(entries, fn {key, item} ->
        externalized_key = externalize_memory_key(key)
        display_key = if match?(%LispKeyword{}, key), do: key, else: externalized_key
        {externalized_key, display_key, externalize_lisp_values(item)}
      end)

    rebuild_externalized_map(pairs)
  end

  defp rebuild_externalized_map(pairs) do
    frequencies = Enum.frequencies_by(pairs, &elem(&1, 0))
    next_ordinal = pairs |> Enum.map(&elem(&1, 0)) |> next_collision_ordinal(:map)

    pairs
    |> Enum.map_reduce(next_ordinal, fn {key, display_key, item}, ordinal ->
      if Map.fetch!(frequencies, key) > 1 do
        {{%ExternalizedCollision{
            collection: :map,
            value: display_key,
            ordinal: ordinal
          }, item}, ordinal + 1}
      else
        {{key, item}, ordinal}
      end
    end)
    |> elem(0)
    |> Map.new()
  end

  defp externalize_memory_key(%{__struct__: LispKeyword} = keyword),
    do: externalize_lisp_values(keyword)

  defp externalize_memory_key(name) when is_binary(name), do: name
  defp externalize_memory_key(other), do: externalize_lisp_values(other)

  # Validate return value against signature
  def validate_return_value(nil, _signature_str, step), do: {:ok, step}

  def validate_return_value(parsed_signature, signature_str, step) do
    case JavaProject.project(step.return, :public) do
      {:ok, projected_return} ->
        externalized_return = externalize_lisp_values(projected_return)

        case validate_externalized_symbol_refs(externalized_return) do
          :ok ->
            case Signature.validate(parsed_signature, externalized_return, max_errors: 16) do
              :ok ->
                # Store the original signature string in the step
                {:ok, %{step | signature: signature_str}}

              {:error, errors} ->
                msg = format_validation_errors(errors)

                {:error, Step.error(:validation_error, msg, step.memory, %{})}
            end

          {:error, reason} ->
            {:error, symbol_projection_error_step(step, reason)}
        end

      {:error, reason} ->
        {:error, java_projection_error_step(step, reason)}
    end
  end

  # Format validation errors into a readable message
  defp format_validation_errors(errors) do
    message =
      Enum.map_join(errors, "; ", fn %{path: path, message: message} ->
        path_str = format_path(path)
        "#{path_str}: #{message}"
      end)

    if length(errors) == 16 or byte_size(message) > 1_024 do
      PtcRunner.Utf8.truncate_valid(message, 1_000) <> "; diagnostics truncated"
    else
      message
    end
  end

  defp format_path([]), do: "return"
  defp format_path(path), do: "return." <> Enum.join(path, ".")
end
