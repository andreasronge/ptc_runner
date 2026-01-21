defmodule PtcRunner.SubAgent.Compiler do
  @moduledoc """
  Compilation logic for SubAgents.

  This module provides the `compile/2` function that transforms a SubAgent into
  a `CompiledAgent` by running it once with an LLM to derive the PTC-Lisp program.
  The resulting CompiledAgent can then be executed many times without further LLM calls.

  ## SubAgentTools Support

  Compiled agents can include SubAgentTools. The orchestrator's PTC-Lisp code is
  deterministic (sequencing tool calls), while SubAgentTools execute their child
  agents with an LLM at runtime.

  When executing a compiled agent with SubAgentTools, pass the LLM at runtime:

      {:ok, compiled} = SubAgent.compile(orchestrator, llm: compile_llm)
      compiled.execute.(%{topic: "cats"}, llm: runtime_llm)

  See `PtcRunner.SubAgent.compile/2` for the public API.
  """

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.CompiledAgent
  alias PtcRunner.SubAgent.Loop.ToolNormalizer
  alias PtcRunner.SubAgent.{SubAgentTool, Telemetry}

  @doc """
  Compiles a SubAgent into a reusable PTC-Lisp function.

  The LLM is called once during compilation to derive the logic. The resulting
  `CompiledAgent` can then be executed many times without further LLM calls,
  making it efficient for processing many items with deterministic logic.

  ## Requirements

  - `max_turns: 1` - Only single-shot agents can be compiled
  - `output: :ptc_lisp` - Only PTC-Lisp output mode (not `:json`)

  ## Tool Support

  - Pure Elixir tools - Supported, executed directly
  - `LLMTool` - NOT supported (raises ArgumentError)
  - `SubAgentTool` - Supported if child agent has no `mission_timeout`

  When SubAgentTools are present, the compiled agent requires an `llm` option
  at execute time for the child agents.

  ## Options

  - `llm` - Required. LLM callback used once during compilation. Can be a function or atom.
  - `llm_registry` - Required if `llm` is an atom. Maps atoms to LLM callbacks.
  - `sample` - Optional sample data to help LLM understand the input structure (default: %{})

  ## Returns

  - `{:ok, CompiledAgent.t()}` - Successfully compiled agent
  - `{:error, Step.t()}` - Compilation failed (agent execution failed)

  ## Examples

      iex> tools = %{"double" => fn %{"n" => n} -> n * 2 end}
      iex> agent = PtcRunner.SubAgent.new(
      ...>   prompt: "Double the input number {{n}}",
      ...>   signature: "(n :int) -> {result :int}",
      ...>   tools: tools,
      ...>   max_turns: 1
      ...> )
      iex> mock_llm = fn _ -> {:ok, ~S|(return {:result (tool/double {:n data/n})})|} end
      iex> {:ok, compiled} = PtcRunner.SubAgent.Compiler.compile(agent, llm: mock_llm, sample: %{n: 5})
      iex> compiled.signature
      "(n :int) -> {result :int}"
      iex> is_binary(compiled.source)
      true
      iex> is_function(compiled.execute, 2)
      true
      iex> result = compiled.execute.(%{n: 10}, [])
      iex> result.return.result
      20

  Rejects agents with LLM-dependent tools:

      iex> alias PtcRunner.SubAgent.LLMTool
      iex> tools = %{"classify" => LLMTool.new(prompt: "Classify {{x}}", signature: "(x :string) -> :string")}
      iex> agent = PtcRunner.SubAgent.new(prompt: "Process {{item}}", signature: "(item :string) -> {category :string}", tools: tools, max_turns: 1)
      iex> PtcRunner.SubAgent.Compiler.compile(agent, llm: fn _ -> {:ok, ""} end)
      ** (ArgumentError) cannot compile agent with LLM-dependent tool: classify
  """
  @spec compile(SubAgent.t(), keyword()) ::
          {:ok, CompiledAgent.t()} | {:error, PtcRunner.Step.t()}
  def compile(%SubAgent{max_turns: max_turns}, _opts) when max_turns != 1 do
    raise ArgumentError, "only single-shot agents (max_turns: 1) can be compiled"
  end

  def compile(%SubAgent{output: :json}, _opts) do
    raise ArgumentError, "only PTC-Lisp agents (output: :ptc_lisp) can be compiled"
  end

  def compile(%SubAgent{} = agent, opts) do
    # Validate that all tools are compilable (no LLM-dependent tools)
    validate_compilable_tools!(agent.tools)

    # Get sample data for compilation - auto-generate from signature if not provided
    user_sample = Keyword.get(opts, :sample, %{})
    sample = build_sample_data(agent, user_sample)

    # Run the agent once to derive the PTC-Lisp program
    case SubAgent.run(agent, Keyword.put(opts, :context, sample)) do
      {:ok, step} ->
        # Extract the final program from the turns
        source = extract_final_program(step.turns)

        # Separate pure tools from SubAgentTools using single pass
        {sub_agent_list, pure_list} =
          Enum.split_with(agent.tools, fn {_, t} -> match?(%SubAgentTool{}, t) end)

        pure_tools = Map.new(pure_list)
        sub_agent_tools = Map.new(sub_agent_list)
        llm_required = map_size(sub_agent_tools) > 0

        # Build executor function that runs the compiled program
        # Include system tools (return/fail) as they're needed at runtime
        # Both return sentinel tuples for consistency with loop detection
        system_tools = %{
          "return" => fn args -> {:__ptc_return__, args} end,
          "fail" => fn args -> {:__ptc_fail__, args} end
        }

        # Capture field_descriptions for populating in the returned step
        field_descs = agent.field_descriptions

        execute = fn args, opts_runtime ->
          # Runtime validation for SubAgentTools
          llm = Keyword.get(opts_runtime, :llm)
          llm_registry = Keyword.get(opts_runtime, :llm_registry, %{})

          if llm_required do
            validate_runtime_llm!(llm, llm_registry)
            validate_llm_registry_for_sub_agents!(sub_agent_tools, llm, llm_registry)
          end

          # Inherit context from caller (when CompiledAgent used inside another agent)
          nesting_depth = Keyword.get(opts_runtime, :_nesting_depth, 0)
          remaining_turns = Keyword.get(opts_runtime, :_remaining_turns)
          mission_deadline = Keyword.get(opts_runtime, :_mission_deadline)

          # Build runtime tools
          runtime_tools =
            if llm_required do
              # Build state for ToolNormalizer (same structure as Loop state)
              state = %{
                llm: llm,
                llm_registry: llm_registry,
                nesting_depth: nesting_depth,
                remaining_turns: remaining_turns,
                mission_deadline: mission_deadline
              }

              # Reuse ToolNormalizer to wrap SubAgentTools (includes telemetry)
              wrapped_sub_agents = ToolNormalizer.normalize(sub_agent_tools, state, agent)
              pure_tools |> Map.merge(wrapped_sub_agents) |> Map.merge(system_tools)
            else
              pure_tools |> Map.merge(system_tools)
            end

          # Wrap entire execution in telemetry span
          Telemetry.span([:compiled, :execute], %{agent: agent}, fn ->
            result =
              args
              |> run_and_unwrap(source, runtime_tools)
              |> add_field_descriptions(field_descs)

            {result, %{agent: agent, status: step_status(result)}}
          end)
        end

        # Build metadata from the compilation step
        metadata = build_compilation_metadata(step, opts)

        {:ok,
         %CompiledAgent{
           source: source,
           signature: agent.signature,
           execute: execute,
           metadata: metadata,
           field_descriptions: agent.field_descriptions,
           llm_required?: llm_required
         }}

      {:error, step} ->
        {:error, step}
    end
  end

  # Validates that all tools are compilable
  # - Rejects LLMTool (always requires LLM)
  # - Allows SubAgentTool but rejects if mission_timeout is set
  defp validate_compilable_tools!(tools) do
    Enum.each(tools, fn
      {name, %PtcRunner.SubAgent.LLMTool{}} ->
        raise ArgumentError, "cannot compile agent with LLM-dependent tool: #{name}"

      {name, %SubAgentTool{agent: agent}} ->
        if agent.mission_timeout do
          raise ArgumentError,
                "cannot compile agent with SubAgentTool that has mission_timeout: #{name}"
        end

      {_name, _other} ->
        :ok
    end)
  end

  # Validate runtime LLM is provided and in registry if it's an atom
  defp validate_runtime_llm!(nil, _llm_registry) do
    raise ArgumentError, "llm required for compiled agents with SubAgentTools"
  end

  defp validate_runtime_llm!(llm, llm_registry) when is_atom(llm) do
    unless Map.has_key?(llm_registry, llm) do
      raise ArgumentError,
            "Runtime LLM :#{llm} is not in llm_registry. " <>
              "Pass llm_registry: %{#{llm}: &callback/1}"
    end
  end

  defp validate_runtime_llm!(_llm, _llm_registry), do: :ok

  # Validate that atom LLMs used by SubAgentTools are in the registry
  defp validate_llm_registry_for_sub_agents!(sub_agent_tools, _llm, llm_registry) do
    Enum.each(sub_agent_tools, fn {name, %SubAgentTool{agent: agent, bound_llm: bound_llm}} ->
      # Check agent.llm (highest priority)
      if is_atom(agent.llm) and agent.llm != nil and not Map.has_key?(llm_registry, agent.llm) do
        raise ArgumentError,
              "SubAgentTool #{name} requires LLM :#{agent.llm} which is not in llm_registry"
      end

      # Check bound_llm (second priority)
      if is_atom(bound_llm) and bound_llm != nil and not Map.has_key?(llm_registry, bound_llm) do
        raise ArgumentError,
              "SubAgentTool #{name} requires LLM :#{bound_llm} which is not in llm_registry"
      end
    end)
  end

  # Runs the compiled program and unwraps any return/fail sentinels
  defp run_and_unwrap(args, source, tools) do
    case PtcRunner.Lisp.run(source, context: args, tools: tools) do
      {:ok, step} -> SubAgent.unwrap_sentinels(step)
      {:error, step} -> {:error, step}
    end
  end

  # Adds field_descriptions to the step regardless of success/error
  defp add_field_descriptions({:ok, step}, field_descs),
    do: %{step | field_descriptions: field_descs}

  defp add_field_descriptions({:error, step}, field_descs),
    do: %{step | field_descriptions: field_descs}

  # Determine status for telemetry from step result
  defp step_status(%{fail: nil}), do: :ok
  defp step_status(_), do: :error

  # Extracts the final PTC-Lisp program from the turns
  defp extract_final_program(turns) when is_list(turns) do
    turns
    |> List.last()
    |> Map.get(:program)
  end

  # Builds compilation metadata from the step
  defp build_compilation_metadata(step, opts) do
    %{
      compiled_at: DateTime.utc_now(),
      tokens_used: get_in(step, [Access.key(:usage), Access.key(:total_tokens)]) || 0,
      turns: get_in(step, [Access.key(:usage), Access.key(:turns)]) || 1,
      llm_model: extract_llm_model(opts[:llm])
    }
  end

  # Extracts LLM model name from options
  defp extract_llm_model(llm) when is_atom(llm), do: to_string(llm)
  defp extract_llm_model(_), do: nil

  # Builds sample data for compilation by merging user-provided sample with
  # auto-generated defaults from the signature. User values take precedence.
  defp build_sample_data(%SubAgent{parsed_signature: nil}, user_sample), do: user_sample

  defp build_sample_data(%SubAgent{parsed_signature: {:signature, params, _}}, user_sample) do
    # Generate default sample values for each input parameter
    generated =
      params
      |> Enum.map(fn {name, type} -> {name, default_sample_for_type(type)} end)
      |> Map.new()

    # User-provided values take precedence
    Map.merge(generated, stringify_keys(user_sample))
  end

  defp build_sample_data(_agent, user_sample), do: user_sample

  # Ensure keys are strings for consistency
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # Generate a sensible default sample value for each type
  defp default_sample_for_type(:string), do: "example"
  defp default_sample_for_type(:int), do: 42
  defp default_sample_for_type(:float), do: 3.14
  defp default_sample_for_type(:bool), do: true
  defp default_sample_for_type(:any), do: "value"
  defp default_sample_for_type({:list, inner}), do: [default_sample_for_type(inner)]
  defp default_sample_for_type({:optional, inner}), do: default_sample_for_type(inner)

  defp default_sample_for_type({:map, fields}) when is_list(fields) do
    Map.new(fields, fn {name, type} -> {name, default_sample_for_type(type)} end)
  end

  defp default_sample_for_type(_), do: "value"
end
