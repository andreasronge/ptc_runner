defmodule PtcRunner.Lisp.Compile do
  @moduledoc false
  require Logger
  alias PtcRunner.Lisp.{Analyze, CoreAST, Env, Parser, Sandbox, SymbolCounter}

  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Prelude

  alias PtcRunner.Lisp.Result, as: Step
  alias PtcRunner.Lisp.Tool

  alias PtcRunner.Lisp.ErrorFormat

  def compile_program(source, opts) do
    %{
      memory: memory,
      normalized_tools: normalized_tools,
      max_symbols: max_symbols,
      compile_timeout: compile_timeout,
      compile_max_heap: compile_max_heap,
      check_tool_resolution: check_tool_resolution?
    } = opts

    prelude = Map.get(opts, :prelude)
    prelude_filtered_exports = Map.get(opts, :prelude_filtered_exports, [])

    # The compile sandbox closure must capture ONLY what parse/analyze need:
    # tool names, never tool closures or continuation memory (whose data can be
    # megabytes of granted environment). It returns the AST-bounded unresolved
    # variable candidates; the caller then performs direct map lookups for only
    # those names instead of enumerating the memory grant.
    tool_names = Map.keys(normalized_tools)

    public_tool_names =
      normalized_tools
      |> Enum.reject(fn {_name, tool} -> Tool.private?(tool) end)
      |> Enum.map(fn {name, _tool} -> name end)

    compile_fn = fn ->
      with {:ok, raw_ast} <- Parser.parse_with_position(source),
           :ok <- check_symbol_limit(raw_ast, max_symbols),
           {:ok, core_ast} <- Analyze.analyze(raw_ast, prelude, prelude_filtered_exports),
           :ok <- CoreAST.validate(core_ast) do
        undefined_vars = core_ast |> collect_undefined_vars(MapSet.new()) |> Enum.uniq()

        tool_check =
          if check_tool_resolution?,
            do: check_undefined_tools(core_ast, public_tool_names, tool_names, prelude),
            else: :ok

        prelude_calls = static_prelude_calls(core_ast, prelude)
        {:ok, core_ast, undefined_vars, tool_check, prelude_calls}
      end
    end

    compile_opts = [
      timeout: compile_timeout,
      max_heap: compile_max_heap,
      link: Map.get(opts, :link, false)
    ]

    case Sandbox.run_bounded(compile_fn, compile_opts) do
      {:ok, {:ok, core_ast, undefined_vars, tool_check, prelude_calls}} ->
        with :ok <- check_undefined_var_candidates(undefined_vars, memory),
             :ok <- tool_check do
          {:ok, core_ast, prelude_calls}
        else
          {:error, _} = compile_error ->
            handle_compile_error(compile_error, memory)
        end

      {:ok, {:error, _} = compile_error} ->
        handle_compile_error(compile_error, memory)

      {:error, {:timeout, ms}} ->
        Step.error(
          :compile_timeout,
          "compilation exceeded #{ms}ms limit",
          memory,
          %{}
        )
        |> then(&{:error, &1})

      {:error, {:memory_exceeded, bytes}} ->
        Step.error(
          :compile_memory_exceeded,
          "compilation exceeded #{bytes} byte heap limit",
          memory,
          %{}
        )
        |> then(&{:error, &1})

      {:error, {:execution_error, msg}} ->
        Step.error(:compile_error, "compilation failed: #{msg}", memory, %{})
        |> then(&{:error, &1})
    end
  end

  defp handle_compile_error({:error, {:parse_error, msg}}, memory) do
    {:error, Step.error(:parse_error, msg, memory, %{})}
  end

  defp handle_compile_error({:error, {:parse_error, msg, position}}, memory) do
    details = if is_integer(position) and position >= 0, do: %{source_offset: position}, else: %{}
    {:error, Step.error(:parse_error, msg, memory, details)}
  end

  # Compile-sandbox Steps are built with placeholder memory so the compile
  # closure doesn't capture the granted environment — restore it here.
  defp handle_compile_error({:error, %Step{} = step}, memory) do
    {:error, %{step | memory: memory}}
  end

  defp handle_compile_error({:error, {reason_atom, _, _} = reason}, memory)
       when is_atom(reason_atom) do
    {:error, Step.error(reason_atom, ErrorFormat.format_error(reason), memory, %{})}
  end

  defp handle_compile_error({:error, {reason_atom, _} = reason}, memory)
       when is_atom(reason_atom) do
    {:error, Step.error(reason_atom, ErrorFormat.format_error(reason), memory, %{})}
  end

  defp check_symbol_limit(ast, max_symbols) do
    count = SymbolCounter.count(ast)

    if count <= max_symbols do
      :ok
    else
      {:error,
       Step.error(
         :symbol_limit_exceeded,
         "program contains #{count} unique symbols/keywords, exceeds limit of #{max_symbols}",
         %{}
       )}
    end
  end

  # Pre-execution check: reject programs with undefined variables before any
  # side effects can execute. `undefined` comes from the symbol-bounded compile
  # worker. Checking only those candidate names avoids enumerating continuation
  # memory in the unbounded caller process.
  defp check_undefined_var_candidates(undefined, memory) do
    vars = Enum.reject(undefined, &memory_binding?(memory, &1))

    if vars == [] do
      :ok
    else
      label = if length(vars) == 1, do: "Undefined variable", else: "Undefined variables"
      message = "#{label}: #{Enum.join(vars, ", ")}#{Helpers.unresolved_name_suffix(vars)}"
      {:error, Step.error(:unbound_var, message, %{}, %{unbound_names: vars})}
    end
  end

  defp memory_binding?(memory, name) when is_binary(name) do
    Map.has_key?(memory, name)
  end

  # Pre-execution check: reject programs that reference tools not in the provided
  # toolset, preventing partial execution where early tool calls succeed before
  # a later unknown tool call crashes.
  # Takes tool NAMES (not the tools map) so the compile sandbox closure never
  # captures the tool closures and their granted environments. Direct user
  # references are checked against public names only; private names are admitted
  # only when they are reached through a prelude export's declared tool refs, and
  # runtime origin checks still enforce that same boundary at call time.
  defp check_undefined_tools(core_ast, public_tool_names, tool_names, prelude) do
    # CoreAST tool names are atoms, tool_names entries are strings — convert to strings
    direct =
      core_ast |> collect_tool_names() |> MapSet.new(fn name -> to_string(name) end)

    # A prelude export wraps tools in its captured body, invisible to the AST
    # walk above; union in the tools any referenced export will invoke so a
    # missing wrapped tool fails BEFORE an earlier tool can run (side-effect guard).
    prelude_refs = collect_prelude_tool_refs(core_ast, prelude)
    available = MapSet.new(tool_names)
    public_available = MapSet.new(public_tool_names)
    private_available = MapSet.difference(available, public_available)
    private_direct = MapSet.intersection(direct, private_available)
    referenced = MapSet.union(direct, prelude_refs)
    undefined = MapSet.difference(referenced, available)

    cond do
      MapSet.size(private_direct) > 0 ->
        names = private_direct |> MapSet.to_list() |> Enum.sort()
        label = if length(names) == 1, do: "Private tool", else: "Private tools"

        {:error,
         Step.error(
           :private_tool_unauthorized,
           "#{label} may only be called by authorized prelude exports: #{Enum.join(names, ", ")}",
           %{}
         )}

      MapSet.size(undefined) > 0 ->
        names = undefined |> MapSet.to_list() |> Enum.sort()
        label = if length(names) == 1, do: "Unknown tool", else: "Unknown tools"

        hint =
          case MapSet.to_list(public_available) |> Enum.sort() do
            [] -> "No tools available."
            tools -> "Available tools: #{Enum.join(tools, ", ")}"
          end

        {:error, Step.error(:unknown_tool, "#{label}: #{Enum.join(names, ", ")}. #{hint}", %{})}

      true ->
        :ok
    end
  end

  # Collect all tool names referenced in the CoreAST
  defp collect_tool_names(ast), do: collect_tool_names(ast, MapSet.new())

  defp collect_tool_names({:tool_call, name, args}, acc) do
    Enum.reduce(args, MapSet.put(acc, name), &collect_tool_names/2)
  end

  defp collect_tool_names({:runtime_callable, :tool, name}, acc), do: MapSet.put(acc, name)
  defp collect_tool_names({:runtime_callable, _namespace, _name}, acc), do: acc
  defp collect_tool_names({:symbol_ref, _name}, acc), do: acc

  # Prelude export call: the wrapped tool/call lives inside the captured prelude
  # closure body, not in the user AST; recurse into the call args only. The
  # body's own tools are surfaced separately via collect_prelude_tool_refs/2.
  defp collect_tool_names({:prelude_ref, _ref}, acc), do: acc

  defp collect_tool_names({:prelude_call, _ref, args}, acc),
    do: Enum.reduce(args, acc, &collect_tool_names/2)

  defp collect_tool_names({:do, exprs}, acc) do
    Enum.reduce(exprs, acc, &collect_tool_names/2)
  end

  defp collect_tool_names({:let, bindings, body}, acc) do
    acc =
      Enum.reduce(bindings, acc, fn {:binding, _pat, val}, a -> collect_tool_names(val, a) end)

    collect_tool_names(body, acc)
  end

  defp collect_tool_names({:fn, _params, body}, acc), do: collect_tool_names(body, acc)

  defp collect_tool_names({:loop, bindings, body}, acc) do
    acc =
      Enum.reduce(bindings, acc, fn {:binding, _pat, val}, a -> collect_tool_names(val, a) end)

    collect_tool_names(body, acc)
  end

  defp collect_tool_names({:call, target, args}, acc) do
    acc = collect_tool_names(target, acc)
    Enum.reduce(args, acc, &collect_tool_names/2)
  end

  defp collect_tool_names({tag, _reference_id, args}, acc)
       when tag in [:java_static, :java_new],
       do: Enum.reduce(args, acc, &collect_tool_names/2)

  defp collect_tool_names({tag, _reference_id, receiver, args}, acc)
       when tag in [:java_instance, :java_dot] do
    Enum.reduce(args, collect_tool_names(receiver, acc), &collect_tool_names/2)
  end

  defp collect_tool_names({tag, _reference_id}, acc) when tag in [:java_field, :java_ref], do: acc

  defp collect_tool_names({:if, c, t, e}, acc) do
    acc = collect_tool_names(c, acc)
    acc = collect_tool_names(t, acc)
    collect_tool_names(e, acc)
  end

  defp collect_tool_names({:and, exprs}, acc), do: Enum.reduce(exprs, acc, &collect_tool_names/2)
  defp collect_tool_names({:or, exprs}, acc), do: Enum.reduce(exprs, acc, &collect_tool_names/2)
  defp collect_tool_names({:return, val}, acc), do: collect_tool_names(val, acc)
  defp collect_tool_names({:fail, val}, acc), do: collect_tool_names(val, acc)
  defp collect_tool_names({:recur, args}, acc), do: Enum.reduce(args, acc, &collect_tool_names/2)
  defp collect_tool_names({:def, _name, val, _meta}, acc), do: collect_tool_names(val, acc)

  defp collect_tool_names({:vector, elems}, acc),
    do: Enum.reduce(elems, acc, &collect_tool_names/2)

  defp collect_tool_names({:map, pairs}, acc) do
    Enum.reduce(pairs, acc, fn {k, v}, a ->
      a = collect_tool_names(k, a)
      collect_tool_names(v, a)
    end)
  end

  defp collect_tool_names({:set, elems}, acc), do: Enum.reduce(elems, acc, &collect_tool_names/2)

  defp collect_tool_names({:pmap, fn_expr, colls}, acc) do
    acc = collect_tool_names(fn_expr, acc)
    Enum.reduce(colls, acc, &collect_tool_names/2)
  end

  defp collect_tool_names({:pcalls, fns}, acc), do: Enum.reduce(fns, acc, &collect_tool_names/2)

  defp collect_tool_names({:task, _id, body}, acc), do: collect_tool_names(body, acc)

  defp collect_tool_names({:task_dynamic, id, body}, acc) do
    acc = collect_tool_names(id, acc)
    collect_tool_names(body, acc)
  end

  defp collect_tool_names({:step_done, id, summary}, acc) do
    acc = collect_tool_names(id, acc)
    collect_tool_names(summary, acc)
  end

  defp collect_tool_names({:task_reset, id}, acc), do: collect_tool_names(id, acc)

  defp collect_tool_names({:juxt, fns}, acc), do: Enum.reduce(fns, acc, &collect_tool_names/2)

  defp collect_tool_names(_other, acc), do: acc

  # Typed tools a referenced prelude export will invoke (from its export record),
  # so the pre-execution guard rejects a wrapped `(tool/call ...)` whose tool is
  # missing BEFORE any earlier tool can run.
  defp collect_prelude_tool_refs(_core_ast, nil), do: MapSet.new()

  defp collect_prelude_tool_refs(core_ast, %Prelude{} = prelude) do
    core_ast
    |> collect_prelude_refs(MapSet.new())
    |> Enum.reduce(MapSet.new(), fn ref, acc ->
      prelude |> Prelude.export_tool_refs(ref) |> MapSet.new() |> MapSet.union(acc)
    end)
  end

  # Generic CoreAST walk collecting prelude export refs ({:prelude_call,...} /
  # {:prelude_ref,...}) referenced anywhere in the user program.
  defp collect_prelude_refs({:prelude_call, ref, args}, acc),
    do: Enum.reduce(args, MapSet.put(acc, ref), &collect_prelude_refs/2)

  defp collect_prelude_refs({:prelude_ref, ref}, acc), do: MapSet.put(acc, ref)

  defp collect_prelude_refs(tuple, acc) when is_tuple(tuple),
    do: Enum.reduce(Tuple.to_list(tuple), acc, &collect_prelude_refs/2)

  defp collect_prelude_refs(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_prelude_refs/2)

  defp collect_prelude_refs(map, acc) when is_map(map),
    do: Enum.reduce(Map.values(map), acc, &collect_prelude_refs/2)

  defp collect_prelude_refs(_other, acc), do: acc

  defp static_prelude_calls(_core_ast, nil), do: []

  defp static_prelude_calls(core_ast, %Prelude{} = prelude) do
    callable_refs =
      prelude.exports
      |> Enum.filter(&(&1.kind == :function))
      |> MapSet.new(& &1.ref)

    core_ast
    |> collect_static_prelude_calls(callable_refs, MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp collect_static_prelude_calls({:prelude_call, ref, args}, callable_refs, acc) do
    Enum.reduce(args, MapSet.put(acc, ref), &collect_static_prelude_calls(&1, callable_refs, &2))
  end

  defp collect_static_prelude_calls({:prelude_ref, ref}, callable_refs, acc) do
    if MapSet.member?(callable_refs, ref), do: MapSet.put(acc, ref), else: acc
  end

  defp collect_static_prelude_calls(tuple, callable_refs, acc) when is_tuple(tuple),
    do:
      Enum.reduce(
        Tuple.to_list(tuple),
        acc,
        &collect_static_prelude_calls(&1, callable_refs, &2)
      )

  defp collect_static_prelude_calls(list, callable_refs, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_static_prelude_calls(&1, callable_refs, &2))

  defp collect_static_prelude_calls(map, callable_refs, acc) when is_map(map),
    do: Enum.reduce(Map.values(map), acc, &collect_static_prelude_calls(&1, callable_refs, &2))

  defp collect_static_prelude_calls(_other, _callable_refs, acc), do: acc

  @doc false
  # Returns the unresolved variable names in `core_ast` given an initial scope
  # (a `MapSet` of in-scope names, atoms or binaries). Exposed so the prelude
  # compiler can run the SAME static undefined-var check on captured definition
  # bodies.
  @spec undefined_vars(term(), MapSet.t()) :: [String.t()]
  def undefined_vars(core_ast, %MapSet{} = scope) do
    core_ast |> collect_undefined_vars(normalize_scope(scope)) |> Enum.uniq()
  end

  # The scope holds names as binaries, never atoms. `SourceAtoms.intern/1`
  # returns an atom for the bounded vocabulary and a binary for everything
  # else, so one form can carry both representations of ordinary user names —
  # `(defn- parse …)` parses as `:parse` while `(defn- parse-report …)` parses
  # as `"parse-report"`. Comparing raw representations reported a definition
  # whose spelling happens to be interned as undefined (#1166).
  defp normalize_scope(%MapSet{} = scope), do: MapSet.new(scope, &to_string/1)

  defp put_scope(scope, name), do: MapSet.put(scope, to_string(name))

  # Variable reference — check builtins and local scope
  defp collect_undefined_vars({:var, name}, scope) do
    name_str = to_string(name)

    # Skip interop method names (e.g., .toString) — validity checked at runtime
    if String.starts_with?(name_str, ".") or Env.builtin?(name) or
         MapSet.member?(scope, name_str) do
      []
    else
      [name_str]
    end
  end

  # Data access — always valid
  defp collect_undefined_vars({:data, _key}, _scope), do: []

  # Literals
  defp collect_undefined_vars(nil, _scope), do: []
  defp collect_undefined_vars(n, _scope) when is_number(n), do: []
  defp collect_undefined_vars(b, _scope) when is_boolean(b), do: []
  defp collect_undefined_vars({:string, _}, _scope), do: []
  defp collect_undefined_vars({:keyword, _}, _scope), do: []
  defp collect_undefined_vars({:literal, _}, _scope), do: []
  defp collect_undefined_vars(a, _scope) when a in [:infinity, :negative_infinity, :nan], do: []

  # Let bindings — extend scope with bound vars
  defp collect_undefined_vars({:let, bindings, body}, scope) do
    {binding_errors, extended_scope} = reduce_bindings(bindings, scope)
    binding_errors ++ collect_undefined_vars(body, extended_scope)
  end

  # fn — extend scope with param vars
  defp collect_undefined_vars({:fn, params, body}, scope) do
    param_names = fn_param_vars(params)
    extended_scope = Enum.reduce(param_names, scope, &put_scope(&2, &1))
    collect_undefined_vars(body, extended_scope)
  end

  defp collect_undefined_vars({:fn, name, params, body}, scope) do
    param_names = fn_param_vars(params)

    extended_scope =
      [name | param_names]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(scope, &put_scope(&2, &1))

    collect_undefined_vars(body, extended_scope)
  end

  # loop — extend scope with binding vars
  defp collect_undefined_vars({:loop, bindings, body}, scope) do
    {binding_errors, extended_scope} = reduce_bindings(bindings, scope)
    binding_errors ++ collect_undefined_vars(body, extended_scope)
  end

  # Function call
  defp collect_undefined_vars({:call, target, args}, scope) do
    collect_undefined_vars(target, scope) ++
      Enum.flat_map(args, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({tag, _reference_id, args}, scope)
       when tag in [:java_static, :java_new],
       do: Enum.flat_map(args, &collect_undefined_vars(&1, scope))

  defp collect_undefined_vars({tag, _reference_id, receiver, args}, scope)
       when tag in [:java_instance, :java_dot] do
    collect_undefined_vars(receiver, scope) ++
      Enum.flat_map(args, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({tag, _reference_id}, _scope)
       when tag in [:java_field, :java_ref],
       do: []

  # Tool call
  defp collect_undefined_vars({:tool_call, _name, args}, scope) do
    Enum.flat_map(args, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({:runtime_callable, _namespace, _name}, _scope), do: []
  defp collect_undefined_vars({:symbol_ref, _name}, _scope), do: []

  # Prelude export ref/call: the ref resolves through the prelude export table,
  # not user scope; recurse into call args only.
  defp collect_undefined_vars({:prelude_ref, _ref}, _scope), do: []

  defp collect_undefined_vars({:prelude_call, _ref, args}, scope),
    do: Enum.flat_map(args, &collect_undefined_vars(&1, scope))

  # def / defonce — add name to scope before recursing (enables recursive defn)
  defp collect_undefined_vars({:def, name, value, _meta}, scope) do
    collect_undefined_vars(value, put_scope(scope, name))
  end

  defp collect_undefined_vars({:defonce, name, value, _opts}, scope) do
    collect_undefined_vars(value, put_scope(scope, name))
  end

  # Control flow
  defp collect_undefined_vars({:if, c, t, e}, scope) do
    collect_undefined_vars(c, scope) ++
      collect_undefined_vars(t, scope) ++ collect_undefined_vars(e, scope)
  end

  defp collect_undefined_vars({:do, exprs}, scope) do
    {errors, _final_scope} =
      Enum.reduce(exprs, {[], scope}, fn expr, {errs, sc} ->
        new_errs = collect_undefined_vars(expr, sc)
        new_sc = Enum.reduce(extract_def_names(expr), sc, &put_scope(&2, &1))
        {errs ++ new_errs, new_sc}
      end)

    errors
  end

  defp collect_undefined_vars({:and, exprs}, scope) do
    Enum.flat_map(exprs, &collect_undefined_vars(&1, scope))
  end

  # `or` treats unbound vars as nil at runtime (see eval.ex), so bare variable
  # references inside `or` are safe — skip them in the static check.  This
  # supports the common `(or my-var default)` pattern for memory initialisation.
  defp collect_undefined_vars({:or, exprs}, scope) do
    Enum.flat_map(exprs, fn
      {:var, _} -> []
      expr -> collect_undefined_vars(expr, scope)
    end)
  end

  defp collect_undefined_vars({:return, value}, scope) do
    collect_undefined_vars(value, scope)
  end

  defp collect_undefined_vars({:fail, value}, scope) do
    collect_undefined_vars(value, scope)
  end

  defp collect_undefined_vars({:recur, args}, scope) do
    Enum.flat_map(args, &collect_undefined_vars(&1, scope))
  end

  # Collections
  defp collect_undefined_vars({:vector, elems}, scope) do
    Enum.flat_map(elems, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({:map, pairs}, scope) do
    Enum.flat_map(pairs, fn {k, v} ->
      collect_undefined_vars(k, scope) ++ collect_undefined_vars(v, scope)
    end)
  end

  defp collect_undefined_vars({:set, elems}, scope) do
    Enum.flat_map(elems, &collect_undefined_vars(&1, scope))
  end

  # Juxt
  defp collect_undefined_vars({:juxt, fns}, scope) do
    Enum.flat_map(fns, &collect_undefined_vars(&1, scope))
  end

  # Parallel operations
  defp collect_undefined_vars({:pmap, fn_expr, coll_exprs}, scope) do
    collect_undefined_vars(fn_expr, scope) ++
      Enum.flat_map(coll_exprs, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({:pcalls, fn_exprs}, scope) do
    Enum.flat_map(fn_exprs, &collect_undefined_vars(&1, scope))
  end

  # Task/step operations
  # Turn history
  defp collect_undefined_vars({:turn_history, _n}, _scope), do: []

  # Catch-all: safe to skip unknown nodes (runtime eval still catches real errors).
  # Log in debug to surface missing clauses when CoreAST is extended.
  defp collect_undefined_vars(_other, _scope) do
    Logger.debug("collect_undefined_vars: unhandled CoreAST node")
    []
  end

  defp reduce_bindings(bindings, scope) do
    Enum.reduce(bindings, {[], scope}, fn {:binding, pattern, value}, {errs, sc} ->
      value_errs = collect_undefined_vars(value, sc)
      new_scope = Enum.reduce(pattern_vars(pattern), sc, &put_scope(&2, &1))
      {errs ++ value_errs, new_scope}
    end)
  end

  # Extract def/defonce names from definite-execution contexts only.
  # Used to propagate top-level vars across program expressions in {:do, ...}.
  # Only recurses into forms guaranteed to execute: do, let, loop.
  # Does NOT recurse into conditional (if, and, or) or deferred (fn) forms.
  defp extract_def_names({:def, name, _value, _meta}), do: [name]
  defp extract_def_names({:defonce, name, _value, _meta}), do: [name]
  defp extract_def_names({:do, exprs}), do: Enum.flat_map(exprs, &extract_def_names/1)

  defp extract_def_names({:let, bindings, body}) do
    Enum.flat_map(bindings, fn {:binding, _pat, value} -> extract_def_names(value) end) ++
      extract_def_names(body)
  end

  defp extract_def_names({:loop, bindings, body}) do
    Enum.flat_map(bindings, fn {:binding, _pat, value} -> extract_def_names(value) end) ++
      extract_def_names(body)
  end

  defp extract_def_names(_), do: []

  # Extract variable names from fn params
  defp fn_param_vars(params) when is_list(params) do
    Enum.flat_map(params, &pattern_vars/1)
  end

  defp fn_param_vars({:variadic, leading, rest_pattern}) do
    Enum.flat_map(leading, &pattern_vars/1) ++ pattern_vars(rest_pattern)
  end

  # Extract all variable names from a destructuring pattern
  defp pattern_vars({:var, name}), do: [name]

  defp pattern_vars({:destructure, {:keys, keys, _defaults}}) do
    keys
  end

  defp pattern_vars({:destructure, {:map, keys, renames, _defaults}}) do
    keys ++
      Enum.flat_map(renames, fn {target_pattern, _source_key} -> pattern_vars(target_pattern) end)
  end

  defp pattern_vars({:destructure, {:as, name, inner}}) do
    [name | pattern_vars(inner)]
  end

  defp pattern_vars({:destructure, {:seq, patterns}}) do
    Enum.flat_map(patterns, &pattern_vars/1)
  end

  defp pattern_vars({:destructure, {:seq_rest, leading, rest}}) do
    Enum.flat_map(leading, &pattern_vars/1) ++ pattern_vars(rest)
  end

  defp pattern_vars(_other), do: []
end
