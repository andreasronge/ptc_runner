defmodule Mix.Tasks.Ptc.RunDownstreamTest do
  use ExUnit.Case, async: false

  @root Path.expand("../../..", __DIR__)

  # The consumer project lives in a fresh tmp_dir each run, but its prod build
  # is cached here instead. Pointing MIX_BUILD_PATH inside tmp_dir rebuilt
  # PtcRunner from scratch under MIX_ENV=prod on every suite run, which cost
  # ~40 s -- more than any other single test. PtcRunner enters the build as a
  # path dependency on the stable @root, so Mix's own staleness checks still
  # recompile it whenever the library sources change.
  @build_path Path.join(@root, "_build/downstream_consumer")

  # `:nightly` because the assertion is only observable through a real
  # `mix ptc run` in a separate OS process against a real prod build. The cached
  # build above holds a warm run to ~5.5 s, but the cache is per-worktree and
  # PtcRunner is a path dependency, so a fresh clone or any library change pays
  # the full compile: 61.1 s measured on CI, where the cache misses on every
  # library change. That is the single most expensive test in the suite.
  @tag :tmp_dir
  @tag :nightly
  test "starts only the PtcRunner core when a downstream project depends on req_llm", %{
    tmp_dir: dir
  } do
    write_consumer_project(dir)
    {manifest_path, host_path} = write_llm_application(dir)
    File.cp!(Path.join(@root, "mix.lock"), Path.join(dir, "mix.lock"))

    env = [
      {"MIX_ENV", "prod"},
      {"MIX_DEPS_PATH", Path.join(@root, "deps")},
      {"MIX_BUILD_PATH", @build_path}
    ]

    # Build the consumer in its own invocation. Mix reports compilation progress
    # on standard output, so a cold `@build_path` -- every fresh clone, and every
    # CI run -- would otherwise prefix the closed run envelope with build noise.
    {build_output, build_status} =
      System.cmd(System.find_executable("mix"), ["compile"],
        cd: dir,
        env: env,
        stderr_to_stdout: true
      )

    assert build_status == 0, build_output

    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        ["ptc", "run", manifest_path, "--host-config", host_path],
        cd: dir,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert Jason.decode!(output) == %{}
  end

  defp write_consumer_project(dir) do
    File.write!(
      Path.join(dir, "mix.exs"),
      """
      defmodule Downstream.MixProject do
        use Mix.Project

        def project do
          [
            app: :downstream,
            version: "0.1.0",
            elixir: "~> 1.15",
            deps: [
              {:ptc_runner, path: #{inspect(@root)}},
              {:req_llm, path: #{inspect(Path.join(@root, "deps/req_llm"))}, override: true}
            ]
          ]
        end

        def application, do: [extra_applications: [:logger]]
      end
      """
    )
  end

  defp write_llm_application(dir) do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return input))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{"workflow" => [%{"name" => "deepseek"}]}
    }

    host = %{
      "credentials" => %{"key" => %{"literal" => "downstream-test-secret"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "installation_revision" => "downstream-llm-v1",
          "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
          "credential" => "key"
        }
      }
    }

    manifest_path = Path.join(dir, "ptc.json")
    host_path = Path.join(dir, "host.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(host_path, Jason.encode!(host))
    {manifest_path, host_path}
  end
end
