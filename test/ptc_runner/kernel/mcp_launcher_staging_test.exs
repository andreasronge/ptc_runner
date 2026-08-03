defmodule PtcRunner.Kernel.MCPLauncherStagingTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPLauncherStaging
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar

  test "owner death removes private launcher staging" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, staging} = MCPLauncherStaging.start(self(), 5_000)
        send(parent, {:staging, staging})
        receive do: (:stop -> :ok)
      end)

    # The owner starts a GenServer and creates/chmods a private directory
    # before acknowledging readiness. Under the full parallel suite that can
    # legitimately exceed ExUnit's 100 ms mailbox default.
    assert_receive {:staging, staging}, 5_000
    staging_ref = Process.monitor(staging.pid)
    File.write!(staging.path, "fixture")
    assert File.exists?(staging.path)

    send(owner, :stop)
    assert_receive {:DOWN, ^staging_ref, :process, _, :normal}, 5_000
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

  test "abnormal provider-session death still removes launcher staging" do
    {:ok, session} = ProviderSession.start(Limits.defaults())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    {:ok, staging} =
      MCPLauncherStaging.start(ResourceRegistrar.owner(registrar), 5_000, registrar)

    File.write!(staging.path, "fixture")
    staging_ref = Process.monitor(staging.pid)
    assert File.exists?(staging.path)

    Process.exit(session.pid, :kill)

    assert_receive {:DOWN, ^staging_ref, :process, _, :normal}, 5_000
    refute File.exists?(staging.path)
    refute File.exists?(Path.dirname(staging.path))
  end
end
