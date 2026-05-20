defmodule PtcRunnerMcp.CatalogPrompt do
  @moduledoc false

  alias PtcRunner.PromptLoader

  @prompt_dir Path.expand(Path.join([__DIR__, "..", "..", "priv", "prompts"]))

  @builtin_prompt_specs %{
    summary: "catalog/summary.md",
    list_servers: "catalog/list_servers.md",
    search_tools: "catalog/search_tools.md",
    list_tools: "catalog/list_tools.md",
    describe_tool: "catalog/describe_tool.md"
  }

  @discovery_order [
    :search_tools,
    :list_tools,
    :describe_tool
  ]

  @agentic_order [
    :list_servers,
    :search_tools,
    :list_tools,
    :describe_tool
  ]

  for {_key, relative_path} <- @builtin_prompt_specs do
    @external_resource Path.join(@prompt_dir, relative_path)
  end

  @builtin_prompts Map.new(@builtin_prompt_specs, fn {key, relative_path} ->
                     text =
                       @prompt_dir
                       |> Path.join(relative_path)
                       |> File.read!()
                       |> PromptLoader.extract_content()

                     {key, text}
                   end)

  @doc false
  @spec builtin_keys() :: [atom()]
  def builtin_keys, do: Map.keys(@builtin_prompts)

  @doc false
  @spec builtin_text(atom()) :: String.t() | nil
  def builtin_text(key) when is_atom(key), do: Map.get(@builtin_prompts, key)

  @doc false
  @spec discovery_block() :: String.t()
  def discovery_block do
    """
    Discover tools inside the program:

    #{join_prompts(@discovery_order)}
    `(tool/mcp-call {:server "server-name" :tool "tool-name" :args {...}})` calls the selected upstream tool.\
    """
  end

  @doc false
  @spec agentic_discovery_block() :: String.t()
  def agentic_discovery_block do
    """
    Upstream catalog: not inlined (catalog mode: lazy).
    Discover servers and tools at runtime from inside lisp_eval:
    #{join_prompts(@agentic_order)}
    Then call them with `(tool/mcp-call {:server "<server>" :tool "<tool>" :args {...}})`.
    catalog/* ops have their own budget and never consume the upstream-call quota.\
    """
  end

  defp join_prompts(keys) do
    Enum.map_join(keys, "\n", &Map.fetch!(@builtin_prompts, &1))
  end
end
