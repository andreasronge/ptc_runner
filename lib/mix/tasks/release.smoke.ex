defmodule Mix.Tasks.Release.Smoke do
  @shortdoc "Run local release smoke checks"
  @moduledoc """
  Runs the local release-readiness smoke checks used before pushing a release tag.

      mix release.smoke

  This task does not publish anything. It runs deterministic root release checks,
  root and MCP memory soak checks, then builds and smoke-tests the sibling
  `mcp_server` release binary.

  The MCP smoke builds `mcp_server` with `MIX_ENV=prod mix release --overwrite`
  and then runs `mcp_server/test/integration/release_stdio_test.exs` against the
  built binary. Set `PTC_SOAK_ITERATIONS` to tune soak duration; it defaults to
  `3000`.
  """

  use Mix.Task

  @requirements []
  @recursive true

  @package_dir Path.join(["tmp", "hex-unpack"])
  @required_package_paths [
    "priv/prompts",
    "priv/spec",
    "priv/ptc_schema.json",
    "docs",
    "docs/function-reference.md",
    "docs/java-interop.md",
    "docs/conformance/index.md",
    "README.md",
    "CHANGELOG.md"
  ]

  @impl Mix.Task
  def run(args) do
    reject_args!(args)

    Mix.shell().info("==> local release smoke")

    root_checks()
    mcp_server_smoke()

    Mix.shell().info("\nRelease smoke complete.")
  end

  defp reject_args!([]), do: :ok

  defp reject_args!(args) do
    Mix.raise("mix release.smoke does not accept arguments, got: #{Enum.join(args, " ")}")
  end

  defp root_checks do
    version = project_version()

    Mix.shell().info("==> verify CHANGELOG.md has ## [#{version}]")

    assert!(
      changelog_has_version?(version),
      "CHANGELOG.md is missing a ## [#{version}] heading"
    )

    run!("mix", ["test"], env: [{"MIX_ENV", "test"}])
    run!("mix", ["test", "--only", "soak"], env: soak_env())
    run!("mix", ["hex.build", "--unpack", "--output", @package_dir])
    verify_package_contents!()

    assert_no_new_diff!(["priv/ptc_schema.json"], fn ->
      run!("mix", ["schema.gen"])
    end)

    run!("mix", ["ptc.validate_spec"])
    run!("mix", ["bench.check"])
    run!("mix", ["docs", "--warnings-as-errors"], env: [{"MIX_ENV", "dev"}])

    assert_no_new_diff!(["docs/", "conformance_inventory.json"], fn ->
      run!("mix", ["ptc.gen_docs"])
      run!("mix", ["ptc.conformance_report", "--write-inventory"])
    end)
  end

  defp mcp_server_smoke do
    run!("mix", ["deps.get"], cd: "mcp_server")
    run!("mix", ["test"], cd: "mcp_server", env: [{"MIX_ENV", "test"}])

    run!(
      "mix",
      [
        "test",
        "--only",
        "soak",
        "test/soak/session_churn_soak_test.exs",
        "test/soak/many_turns_soak_test.exs",
        "test/soak/http_mcp_soak_test.exs"
      ],
      cd: "mcp_server",
      env: soak_env()
    )

    run!("mix", ["release", "--overwrite"], cd: "mcp_server", env: [{"MIX_ENV", "prod"}])

    run!("mix", ["test", "--include", "integration", "test/integration/release_stdio_test.exs"],
      cd: "mcp_server",
      env: [{"MIX_ENV", "test"}]
    )
  end

  defp project_version do
    Mix.Project.config()
    |> Keyword.fetch!(:version)
  end

  defp soak_env do
    [
      {"MIX_ENV", "test"},
      {"PTC_SOAK_ITERATIONS", System.get_env("PTC_SOAK_ITERATIONS", "3000")}
    ]
  end

  defp changelog_has_version?(version) do
    case File.read("CHANGELOG.md") do
      {:ok, changelog} ->
        Regex.match?(~r/^## \[#{Regex.escape(version)}\]/m, changelog)

      {:error, _reason} ->
        false
    end
  end

  defp verify_package_contents! do
    Mix.shell().info("==> verify Hex package contents")

    assert!(
      File.dir?(Path.join(@package_dir, "lib")),
      "mix hex.build --unpack did not create the expected package tree at #{@package_dir}"
    )

    missing =
      Enum.reject(@required_package_paths, fn path ->
        File.exists?(Path.join(@package_dir, path))
      end)

    assert!(missing == [], "Hex package is missing: #{Enum.join(missing, ", ")}")
  end

  defp run!(command, args, opts \\ []) do
    cd = Keyword.get(opts, :cd, File.cwd!())
    env = Keyword.get(opts, :env, [])

    Mix.shell().info("==> #{display_command(command, args, cd)}")

    case System.cmd(command, args, cd: cd, env: env, into: IO.stream(:stdio, :line)) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("#{display_command(command, args, cd)} failed: #{status}")
    end
  end

  defp assert_no_new_diff!(paths, fun) do
    before = git_diff(paths)
    before_status = git_status(paths)
    fun.()
    after_diff = git_diff(paths)
    after_status = git_status(paths)

    assert!(
      before == after_diff and before_status == after_status,
      "generated-file drift changed for #{Enum.join(paths, ", ")}"
    )
  end

  defp git_diff(paths) do
    args = ["diff", "--" | paths]

    case System.cmd("git", args) do
      {output, 0} -> output
      {output, status} -> Mix.raise("git #{Enum.join(args, " ")} failed: #{status}\n#{output}")
    end
  end

  defp git_status(paths) do
    args = ["status", "--porcelain", "--" | paths]

    case System.cmd("git", args) do
      {output, 0} -> output
      {output, status} -> Mix.raise("git #{Enum.join(args, " ")} failed: #{status}\n#{output}")
    end
  end

  defp display_command(command, args, cd) do
    command = Enum.join([command | args], " ")

    case Path.relative_to_cwd(cd) do
      "." -> command
      relative -> "cd #{relative} && #{command}"
    end
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: Mix.raise(message)
end
