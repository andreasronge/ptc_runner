defmodule Mix.Tasks.Ptc.RunDownstreamTest do
  use ExUnit.Case, async: false

  @root Path.expand("../../..", __DIR__)

  @tag :tmp_dir
  test "starts only the PtcRunner core when a downstream project depends on req_llm", %{
    tmp_dir: dir
  } do
    write_consumer_project(dir)
    {manifest_path, host_path} = write_llm_application(dir)
    File.cp!(Path.join(@root, "mix.lock"), Path.join(dir, "mix.lock"))

    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        ["ptc.run", manifest_path, "--host-config", host_path, "--check"],
        cd: dir,
        env: [
          {"MIX_ENV", "prod"},
          {"MIX_DEPS_PATH", Path.join(@root, "deps")},
          {"MIX_BUILD_PATH", Path.join(dir, "_build")}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "workflow  deepseek  llm  revision downstream-llm-v1"
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
          "model" => "openrouter:deepseek/deepseek-v4-flash",
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
