defmodule PtcRunnerMcp.Agentic.Prompt do
  @moduledoc """
  System prompt assembly for SubAgent-backed `ptc_task`.

  MCP-controlled sections are ordered here so operator prefix/suffix text cannot
  replace the terminal or upstream-call contract.
  """

  alias PtcRunnerMcp.PromptRegistry

  @type assembled :: %{
          required(:system_prompt) => String.t(),
          required(:user_message) => String.t(),
          required(:tool_rendering) => map()
        }

  @doc """
  Builds the SubAgent prompt payload for one `ptc_task` call.
  """
  @spec assemble(map(), keyword()) :: assembled()
  def assemble(validated, opts \\ []) when is_map(validated) do
    %{
      system_prompt: system_prompt(opts),
      user_message: user_message(validated),
      tool_rendering: tool_rendering()
    }
  end

  @doc """
  Builds the ordered MCP-controlled system prompt.
  """
  @spec system_prompt(keyword()) :: String.t()
  def system_prompt(opts \\ []) do
    PromptRegistry.render(:mcp_agentic_task_prompt, opts)
  end

  @doc """
  Metadata for the later SubAgent adapter.

  `ptc_task` owns the authoritative `mcp-call` card, so a generic SubAgent
  renderer should not add a second tool description for this tool.
  """
  @spec tool_rendering() :: map()
  def tool_rendering do
    %{
      "suppress_generic_tools" => ["mcp-call"],
      "authoritative_tool_contracts" => ["mcp-call"]
    }
  end

  @doc """
  Builds the user message for a single `ptc_task` request.
  """
  @spec user_message(map()) :: String.t()
  def user_message(%{task: task} = validated) do
    context = Map.get(validated, :context, %{})
    constraints = Map.get(validated, :constraints, %{})

    """
    Task:
    #{task}

    Context JSON:
    #{Jason.encode!(context)}

    Constraints JSON:
    #{Jason.encode!(constraints)}
    """
    |> String.trim()
  end
end
