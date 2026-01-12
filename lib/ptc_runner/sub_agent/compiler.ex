defmodule PtcRunner.SubAgent.Compiler do
  @moduledoc """
  Compilation logic for SubAgents.

  This module provides the `compile/2` function that transforms a SubAgent into
  a `CompiledAgent` by running it once with an LLM to derive the PTC-Lisp program.
  The resulting CompiledAgent can then be executed many times without further LLM calls.

  See `PtcRunner.SubAgent.compile/2` for the public API.
  """

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.CompiledAgent

  @doc """
  Compiles a SubAgent into a reusable PTC-Lisp function.

  The LLM is called once during compilation to derive the logic. The resulting
  `CompiledAgent` can then be executed many times without further LLM calls,
  making it efficient for processing many items with deterministic logic.

  ## Restrictions

  Only agents with pure tools can be compiled. Agents with LLM-dependent tools
  will raise `ArgumentError`:
  - `LLMTool` - requires LLM at execution time
  - `SubAgentTool` - requires LLM at execution time

  ## Options

  - `llm` - Required. LLM callback used once during compilation. Can be a function or atom.
  - `llm_registry` - Required if `llm` is an atom. Maps atoms to LLM callbacks.
  - `sample` - Optional sample data to help LLM understand the input structure (default: %{})

  ## Returns

  - `{:ok, CompiledAgent.t()}` - Successfully compiled agent
  - `{:error, Step.t()}` - Compilation failed (agent execution failed)

  ## Examples

      iex> tools = %{"double" => fn %{n: n} -> n * 2 end}
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
      iex> is_function(compiled.execute, 1)
      true
      iex> result = compiled.execute.(%{n: 10})
      iex> result.return.result
      20

  Rejects agents with LLM-dependent tools:

      iex> alias PtcRunner.SubAgent.LLMTool
      iex> tools = %{"classify" => LLMTool.new(prompt: "Classify {{x}}", signature: "(x :string) -> :string")}
      iex> agent = PtcRunner.SubAgent.new(prompt: "Process {{item}}", signature: "(item :string) -> {category :string}", tools: tools)
      iex> PtcRunner.SubAgent.Compiler.compile(agent, llm: fn _ -> {:ok, ""} end)
      ** (ArgumentError) cannot compile agent with LLM-dependent tool: classify
  """
  @spec compile(SubAgent.t(), keyword()) ::
          {:ok, CompiledAgent.t()} | {:error, PtcRunner.Step.t()}
  def compile(%SubAgent{} = agent, opts) do
    # Validate that all tools are compilable (no LLM-dependent tools)
    validate_compilable_tools!(agent.tools)

    # Get sample data for compilation
    sample = Keyword.get(opts, :sample, %{})

    # Run the agent once to derive the PTC-Lisp program
    case SubAgent.run(agent, Keyword.put(opts, :context, sample)) do
      {:ok, step} ->
        # Extract the final program from the turns
        source = extract_final_program(step.turns)

        # Build executor function that runs the compiled program
        # Include system tools (return/fail) as they're needed at runtime
        # Both return sentinel tuples for consistency with loop detection
        system_tools = %{
          "return" => fn args -> {:__ptc_return__, args} end,
          "fail" => fn args -> {:__ptc_fail__, args} end
        }

        all_tools = Map.merge(agent.tools, system_tools)

        # Capture field_descriptions for populating in the returned step
        field_descs = agent.field_descriptions

        execute = fn args ->
          args
          |> run_and_unwrap(source, all_tools)
          |> add_field_descriptions(field_descs)
        end

        # Build metadata from the compilation step
        metadata = build_compilation_metadata(step, opts)

        {:ok,
         %CompiledAgent{
           source: source,
           signature: agent.signature,
           execute: execute,
           metadata: metadata,
           field_descriptions: agent.field_descriptions
         }}

      {:error, step} ->
        {:error, step}
    end
  end

  # Validates that all tools are compilable (no LLM-dependent tools)
  defp validate_compilable_tools!(tools) do
    Enum.each(tools, fn
      {name, %PtcRunner.SubAgent.LLMTool{}} ->
        raise ArgumentError, "cannot compile agent with LLM-dependent tool: #{name}"

      {name, %PtcRunner.SubAgent.SubAgentTool{}} ->
        raise ArgumentError, "cannot compile agent with LLM-dependent tool: #{name}"

      {_name, _other} ->
        :ok
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
end
