defmodule PtcRunner.Kernel.NamedMissionReaderWriterExampleTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.ProjectConfig

  @example Path.expand("../../../examples/named-mission-reader-writer", __DIR__)
  @host Path.join(@example, "ptc-host.json")

  test "the example project remembers the host installation" do
    assert {:ok, project} = ProjectConfig.load(Path.join(@example, "ptc-project.json"))
    assert project.application == Path.join(@example, "ptc.json")
    assert project.host == @host
    assert project.env_file == Path.join(@example, ".env")
    assert project.artifacts.inspection
    assert project.viewer.private
  end

  test "the example splits read and write across two installations of one server" do
    assert {:ok, host} = HostConfig.load(@host)

    reader = Map.fetch!(host.install, "reader_workspace")
    writer = Map.fetch!(host.install, "writer_workspace")

    assert reader.source == :mcp
    assert writer.source == :mcp
    assert reader.transport.command == "npx"
    assert writer.transport.command == "npx"
    assert "ptc-fs-mcp@0.3.0" in reader.transport.args
    assert "ptc-fs-mcp@0.3.0" in writer.transport.args
    assert "reader-state" in reader.transport.args
    assert "writer-state" in writer.transport.args

    assert %{
             "read_text_file" => %{as: "workspace.read", effect: :read}
           } = reader.tools

    assert %{
             "write_text_file" => %{
               as: "workspace.write",
               effect: :write,
               model_visible: true
             }
           } = writer.tools
  end
end
