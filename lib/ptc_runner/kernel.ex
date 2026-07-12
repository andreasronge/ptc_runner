defmodule PtcRunner.Kernel do
  @moduledoc false

  alias PtcRunner.Kernel.Action
  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InnerPrelude
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.StateHandle
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.ExecutionError
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Bundle
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.PreludeOrigin
  alias PtcRunner.PreludeRolePolicy
  alias PtcRunner.PreludeRuntime
  alias PtcRunner.Step
  alias PtcRunner.Step.Public
  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.SymbolInventory
  alias PtcRunner.Tool
  alias PtcRunner.TraceContext
  alias PtcRunner.TraceLog
  alias PtcRunner.TraceLog.TurnEvent

  @outer_timeout 30_000
  @outer_heap_words 8_000_000
  @inner_timeout 1_000
  @inner_heap_words 1_250_000
  @outer_parallel_workers 2
  @inner_parallel_workers 1
  @memory_byte_cap 2_000_000
  @summary_name_limit 24
  @summary_entry_limit 8
  @summary_preview_chars 160
  @private_capability_name ~r/\A[A-Za-z][A-Za-z0-9_.\/-]*\z/
  @private_capability_name_max 128
  @reserved_capabilities MapSet.new(["llm-complete", "eval-program", "log"])
  @private_capability_options [
    :signature,
    :description,
    :cache,
    :visibility
  ]

  @prelude_dir Path.expand("../../priv/preludes/agent", __DIR__)
  @prelude_paths %{
    "agent.prompt" => Path.join(@prelude_dir, "prompt.lisp"),
    "agent.feedback" => Path.join(@prelude_dir, "feedback.lisp"),
    "agent.core" => Path.join(@prelude_dir, "core.lisp")
  }
  @prelude_origin_paths %{
    "agent.prompt" => "priv/preludes/agent/prompt.lisp",
    "agent.feedback" => "priv/preludes/agent/feedback.lisp",
    "agent.core" => "priv/preludes/agent/core.lisp"
  }
  @external_resource @prelude_paths["agent.prompt"]
  @external_resource @prelude_paths["agent.feedback"]
  @external_resource @prelude_paths["agent.core"]
  @prelude_sources %{
    "agent.prompt" => File.read!(@prelude_paths["agent.prompt"]),
    "agent.feedback" => File.read!(@prelude_paths["agent.feedback"]),
    "agent.core" => File.read!(@prelude_paths["agent.core"])
  }
  @namespace_deps %{
    "agent.core" => ["agent.prompt", "agent.feedback"]
  }
  @default_prelude_cache_key {
    __MODULE__,
    :default_embedded_prelude,
    :crypto.hash(:sha256, :erlang.term_to_binary(@prelude_sources))
  }

  @spec compile_prelude(keyword()) :: {:ok, Prelude.t()} | {:error, term()}
  def compile_prelude(opts \\ []) when is_list(opts) do
    if role_backed_prelude?(opts) do
      compile_role_backed_prelude(opts)
    else
      compile_embedded_prelude(opts)
    end
  end

  @doc "Compiles an explicit, component-ID addressed source bundle."
  @spec compile_bundle([Component.t()]) ::
          {:ok, PtcRunner.Kernel.FrozenBundle.t()} | {:error, map()}
  def compile_bundle(components), do: BundleCompiler.compile(components)

  defp compile_preludes(opts, mission_tools) do
    cond do
      role_backed_prelude?(opts) ->
        with {:ok, grant} <- resolve_role_grant(opts),
             {:ok, inner_resolved} <-
               resolve_prelude_surface(opts, grant, :inner),
             {:ok, loop_resolved} <-
               resolve_prelude_surface(opts, grant, :loop),
             {:ok, inner_refs} <-
               InnerPrelude.validate(loop_resolved.prelude, inner_resolved.prelude, mission_tools) do
          {:ok,
           %{
             loop: annotate_role_prelude(loop_resolved.prelude, loop_resolved, :loop),
             inner: annotate_role_prelude(inner_resolved.prelude, inner_resolved, :inner),
             inner_refs: inner_refs
           }}
        end

      Keyword.has_key?(opts, :inner_preludes) ->
        {:error,
         %{reason: :role_policy_required, message: ":inner_preludes requires :role_policy"}}

      true ->
        with {:ok, loop} <-
               compile_embedded_prelude(opts)
               |> tag_error_option(:prelude_source_overrides),
             do: {:ok, %{loop: loop, inner: nil, inner_refs: MapSet.new()}}
    end
  end

  defp resolve_prelude_surface(opts, grant, surface) do
    opts
    |> Keyword.get(:prelude_store)
    |> PreludeRuntime.resolve(grant, surface, opts)
    |> tag_preflight_option(prelude_selection_option(surface, opts))
  end

  defp prelude_selection_option(:loop, opts) do
    if Keyword.has_key?(opts, :preludes), do: :preludes, else: :role_policy
  end

  defp prelude_selection_option(:inner, opts) do
    if Keyword.has_key?(opts, :inner_preludes), do: :inner_preludes, else: :role_policy
  end

  defp tag_preflight_option({:error, error}, option) when is_map(error),
    do: tag_selection_error(error, option)

  defp tag_preflight_option(result, _option), do: result

  defp tag_error_option({:error, error}, option) when is_map(error),
    do: {:error, Map.put(error, :kernel_option, option)}

  defp tag_error_option(result, _option), do: result

  defp tag_selection_error(%{reason: reason} = error, option)
       when reason in [
              :missing_prelude_selection,
              :prelude_selection_failed,
              :invalid_prelude_ref,
              :prelude_not_granted
            ],
       do: {:error, Map.put(error, :kernel_option, option)}

  defp tag_selection_error(error, _option), do: {:error, error}

  defp compile_role_backed_prelude(opts) do
    with {:ok, grant} <- resolve_role_grant(opts),
         {:ok, resolved} <-
           PreludeRuntime.resolve(Keyword.get(opts, :prelude_store), grant, opts) do
      {:ok, annotate_role_prelude(resolved.prelude, resolved, :loop)}
    end
  end

  defp resolve_role_grant(opts) do
    with {:ok, policy} <- role_policy(opts),
         {:ok, grant} <- PreludeRolePolicy.resolve(policy, Keyword.get(opts, :role)) do
      case grant do
        nil ->
          {:error,
           %{reason: :role_required, message: "role is required for role-backed preludes"}}

        grant ->
          {:ok, grant}
      end
    end
  end

  defp compile_embedded_prelude(opts) do
    overrides = Keyword.get(opts, :prelude_source_overrides, %{})

    if map_size(overrides) == 0 do
      default_embedded_prelude()
    else
      compile_overridden_embedded_prelude(overrides)
    end
  end

  defp default_embedded_prelude do
    case :persistent_term.get(@default_prelude_cache_key, :missing) do
      :missing ->
        result = compile_overridden_embedded_prelude(%{})
        :persistent_term.put(@default_prelude_cache_key, result)
        result

      result ->
        result
    end
  end

  defp compile_overridden_embedded_prelude(overrides) do
    with {:ok, prompt} <- compile_component("agent.prompt", overrides),
         {:ok, feedback} <- compile_component("agent.feedback", overrides),
         {:ok, core} <-
           compile_component("agent.core", overrides,
             deps: [prompt, feedback],
             namespace_deps: @namespace_deps
           ) do
      Bundle.compile_precompiled(
        [
          component("agent.prompt", prompt, overrides),
          component("agent.feedback", feedback, overrides),
          component("agent.core", core, overrides)
        ],
        namespace_deps: @namespace_deps
      )
    end
  end

  defp role_backed_prelude?(opts) do
    Keyword.has_key?(opts, :role_policy)
  end

  defp role_policy(opts) do
    case Keyword.fetch(opts, :role_policy) do
      {:ok, %PreludeRolePolicy{} = policy} ->
        {:ok, policy}

      {:ok, policy} when is_map(policy) ->
        PreludeRolePolicy.from_map(policy)

      {:ok, _policy} ->
        {:error, %{reason: :invalid_policy, message: ":role_policy must be a map"}}

      :error ->
        {:error,
         %{
           reason: :role_policy_required,
           message: ":role_policy is required for role-backed prelude selection"
         }}
    end
  end

  defp annotate_role_prelude(%Prelude{} = prelude, resolved, surface) do
    runtime = %{
      role: resolved.role,
      grant_fingerprint: resolved.grant_fingerprint,
      prelude_store_access: resolved.prelude_store_access,
      surface: surface,
      selected_refs: Enum.map(resolved.selected_refs, &public_selected_ref/1),
      resolved_refs: Enum.map(resolved.resolved_refs, &public_resolved_ref/1)
    }

    %{prelude | metadata: Map.put(prelude.metadata, :role_prelude_selection, runtime)}
  end

  defp annotate_role_prelude(nil, _resolved, :inner), do: nil

  defp public_selected_ref(ref) when is_binary(ref), do: ref

  defp public_selected_ref(ref) when is_map(ref) do
    ref
    |> Map.take([:id, :version, :checksum, "id", "version", "checksum"])
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
  end

  defp public_selected_ref(ref), do: inspect(ref, limit: 5, printable_limit: 100)

  defp public_resolved_ref(ref) when is_map(ref) do
    %{
      id: Map.get(ref, :id),
      version: Map.get(ref, :version),
      checksum: Map.get(ref, :checksum),
      namespaces: Map.get(ref, :namespaces, []),
      origin: PreludeOrigin.sanitize(Map.get(ref, :origin)),
      required_by: Map.get(ref, :required_by, [])
    }
  end

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(mission, opts) when is_map(mission) and is_list(opts) do
    with {:ok, opts} <- validate_run_options(opts),
         {:ok, preludes} <- compile_preludes(opts, Keyword.get(opts, :tools, %{})),
         :ok <- log_prelude(opts, preludes.loop, :loop),
         :ok <- log_prelude(opts, preludes.inner, :inner),
         {:ok, symbol_facts, symbol_inventory, symbol_inventory_meta} <-
           render_symbol_inventory(mission, opts, preludes.inner),
         {:ok, memory} <-
           StateHandle.start(byte_cap: Keyword.fetch!(opts, :kernel_memory_byte_cap)) do
      run_with_memory(
        mission,
        opts,
        preludes,
        symbol_facts,
        symbol_inventory,
        symbol_inventory_meta,
        memory
      )
    else
      {:error, %{reason: reason} = error}
      when reason in ["invalid_kernel_option", "invalid_private_capability"] ->
        {:error, error}

      {:error, error} ->
        {:error, normalize_preflight_error(error, opts)}
    end
  end

  @doc "Runs one bounded workflow entry expression through the new Kernel path."
  @spec run(binary(), RunConfig.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(entry_source, %RunConfig{} = config) when is_binary(entry_source) do
    with :ok <- entry_source_within_limit(entry_source, config.limits),
         {:ok, state} <- RunState.start(config.limits),
         :ok <- EventSink.emit(config.event_sink, "run-started", %{labels: config.labels}),
         result <- run_workflow(entry_source, config, state),
         :ok <-
           EventSink.emit(config.event_sink, "run-stopped", %{
             outcome: outcome(result),
             usage: RunState.usage(state)
           }) do
      RunState.close(state)
      result
    else
      {:error, reason} -> configuration_error(reason, %{})
    end
  end

  defp run_workflow(entry_source, config, state) do
    opts = [
      context: config.input,
      tools: workflow_tools(config, state),
      prelude: bundle_prelude(config.workflow_environment),
      timeout: config.limits.workflow_timeout_ms,
      max_heap: config.limits.workflow_heap_words,
      max_program_bytes: config.limits.entry_source_bytes,
      filter_context: false,
      caller: :in_process_v1
    ]

    case Lisp.run_native(entry_source, opts) do
      {:ok, step} ->
        {:ok,
         %Result{
           value: step.return |> kernel_return_value() |> Lisp.externalize_value(),
           usage: RunState.usage(state),
           evaluation_memory: %{defined_count: map_size(step.memory)}
         }}

      {:error, step} ->
        {:error,
         %Error{
           kind: workflow_error_kind(step.fail.reason),
           reason: step.fail.reason,
           details: %{message: String.slice(step.fail.message || "workflow failed", 0, 4_096)},
           usage: RunState.usage(state)
         }}
    end
  end

  defp workflow_tools(config, state) do
    tools =
      Map.new(config.workflow_environment.capabilities, fn {name, _capability} ->
        {name,
         fn arguments ->
           Dispatcher.dispatch(
             state,
             :workflow,
             config.workflow_environment,
             name,
             arguments,
             config.limits.workflow_timeout_ms
           )
         end}
      end)

    Map.put(tools, "kernel-eval", fn arguments -> kernel_eval(config, state, arguments) end)
  end

  defp bundle_prelude(%{bundle: %{prelude: prelude}}), do: prelude
  defp bundle_prelude(_environment), do: nil

  defp kernel_eval(config, state, %{"kind" => kind, "source" => source}) when is_binary(source) do
    if keyword_name(kind) == "source" do
      %{
        status: :ok,
        value:
          Evaluation.evaluate_source(
            state,
            config.mission_environment,
            source,
            config.limits.evaluation_timeout_ms
          )
      }
    else
      invalid_kernel_eval_request(state)
    end
  end

  defp kernel_eval(_config, state, _arguments) do
    invalid_kernel_eval_request(state)
  end

  defp invalid_kernel_eval_request(state) do
    _ = RunState.protocol_error(state)

    %{
      status: :error,
      kind: :protocol_error,
      reason: :invalid_kernel_eval_request,
      retryable?: false
    }
  end

  defp keyword_name(%LispKeyword{name: name}), do: name
  defp keyword_name(name) when is_atom(name), do: Atom.to_string(name)
  defp keyword_name(name) when is_binary(name), do: name
  defp keyword_name(_value), do: nil

  defp entry_source_within_limit(source, limits) do
    if byte_size(source) <= limits.entry_source_bytes,
      do: :ok,
      else: {:error, :entry_source_exceeded}
  end

  defp kernel_return_value({:__ptc_return__, value}), do: value
  defp kernel_return_value(value), do: value

  defp outcome({:ok, _result}), do: :ok
  defp outcome({:error, _error}), do: :error

  defp workflow_error_kind(reason)
       when reason in [:timeout, :memory_exceeded, :program_too_large], do: :limit_exceeded

  defp workflow_error_kind(_reason), do: :workflow_failed

  defp configuration_error(reason, usage),
    do: {:error, %Error{kind: :configuration_error, reason: reason, details: %{}, usage: usage}}

  defp run_with_memory(
         mission,
         opts,
         preludes,
         symbol_facts,
         symbol_inventory,
         symbol_inventory_meta,
         memory
       ) do
    result =
      with {:ok, turn_recorder} <- start_turn_recorder(preludes, opts) do
        run_with_owners(
          mission,
          opts,
          preludes,
          symbol_facts,
          symbol_inventory,
          symbol_inventory_meta,
          memory,
          turn_recorder
        )
      end

    result
  after
    StateHandle.stop(memory)
  end

  defp run_with_owners(
         mission,
         opts,
         preludes,
         symbol_facts,
         symbol_inventory,
         symbol_inventory_meta,
         memory,
         turn_recorder
       ) do
    {:ok, tools} =
      kernel_tools(
        mission,
        Keyword.put(opts, :inner_prelude, preludes.inner)
        |> Keyword.put(:inner_prelude_refs, preludes.inner_refs),
        memory,
        turn_recorder
      )

    cfg = %{
      "max_turns" => Keyword.fetch!(opts, :max_turns),
      "protocol_tool_name" => Action.tool_name(),
      "tool_names" => opts |> Keyword.get(:tools, %{}) |> public_tool_names(),
      "symbol_facts" => symbol_facts,
      "symbol_inventory" => inventory_with_return_contract(symbol_inventory, opts),
      "symbol_inventory_meta" => symbol_inventory_meta,
      "return_type" => Keyword.get(opts, :return_type)
    }

    program = ~S|(agent.core/run-mission data/mission data/cfg)|

    result =
      case Lisp.run(program,
             prelude: preludes.loop,
             tools: tools,
             context: %{mission: mission, cfg: cfg},
             filter_context: false,
             timeout: Keyword.fetch!(opts, :timeout),
             max_heap: Keyword.fetch!(opts, :max_heap),
             setup_max_heap: Keyword.fetch!(opts, :setup_max_heap),
             worker_max_heap: Keyword.fetch!(opts, :max_heap),
             max_parallel_workers: @outer_parallel_workers
           ) do
        {:ok, step} -> unwrap_outer_step(step)
        {:error, step} -> {:error, %{reason: "kernel_error", step: project_public_step(step)}}
      end

    result
  after
    stop_agent(turn_recorder)
  end

  defp validate_run_options(opts) do
    max_turns = Keyword.get(opts, :max_turns, 3)

    with :ok <- positive_integer_option(opts, :max_turns, max_turns),
         max_llm_calls = Keyword.get(opts, :max_llm_calls, max_turns),
         :ok <- positive_integer_option(opts, :max_llm_calls, max_llm_calls),
         :ok <- function_option(opts, :llm, 1),
         :ok <-
           positive_integer_option(opts, :timeout, Keyword.get(opts, :timeout, @outer_timeout)),
         :ok <-
           positive_integer_option(
             opts,
             :max_heap,
             Keyword.get(opts, :max_heap, @outer_heap_words)
           ),
         :ok <-
           positive_integer_option(
             opts,
             :setup_max_heap,
             Keyword.get(opts, :setup_max_heap, @outer_heap_words * 2)
           ),
         :ok <-
           positive_integer_option(
             opts,
             :inner_timeout,
             Keyword.get(opts, :inner_timeout, @inner_timeout)
           ),
         :ok <-
           positive_integer_option(
             opts,
             :inner_max_heap,
             Keyword.get(opts, :inner_max_heap, @inner_heap_words)
           ),
         :ok <- optional_positive_integer_option(opts, :max_tool_calls),
         :ok <- optional_positive_integer_option(opts, :inner_max_tool_calls),
         :ok <- prelude_source_overrides_option(opts),
         {:ok, parsed_signature, return_type} <- signature_option(opts),
         {:ok, memory_cap} <- memory_byte_cap(opts),
         {:ok, private_capabilities} <- normalize_private_capabilities(opts) do
      {:ok,
       opts
       |> Keyword.put(:parsed_signature, parsed_signature)
       |> Keyword.put(:return_type, return_type)
       |> Keyword.put(:max_turns, max_turns)
       |> Keyword.put(:max_llm_calls, max_llm_calls)
       |> Keyword.put(:timeout, Keyword.get(opts, :timeout, @outer_timeout))
       |> Keyword.put(:max_heap, Keyword.get(opts, :max_heap, @outer_heap_words))
       |> Keyword.put(:setup_max_heap, Keyword.get(opts, :setup_max_heap, @outer_heap_words * 2))
       |> Keyword.put(:inner_timeout, Keyword.get(opts, :inner_timeout, @inner_timeout))
       |> Keyword.put(:inner_max_heap, Keyword.get(opts, :inner_max_heap, @inner_heap_words))
       |> Keyword.put(:kernel_memory_byte_cap, memory_cap)
       |> Keyword.put(:private_capabilities, private_capabilities)}
    end
  end

  defp positive_integer_option(_opts, _option, value) when is_integer(value) and value > 0,
    do: :ok

  defp positive_integer_option(_opts, option, value), do: invalid_option(option, value)

  defp optional_positive_integer_option(opts, option) do
    if Keyword.has_key?(opts, option) do
      positive_integer_option(opts, option, Keyword.get(opts, option))
    else
      :ok
    end
  end

  defp signature_option(opts) do
    case Keyword.get(opts, :signature) do
      nil ->
        {:ok, nil, nil}

      signature when is_binary(signature) ->
        case Signature.parse(signature) do
          {:ok, {:signature, [], return_type} = parsed} ->
            {:ok, parsed, Signature.Renderer.render_type(return_type, key_style: :lisp_prompt)}

          _error ->
            invalid_signature_option(signature)
        end

      other ->
        invalid_signature_option(other)
    end
  end

  defp invalid_signature_option(value) do
    case invalid_option(:signature, value) do
      {:error, error} -> {:error, error}
    end
  end

  defp function_option(opts, option, arity) do
    case Keyword.fetch(opts, option) do
      {:ok, fun} when is_function(fun, arity) -> :ok
      {:ok, value} -> invalid_option(option, value)
      :error -> invalid_option(option, nil)
    end
  end

  defp prelude_source_overrides_option(opts) do
    overrides = Keyword.get(opts, :prelude_source_overrides, %{})

    if is_map(overrides) and Enum.all?(overrides, &valid_prelude_override?/1) do
      :ok
    else
      invalid_option(:prelude_source_overrides, overrides)
    end
  end

  defp valid_prelude_override?({namespace, override})
       when namespace in [
              "agent.prompt",
              "agent.feedback",
              "agent.core",
              :"agent.prompt",
              :"agent.feedback",
              :"agent.core"
            ] do
    case override do
      source when is_binary(source) -> true
      {source, _origin} when is_binary(source) -> true
      %{source: source} when is_binary(source) -> true
      %{"source" => source} when is_binary(source) -> true
      _ -> false
    end
  end

  defp valid_prelude_override?(_entry), do: false

  defp invalid_option(option, value) do
    {:error,
     %{
       reason: "invalid_kernel_option",
       option: Atom.to_string(option),
       value_type: value_type(value)
     }}
  end

  defp normalize_private_capabilities(opts) do
    capabilities = Keyword.get(opts, :private_capabilities, %{})

    if is_map(capabilities) do
      normalize_private_capability_map(capabilities, Keyword.get(opts, :tools, %{}))
    else
      private_capability_error(capabilities, nil, "invalid_format")
    end
  end

  defp normalize_private_capability_map(capabilities, mission_tools) do
    entries =
      Enum.map(capabilities, fn {name, format} ->
        {normalize_capability_name(name), name, format}
      end)

    with :ok <- valid_capability_names(entries, capabilities),
         :ok <- unreserved_capability_names(entries, capabilities),
         :ok <- unique_capability_names(entries, mission_tools, capabilities) do
      entries
      |> Enum.sort_by(fn {{:ok, name}, _raw, _format} -> name end)
      |> Enum.reduce_while({:ok, %{}}, fn {{:ok, name}, _raw, format}, {:ok, acc} ->
        case normalize_private_capability(name, format, capabilities) do
          {:ok, tool} -> {:cont, {:ok, Map.put(acc, name, tool)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp normalize_capability_name(name) when is_binary(name), do: {:ok, name}
  defp normalize_capability_name(name) when is_atom(name), do: {:ok, Atom.to_string(name)}
  defp normalize_capability_name(_name), do: :error

  defp valid_capability_names(entries, original) do
    case Enum.find(entries, fn
           {{:ok, name}, _raw, _format} ->
             byte_size(name) > @private_capability_name_max or
               not Regex.match?(@private_capability_name, name)

           {:error, _raw, _format} ->
             true
         end) do
      nil -> :ok
      {{:ok, name}, _raw, _format} -> private_capability_error(original, name, "invalid_name")
      {:error, _raw, _format} -> private_capability_error(original, nil, "invalid_name")
    end
  end

  defp unreserved_capability_names(entries, original) do
    case Enum.find(entries, fn {{:ok, name}, _, _} ->
           MapSet.member?(@reserved_capabilities, name)
         end) do
      nil -> :ok
      {{:ok, name}, _, _} -> private_capability_error(original, name, "reserved_name")
    end
  end

  defp unique_capability_names(entries, mission_tools, original) do
    names = Enum.map(entries, fn {{:ok, name}, _, _} -> name end)

    duplicate =
      Enum.find(names, fn name ->
        Enum.count(names, &(&1 == name)) > 1 or mission_tool_name?(mission_tools, name)
      end)

    if duplicate, do: private_capability_error(original, duplicate, "duplicate_name"), else: :ok
  end

  defp mission_tool_name?(tools, name) when is_map(tools),
    do: Enum.any?(Map.keys(tools), &(normalize_capability_name(&1) == {:ok, name}))

  defp mission_tool_name?(_tools, _name), do: false

  defp normalize_private_capability(name, %Tool{} = tool, original) do
    cond do
      tool.type != :native ->
        private_capability_error(original, name, "not_native")

      not is_function(tool.function, 1) ->
        private_capability_error(original, name, "invalid_arity")

      not valid_private_tool_fields?(tool) ->
        private_capability_error(original, name, "malformed_options")

      not Tool.private?(tool) ->
        private_capability_error(original, name, "not_private")

      true ->
        {:ok, %{tool | name: name}}
    end
  end

  defp normalize_private_capability(name, {fun, options} = format, original)
       when is_function(fun, 1) and is_list(options) do
    cond do
      not Keyword.keyword?(options) ->
        private_capability_error(original, name, "malformed_options")

      Keyword.keys(options) -- @private_capability_options != [] ->
        private_capability_error(original, name, "malformed_options")

      not valid_private_capability_options?(options) ->
        private_capability_error(original, name, "malformed_options")

      true ->
        normalize_private_tool(name, format, original)
    end
  end

  defp normalize_private_capability(name, {fun, _options}, original) when is_function(fun),
    do: private_capability_error(original, name, "invalid_arity")

  defp normalize_private_capability(name, _format, original),
    do: private_capability_error(original, name, "invalid_format")

  defp valid_private_capability_options?(options) do
    keys = Keyword.keys(options)

    length(keys) == length(Enum.uniq(keys)) and
      valid_private_signature?(Keyword.get(options, :signature)) and
      valid_optional_binary?(Keyword.get(options, :description)) and
      valid_boolean?(Keyword.get(options, :cache, false))
  end

  defp valid_private_signature?(nil), do: true

  defp valid_private_signature?(signature) when is_binary(signature),
    do: match?({:ok, _}, Signature.parse(signature))

  defp valid_private_signature?(_signature), do: false

  defp valid_optional_binary?(nil), do: true
  defp valid_optional_binary?(value), do: is_binary(value)

  defp valid_boolean?(value), do: is_boolean(value)

  defp valid_private_tool_fields?(tool) do
    valid_private_signature?(tool.signature) and
      valid_optional_binary?(tool.description) and
      valid_boolean?(tool.cache) and
      is_nil(tool.expose) and
      is_nil(tool.native_result)
  end

  defp normalize_private_tool(name, format, original) do
    case Tool.new(name, format) do
      {:ok, %Tool{type: :native, function: fun} = tool} when is_function(fun, 1) ->
        if Tool.private?(tool),
          do: {:ok, tool},
          else: private_capability_error(original, name, "not_private")

      {:ok, %Tool{type: type}} when type != :native ->
        private_capability_error(original, name, "not_native")

      {:ok, _tool} ->
        private_capability_error(original, name, "invalid_arity")

      {:error, _reason} ->
        private_capability_error(original, name, "malformed_options")
    end
  end

  defp private_capability_error(original, capability, detail) do
    error = %{
      reason: "invalid_private_capability",
      option: "private_capabilities",
      value_type: value_type(original),
      detail: detail
    }

    capability =
      if is_binary(capability), do: String.slice(capability, 0, @private_capability_name_max)

    {:error, if(capability, do: Map.put(error, :capability, capability), else: error)}
  end

  defp normalize_preflight_error(error, opts) do
    option = preflight_option(error, opts)
    value = Keyword.get(opts, option)

    %{
      reason: "invalid_kernel_option",
      option: Atom.to_string(option),
      value_type: value_type(value)
    }
  end

  defp preflight_option(%{kernel_option: option}, _opts) when is_atom(option), do: option

  defp preflight_option(%{reason: reason}, _opts) when reason in [:invalid_policy],
    do: :role_policy

  defp preflight_option(%{reason: reason}, _opts)
       when reason in [:role_required, :invalid_role, :unknown_role],
       do: :role

  defp preflight_option(%{reason: reason}, _opts)
       when reason in [:missing_prelude_store, :invalid_prelude_store],
       do: :prelude_store

  defp preflight_option(%{reason: :role_policy_required}, opts) do
    if Keyword.has_key?(opts, :inner_preludes), do: :inner_preludes, else: :role_policy
  end

  defp preflight_option(%{reason: :invalid_inner_prelude}, opts) do
    if Keyword.has_key?(opts, :inner_preludes), do: :inner_preludes, else: :role_policy
  end

  defp preflight_option(%{reason: "invalid_symbol_inventory_renderer"}, _opts),
    do: :symbol_inventory_renderer

  defp preflight_option(%{reason: reason}, opts)
       when reason in [:invalid_prelude_ref, :prelude_not_granted] do
    cond do
      Keyword.has_key?(opts, :inner_preludes) -> :inner_preludes
      Keyword.has_key?(opts, :preludes) -> :preludes
      true -> :role_policy
    end
  end

  defp preflight_option(_error, _opts), do: :kernel_configuration

  defp value_type(nil), do: "nil"
  defp value_type(value) when is_boolean(value), do: "boolean"
  defp value_type(value) when is_integer(value), do: "integer"
  defp value_type(value) when is_float(value), do: "float"
  defp value_type(value) when is_binary(value), do: "string"
  defp value_type(value) when is_atom(value), do: "atom"
  defp value_type(value) when is_function(value), do: "function"
  defp value_type(value) when is_list(value), do: "list"
  defp value_type(%{__struct__: _}), do: "struct"
  defp value_type(value) when is_map(value), do: "map"
  defp value_type(value) when is_tuple(value), do: "tuple"
  defp value_type(_value), do: "other"

  defp render_symbol_inventory(mission, opts, prelude) do
    facts =
      SymbolInventory.project(
        data: Map.get(mission, "context", %{}),
        tools: Keyword.get(opts, :tools, %{}),
        prelude: role_backed_inventory_prelude(prelude),
        memory_summary: Keyword.get(opts, :memory_summary)
      )

    case SymbolInventory.render(
           facts,
           Keyword.get(opts, :symbol_inventory_renderer, :default),
           Keyword.get(opts, :symbol_inventory_renderer_opts, [])
         ) do
      {:ok, rendered, meta} -> {:ok, Enum.map(facts, &string_key_fact/1), rendered || "", meta}
      {:error, error} -> {:error, error}
    end
  end

  defp role_backed_inventory_prelude(%Prelude{} = prelude), do: prelude
  defp role_backed_inventory_prelude(nil), do: nil

  defp string_key_fact(fact) when is_map(fact) do
    fact
    |> Enum.map(fn {key, value} -> {to_string(key), string_key_fact_value(value)} end)
    |> Map.new()
  end

  defp string_key_fact_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_key_fact_value(value), do: value

  defp public_tool_names(tools) when is_map(tools) do
    tools
    |> Enum.map(fn {name, format} ->
      {to_string(name), normalize_tool(to_string(name), format)}
    end)
    |> Enum.reject(fn {name, tool} ->
      is_nil(tool) or Tool.private?(tool) or name in ["llm-complete", "eval-program", "log"]
    end)
    |> Enum.map(fn {name, _tool} -> name end)
    |> Enum.sort()
  end

  defp public_tool_names(_tools), do: []

  defp inventory_with_return_contract(inventory, opts) do
    case Keyword.get(opts, :return_type) do
      nil ->
        inventory

      return_type ->
        contract =
          ";; === required return ===\n" <>
            ";; type: #{return_type}\n" <>
            ";; The value passed to (return ...) must match this type exactly."

        [inventory, contract]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")
    end
  end

  defp normalize_tool(name, %Tool{} = tool), do: %{tool | name: tool.name || name}

  defp normalize_tool(name, format) do
    case Tool.new(name, format) do
      {:ok, tool} -> tool
      {:error, _reason} -> nil
    end
  end

  defp kernel_tools(mission, opts, memory, turn_recorder) do
    llm = Keyword.fetch!(opts, :llm)
    events = Keyword.get(opts, :events)
    mission_tools = Keyword.get(opts, :tools, %{})
    system_prompt = Keyword.get(opts, :system_prompt)

    kernel_tools = %{
      "llm-complete" =>
        {fn args ->
           case claim_llm_slot(turn_recorder) do
             :ok ->
               system = resolve_system_prompt(args, system_prompt)

               request = %{
                 system: system,
                 messages: normalize_messages(Map.get(args, "messages", [])),
                 tools: [Action.tool_schema()],
                 tool_choice: %{type: "tool", name: Action.tool_name()}
               }

               log_unsafe_llm_request(events, opts, args, request)

               started_at = System.monotonic_time(:millisecond)

               action =
                 request
                 |> llm.()
                 |> normalize_llm_result()
                 |> add_public_tool_call()

               duration_ms = System.monotonic_time(:millisecond) - started_at
               record_model_action(turn_recorder, args, action, duration_ms)

             :exhausted ->
               record_model_action(turn_recorder, args, llm_budget_action(), 0)
           end
         end,
         [signature: "(system :string?, messages :any, turn :int) -> :map", visibility: :private]},
      "eval-program" =>
        {fn args ->
           eval_program(args, mission, mission_tools, opts, memory, events, turn_recorder)
         end, [signature: "(program :string, turn :int) -> :map", visibility: :private]},
      "log" =>
        {fn args ->
           if is_function(events, 1), do: events.(args)
           %{"ok" => true}
         end, [signature: "(event :string) -> :map", visibility: :private]}
    }

    {:ok, Map.merge(Keyword.fetch!(opts, :private_capabilities), kernel_tools)}
  end

  defp claim_llm_slot(recorder) do
    Agent.get_and_update(recorder, fn state ->
      if state.llm_calls < state.max_llm_calls do
        {:ok, %{state | llm_calls: state.llm_calls + 1}}
      else
        {:exhausted, state}
      end
    end)
  end

  defp llm_budget_action do
    %{
      kind: "budget_exhausted",
      program: nil,
      reason: "llm_budget_exhausted",
      content: nil,
      tokens: %{},
      model: nil,
      provider: nil,
      provider_meta: %{},
      transport_error: nil
    }
  end

  defp compile_component(namespace, overrides, opts \\ []) do
    namespace
    |> component_source(overrides)
    |> Compiler.compile(opts)
  end

  defp log_prelude(_opts, nil, _slot), do: :ok

  defp log_prelude(opts, prelude, slot) do
    events = Keyword.get(opts, :events)

    if is_function(events, 1) do
      events.(%{
        "event" => "prelude",
        "slot" => Atom.to_string(slot),
        "prelude" => Prelude.trace_summary(prelude)
      })
    end

    :ok
  end

  defp log_unsafe_llm_request(events, opts, args, request) do
    if is_function(events, 1) and Keyword.get(opts, :unsafe_debug) == true do
      events.(%{
        "event" => "unsafe_llm_request",
        "turn" => Map.get(args, "turn"),
        "system" => request.system,
        "messages" => request.messages
      })
    end
  end

  defp start_turn_recorder(%{loop: %Prelude{} = loop, inner: inner}, opts) do
    state = %{
      kernel_run_id:
        Keyword.get(opts, :kernel_run_id, "kernel-#{System.unique_integer([:positive])}"),
      prelude_trace: Prelude.trace_summary(loop),
      role_selection: Map.get(loop.metadata, :role_prelude_selection),
      inner_prelude_trace: Prelude.trace_summary(inner),
      inner_role_selection: if(inner, do: Map.get(inner.metadata, :role_prelude_selection)),
      prelude_presentation: prelude_presentation(opts),
      trace_context: TraceContext.capture(),
      attempt: 0,
      committed_turn: 0,
      llm_calls: 0,
      max_llm_calls: Keyword.fetch!(opts, :max_llm_calls),
      pending: %{}
    }

    Agent.start_link(fn -> state end)
  end

  defp record_model_action(recorder, args, action, duration_ms) do
    turn = normalize_turn(message_value(args, "turn"))

    {returned_action, event_action} =
      Agent.get_and_update(recorder, fn state ->
        attempt = state.attempt + 1
        state = %{state | attempt: attempt}

        cond do
          action.kind in ["protocol_error", "transport_error", "budget_exhausted"] ->
            event_action = pending_action(action, duration_ms, attempt)
            {{action, event_action}, state}

          Map.has_key?(state.pending, turn) ->
            returned_action = duplicate_llm_turn_action(action, turn)
            event_action = pending_action(returned_action, duration_ms, attempt)
            {{returned_action, event_action}, state}

          true ->
            event_action = pending_action(action, duration_ms, attempt)
            {{action, event_action}, put_in(state, [:pending, turn], event_action)}
        end
      end)

    if event_action.kind in ["protocol_error", "transport_error", "budget_exhausted"] do
      emit_kernel_turn(recorder, event_action, nil, 0)
    end

    returned_action
  end

  defp duplicate_llm_turn_action(action, turn) do
    action
    |> Map.drop([:public_tool_call, :tool_call_id])
    |> Map.merge(%{
      kind: "protocol_error",
      program: nil,
      reason: "duplicate_llm_complete_turn",
      content: nil,
      transport_error: nil,
      duplicate_turn: turn
    })
  end

  defp record_eval_turn(recorder, action, result, event_data, duration_ms) do
    emit_kernel_turn(recorder, action, event_data, duration_ms)
    result
  end

  defp claim_eval_action(recorder, turn, program) do
    turn = normalize_turn(turn)

    Agent.get_and_update(recorder, fn state ->
      case Map.get(state.pending, turn) do
        %{program: ^program} = action ->
          {action, %{state | pending: Map.delete(state.pending, turn)}}

        %{program: _program} = action ->
          {{:program_mismatch, action}, %{state | pending: Map.delete(state.pending, turn)}}

        nil ->
          {nil, state}
      end
    end)
  end

  defp pending_action(action, duration_ms, attempt) when is_map(action) do
    %{
      kind: Map.get(action, :kind),
      program: Map.get(action, :program),
      reason: Map.get(action, :reason),
      tokens: Map.get(action, :tokens, %{}) || %{},
      duration_ms: duration_ms,
      attempt: attempt
    }
  end

  defp mismatched_eval_action(action, supplied_program) do
    Map.merge(action, %{
      kind: "protocol_error",
      reason: "mismatched_eval_program",
      supplied_program: supplied_program
    })
  end

  defp emit_kernel_turn(recorder, action, event_data, eval_duration_ms) do
    status = turn_status(action, event_data)
    committed? = status == :ok

    state =
      Agent.get_and_update(recorder, fn state ->
        event_turn = if committed?, do: state.committed_turn + 1, else: state.committed_turn
        next_state = if committed?, do: %{state | committed_turn: event_turn}, else: state
        {Map.put(state, :event_turn, event_turn), next_state}
      end)

    TraceContext.attach(state.trace_context)

    if TraceLog.recording?() do
      %{
        driver: :kernel,
        agent_id: state.kernel_run_id,
        role: role_selection_value(state.role_selection, :role),
        grant_fingerprint: role_selection_value(state.role_selection, :grant_fingerprint),
        turn: state.event_turn,
        attempt: action.attempt,
        committed: committed?,
        status: status,
        duration_ms: action.duration_ms + eval_duration_ms,
        input_tokens: input_tokens(action.tokens),
        output_tokens: output_tokens(action.tokens),
        total_tokens: total_tokens(action.tokens),
        program: action.program,
        result_preview: Map.get(event_data || %{}, :result_preview),
        prints: Map.get(event_data || %{}, :prints, []),
        memory_diff: Map.get(event_data || %{}, :memory_diff),
        tool_calls: Map.get(event_data || %{}, :tool_calls, []),
        catalog_ops: Map.get(event_data || %{}, :catalog_ops, []),
        fail: turn_fail(action, event_data),
        preludes: TurnEvent.prelude_provenance(state.prelude_trace),
        inner_preludes: TurnEvent.prelude_provenance(state.inner_prelude_trace),
        inner_prelude_projection: role_prelude_projection(state.inner_role_selection),
        inner_prelude_call_counts: Map.get(event_data || %{}, :inner_prelude_call_counts, %{}),
        prelude_projection: role_prelude_projection(state.role_selection),
        prelude_call_policy: role_prelude_call_policy(state.role_selection),
        prelude_presentation: state.prelude_presentation,
        turn_type: turn_type(action, event_data)
      }
      |> TurnEvent.build()
      |> TraceLog.record_turn_event()
    end

    :ok
  end

  defp normalize_turn(turn) when is_integer(turn), do: turn

  defp normalize_turn(turn) when is_binary(turn) do
    case Integer.parse(turn) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_turn(_), do: nil

  defp turn_status(%{kind: "tool_call"}, event_data) when is_map(event_data) do
    case Map.get(event_data, :fail) do
      nil -> :ok
      _ -> :error
    end
  end

  defp turn_status(_action, _event_data), do: :error

  defp turn_type(%{kind: "protocol_error"}, _event_data), do: :protocol_error
  defp turn_type(%{kind: "transport_error"}, _event_data), do: :transport_error
  defp turn_type(%{kind: "budget_exhausted"}, _event_data), do: :budget_exhausted
  defp turn_type(_action, _event_data), do: :eval

  defp turn_fail(
         %{kind: "protocol_error", reason: "mismatched_eval_program"} = action,
         _event_data
       ),
       do: %{
         reason: "mismatched_eval_program",
         message: "eval-program program does not match the pending llm-complete action",
         expected_program: action.program,
         supplied_program: action.supplied_program
       }

  defp turn_fail(%{kind: "protocol_error", reason: reason}, _event_data),
    do: %{
      reason: reason || "protocol_error",
      message: "model response did not match kernel protocol"
    }

  defp turn_fail(%{kind: "transport_error", reason: reason}, _event_data),
    do: %{reason: "transport_error", message: reason || "LLM transport error"}

  defp turn_fail(%{kind: "budget_exhausted"}, _event_data),
    do: %{reason: "llm_budget_exhausted", message: "host LLM-call budget exhausted"}

  defp turn_fail(_action, %{fail: fail}), do: fail
  defp turn_fail(_action, _event_data), do: nil

  defp role_selection_value(selection, key) when is_map(selection), do: Map.get(selection, key)
  defp role_selection_value(_selection, _key), do: nil

  defp role_prelude_projection(nil), do: nil

  defp role_prelude_projection(selection) when is_map(selection) do
    %{
      "selected_refs" => Map.get(selection, :selected_refs, []),
      "resolved_refs" => Map.get(selection, :resolved_refs, [])
    }
  end

  defp role_prelude_call_policy(nil), do: nil

  defp role_prelude_call_policy(selection) when is_map(selection) do
    %{"prelude_store_access" => Map.get(selection, :prelude_store_access)}
  end

  defp prelude_presentation(opts) do
    %{"symbol_inventory_renderer" => Keyword.get(opts, :symbol_inventory_renderer, :default)}
  end

  defp token_value(tokens, key) when is_map(tokens) do
    Map.get(tokens, key, Map.get(tokens, to_string(key)))
  end

  defp token_value(_tokens, _key), do: nil

  defp input_tokens(tokens), do: integer_token_value(tokens, :input)
  defp output_tokens(tokens), do: integer_token_value(tokens, :output)

  defp total_tokens(tokens) do
    case token_value(tokens, :total) do
      total when is_integer(total) ->
        total

      _ ->
        input = input_tokens(tokens)
        output = output_tokens(tokens)

        if is_integer(input) or is_integer(output) do
          (input || 0) + (output || 0)
        end
    end
  end

  defp integer_token_value(tokens, key) do
    case token_value(tokens, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp resolve_system_prompt(args, override) do
    system = override || Map.get(args, "system")

    if is_binary(system) and String.trim(system) != "" do
      system
    else
      raise ExecutionError,
        reason: :missing_system_prompt,
        message: ~s|agent.core must pass a non-empty "system" field to llm-complete|,
        data: %{tool: "llm-complete"}
    end
  end

  defp component(namespace, %Prelude{} = prelude, overrides) do
    %{
      id: namespace,
      source: component_source(namespace, overrides),
      prelude: prelude,
      origin: component_origin(namespace, overrides)
    }
  end

  defp component_source(namespace, overrides) do
    case component_override(namespace, overrides) do
      %{source: source} when is_binary(source) -> source
      %{"source" => source} when is_binary(source) -> source
      {source, _origin} when is_binary(source) -> source
      source when is_binary(source) -> source
      nil -> Map.fetch!(@prelude_sources, namespace)
    end
  end

  defp component_origin(namespace, overrides) do
    case component_override(namespace, overrides) do
      %{origin: origin} -> origin
      %{"origin" => origin} -> origin
      {_source, origin} -> origin
      nil -> {:file, Map.fetch!(@prelude_origin_paths, namespace)}
      _source -> :memory
    end
  end

  defp component_override(namespace, overrides) do
    Map.get(overrides, namespace, Map.get(overrides, String.to_atom(namespace)))
  end

  defp normalize_llm_result({:ok, response}) do
    response
    |> Action.normalize()
    |> Map.put(:transport_error, nil)
  end

  defp normalize_llm_result({:error, _reason}) do
    %{
      kind: "transport_error",
      program: nil,
      reason: "provider_error",
      content: nil,
      tokens: %{},
      model: nil,
      provider: nil,
      provider_meta: %{},
      transport_error: true
    }
  end

  defp normalize_llm_result(response) do
    response
    |> Action.normalize()
    |> Map.put(:transport_error, nil)
  end

  defp memory_byte_cap(opts) do
    case Keyword.get(opts, :kernel_memory_byte_cap, @memory_byte_cap) do
      cap when is_integer(cap) and cap > 0 ->
        {:ok, cap}

      cap ->
        invalid_option(:kernel_memory_byte_cap, cap)
    end
  end

  defp normalize_messages(messages) when is_list(messages),
    do: Enum.map(messages, &normalize_message/1)

  defp normalize_messages(_), do: []

  defp normalize_message(%{} = message) do
    role = message_value(message, "role")
    tool_calls = normalize_tool_calls(message_value(message, "tool_calls"))

    %{}
    |> maybe_put(:role, normalize_role(role))
    |> maybe_put_content(message_value(message, "content"), tool_calls)
    |> maybe_put(:tool_call_id, message_value(message, "tool_call_id"))
    |> maybe_put(:tool_calls, tool_calls)
  end

  defp normalize_message(message), do: message

  defp normalize_role(role) when role in [:system, :user, :assistant, :tool], do: role
  defp normalize_role("system"), do: :system
  defp normalize_role("user"), do: :user
  defp normalize_role("assistant"), do: :assistant
  defp normalize_role("tool"), do: :tool
  defp normalize_role(role), do: role

  defp normalize_tool_calls(nil), do: nil

  defp normalize_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn
      %{} = call ->
        %{
          id: message_value(call, "id"),
          type: message_value(call, "type") || "function",
          function: normalize_tool_call_function(message_value(call, "function"))
        }

      other ->
        other
    end)
  end

  defp normalize_tool_calls(other), do: other

  defp normalize_tool_call_function(%{} = function) do
    %{
      name: message_value(function, "name"),
      arguments: message_value(function, "arguments")
    }
  end

  defp normalize_tool_call_function(function), do: function

  defp message_value(%{} = map, key) when is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key)))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_content(map, nil, tool_calls) when is_list(tool_calls),
    do: Map.put(map, :content, nil)

  defp maybe_put_content(map, content, _tool_calls), do: maybe_put(map, :content, content)

  defp add_public_tool_call(%{kind: "tool_call", program: program} = action) do
    id = "#{Action.tool_name()}_#{System.unique_integer([:positive])}"

    action
    |> Map.put(:tool_call_id, id)
    |> Map.put(:public_tool_call, %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => Action.tool_name(),
        "arguments" => Jason.encode!(%{"program" => program})
      }
    })
  end

  defp add_public_tool_call(action), do: action

  defp eval_program(args, mission, mission_tools, opts, memory_agent, events, turn_recorder) do
    program = Map.fetch!(args, "program")
    turn = fetch_eval_turn!(args)
    started_at = System.monotonic_time(:millisecond)

    case claim_eval_action(turn_recorder, turn, program) do
      nil ->
        unmatched_eval_turn_error(turn)

      {:program_mismatch, action} ->
        result = mismatched_eval_program_error(turn, action)

        record_eval_turn(
          turn_recorder,
          mismatched_eval_action(action, program),
          result,
          nil,
          System.monotonic_time(:millisecond) - started_at
        )

      action ->
        do_eval_program(%{
          program: program,
          action: action,
          mission: mission,
          mission_tools: mission_tools,
          opts: opts,
          memory_agent: memory_agent,
          events: events,
          turn_recorder: turn_recorder,
          started_at: started_at
        })
    end
  end

  defp do_eval_program(%{
         program: program,
         action: action,
         mission: mission,
         mission_tools: mission_tools,
         opts: opts,
         memory_agent: memory_agent,
         events: events,
         turn_recorder: turn_recorder,
         started_at: started_at
       }) do
    {result, event_data} =
      case StateHandle.checkout(memory_agent) do
        {:ok, prior_memory, lease} ->
          try do
            {result, next_memory, event_data} =
              run_inner_program(program, mission, mission_tools, opts, prior_memory)

            :ok = StateHandle.checkin(memory_agent, lease, next_memory)
            {result, event_data}
          rescue
            e ->
              StateHandle.release(memory_agent, lease)
              reraise e, __STACKTRACE__
          catch
            kind, reason ->
              StateHandle.release(memory_agent, lease)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        {:busy, prior_memory} ->
          concurrent_eval_error(prior_memory)
      end

    log_memory_size(events, result)

    record_eval_turn(
      turn_recorder,
      action,
      result,
      event_data,
      System.monotonic_time(:millisecond) - started_at
    )

    result
  end

  defp unmatched_eval_turn_error(turn) do
    eval_contract_error(
      "unmatched_eval_program_turn",
      "eval-program turn #{turn} does not match a pending llm-complete action; call eval-program exactly once for each model tool call.",
      turn
    )
  end

  defp mismatched_eval_program_error(turn, action) do
    eval_contract_error(
      "mismatched_eval_program",
      "eval-program turn #{turn} program does not match the pending llm-complete action.",
      turn,
      %{"expected_program" => action.program}
    )
  end

  defp eval_contract_error(reason, message, turn, details \\ %{}) do
    %{
      "status" => "error",
      "reason" => reason,
      "message" => message,
      "details" => Map.put(details, "turn", turn),
      "prints" => [],
      "memory_summary" => %{
        "defined" => [],
        "defined_count" => 0,
        "changed" => [],
        "changed_count" => 0,
        "entries" => [],
        "truncated" => false,
        "omitted_count" => 0,
        "memory_bytes" => nil
      }
    }
  end

  defp fetch_eval_turn!(args) do
    case Map.fetch(args, "turn") do
      {:ok, turn} when is_integer(turn) and turn >= 0 ->
        turn

      {:ok, turn} ->
        raise ExecutionError,
          reason: :invalid_eval_program_turn,
          message: ~s|agent.core must pass a non-negative integer "turn" to eval-program|,
          data: %{tool: "eval-program", turn: inspect(turn, limit: 5, printable_limit: 100)}

      :error ->
        raise ExecutionError,
          reason: :missing_eval_program_turn,
          message: ~s|agent.core must pass "turn" to eval-program|,
          data: %{tool: "eval-program"}
    end
  end

  defp run_inner_program(program, mission, mission_tools, opts, prior_memory) do
    case Lisp.run_native(program,
           context: Map.get(mission, "context", %{}),
           tools: mission_tools,
           prelude: Keyword.get(opts, :inner_prelude),
           runtime: nil,
           discovery_exec: nil,
           memory: prior_memory,
           preserve_runtime_callables: true,
           link: true,
           timeout: Keyword.get(opts, :inner_timeout, @inner_timeout),
           max_heap: Keyword.get(opts, :inner_max_heap, @inner_heap_words),
           worker_max_heap: Keyword.get(opts, :inner_max_heap, @inner_heap_words),
           max_parallel_workers: @inner_parallel_workers,
           max_tool_calls:
             Keyword.get(opts, :inner_max_tool_calls, Keyword.get(opts, :max_tool_calls))
         ) do
      {:ok, step} -> commit_and_project_step(:ok, step, prior_memory, opts)
      {:error, step} -> commit_and_project_step(:error, step, prior_memory, opts)
    end
  end

  defp concurrent_eval_error(prior_memory) do
    error_step =
      Step.error(
        :concurrent_eval_program,
        "eval-program cannot be called concurrently; run PTC-Lisp programs sequentially.",
        prior_memory,
        %{}
      )

    result =
      project_step(:error, error_step, prior_memory, prior_memory, retained_size(prior_memory))

    {result, event_data(error_step, prior_memory, prior_memory, result, [])}
  end

  defp commit_and_project_step(tag, step, prior_memory, opts) do
    candidate_memory = step.memory
    cap = Keyword.get(opts, :kernel_memory_byte_cap, @memory_byte_cap)
    candidate_bytes = RetainedSize.bytes_with_cap(candidate_memory, cap)

    case candidate_bytes do
      bytes when is_integer(bytes) and bytes <= cap ->
        result =
          project_step(tag, step, prior_memory, candidate_memory, bytes)
          |> validate_return_result(step, opts)

        {result, candidate_memory, event_data(step, prior_memory, candidate_memory, result, opts)}

      bytes ->
        error_step =
          Step.error(
            :memory_limit_exceeded,
            "Kernel PTC-Lisp memory exceeded #{cap} bytes; previous memory was preserved.",
            prior_memory,
            %{limit_bytes: cap, candidate_bytes: candidate_bytes_detail(bytes)}
          )

        result =
          project_step(
            :error,
            error_step,
            prior_memory,
            prior_memory,
            retained_size(prior_memory)
          )

        {result, prior_memory, event_data(error_step, prior_memory, prior_memory, result, opts)}
    end
  end

  defp validate_return_result(
         %{"status" => "return", "value" => value} = result,
         step,
         opts
       ) do
    case Keyword.get(opts, :parsed_signature) do
      nil ->
        result

      parsed_signature ->
        case Signature.validate(parsed_signature, native_return_value(step, value)) do
          :ok -> result
          {:error, errors} -> return_validation_result(result, opts, errors)
        end
    end
  end

  defp validate_return_result(result, _step, _opts), do: result

  defp native_return_value(%{return: {:__ptc_return__, value}}, _projected_value),
    do: Public.value(value)

  defp native_return_value(_step, projected_value), do: projected_value

  defp return_validation_result(result, opts, errors) do
    expected = Keyword.fetch!(opts, :return_type)

    details =
      Enum.map_join(errors, "; ", fn %{path: path, message: message} ->
        location = if path == [], do: "root", else: Enum.join(path, ".")
        "#{location}: #{message}"
      end)

    %{
      "status" => "continue",
      "reason" => "return_validation_failed",
      "message" => "Expected #{expected}; #{details}",
      "prints" => Map.get(result, "prints", []),
      "memory_summary" => Map.get(result, "memory_summary")
    }
  end

  defp event_data(step, prior_memory, current_memory, result, opts) do
    %{
      result_preview: result_preview(result),
      prints: bound_list(Map.get(step, :prints)),
      memory_diff: TurnEvent.memory_diff(prior_memory, current_memory),
      tool_calls: turn_tool_calls(Map.get(step, :tool_calls)),
      catalog_ops: turn_catalog_ops(Map.get(step, :catalog_ops)),
      inner_prelude_call_counts: inner_prelude_call_counts(step, opts),
      fail: eval_projection_fail(result, Map.get(step, :fail))
    }
  end

  defp inner_prelude_call_counts(step, opts) do
    refs = Keyword.get(opts, :inner_prelude_refs, MapSet.new())

    step
    |> Map.get(:prelude_call_counts, %{})
    |> Map.take(MapSet.to_list(refs))
  end

  defp result_preview(%{"value" => value}), do: TurnEvent.preview(value)
  defp result_preview(%{"reason" => reason, "message" => message}), do: "#{reason}: #{message}"
  defp result_preview(result), do: TurnEvent.preview(result)

  defp eval_projection_fail(%{"status" => "fail"} = result, _step_fail) do
    value = Map.get(result, "value")

    %{
      reason: eval_fail_reason(value),
      message: "model program failed"
    }
  end

  defp eval_projection_fail(_result, step_fail), do: step_fail

  defp eval_fail_reason(%{"reason" => reason}) when is_binary(reason), do: reason

  defp eval_fail_reason(%{"reason" => reason}),
    do: inspect(reason, limit: 5, printable_limit: 100)

  defp eval_fail_reason(_value), do: "model_program_failed"

  defp turn_tool_calls(calls) when is_list(calls),
    do: Enum.map(calls, &TurnEvent.tool_call_summary/1)

  defp turn_tool_calls(_), do: []

  defp turn_catalog_ops(ops) when is_list(ops),
    do: Enum.map(ops, &TurnEvent.catalog_op_summary/1)

  defp turn_catalog_ops(_), do: []

  defp project_step(_tag, step, prior_memory, current_memory, memory_bytes) do
    memory_summary = memory_summary(prior_memory, current_memory, memory_bytes)

    cond do
      match?({:__ptc_return__, _}, step.return) ->
        {:__ptc_return__, value} = step.return

        %{
          "status" => "return",
          "value" => public_eval_value(value),
          "prints" => bound_list(step.prints),
          "memory_summary" => memory_summary
        }

      match?({:__ptc_fail__, _}, step.return) ->
        {:__ptc_fail__, value} = step.return

        %{
          "status" => "fail",
          "value" => public_eval_value(value),
          "prints" => bound_list(step.prints),
          "memory_summary" => memory_summary
        }

      step.fail ->
        %{
          "status" => "error",
          "reason" => to_string(step.fail.reason),
          "message" => step.fail.message,
          "details" => public_eval_value(Map.get(step.fail, :details, %{})),
          "prints" => bound_list(step.prints),
          "memory_summary" => memory_summary
        }

      true ->
        %{
          "status" => "continue",
          "value" => public_eval_value(step.return),
          "prints" => bound_list(step.prints),
          "memory_summary" => memory_summary
        }
    end
  end

  defp memory_summary(prior_memory, current_memory, memory_bytes) do
    defined_names = current_memory |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    changed_names =
      current_memory
      |> Enum.filter(fn {name, value} ->
        Map.get(prior_memory, name, :__ptc_missing__) != value
      end)
      |> Enum.map(fn {name, _value} -> to_string(name) end)
      |> Enum.sort()

    {defined, defined_truncated?} = take_bounded(defined_names, @summary_name_limit)
    {changed, changed_truncated?} = take_bounded(changed_names, @summary_name_limit)
    {entry_names, entries_truncated?} = take_bounded(changed_names, @summary_entry_limit)

    {entries, child_truncated?} =
      Enum.map_reduce(entry_names, false, fn name, truncated? ->
        {entry, entry_truncated?} = memory_entry(name, current_memory)
        {entry, truncated? or entry_truncated?}
      end)

    omitted_count =
      max(length(defined_names) - length(defined), 0) +
        max(length(changed_names) - length(entry_names), 0)

    %{
      "defined" => defined,
      "defined_count" => length(defined_names),
      "changed" => changed,
      "changed_count" => length(changed_names),
      "entries" => entries,
      "truncated" =>
        defined_truncated? or changed_truncated? or entries_truncated? or child_truncated?,
      "omitted_count" => omitted_count,
      "memory_bytes" => memory_bytes
    }
  end

  defp memory_entry(name, memory) do
    {_raw_name, value} =
      Enum.find(memory, fn {raw_name, _value} -> to_string(raw_name) == name end)

    {preview, truncated?} =
      Format.to_clojure(value, limit: 4, printable_limit: @summary_preview_chars)

    {%{
       "name" => name,
       "kind" => memory_kind(value),
       "preview" => preview,
       "truncated" => truncated?
     }, truncated?}
  end

  defp memory_kind({:closure, _params, _body, _env, _history, _metadata}), do: "function"
  defp memory_kind({:juxt_fn, fns}) when is_list(fns), do: "function"
  defp memory_kind({:partial_fn, _f, fixed}) when is_list(fixed), do: "function"
  defp memory_kind({tag, _}) when tag in [:complement_fn, :constantly_fn], do: "function"

  defp memory_kind({tag, fns}) when tag in [:comp_fn, :every_pred_fn, :some_fn] and is_list(fns),
    do: "function"

  defp memory_kind({:fnil_fn, _f, _default}), do: "function"
  defp memory_kind(%PtcRunner.Lisp.RuntimeCallable{}), do: "function"
  defp memory_kind(f) when is_function(f), do: "function"
  defp memory_kind(_), do: "value"

  defp public_eval_value(value) do
    value
    |> Public.value()
    |> Jason.encode!()
    |> Jason.decode!()
  rescue
    _ ->
      value
      |> Format.to_clojure(limit: 4, printable_limit: @summary_preview_chars)
      |> elem(0)
  end

  defp take_bounded(list, limit) do
    bounded = Enum.take(list, limit)
    {bounded, length(list) > length(bounded)}
  end

  defp retained_size(value) do
    case RetainedSize.bytes(value) do
      bytes when is_integer(bytes) -> bytes
      :oversized -> 0
    end
  end

  defp candidate_bytes_detail(:oversized), do: "oversized"
  defp candidate_bytes_detail(bytes), do: bytes

  defp log_memory_size(events, %{"memory_summary" => summary}) when is_function(events, 1) do
    events.(%{
      "event" => "memory",
      "memory_bytes" => Map.get(summary, "memory_bytes"),
      "defined_count" => Map.get(summary, "defined_count"),
      "changed_count" => Map.get(summary, "changed_count")
    })
  end

  defp log_memory_size(_events, _result), do: :ok

  defp unwrap_outer_step(step) do
    case step.return do
      {:__ptc_return__, value} ->
        {:ok, value}

      {:__ptc_fail__, %{"reason" => "unknown_action", "action" => action}}
      when is_map(action) ->
        if Map.get(action, "kind", Map.get(action, :kind)) == "budget_exhausted" do
          {:error, %{"reason" => "llm_budget_exhausted"}}
        else
          {:error, %{"reason" => "unknown_action", "action" => action}}
        end

      {:__ptc_fail__, value} ->
        {:error, value}

      other ->
        {:ok, other}
    end
  end

  defp project_public_step(step) do
    %{
      fail: bound_outer_fail(step.fail),
      return: bound_outer_return(step.return),
      prints: step.prints |> bound_list() |> Enum.map(&bound_outer_text/1)
    }
  end

  defp bound_outer_fail(nil), do: nil

  defp bound_outer_fail(fail) when is_map(fail) do
    fail
    |> Map.take([:reason, :message, :details])
    |> Map.update(:message, nil, &bound_outer_text/1)
    |> Map.update(:details, nil, &TurnEvent.preview(&1, limit: 500))
  end

  defp bound_outer_return(nil), do: nil
  defp bound_outer_return(value), do: value |> Public.value() |> TurnEvent.preview(limit: 500)

  defp bound_outer_text(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp bound_outer_text(value), do: TurnEvent.preview(value, limit: 500)

  defp bound_list(list) when is_list(list), do: Enum.take(list, 8)

  defp stop_agent(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
  end
end
