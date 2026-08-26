defmodule PtcRunner.Kernel.TraceDirectoryCaptureTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.Lisp.RetainedSize

  @tag :tmp_dir
  test "a damaged file is isolated beside a healthy filename-bound run", %{tmp_dir: directory} do
    write_events(directory, "healthy.jsonl", [event("healthy", "trace-healthy", 1)])
    File.write!(member(directory, "broken.jsonl"), "not-json\n")

    assert {:ok, capture} = TraceLog.capture_directory(directory)
    assert capture.version == :directory_admission_v1
    assert capture.grant_class == :sanitized
    assert Enum.map(capture.events, & &1["run_id"]) == ["healthy"]
    assert capture.run_sources == %{"healthy" => :sanitized}
    assert capture.analysis.runs_by_id |> Map.keys() == ["healthy"]
    assert capture.known_isolated_run_ids == MapSet.new(["broken"])

    assert [%{source_names: ["broken.jsonl"], reasons: [:malformed_jsonl]}] =
             capture.isolated_components
  end

  @tag :tmp_dir
  test "file evidence uses the closed local reason vocabulary", %{tmp_dir: directory} do
    File.write!(member(directory, "empty.jsonl"), "")

    File.write!(
      member(directory, "duplicate.jsonl"),
      ~s({"schema_version":2,"schema_version":2}\n)
    )

    File.write!(member(directory, "invalid.jsonl"), "{\n")
    File.write!(member(directory, "nonobject.jsonl"), "[]\n")

    unsupported = Map.put(event("version", "trace-version", 1), "schema_version", 3)
    write_events(directory, "version.jsonl", [unsupported])
    write_events(directory, "mismatch.jsonl", [event("other", "trace-other", 1)])

    write_events(directory, "multi.jsonl", [
      event("first", "trace-first", 1),
      event("second", "trace-second", 1)
    ])

    write_events(directory, "sequence.jsonl", [
      event("sequence", "trace-sequence", 1),
      event("sequence", "trace-sequence", 1, "custom", %{})
    ])

    write_events(directory, "lifecycle.jsonl", [
      event("lifecycle", "trace-lifecycle", 1),
      event("lifecycle", "trace-lifecycle", 2)
    ])

    File.ln_s!(member(directory, "empty.jsonl"), member(directory, "linked.jsonl"))

    assert {:ok, capture} = TraceLog.capture_directory(directory)
    reasons = evidence_reasons(capture)

    for name <- ["empty.jsonl", "duplicate.jsonl", "invalid.jsonl", "nonobject.jsonl"] do
      assert reasons[name] == [:malformed_jsonl]
    end

    assert reasons["version.jsonl"] == [:unsupported_version]
    assert reasons["mismatch.jsonl"] == [:filename_run_mismatch]

    assert reasons["multi.jsonl"] == [:filename_run_mismatch]

    assert Enum.find(capture.isolated_components, &(&1.source_names == ["multi.jsonl"])).reasons ==
             [:filename_run_mismatch, :trace_identity_conflict]

    assert reasons["sequence.jsonl"] == [:sequence_conflict]
    assert reasons["lifecycle.jsonl"] == [:lifecycle_conflict]
    assert reasons["linked.jsonl"] == [:not_regular]
  end

  @tag :tmp_dir
  test "a stable unreadable regular member is isolated", %{tmp_dir: directory} do
    path = member(directory, "unreadable.jsonl")
    write_events(directory, "unreadable.jsonl", [event("unreadable", "trace", 1)])
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o600) end)

    assert {:error, :eacces} = File.read(path)
    assert {:ok, capture} = TraceLog.capture_directory(directory)

    assert [%{source_names: ["unreadable.jsonl"], reasons: [:unreadable]}] =
             capture.isolated_components

    assert capture.source_bytes == File.stat!(path).size
  end

  @tag :tmp_dir
  test "invalid basenames stay in proof and identity but not safe source metadata", %{
    tmp_dir: directory
  } do
    raw_name = "-unsafe.jsonl"
    source = Jason.encode!(event("embedded", "trace-embedded", 1)) <> "\n"
    File.write!(member(directory, raw_name), source)

    assert {:ok, first} = TraceLog.capture_directory(directory)

    assert [%{source_names: [], source_count: 1, sources_omitted_count: 1}] =
             first.isolated_components

    assert [%{raw_name: ^raw_name, content_digest: digest}] = first.source_proofs
    assert is_binary(digest) and byte_size(digest) == 32

    File.write!(member(directory, raw_name), source <> "\n")
    assert {:ok, second} = TraceLog.capture_directory(directory)
    refute second.source_id == first.source_id
  end

  @tag :tmp_dir
  test "run and trace claim conflicts isolate complete connected components", %{
    tmp_dir: directory
  } do
    write_events(directory, "same.jsonl", [event("same", "trace-same", 1)])
    write_events(directory, "other.jsonl", [event("same", "trace-same", 2, "custom", %{})])
    write_events(directory, "left.jsonl", [event("left", "shared-trace", 1)])
    write_events(directory, "right.jsonl", [event("right", "shared-trace", 2)])

    assert {:ok, capture} = TraceLog.capture_directory(directory)
    assert capture.events == []

    assert Enum.map(capture.isolated_components, & &1.source_names) == [
             ["left.jsonl", "right.jsonl"],
             ["other.jsonl", "same.jsonl"]
           ]

    assert Enum.map(capture.isolated_components, & &1.reasons) == [
             [:trace_identity_conflict],
             [
               :filename_run_mismatch,
               :run_identity_conflict,
               :trace_identity_conflict,
               :lifecycle_conflict
             ]
           ]
  end

  @tag :tmp_dir
  test "normal, private-only, and mixed grants select only their authorized classes", %{
    tmp_dir: directory
  } do
    write_events(directory, "normal.jsonl", [event("normal", "trace-normal", 1)])
    write_events(directory, "private.private.jsonl", [event("private", "trace-private", 1)])

    assert {:ok, normal} = TraceLog.capture_directory(directory)
    assert normal.grant_class == :sanitized
    assert Map.keys(normal.run_sources) == ["normal"]
    assert normal.excluded_trace_files == %{"excluded_private_trace_files" => 1}
    refute inspect(normal.source_proofs) =~ "private.private.jsonl"

    assert {:ok, private} =
             TraceLog.capture_directory(directory,
               source_kind: :private,
               include_sanitized: false
             )

    assert private.grant_class == :private
    assert Map.keys(private.run_sources) == ["private"]
    assert private.excluded_trace_files == %{"excluded_sanitized_trace_files" => 1}
    refute inspect(private.source_proofs) =~ "normal.jsonl"

    assert {:ok, mixed} = TraceLog.capture_directory(directory, source_kind: :private)
    assert mixed.grant_class == :mixed_private_authorized
    assert Map.keys(mixed.run_sources) |> Enum.sort() == ["normal", "private"]
    assert mixed.excluded_trace_files == %{}
    refute mixed.source_id == private.source_id
  end

  @tag :tmp_dir
  test "source identity is deterministic and excludes opposite-class activity", %{
    tmp_dir: first_directory
  } do
    second_directory = first_directory <> "-second"
    File.mkdir!(second_directory)
    on_exit(fn -> File.rm_rf!(second_directory) end)

    write_events(first_directory, "b.jsonl", [event("b", "trace-b", 1)])
    write_events(first_directory, "a.jsonl", [event("a", "trace-a", 1)])
    write_events(second_directory, "a.jsonl", [event("a", "trace-a", 1)])
    write_events(second_directory, "b.jsonl", [event("b", "trace-b", 1)])

    assert {:ok, first} = TraceLog.capture_directory(first_directory)
    assert {:ok, second} = TraceLog.capture_directory(second_directory)
    assert first.source_id == second.source_id

    write_events(first_directory, "hidden.private.jsonl", [event("hidden", "trace-hidden", 1)])
    assert {:ok, with_excluded} = TraceLog.capture_directory(first_directory)
    assert with_excluded.source_id == first.source_id
    assert with_excluded.excluded_trace_files == %{"excluded_private_trace_files" => 1}
  end

  @tag :tmp_dir
  test "excluded-class namespace changes are advisory unless they cross the entry ceiling", %{
    tmp_dir: directory
  } do
    write_events(directory, "normal.jsonl", [event("normal", "trace-normal", 1)])
    test = self()

    capture =
      Task.async(fn ->
        TraceLog.capture_directory(directory,
          listing_hook: fn ->
            send(test, {:listing, self()})

            receive do
              :continue -> :ok
            end
          end
        )
      end)

    assert_receive {:listing, first_listing}, 5_000
    send(first_listing, :continue)
    assert_receive {:listing, second_listing}, 5_000
    write_events(directory, "private.private.jsonl", [event("private", "trace-private", 1)])
    send(second_listing, :continue)
    assert_receive {:listing, final_listing}, 5_000
    send(final_listing, :continue)

    assert {:ok, captured} = Task.await(capture)
    assert Map.keys(captured.run_sources) == ["normal"]
    assert captured.excluded_trace_files == %{"excluded_private_trace_files" => 1}

    File.rm!(member(directory, "private.private.jsonl"))

    limited =
      Task.async(fn ->
        TraceLog.capture_directory(directory,
          max_directory_entries: 1,
          listing_hook: fn ->
            send(test, {:limited_listing, self()})

            receive do
              :continue -> :ok
            end
          end
        )
      end)

    assert_receive {:limited_listing, first_limited}, 5_000
    send(first_limited, :continue)
    assert_receive {:limited_listing, second_limited}, 5_000
    write_events(directory, "private.private.jsonl", [event("private", "trace-private", 1)])
    send(second_limited, :continue)
    assert {:error, :source_limit_exceeded} = Task.await(limited)
  end

  @tag :tmp_dir
  test "directory root replacement rejects the complete capture", %{tmp_dir: directory} do
    write_events(directory, "stable.jsonl", [event("stable", "trace-stable", 1)])
    original = directory <> "-original"
    on_exit(fn -> File.rm_rf(original) end)
    test = self()

    capture =
      Task.async(fn ->
        TraceLog.capture_directory(directory,
          capture_hook: fn ->
            send(test, {:captured, self()})

            receive do
              :continue -> :ok
            end
          end
        )
      end)

    assert_receive {:captured, capture_pid}, 5_000
    File.rename!(directory, original)
    File.mkdir!(directory)
    write_events(directory, "stable.jsonl", [event("stable", "trace-stable", 1)])
    send(capture_pid, :continue)

    assert {:error, :source_changed} = Task.await(capture)
  end

  @tag :tmp_dir
  test "snapshot retention charges the complete directory admission value", %{tmp_dir: directory} do
    write_events(directory, "healthy.jsonl", [event("healthy", "trace-healthy", 1)])
    File.write!(member(directory, "broken.jsonl"), "bad\n")

    assert {:ok, capture} = TraceLog.capture_directory(directory)
    expected_retained_bytes = RetainedSize.bytes(capture)

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)
    assert {:ok, %{retained_bytes: ^expected_retained_bytes}} = TraceSnapshot.info(snapshot)

    assert {:error,
            {:source_retained_limit_exceeded,
             %{measured_bytes: ^expected_retained_bytes, limit_bytes: 1}}} =
             TraceSnapshot.start({:directory, directory}, owner: self(), max_retained_bytes: 1)
  end

  defp evidence_reasons(capture) do
    capture.components
    |> Enum.flat_map(& &1.sources)
    |> Map.new(&{&1.source_name, &1.reasons})
  end

  defp write_events(directory, name, events) do
    encoded = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
    File.write!(member(directory, name), encoded)
  end

  defp member(directory, raw_name), do: directory <> "/" <> raw_name

  defp event(run_id, trace_id, sequence, type \\ "run-started", data \\ nil) do
    data = data || if(type == "run-started", do: %{"missions" => %{}}, else: %{})

    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => trace_id,
      "sequence" => sequence,
      "timestamp" => "2026-08-26T00:00:00Z",
      "type" => type,
      "data" => data
    }
  end
end
