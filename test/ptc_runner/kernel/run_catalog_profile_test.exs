defmodule PtcRunner.Kernel.RunCatalogProfileTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.AnalysisSession
  alias PtcRunner.Kernel.AnalysisSessionBuilder
  alias PtcRunner.Kernel.RunCatalogProfile
  alias PtcRunner.Kernel.RunCatalogSnapshot
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  @profile_id "private-run-catalog-v1"

  test "the closed catalog profile declares one capability and two private resources" do
    assert AnalysisProfileRegistry.ids() == [
             "private-run-analysis-v1",
             "private-run-catalog-v1",
             "run-analysis-v1"
           ]

    assert {:ok, description} = AnalysisProfileRegistry.description(@profile_id)
    assert description["components"] == ["cap", "analysis.catalog"]
    assert description["namespaces"] == ["analysis", "cap"]
    assert description["explicit_capabilities"] == ["analysis-catalog"]
    assert description["resources"] |> Map.keys() |> Enum.sort() == ["inspection", "traces"]
    assert description["source_data_class"] == "private_inspection"
    assert description["result_data_class"] == "private_inspection"

    assert {:ok, private_analysis} =
             AnalysisProfileRegistry.description("private-run-analysis-v1")

    assert description["frontend"] == private_analysis["frontend"]

    assert RunCatalogProfile.explicit_capabilities() == ["analysis-catalog"]
  end

  @tag :tmp_dir
  test "the profile exposes catalog rows through PTC-Lisp and no other analysis capability", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, session, info} = start_session(fixture)
    on_exit(fn -> AnalysisSession.stop(session) end)

    assert info.profile_id == @profile_id
    assert info.namespaces == ["analysis", "cap"]
    assert info.snapshot.row_count == 1

    state = :sys.get_state(session.pid)
    assert state.profile.identity["components"] == ["cap", "analysis.catalog"]

    assert state.config.missions["default"].environment.capabilities
           |> Map.keys()
           |> Enum.sort() == ["analysis-catalog"]

    assert {:ok,
            %{
              status: :ok,
              value: %{
                "items" => [%{"run_id" => run_id, "correlation" => "paired"}],
                "catalog_digest" => digest,
                "excluded_files" => excluded_files
              },
              usage: %{capability_calls: %{"analysis-catalog" => %{used: 1}}}
            }} = AnalysisSession.evaluate(session, "(analysis/catalog {})")

    assert run_id == fixture.run_id
    assert is_binary(digest)
    assert is_integer(excluded_files)
  end

  @tag :tmp_dir
  test "a malformed unselected entry is an isolated row and does not block startup", %{
    tmp_dir: root
  } do
    healthy = PrivateInspectionFixture.create!(root, PrivateInspectionFixture.command_run_ref(1))
    broken = PrivateInspectionFixture.create!(root, PrivateInspectionFixture.command_run_ref(2))
    File.write!(Path.join(broken.traces, "#{broken.run_id}.jsonl"), "{private-malformed\n")

    assert {:ok, session, _info} = start_session(healthy)
    on_exit(fn -> AnalysisSession.stop(session) end)

    assert {:ok, %{status: :ok, value: %{"items" => rows}}} =
             AnalysisSession.evaluate(session, "(analysis/catalog {})")

    assert Enum.find(rows, &(&1["run_id"] == healthy.run_id))["state"] == "admissible"

    assert %{
             "state" => "isolated",
             "isolation_reason" => "malformed_metadata",
             "trace_present" => "unreadable"
           } = Enum.find(rows, &(&1["run_id"] == broken.run_id))
  end

  @tag :tmp_dir
  test "normal close releases the transferred catalog owner", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, session, _info} = start_session(fixture)
    state = :sys.get_state(session.pid)
    catalog = AnalysisResources.handle(state.resources, :catalog)
    catalog_ref = Process.monitor(catalog.pid)

    assert {:ok, %{lifecycle: :closed}} = AnalysisSession.close(session)
    assert_receive {:DOWN, ^catalog_ref, :process, _, :normal}, 5_000
    refute RunCatalogSnapshot.alive?(catalog)

    AnalysisSession.stop(session)
  end

  @tag :tmp_dir
  test "failed session construction releases the captured catalog owner", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    test = self()

    assert {:error, :private_run_catalog_session_failed} =
             AnalysisSessionBuilder.start(
               @profile_id,
               resources(fixture),
               {:directory, fixture.output},
               private_unattended: true,
               builder_fault_hook: fn
                 :after_snapshot, %{catalog_snapshot: catalog} ->
                   send(test, {:captured_catalog, catalog})
                   {:error, :injected}

                 _stage, _resources ->
                   :ok
               end
             )

    assert_receive {:captured_catalog, catalog}
    ref = Process.monitor(catalog.pid)
    assert_receive {:DOWN, ^ref, :process, _, _reason}, 5_000
    refute RunCatalogSnapshot.alive?(catalog)
  end

  test "whole-catalog capture refusals are path-free" do
    missing = "/private/catalog/path-that-does-not-exist"

    assert {:error, :source_unavailable} =
             RunCatalogProfile.capture(%{"traces" => missing, "inspection" => missing}, [])
  end

  defp start_session(fixture) do
    AnalysisSessionBuilder.start(
      @profile_id,
      resources(fixture),
      {:directory, fixture.output},
      private_unattended: true
    )
  end

  defp resources(fixture),
    do: %{"traces" => fixture.traces, "inspection" => fixture.inspection}
end
