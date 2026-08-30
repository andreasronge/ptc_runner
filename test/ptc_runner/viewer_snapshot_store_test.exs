defmodule PtcRunner.ViewerSnapshotStoreTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.SchemaViolation
  alias PtcRunner.TestSupport.PrivateInspectionFixture
  alias PtcRunner.ViewerSnapshotStore

  @tag :tmp_dir
  test "a requested refresh atomically exposes a newly completed run", %{tmp_dir: directory} do
    write_events(Path.join(directory, "first.jsonl"), [event("first", 1, "run-started")])

    assert {:ok, store} =
             ViewerSnapshotStore.start({:directory, directory}, fn _trace, _deadline ->
               {:ok, nil}
             end)

    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    assert {:ok, %{"run_id" => "first"}} =
             ViewerSnapshotStore.query(store, :get_run, %{"run_id" => "first"})

    assert {:error, :not_found} =
             ViewerSnapshotStore.query(store, :get_run, %{"run_id" => "second"})

    write_events(Path.join(directory, "second.jsonl"), [
      event("second", 1, "run-started"),
      event("second", 2, "run-stopped")
    ])

    assert :ok = ViewerSnapshotStore.refresh(store, "second")

    assert {:ok, %{"run_id" => "second"}} =
             ViewerSnapshotStore.query(store, :get_run, %{"run_id" => "second"})
  end

  @tag :tmp_dir
  test "a no-run refresh retains a newly completed run", %{tmp_dir: directory} do
    write_events(Path.join(directory, "first.jsonl"), [event("first", 1, "run-started")])

    assert {:ok, store} =
             ViewerSnapshotStore.start({:directory, directory}, fn _trace, _deadline ->
               {:ok, nil}
             end)

    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    write_events(Path.join(directory, "second.jsonl"), [event("second", 1, "run-started")])

    assert {:error, :not_found} =
             ViewerSnapshotStore.query(store, :get_run, %{"run_id" => "second"})

    assert :ok = ViewerSnapshotStore.refresh(store)

    assert {:ok, %{"run_id" => "second"}} =
             ViewerSnapshotStore.query(store, :get_run, %{"run_id" => "second"})
  end

  @tag :tmp_dir
  test "revoking viewer.private withholds inspection and stops the held snapshot", %{
    tmp_dir: directory
  } do
    fixture = PrivateInspectionFixture.create!(Path.join(directory, ".ptc"), "granted-run")
    path = write_project(directory, true)
    {:ok, project} = ProjectConfig.load(path)
    {:ok, store} = start_granted_store(project, path, fixture)
    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    inspection = :sys.get_state(store.pid).inspection
    assert InspectionSnapshot.alive?(inspection)

    assert {:ok, %{"complete?" => true, "streams" => [_ | _]}} =
             ViewerSnapshotStore.conversation(store, fixture.run_id)

    write_project(directory, false)

    assert {:error, :inspection_not_private} =
             ViewerSnapshotStore.conversation(store, fixture.run_id)

    refute InspectionSnapshot.alive?(inspection)
    refute ViewerSnapshotStore.inspection?(store)

    assert {:error, :inspection_not_private} =
             ViewerSnapshotStore.preludes(store, fixture.run_id)
  end

  @tag :tmp_dir
  test "revoking viewer.private recaptures kernel runs without private traces", %{
    tmp_dir: directory
  } do
    artifact_root = Path.join(directory, ".ptc")
    traces = Path.join(artifact_root, "traces")
    File.mkdir_p!(traces)
    write_events(Path.join(traces, "normal.jsonl"), [event("normal", 1, "run-started")])
    write_events(Path.join(traces, "secret.private.jsonl"), [event("secret", 1, "run-started")])

    path = write_project(directory, true)
    {:ok, project} = ProjectConfig.load(path)

    assert {:ok, store} =
             ViewerSnapshotStore.start(
               {:private_authorized_directory, traces},
               fn _project, _trace, _deadline -> {:ok, nil} end,
               project: project,
               project_path: path
             )

    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    held_trace = :sys.get_state(store.pid).trace
    assert Process.alive?(held_trace.pid)

    assert {:ok, %{"items" => items}} = ViewerSnapshotStore.query(store, :list_runs, %{})
    assert MapSet.new(Enum.map(items, & &1["run_id"])) == MapSet.new(["normal", "secret"])

    write_project(directory, false)

    assert {:ok, %{"items" => sanitized} = page} =
             ViewerSnapshotStore.query(store, :list_runs, %{})

    assert Enum.map(sanitized, & &1["run_id"]) == ["normal"]
    assert page["excluded_private_trace_files"] == 1
    refute Process.alive?(held_trace.pid)
    recaptured = :sys.get_state(store.pid).trace
    assert recaptured.pid != held_trace.pid
    assert Process.alive?(recaptured.pid)
  end

  @tag :tmp_dir
  test "a revocation written before the first serving call takes effect immediately", %{
    tmp_dir: directory
  } do
    fixture = PrivateInspectionFixture.create!(Path.join(directory, ".ptc"), "granted-run")
    path = write_project(directory, true)
    {:ok, project} = ProjectConfig.load(path)
    write_project(directory, false)

    {:ok, store} = start_granted_store(project, path, fixture)
    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    inspection = :sys.get_state(store.pid).inspection
    assert InspectionSnapshot.alive?(inspection)

    assert {:error, :inspection_not_private} =
             ViewerSnapshotStore.conversation(store, fixture.run_id)

    refute InspectionSnapshot.alive?(inspection)
  end

  @tag :tmp_dir
  test "a failed post-revoke recapture does not restore the discarded admission", %{
    tmp_dir: directory
  } do
    artifact_root = Path.join(directory, ".ptc")
    traces = Path.join(artifact_root, "traces")
    File.mkdir_p!(traces)
    write_events(Path.join(traces, "normal.jsonl"), [event("normal", 1, "run-started")])
    write_events(Path.join(traces, "secret.private.jsonl"), [event("secret", 1, "run-started")])

    path = write_project(directory, true)
    {:ok, project} = ProjectConfig.load(path)
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    capture = fn _project, _trace, _deadline ->
      case Agent.get(agent, & &1) do
        :ok -> {:ok, nil}
        :fail -> {:error, :snapshot_unavailable}
      end
    end

    assert {:ok, store} =
             ViewerSnapshotStore.start(
               {:private_authorized_directory, traces},
               capture,
               project: project,
               project_path: path
             )

    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    held_trace = :sys.get_state(store.pid).trace
    assert {:ok, %{"items" => items}} = ViewerSnapshotStore.query(store, :list_runs, %{})
    assert MapSet.new(Enum.map(items, & &1["run_id"])) == MapSet.new(["normal", "secret"])

    :ok = Agent.update(agent, fn _ -> :fail end)
    write_project(directory, false)

    assert {:error, :snapshot_unavailable} =
             ViewerSnapshotStore.query(store, :list_runs, %{})

    refute Process.alive?(held_trace.pid)
    assert is_nil(:sys.get_state(store.pid).trace)

    :ok = Agent.update(agent, fn _ -> :ok end)

    assert {:ok, %{"items" => sanitized} = page} =
             ViewerSnapshotStore.query(store, :list_runs, %{})

    assert Enum.map(sanitized, & &1["run_id"]) == ["normal"]
    assert page["excluded_private_trace_files"] == 1
  end

  @tag :tmp_dir
  test "a GET after a failed post-revoke recapture does not widen the grant", %{
    tmp_dir: directory
  } do
    artifact_root = Path.join(directory, ".ptc")
    traces = Path.join(artifact_root, "traces")
    File.mkdir_p!(traces)
    write_events(Path.join(traces, "normal.jsonl"), [event("normal", 1, "run-started")])
    write_events(Path.join(traces, "secret.private.jsonl"), [event("secret", 1, "run-started")])

    path = write_project(directory, true)
    {:ok, project} = ProjectConfig.load(path)
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    capture = fn _current, _trace, _deadline ->
      case Agent.get(agent, & &1) do
        :ok -> {:ok, nil}
        :fail -> {:error, :snapshot_unavailable}
      end
    end

    assert {:ok, store} =
             ViewerSnapshotStore.start(
               {:private_authorized_directory, traces},
               capture,
               project: project,
               project_path: path
             )

    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    assert {:ok, _} = ViewerSnapshotStore.query(store, :list_runs, %{})

    :ok = Agent.update(agent, fn _ -> :fail end)
    write_project(directory, false)

    assert {:error, :snapshot_unavailable} =
             ViewerSnapshotStore.query(store, :list_runs, %{})

    :ok = Agent.update(agent, fn _ -> :ok end)
    write_project(directory, true)

    assert {:ok, %{"items" => sanitized} = page} =
             ViewerSnapshotStore.query(store, :list_runs, %{})

    assert Enum.map(sanitized, & &1["run_id"]) == ["normal"]
    assert page["excluded_private_trace_files"] == 1

    assert :ok = ViewerSnapshotStore.refresh(store)

    assert {:ok, %{"items" => items}} = ViewerSnapshotStore.query(store, :list_runs, %{})
    assert MapSet.new(Enum.map(items, & &1["run_id"])) == MapSet.new(["normal", "secret"])
  end

  @tag :tmp_dir
  test "revocation recaptures from the boot trace directory, not a reloaded artifact root", %{
    tmp_dir: directory
  } do
    artifact_root = Path.join(directory, ".ptc")
    traces = Path.join(artifact_root, "traces")
    File.mkdir_p!(traces)
    write_events(Path.join(traces, "normal.jsonl"), [event("normal", 1, "run-started")])
    write_events(Path.join(traces, "secret.private.jsonl"), [event("secret", 1, "run-started")])

    path = write_project(directory, true)
    {:ok, project} = ProjectConfig.load(path)

    assert {:ok, store} =
             ViewerSnapshotStore.start(
               {:private_authorized_directory, traces},
               fn _project, _trace, _deadline -> {:ok, nil} end,
               project: project,
               project_path: path
             )

    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    File.write!(
      path,
      Jason.encode!(%{
        "kind" => "ptc-project",
        "version" => 1,
        "application" => %{"path" => "ptc.json"},
        "artifacts" => %{
          "root" => "elsewhere",
          "trace" => true,
          "inspection" => true
        },
        "viewer" => %{
          "port" => 0,
          "open" => false,
          "repl" => false,
          "private" => false
        }
      })
    )

    assert {:ok, %{"items" => sanitized}} = ViewerSnapshotStore.query(store, :list_runs, %{})
    assert Enum.map(sanitized, & &1["run_id"]) == ["normal"]
  end

  @tag :tmp_dir
  test "widening viewer.private does not capture inspection until refresh", %{
    tmp_dir: directory
  } do
    fixture = PrivateInspectionFixture.create!(Path.join(directory, ".ptc"), "granted-run")
    path = write_project(directory, false)
    {:ok, project} = ProjectConfig.load(path)
    {:ok, store} = start_granted_store(project, path, fixture)
    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    assert {:error, :inspection_not_private} =
             ViewerSnapshotStore.conversation(store, fixture.run_id)

    refute ViewerSnapshotStore.inspection?(store)

    write_project(directory, true)

    assert {:error, :inspection_not_private} =
             ViewerSnapshotStore.conversation(store, fixture.run_id)

    refute ViewerSnapshotStore.inspection?(store)

    assert :ok = ViewerSnapshotStore.refresh(store)
    assert ViewerSnapshotStore.inspection?(store)
    assert {:ok, _} = ViewerSnapshotStore.conversation(store, fixture.run_id)
  end

  @tag :tmp_dir
  test "an unchanged document digest does not reload the project grant", %{tmp_dir: directory} do
    fixture = PrivateInspectionFixture.create!(Path.join(directory, ".ptc"), "granted-run")
    path = write_project(directory, true)
    {:ok, project} = ProjectConfig.load(path)
    revoked = %{project | viewer: %{project.viewer | private: false}}
    {:ok, agent} = Agent.start_link(fn -> project end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    loader = fn ^path -> {:ok, Agent.get(agent, & &1)} end
    {:ok, store} = start_granted_store(project, path, fixture, project_loader: loader)
    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    assert {:ok, _} = ViewerSnapshotStore.conversation(store, fixture.run_id)
    :ok = Agent.update(agent, fn _ -> revoked end)

    assert {:ok, _} = ViewerSnapshotStore.conversation(store, fixture.run_id)

    write_project(directory, true, 1)

    assert {:error, :inspection_not_private} =
             ViewerSnapshotStore.conversation(store, fixture.run_id)
  end

  @tag :tmp_dir
  test "every project-load failure withholds private routes and keeps the trace snapshot", %{
    tmp_dir: directory
  } do
    fixture = PrivateInspectionFixture.create!(Path.join(directory, ".ptc"), "granted-run")
    path = write_project(directory, true)
    {:ok, project} = ProjectConfig.load(path)

    failures = [
      :project_unavailable,
      :project_invalid,
      {:schema_validation_unavailable, :timeout},
      {:project_schema_invalid, SchemaViolation.new(:schema, [])}
    ]

    Enum.with_index(failures, fn reason, index ->
      {:ok, agent} = Agent.start_link(fn -> {:ok, project} end)
      loader = fn ^path -> Agent.get(agent, & &1) end
      {:ok, store} = start_granted_store(project, path, fixture, project_loader: loader)

      inspection = :sys.get_state(store.pid).inspection
      assert {:ok, _} = ViewerSnapshotStore.conversation(store, fixture.run_id)

      :ok = Agent.update(agent, fn _ -> {:error, reason} end)
      write_project(directory, true, index + 1)

      assert {:error, :inspection_not_private} =
               ViewerSnapshotStore.conversation(store, fixture.run_id)

      assert InspectionSnapshot.alive?(inspection)

      assert {:ok, %{"run_id" => run_id}} =
               ViewerSnapshotStore.query(store, :get_run, %{"run_id" => fixture.run_id})

      assert run_id == fixture.run_id
      ViewerSnapshotStore.stop(store)
      if Process.alive?(agent), do: Agent.stop(agent)
    end)
  end

  @tag :tmp_dir
  test "an unreadable project document fails closed without dropping held evidence", %{
    tmp_dir: directory
  } do
    fixture = PrivateInspectionFixture.create!(Path.join(directory, ".ptc"), "granted-run")
    path = write_project(directory, true)
    {:ok, project} = ProjectConfig.load(path)
    {:ok, store} = start_granted_store(project, path, fixture)
    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    inspection = :sys.get_state(store.pid).inspection
    File.rm!(path)

    assert {:error, :inspection_not_private} =
             ViewerSnapshotStore.conversation(store, fixture.run_id)

    assert InspectionSnapshot.alive?(inspection)

    assert {:ok, %{"run_id" => run_id}} =
             ViewerSnapshotStore.query(store, :get_run, %{"run_id" => fixture.run_id})

    assert run_id == fixture.run_id
  end

  defp start_granted_store(project, path, fixture, opts \\ []) do
    capture = fn current, trace, deadline ->
      granted? =
        match?(%{artifacts: %{inspection: true}, viewer: %{private: true}}, current)

      if granted? do
        InspectionSnapshot.start(
          {:directory, fixture.inspection},
          trace,
          capture_deadline_ms: deadline
        )
      else
        {:ok, nil}
      end
    end

    source =
      if project.viewer.private,
        do: {:private_authorized_directory, fixture.traces},
        else: {:directory, fixture.traces}

    ViewerSnapshotStore.start(
      source,
      capture,
      Keyword.merge([project: project, project_path: path], opts)
    )
  end

  defp write_project(directory, private?, port \\ 0) do
    path = Path.join(directory, "ptc-project.json")

    File.write!(
      path,
      Jason.encode!(%{
        "kind" => "ptc-project",
        "version" => 1,
        "application" => %{"path" => "ptc.json"},
        "artifacts" => %{
          "root" => ".ptc",
          "trace" => true,
          "inspection" => true
        },
        "viewer" => %{
          "port" => port,
          "open" => false,
          "repl" => false,
          "private" => private?
        }
      })
    )

    path
  end

  defp write_events(path, events) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
  end

  defp event(run_id, sequence, type) do
    data =
      if type == "run-started" do
        %{"missions" => %{}}
      else
        %{
          "outcome" => "ok",
          "usage" => %{"llm_budget" => %{"total_tokens" => nil, "cost" => nil}}
        }
      end

    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-08-17T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end
end
