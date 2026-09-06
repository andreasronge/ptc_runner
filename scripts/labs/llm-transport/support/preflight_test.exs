ExUnit.start()

defmodule PtcRunner.Labs.TransportPreflightTest do
  use ExUnit.Case, async: false
  alias PtcRunner.Labs.TransportPreflight
  @live Path.expand("../live.exs", __DIR__)
  @root_beams PtcRunner.Kernel.Error |> :code.which() |> List.to_string() |> Path.dirname()

  test "live entry refuses absent or empty checkout before opening its environment file" do
    for value <- [nil, ""] do
      {output, status} =
        System.cmd("elixir", ["-pa", @root_beams, @live, "/nonexistent/pilot.env"],
          env: [{"PTC_LLM_HTTP_PATH", value}],
          stderr_to_stdout: true
        )

      assert status != 0
      assert output =~ "set PTC_LLM_HTTP_PATH"
      refute output =~ "load_file"
    end
  end

  test "live entry refuses unavailable transport APIs before opening its environment file" do
    {output, status} =
      System.cmd("elixir", ["-pa", @root_beams, @live, "/nonexistent/pilot.env"],
        env: [{"PTC_LLM_HTTP_PATH", System.tmp_dir!()}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "pilot transport APIs are unavailable"
    refute output =~ "load_file"
  end

  test "evidence refuses dirty checkouts and revisions changed during a probe" do
    directory =
      Path.join(System.tmp_dir!(), "ptc-provenance-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    git!(directory, ["init", "--quiet"])
    file = Path.join(directory, "source.ex")
    File.write!(file, "original\n")
    commit!(directory)
    identity = TransportPreflight.clean_source!(directory)
    assert identity.clean
    assert TransportPreflight.verify_source!(directory, identity) == identity
    File.write!(file, "modified\n")

    assert_raise RuntimeError, ~r/source checkout must be clean/, fn ->
      TransportPreflight.clean_source!(directory)
    end

    commit!(directory)

    assert_raise RuntimeError, ~r/source revision changed/, fn ->
      TransportPreflight.verify_source!(directory, identity)
    end
  end

  defp commit!(directory) do
    git!(directory, ["add", "source.ex"])

    git!(directory, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.hooksPath=/dev/null",
      "commit",
      "--quiet",
      "-m",
      "fixture"
    ])
  end

  defp git!(directory, args) do
    {_output, 0} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
  end
end
