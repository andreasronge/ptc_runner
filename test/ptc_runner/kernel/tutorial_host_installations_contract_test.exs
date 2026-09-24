defmodule PtcRunner.Kernel.TutorialHostInstallationsContractTest do
  alias PtcRunner.TestSupport.TutorialExamplesContractHelpers

  @repo_root TutorialExamplesContractHelpers.repo_root()

  use ExUnit.Case,
    async: true,
    parameterize:
      for(
        {host, alias_name, model} <- TutorialExamplesContractHelpers.host_installations(),
        do: %{host: host, alias_name: alias_name, model: model}
      )

  @moduletag :operator

  test "a shipped host installation belongs to ReqLLM's catalog", %{
    host: host,
    alias_name: alias_name,
    model: model
  } do
    assert {:ok, _catalog_model} = LLMDB.model(model),
           "#{Path.relative_to(host, @repo_root)} installs #{alias_name}"
  end
end
