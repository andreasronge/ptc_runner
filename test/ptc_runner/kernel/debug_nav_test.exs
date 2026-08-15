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

    for ref <- ~w(debug.nav/runs debug.nav/open debug.nav/read debug.nav/follow) do
      assert {:ok, _export} = Prelude.fetch_export(bundle.prelude, ref)
    end

    # Navigation policy only. Anything that chooses a diagnosis, ranks a
    # suspect, or aggregates an incident belongs to the caller, not here.
    assert bundle.prelude
           |> Prelude.prompt_exports()
           |> Enum.filter(&(&1.namespace == "debug.nav"))
           |> Enum.map(& &1.ref)
           |> Enum.sort() ==
             ~w(debug.nav/follow debug.nav/open debug.nav/read debug.nav/runs)
  end

  test "runs, open, and read delegate the unwrapped native page unchanged" do
    assert run(~S|(debug.nav/runs {"status" "error" "limit" 5})|) == %{
             "items" => [failed_run()],
             "next_cursor" => nil
           }

    assert_receive {:runs_arguments, %{"status" => "error", "limit" => 5}}

    assert %{"collections" => _collections} = run(~S|(debug.nav/open "run-1")|)
    assert_receive {:open_arguments, %{"run_id" => "run-1"}}

    assert run(~S|(debug.nav/read "run-1" {"collection" "turns"})|) == %{
             "items" => [turn()],
             "next_cursor" => nil
           }

    assert_receive {:read_arguments, %{"collection" => "turns", "run_id" => "run-1"}}
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

    # Cursors, omitted counts, snapshot identity, and truncation are native
    # page facts; the hop must not summarize or drop them.
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

  test "follow retains an incomplete or ambiguous relationship state" do
    for state <- ~w(incomplete ambiguous) do
      result =
        run(~s|(debug.nav/follow
          "run-1"
          {"rel" "direct_boundary_producer"
           "semantics" "causation"
           "target_collection" "activity"
           "filters" {"evaluation_id" "mission-evaluation-9"}
           "state" "#{state}"}
          {})|)

      assert result["relationship"]["state"] == state
      assert result["page"]["items"] == [%{"evaluation_id" => "mission-evaluation-9"}]
    end
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

    # A null-filtered relationship is never followable, whatever its state.
    filterless = ~S|(debug.nav/follow
      "run-1"
      {"rel" "dependency_prelude_source"
       "semantics" "dependency"
       "target_collection" "prelude_sources"
       "filters" nil
       "state" "incomplete"}
      {})|

    assert {:ok, %{return: {:__ptc_fail__, filterless_reason}}} = run_result(filterless)
    assert filterless_reason =~ "cannot follow"

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

  test "a walker reaches dependency source from a turn without an extra exact read" do
    program = ~S"""
    (let [turn (first (get (debug.nav/read "run-1" {"collection" "turns"}) "items"))
          generated (first (get turn "generated"))
          referenced (first
                       (filter
                         #(= (get % "rel") "referenced_prelude_source")
                         (get generated "relationships")))
          component (first (get (get (debug.nav/follow "run-1" referenced {}) "page") "items"))
          dependency (first
                       (filter
                         #(= (get % "rel") "dependency_prelude_source")
                         (get component "relationships")))]
      [(get component "component_id")
       (get (first (get (get (debug.nav/follow "run-1" dependency {}) "page") "items"))
            "component_id")])
    """

    assert run(program) == ["orders", "pricing.tax"]
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
      "debug.nav.runs" =>
        tool(fn arguments ->
          send(owner, {:runs_arguments, arguments})
          %{"items" => [failed_run()], "next_cursor" => nil}
        end),
      "debug.nav.open" =>
        tool(fn arguments ->
          send(owner, {:open_arguments, arguments})
          %{"collections" => ["turns", "generated_sources", "prelude_sources"]}
        end),
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

  defp read(%{"collection" => "activity", "evaluation_id" => evaluation_id}),
    do: %{"items" => [%{"evaluation_id" => evaluation_id}], "next_cursor" => nil}

  defp read(%{"collection" => "prelude_sources", "component_id" => component_id} = arguments) do
    %{
      "items" => [prelude_source(component_id, arguments["mission_name"])],
      "next_cursor" => nil
    }
  end

  defp failed_run, do: %{"run_id" => "run-1", "status" => "error"}

  # Mirrors the shape `RunAnalysisRelationships` publishes: the generated entry
  # embedded in a turn carries the same relationships as its `generated_sources`
  # item, and a prelude source carries its occurrence-qualified dependencies.
  defp turn do
    %{
      "turn" => 1,
      "feedback" => [],
      "generated" => [
        %{
          "evaluation_id" => "mission-evaluation-9",
          "source" => "(orders/place 100)",
          "relationships" => [
            relation("producing_turn", "turns", %{"evaluation_id" => "mission-evaluation-9"}),
            relation("referenced_prelude_source", "prelude_sources", %{
              "component_id" => "orders",
              "environment" => "mission",
              "mission_name" => "default"
            })
          ]
        }
      ]
    }
  end

  defp prelude_source("orders", mission_name) do
    %{
      "component_id" => "orders",
      "mission_name" => mission_name,
      "source" => "(ns orders)",
      "relationships" => [
        relation("dependency_prelude_source", "prelude_sources", %{
          "component_id" => "pricing.tax",
          "environment" => "mission",
          "mission_name" => "default"
        })
      ]
    }
  end

  defp prelude_source(component_id, mission_name) do
    %{
      "component_id" => component_id,
      "mission_name" => mission_name,
      "source" => "(ns #{component_id})",
      "relationships" => []
    }
  end

  defp relation(rel, target_collection, filters) do
    %{
      "rel" => rel,
      "semantics" => "association",
      "target_collection" => target_collection,
      "filters" => filters,
      "state" => "complete"
    }
  end
end
