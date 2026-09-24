defmodule PtcRunner.Kernel.MCPStdioTransportSerialTest do
  # This case observes the VM-global port list (class C).
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel.MCPStdioTransport
  alias PtcRunner.Kernel.MCPStdioTransportTest

  @stall_launcher Path.expand("../../support/mcp_stdio_stall_launcher.sh", __DIR__)

  @tag :tmp_dir
  test "owner death aborts a launcher that is still starting", %{tmp_dir: tmp_dir} do
    existing = matching_ports(@stall_launcher)
    parent = self()

    owner =
      spawn(fn ->
        send(parent, :starting_transport)

        result =
          MCPStdioTransport.start(
            tmp_dir
            |> MCPStdioTransportTest.launch_options()
            |> Keyword.put(:launcher, @stall_launcher)
            |> Keyword.put(:start_timeout_ms, 60_000)
          )

        send(parent, {:start_result, result})
      end)

    assert_receive :starting_transport
    assert_eventually(fn -> matching_ports(@stall_launcher) -- existing != [] end)
    Process.exit(owner, :kill)
    assert_eventually(fn -> matching_ports(@stall_launcher) -- existing == [] end)
    refute_receive {:start_result, _result}
  end

  defp matching_ports(executable) do
    Enum.filter(Port.list(), fn port ->
      case Port.info(port, :name) do
        {:name, name} -> List.to_string(name) == executable
        _closed -> false
      end
    end)
  end
end
