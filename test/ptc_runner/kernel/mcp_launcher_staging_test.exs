defmodule PtcRunner.Kernel.MCPLauncherStagingTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPLauncherStaging

  test "owner death removes private launcher staging" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, staging} = MCPLauncherStaging.start(self(), 5_000)
        send(parent, {:staging, staging})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:staging, staging}
    staging_ref = Process.monitor(staging.pid)
    File.write!(staging.path, "fixture")
    assert File.exists?(staging.path)

    send(owner, :stop)
    assert_receive {:DOWN, ^staging_ref, :process, _, :normal}
    refute File.exists?(staging.path)
    refute File.exists?(Path.dirname(staging.path))
  end

  test "explicit close removes private launcher staging" do
    {:ok, staging} = MCPLauncherStaging.start(self(), 5_000)
    File.write!(staging.path, "fixture")
    assert File.exists?(staging.path)
    assert File.exists?(Path.dirname(staging.path))

    assert :ok = MCPLauncherStaging.close(staging, 5_000)
    refute File.exists?(Path.dirname(staging.path))
  end
end
