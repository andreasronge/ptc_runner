defmodule PtcRunner.Kernel.TutorialExamplesContractTest do
  use ExUnit.Case, async: true
  @moduletag :operator

  alias PtcRunner.TestSupport.TutorialExamplesContractHelpers

  @root TutorialExamplesContractHelpers.repo_root()

  test "each shipped example label matches the host selected by its project" do
    installations = TutorialExamplesContractHelpers.host_installations()
    assert length(installations) >= 12

    for root <- ["examples", "scripts/labs"],
        path <- Path.wildcard(Path.join([@root, root, "**", "*.json"])) do
      case decode!(path) do
        %{
          "kind" => "ptc-project",
          "host" => %{"path" => host},
          "application" => %{"path" => application}
        } ->
          directory = Path.dirname(path)
          host_path = Path.expand(host, directory)
          application_path = Path.expand(application, directory)
          label = get_in(decode!(application_path), ["labels", "model"])

          if label do
            assert Enum.any?(installations, fn {installed_host, _alias, model} ->
                     installed_host == host_path and model == label
                   end),
                   application_path
          end

        _ ->
          :ok
      end
    end

    viewer = Path.join(@root, "scripts/labs/viewer-demo")
    host = Path.join(viewer, "ptc-host.json")
    models = for {^host, _alias, model} <- installations, do: model

    for path <- Path.wildcard(Path.join(viewer, "*.json")),
        label = get_in(decode!(path), ["labels", "model"]),
        label do
      assert label in models, path
    end
  end

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()
end
