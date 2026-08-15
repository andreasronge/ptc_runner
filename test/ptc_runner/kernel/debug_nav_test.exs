defmodule PtcRunner.Kernel.DebugNavTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.TrustedTool

  test "the shipped component exposes the bounded navigation surface" do
    assert {:ok, component} = Library.component("debug.nav")
    assert component.dependencies == ["cap"]

    assert {:ok, components} = Library.resolve_components([{:library, "debug.nav"}])
    assert {:ok, bundle} = Kernel.compile_bundle(components)

    for ref <- ~w(
      debug.nav/runs
      debug.nav/open
      debug.nav/read
      debug.nav/component-source
      debug.nav/evaluation
      debug.nav/latest-failure
    ) do
      assert {:ok, _export} = Prelude.fetch_export(bundle.prelude, ref)
    end
  end

  test "latest-failure includes called components and their immediate dependency sources" do
    result = run(~S|(debug.nav/latest-failure {})|)

    assert result["run"]["run_id"] == "run-1"
    assert result["called_components"] == ["orders"]
    assert result["dependency_components"] == ["pricing.tax"]

    assert Enum.map(result["prelude_sources"], & &1["component_id"]) == [
             "orders",
             "pricing.tax"
           ]

    assert Enum.any?(result["links"], fn link ->
             link["rel"] == "component-source" and
               link["component_id"] == "pricing.tax" and
               link["call"] == ~S|(debug.nav/component-source "run-1" "pricing.tax")|
           end)
  end

  test "evaluation follows direct advertised filters instead of inventing a filter envelope" do
    result = run(~S|(debug.nav/evaluation "run-1" "mission-evaluation-9")|)

    assert result == %{
             "activity" => [%{"evaluation_id" => "mission-evaluation-9", "status" => "failed"}],
             "execution_errors" => [],
             "generated_sources" => [
               %{"evaluation_id" => "mission-evaluation-9", "source" => "(orders/place 100)"}
             ],
             "run_id" => "run-1",
             "turns" => []
           }
  end

  defp run(source) do
    {:ok, components} = Library.resolve_components([{:library, "debug.nav"}])
    {:ok, bundle} = Kernel.compile_bundle(components)

    {:ok, result} =
      Lisp.run_native(source,
        prelude: bundle.prelude,
        tools: tools(),
        filter_context: false,
        caller: :kernel
      )

    result.return
  end

  defp tools do
    %{
      "debug.nav.runs" => tool(fn _arguments -> %{"items" => [failed_run()]} end),
      "debug.nav.open" => tool(fn _arguments -> %{"collections" => []} end),
      "debug.nav.read" => tool(&read/1),
      "cap-list" => tool(fn _arguments -> [] end),
      "cap-describe" => tool(fn _arguments -> %{} end)
    }
  end

  defp tool(callback) do
    %TrustedTool{
      function: fn arguments -> %{status: :ok, value: callback.(arguments)} end
    }
  end

  defp read(%{"collection" => "execution_errors"}),
    do: %{"items" => [], "next_cursor" => nil}

  defp read(%{"collection" => "turns", "evaluation_id" => _evaluation_id}),
    do: %{"items" => [], "next_cursor" => nil}

  defp read(%{"collection" => "turns"}), do: %{"items" => [turn()], "next_cursor" => nil}

  defp read(%{"collection" => "generated_sources", "evaluation_id" => evaluation_id}) do
    %{
      "items" => [%{"evaluation_id" => evaluation_id, "source" => "(orders/place 100)"}],
      "next_cursor" => nil
    }
  end

  defp read(%{"collection" => "activity", "evaluation_id" => evaluation_id}) do
    %{
      "items" => [%{"evaluation_id" => evaluation_id, "status" => "failed"}],
      "next_cursor" => nil
    }
  end

  defp read(%{"collection" => "prelude_sources", "component_id" => component_id}) do
    %{
      "items" => [%{"component_id" => component_id, "source" => "source for #{component_id}"}],
      "next_cursor" => nil
    }
  end

  defp failed_run do
    %{
      "run_id" => "run-1",
      "status" => "error",
      "missions" => %{
        "default" => %{
          "prelude" => %{
            "component_ids" => ["pricing.tax", "orders"],
            "dependency_indices" => [[], [0]]
          }
        }
      }
    }
  end

  defp turn do
    %{
      "turn" => 1,
      "generated" => [
        %{
          "evaluation_id" => "mission-evaluation-9",
          "source" => "(orders/place 100)",
          "prelude_calls" => [%{"component_id" => "orders", "ref" => "orders/place"}]
        }
      ],
      "feedback" => []
    }
  end
end
