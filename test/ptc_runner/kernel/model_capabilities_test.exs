defmodule PtcRunner.Kernel.ModelCapabilitiesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.ModelCapabilities
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.TestHelpers

  test "model and chat classification accepts strings and atoms" do
    for name <- ["llm-request", :"llm-request"] do
      assert ModelCapabilities.model_call?(name)
      assert ModelCapabilities.chat?(name)
      assert ModelCapabilities.reserved_name?(name)
    end

    for name <- ["decision-request", :"decision-request"] do
      refute ModelCapabilities.model_call?(name)
      refute ModelCapabilities.chat?(name)
      assert ModelCapabilities.reserved_name?(name)
    end

    for name <- ["workspace.read", nil, 42] do
      refute ModelCapabilities.model_call?(name)
      refute ModelCapabilities.chat?(name)
      refute ModelCapabilities.reserved_name?(name)
    end
  end

  test "MCP public mappings cannot claim current or future model names" do
    for name <- ["llm-request", "decision-request"] do
      assert_raise ArgumentError, fn ->
        MCPSource.builder(
          transport: {:streamable_http, endpoint: "https://example.com/mcp"},
          tools: %{"upstream" => %{as: name, effect: :read}}
        )
      end
    end
  end

  test "a host-built chat capability retains model-call treatment by name" do
    documents = %{
      "ptc.json" => Jason.encode!(TestHelpers.valid_manifest()),
      "main.clj" => "(ns app) (defn run [input] (return input))"
    }

    assert {:ok, package, _input} = ApplicationPackage.acquire_memory("ptc.json", documents)

    {:ok, capability} =
      Capability.new(
        name: "llm-request",
        input_schema: %{"type" => "object"},
        callback: fn _arguments -> {:ok, %{}} end
      )

    assert {:ok, environment} =
             WorkflowEnvironment.new_for_package([capabilities: [capability]], package)

    assert Map.has_key?(environment.capabilities, "llm-request")
  end
end
