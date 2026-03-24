defmodule PtcRunner.SubAgent.BuiltinTools do
  @moduledoc """
  Pure functions for resolving builtin tool families into tool maps.

  Extracted from `PtcRunner.SubAgent` to break a runtime dependency cycle
  between `SubAgent`, `Loop`, and `SystemPrompt`.
  """

  @builtin_tool_families %{
    grep: [{"grep", :builtin_grep}, {"grep-n", :builtin_grep_n}]
  }

  @doc """
  Expands a list of builtin tool family atoms to `[{name, sentinel}]` pairs.

  Useful for external modules that need to generate tool descriptions
  for builtins without reaching into SubAgent internals.

  ## Examples

      iex> PtcRunner.SubAgent.BuiltinTools.expand_builtin_tools([:grep])
      [{"grep", :builtin_grep}, {"grep-n", :builtin_grep_n}]

      iex> PtcRunner.SubAgent.BuiltinTools.expand_builtin_tools([])
      []

  """
  @spec expand_builtin_tools([atom()]) :: [{String.t(), atom()}]
  def expand_builtin_tools(families) when is_list(families) do
    Enum.flat_map(families, fn family ->
      case Map.fetch(@builtin_tool_families, family) do
        {:ok, entries} -> entries
        :error -> []
      end
    end)
  end

  @doc """
  Returns the agent's tools with builtin tools injected.

  Merges `llm_query` and `builtin_tools` families into the tools map.
  User-defined tools are never overwritten by builtins.

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "test", builtin_tools: [:grep])
      iex> tools = PtcRunner.SubAgent.BuiltinTools.effective_tools(agent)
      iex> Map.has_key?(tools, "grep")
      true

      iex> agent = PtcRunner.SubAgent.new(prompt: "test", builtin_tools: [:grep], tools: %{"grep" => fn _ -> :custom end})
      iex> tools = PtcRunner.SubAgent.BuiltinTools.effective_tools(agent)
      iex> is_function(tools["grep"])
      true
  """
  @spec effective_tools(map()) :: map()
  def effective_tools(%{tools: _, llm_query: _, builtin_tools: _} = agent) do
    tools = agent.tools

    # Use Map.put_new to avoid overwriting user-defined tools
    tools =
      if agent.llm_query,
        do: Map.put_new(tools, "llm-query", :builtin_llm_query),
        else: tools

    # Expand builtin_tools families
    Enum.reduce(agent.builtin_tools, tools, fn family, acc ->
      case Map.fetch(@builtin_tool_families, family) do
        {:ok, entries} ->
          Enum.reduce(entries, acc, fn {name, sentinel}, inner_acc ->
            Map.put_new(inner_acc, name, sentinel)
          end)

        :error ->
          acc
      end
    end)
  end
end
