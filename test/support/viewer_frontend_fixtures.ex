defmodule PtcRunner.TestSupport.ViewerFrontendFixtures do
  @moduledoc false

  import ExUnit.Assertions

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome

  def viewer_page_config(base_url) do
    assert {:ok, %{status: 200, body: body}} = Req.get(base_url <> "/")

    [encoded] =
      Regex.run(~r/<meta name="ptc-viewer-config" content="([^"]+)">/, body,
        capture: :all_but_first
      )

    encoded
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
  end

  def viewer_project(directory, viewer_overrides \\ %{}, artifact_overrides \\ %{}) do
    target = Path.join(directory, "demo")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["init", target])
    project_path = Path.join(target, "ptc-project.json")
    assert {:ok, %CommandOutcome{}} = CommandEngine.dispatch(["run", project_path])
    project = Jason.decode!(File.read!(project_path))

    viewer =
      Map.merge(
        %{"port" => 0, "open" => false, "repl" => false, "private" => false},
        viewer_overrides
      )

    artifacts = Map.merge(project["artifacts"] || %{}, artifact_overrides)

    document =
      project
      |> put_in(["viewer"], viewer)
      |> put_in(["artifacts"], artifacts)

    File.write!(project_path, Jason.encode!(document))
    project_path
  end
end
