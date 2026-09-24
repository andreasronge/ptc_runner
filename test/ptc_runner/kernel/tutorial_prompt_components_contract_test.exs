defmodule PtcRunner.Kernel.TutorialPromptComponentsContractTest do
  alias PtcRunner.TestSupport.TutorialExamplesContractHelpers

  @repo_root TutorialExamplesContractHelpers.repo_root()

  use ExUnit.Case,
    async: true,
    parameterize:
      for(path <- TutorialExamplesContractHelpers.prompt_visible_components(), do: %{path: path})

  @moduletag :operator

  test "a prompt-visible component does not hide stable results behind any", %{path: path} do
    refute File.read!(path) =~ "-> :any", Path.relative_to(path, @repo_root)
  end
end
