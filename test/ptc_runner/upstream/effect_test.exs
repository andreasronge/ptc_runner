defmodule PtcRunner.Upstream.EffectTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Upstream.Effect

  defmodule FakeRuntime do
    use GenServer

    def start_link(upstream) do
      GenServer.start_link(__MODULE__, upstream)
    end

    @impl GenServer
    def init(upstream), do: {:ok, upstream}

    @impl GenServer
    def handle_call({:upstream, "remote"}, _from, upstream), do: {:reply, upstream, upstream}
    def handle_call({:upstream, _name}, _from, upstream), do: {:reply, nil, upstream}
  end

  describe "classify/3" do
    test "classifies OpenAPI GET as read" do
      runtime = runtime_with(tool(%{"_ptc" => %{"transport" => "openapi", "method" => "GET"}}))

      assert Effect.classify(runtime, "remote", "echo") == :read
    end

    test "classifies non-GET OpenAPI methods as write" do
      runtime = runtime_with(tool(%{"_ptc" => %{"transport" => "openapi", "method" => "POST"}}))

      assert Effect.classify(runtime, "remote", "echo") == :write
    end

    test "classifies MCP readOnlyHint as read" do
      runtime = runtime_with(tool(%{"annotations" => %{"readOnlyHint" => true}}))

      assert Effect.classify(runtime, "remote", "echo") == :read
    end

    test "classifies MCP destructiveHint as write" do
      runtime = runtime_with(tool(%{"annotations" => %{"destructiveHint" => true}}))

      assert Effect.classify(runtime, "remote", "echo") == :write
    end

    test "conflicting MCP annotations fail closed as unknown" do
      runtime =
        runtime_with(
          tool(%{"annotations" => %{"readOnlyHint" => true, "destructiveHint" => true}})
        )

      assert Effect.classify(runtime, "remote", "echo") == :unknown
    end

    test "missing tools and missing metadata fail closed as unknown" do
      runtime = runtime_with(tool(%{}))

      assert Effect.classify(runtime, "remote", "echo") == :unknown
      assert Effect.classify(runtime, "remote", "missing") == :unknown
      assert Effect.classify(runtime, "missing", "echo") == :unknown
    end
  end

  defp runtime_with(tool) do
    {:ok, pid} = start_supervised({FakeRuntime, %{tools: [tool]}})
    pid
  end

  defp tool(extra) do
    Map.merge(%{"name" => "echo"}, extra)
  end
end
