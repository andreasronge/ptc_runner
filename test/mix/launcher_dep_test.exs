defmodule PtcRunner.Mix.LauncherDepTest do
  use ExUnit.Case, async: true

  # Dependabot's Hex updater copies the mix files it fetched into a scratch
  # directory and loads the project there. `ptc_runner_launcher/mix.exs` is
  # fetched because the checkout declares it as a path dependency, but its
  # sibling `release_config.exs` is not a mix file and never comes along, so
  # every update run died in `Code.eval_file/1` before resolving a dependency.
  @moduletag :tmp_dir
  @moduletag :slow

  @root Path.expand("../..", __DIR__)
  @fetched_mix_files ["mix.exs", "mix.lock", "ptc_runner_launcher/mix.exs"]
  @probe "Mix.Project.config()[:deps] |> List.keyfind(:ptc_runner_launcher, 0) |> inspect() |> IO.puts()"

  test "the project loads from the mix files alone, without the launcher's version file", %{
    tmp_dir: directory
  } do
    stage(directory, @fetched_mix_files)

    assert {output, 0} = load_project(directory)
    assert output =~ ~s({:ptc_runner_launcher, "~> 0.1.0", [optional: true]})
  end

  test "a complete launcher checkout is still used as a path dependency", %{tmp_dir: directory} do
    stage(directory, ["ptc_runner_launcher/release_config.exs" | @fetched_mix_files])

    assert {output, 0} = load_project(directory)
    assert output =~ "path: \"ptc_runner_launcher\""
  end

  defp stage(directory, files) do
    for file <- files do
      target = Path.join(directory, file)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(@root, file), target)
    end
  end

  defp load_project(directory) do
    System.cmd("mix", ["run", "--no-deps-check", "--no-compile", "--no-start", "-e", @probe],
      cd: directory,
      # GitHub Actions exports GITHUB_SHA to every step. It is workflow
      # context, not an explicit hermetic-build input, and must not turn this
      # config-only scratch directory into a partial source-identity build.
      env: [
        {"GITHUB_SHA", String.duplicate("a", 40)},
        {"MIX_ENV", "dev"},
        {"MIX_QUIET", "1"}
      ],
      stderr_to_stdout: true
    )
  end
end
