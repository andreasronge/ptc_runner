defmodule PtcRunner.Kernel.RunCatalogTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.RunCatalog

  @run_ref "cmd-00000000000000000000000001"
  @trace_id "trace-cmd-00000000000000000000000001"

  describe "states no filesystem can be made to hold still for" do
    test "an entry that moved under its own probe is isolated, never described" do
      {:ok, %{rows: [row]}} =
        RunCatalog.generation([probe(trace: %{present: :unstable})], 0)

      assert row["run_id"] == @run_ref
      assert row["state"] == "isolated"
      assert row["isolation_reason"] == "unstable_entry"
      assert row["trace_present"] == "unreadable"
      assert row["trace_id"] == nil
      assert row["trace_bytes"] == nil
    end

    test "an unstable sealed artifact isolates its row" do
      {:ok, %{rows: [row]}} =
        RunCatalog.generation([probe(inspection: %{present: :unstable})], 0)

      assert row["isolation_reason"] == "unstable_entry"
      assert row["inspection_present"] == true
      assert row["artifact_digest"] == nil
    end
  end

  describe "reason precedence" do
    test "an entry that is both malformed and duplicated reports the malformation" do
      duplicate = fn run_ref ->
        probe(run_ref: run_ref, trace: trace_probe(run_id: run_ref))
      end

      {:ok, %{rows: rows}} =
        RunCatalog.generation(
          [
            %{duplicate.("cmd-0000000000000000000000000a") | inspection: %{present: :malformed}},
            duplicate.("cmd-0000000000000000000000000b")
          ],
          0
        )

      [malformed, plain] = rows

      assert malformed["isolation_reason"] == "malformed_metadata"
      assert plain["isolation_reason"] == "duplicate_run_identity"
    end

    test "every reason the catalog can report is ordered" do
      assert RunCatalog.reason_order() == Enum.uniq(RunCatalog.reason_order())
      assert Enum.all?(RunCatalog.reason_order(), &is_atom/1)
    end
  end

  describe "generation identity" do
    test "the same probes commit to the same digest regardless of capture order" do
      probes = [
        probe(
          run_ref: "cmd-0000000000000000000000000a",
          trace: trace_probe(run_id: "cmd-0000000000000000000000000a")
        ),
        probe(
          run_ref: "cmd-0000000000000000000000000b",
          trace: trace_probe(run_id: "cmd-0000000000000000000000000b")
        )
      ]

      {:ok, forward} = RunCatalog.generation(probes, 0)
      {:ok, reversed} = RunCatalog.generation(Enum.reverse(probes), 0)

      assert forward.catalog_digest == reversed.catalog_digest
      assert Enum.map(forward.rows, & &1["run_id"]) == Enum.map(reversed.rows, & &1["run_id"])
    end

    test "an absent half commits to its absence" do
      {:ok, paired} = RunCatalog.generation([probe()], 0)
      {:ok, trace_only} = RunCatalog.generation([probe(inspection: %{present: :absent})], 0)

      refute paired.catalog_digest == trace_only.catalog_digest
    end

    test "the same bytes under a different reference are a different generation" do
      {:ok, first} = RunCatalog.generation([probe()], 0)

      {:ok, second} =
        RunCatalog.generation([probe(run_ref: "cmd-0000000000000000000000000z")], 0)

      refute first.catalog_digest == second.catalog_digest
    end

    test "a probe list that repeats a reference is refused" do
      assert {:error, :invalid_catalog} = RunCatalog.generation([probe(), probe()], 0)
      assert {:error, :invalid_catalog} = RunCatalog.generation([%{run_ref: @run_ref}], 0)
      assert {:error, :invalid_catalog} = RunCatalog.generation([probe()], -1)
    end

    test "a probed half missing a field a row reads refuses the generation" do
      assert {:error, :invalid_catalog} =
               RunCatalog.generation([probe(trace: %{present: :probed})], 0)

      assert {:error, :invalid_catalog} =
               RunCatalog.generation([probe(inspection: %{present: :probed})], 0)

      assert {:error, :invalid_catalog} =
               RunCatalog.generation([probe(trace: %{present: :unrecognised})], 0)

      assert {:error, :invalid_catalog} =
               RunCatalog.generation(
                 [probe(trace: put_in(trace_probe([]), [:head, :trace_id], 42))],
                 0
               )
    end
  end

  describe "row bounds" do
    test "label data beyond the row bound is reduced and isolated, not published" do
      labels = %{"name" => String.duplicate("n", RunCatalog.max_row_bytes())}

      {:ok, %{rows: [row]}} =
        RunCatalog.generation([probe(trace: trace_probe(labels: labels))], 0)

      assert row["state"] == "isolated"
      assert row["isolation_reason"] == "malformed_metadata"
      assert row["name"] == nil
      assert row["labels"] == %{}
      assert row["run_id"] == @run_ref
      assert row["trace_id"] == @trace_id
      assert byte_size(Jason.encode!(row)) <= RunCatalog.max_row_bytes()
    end

    test "label data inside the bound is published as the public surface exposes it" do
      labels = %{
        "name" => "cohort-arm",
        "model" => "model-a",
        "provider" => "provider-a",
        "tags" => %{"suite" => "conformance"}
      }

      {:ok, %{rows: [row]}} =
        RunCatalog.generation([probe(trace: trace_probe(labels: labels))], 0)

      assert row["state"] == "admissible"
      assert row["name"] == "cohort-arm"
      assert row["model"] == "model-a"
      assert row["provider"] == "provider-a"
      assert row["tags"] == %{"suite" => "conformance"}
    end
  end

  defp probe(overrides \\ []) do
    run_ref = Keyword.get(overrides, :run_ref, @run_ref)

    %{
      run_ref: run_ref,
      trace: Keyword.get(overrides, :trace, trace_probe(run_id: run_ref)),
      inspection: Keyword.get(overrides, :inspection, inspection_probe(run_id: run_ref))
    }
  end

  defp trace_probe(overrides) do
    %{
      present: :probed,
      source_kind: :sanitized,
      bytes: 512,
      identity: {512, 1, 2, 3, 0},
      commitment: :crypto.hash(:sha256, "head-tail"),
      head: %{
        run_id: Keyword.get(overrides, :run_id, @run_ref),
        trace_id: @trace_id,
        schema_version: 2,
        timestamp: "2026-07-26T12:00:01Z",
        labels: Keyword.get(overrides, :labels, %{})
      },
      tail: %{
        timestamp: "2026-07-26T12:00:08Z",
        status: "ok",
        terminal_reason: nil,
        result_hash: nil
      }
    }
  end

  defp inspection_probe(overrides) do
    %{
      present: :probed,
      format_version: Format.format_version(),
      schema_version: Format.schema_version(),
      bytes: 4_096,
      record_count: 12,
      run_id_sha256: Format.identity_sha256(Keyword.fetch!(overrides, :run_id)),
      trace_id_sha256: Format.identity_sha256(@trace_id),
      artifact_digest: :crypto.hash(:sha256, "artifact")
    }
  end
end
