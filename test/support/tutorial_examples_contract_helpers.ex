defmodule PtcRunner.TestSupport.TutorialExamplesContractHelpers do
  @moduledoc false

  @repo_root Path.expand("../..", __DIR__)

  def host_installations do
    ["examples", "scripts/labs"]
    |> Enum.flat_map(&Path.wildcard(Path.join([@repo_root, &1, "**", "*.json"])))
    |> Enum.flat_map(fn path ->
      case Jason.decode(File.read!(path)) do
        {:ok, %{"install" => install}} when is_map(install) ->
          for {alias_name, %{"model" => model}} <- install,
              do: {path, alias_name, model}

        _ ->
          []
      end
    end)
    |> Enum.sort()
  end

  def prompt_visible_components do
    @repo_root
    |> Path.join("examples/**/*.clj")
    |> Path.wildcard()
    |> Enum.filter(&(File.read!(&1) =~ ":visibility :prompt"))
  end

  def repo_root, do: @repo_root
end
