defmodule PtcRunner.Kernel.PreSinkSchemaBudgetTest do
  use ExUnit.Case, async: true
  @moduletag :operator

  import PtcRunner.TestSupport.CommandEngineFixtures

  alias PtcRunner.Kernel.CommandEngine

  @tag :tmp_dir
  test "host schema worker exhaustion reaches the command envelope", %{tmp_dir: dir} do
    installations =
      Map.new(1..10_000, fn index ->
        {"provider#{index}", %{"installation_revision" => "r", "source" => "mcp"}}
      end)

    host = write_host_config(dir, "wide", %{"install" => installations})
    assert {:error, outcome} = CommandEngine.dispatch(["models", "--host-config", host])
    assert outcome.envelope["error"]["code"] == "schema_validation_unavailable"
    assert outcome.envelope["error"]["cause"] == "resource_unavailable"
    assert_schema_valid(outcome.envelope)
    refute Jason.encode!(outcome.envelope) =~ dir
    refute Jason.encode!(outcome.envelope) =~ "provider10000"
  end

  @tag :tmp_dir
  test "project schema worker exhaustion reaches the command envelope", %{tmp_dir: dir} do
    unknown = Map.new(1..10_000, fn index -> {"unknown#{index}", true} end)

    document =
      Map.merge(unknown, %{
        "kind" => "ptc-project",
        "version" => 1,
        "application" => %{"path" => "ptc.json"}
      })

    path = Path.join(dir, "ptc-project.json")
    File.write!(path, Jason.encode!(document))
    assert {:error, outcome} = CommandEngine.dispatch(["validate", path])
    assert outcome.envelope["error"]["code"] == "schema_validation_unavailable"
    assert outcome.envelope["error"]["cause"] == "resource_unavailable"
    assert_schema_valid(outcome.envelope)
    refute Jason.encode!(outcome.envelope) =~ dir
  end
end
