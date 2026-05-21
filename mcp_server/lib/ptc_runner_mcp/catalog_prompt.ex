defmodule PtcRunnerMcp.CatalogPrompt do
  @moduledoc false

  alias PtcRunner.PromptLoader

  @prompt_dir Path.expand(Path.join([__DIR__, "..", "..", "priv", "prompts"]))

  @builtin_prompt_specs %{
    discovery: "catalog/discovery.md",
    agentic_discovery: "catalog/agentic_discovery.md"
  }

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
    Map.fetch!(@builtin_prompts, :discovery)
  end

  @doc false
  @spec agentic_discovery_block() :: String.t()
  def agentic_discovery_block do
    Map.fetch!(@builtin_prompts, :agentic_discovery)
  end
end
