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
      debug.nav/follow
    ) do
      assert {:ok, _export} = Prelude.fetch_export(bundle.prelude, ref)
    end
  end

  test "follow preserves a typed relationship and its complete native page" do
    result =
      run(~S|(debug.nav/follow
        "run-1"
        {"rel" "generated_source"
         "semantics" "association"
         "target_collection" "generated_sources"
         "filters" {"evaluation_id" "mission-evaluation-9"}
         "state" "complete"}
        {"limit" 7})|)

    assert result["relationship"]["rel"] == "generated_source"

    assert result["page"] == %{
             "items" => [
               %{"evaluation_id" => "mission-evaluation-9", "source" => "(orders/place 100)"}
             ],
             "next_cursor" => "next-page",
             "omitted_count" => 1,
             "snapshot_hash" => "sha256:snapshot",
             "truncated" => true
           }

    assert_receive {:read_arguments,
                    %{
                      "collection" => "generated_sources",
                      "evaluation_id" => "mission-evaluation-9",
                      "limit" => 7,
                      "run_id" => "run-1"
                    }}
  end

  test "follow refuses unavailable relationships and caller filter overrides" do
    unavailable = ~S|(debug.nav/follow
      "run-1"
      {"rel" "generated_source"
       "semantics" "association"
       "target_collection" "generated_sources"
       "filters" nil
       "state" "unavailable"}
      {})|

    assert {:ok, %{return: {:__ptc_fail__, reason}}} = run_result(unavailable)
    assert reason =~ "cannot follow"

    override = ~S|(debug.nav/follow
      "run-1"
      {"rel" "generated_source"
       "semantics" "association"
       "target_collection" "generated_sources"
       "filters" {"evaluation_id" "mission-evaluation-9"}
       "state" "complete"}
      {"evaluation_id" "different"})|

    assert {:ok, %{return: {:__ptc_fail__, override_reason}}} = run_result(override)
    assert override_reason =~ "limit and cursor"
  end

  defp run(source) do
    {:ok, result} = run_result(source)
    result.return
  end

  defp run_result(source) do
    {:ok, components} = Library.resolve_components([{:library, "debug.nav"}])
    {:ok, bundle} = Kernel.compile_bundle(components)

    Lisp.run_native(source,
      prelude: bundle.prelude,
      tools: tools(),
      filter_context: false,
      caller: :kernel
    )
  end

  defp tools do
    owner = self()

    %{
      "debug.nav.runs" => tool(fn _arguments -> %{"items" => [failed_run()]} end),
      "debug.nav.open" => tool(fn _arguments -> %{"collections" => []} end),
      "debug.nav.read" =>
        tool(fn arguments ->
          send(owner, {:read_arguments, arguments})
          read(arguments)
        end),
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
      "next_cursor" => "next-page",
      "omitted_count" => 1,
      "snapshot_hash" => "sha256:snapshot",
      "truncated" => true
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
