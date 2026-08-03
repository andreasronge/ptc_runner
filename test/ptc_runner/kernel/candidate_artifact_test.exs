defmodule PtcRunner.Kernel.CandidateArtifactTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Covers candidate publication: no-clobber, private modes, and cleanup.
  """

  alias PtcRunner.Kernel.CandidateArtifact
  alias PtcRunner.Kernel.ComponentOverride

  @source ~S|(ns helper "Helper." {:visibility :prompt})|

  @tag :tmp_dir
  test "publication derives the hash from the bytes it writes", context do
    out = Path.join(context.tmp_dir, "candidate")

    assert {:ok, published} = CandidateArtifact.publish(out, @source, descriptor())

    assert File.read!(published.candidate) == @source
    descriptor = published.descriptor |> File.read!() |> Jason.decode!()

    # A descriptor that named source it was not published beside would let an
    # operator compile bytes they never reviewed.
    assert descriptor["source_hash"] == ComponentOverride.hash(@source)
    assert descriptor["path"] == "candidate.clj"
  end

  @tag :tmp_dir
  test "candidate source is never world-readable", context do
    out = Path.join(context.tmp_dir, "candidate")

    assert {:ok, published} = CandidateArtifact.publish(out, @source, descriptor())

    # Source may have been extracted from a private result artifact, so
    # publishing it must not declassify it.
    assert %{mode: directory_mode} = File.stat!(published.directory)
    assert Bitwise.band(directory_mode, 0o077) == 0

    for path <- [published.candidate, published.descriptor] do
      assert %{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o077) == 0
    end
  end

  @tag :tmp_dir
  test "an existing destination is refused rather than replaced", context do
    out = Path.join(context.tmp_dir, "candidate")
    File.mkdir_p!(out)

    # An empty directory is the case a rename-based publication would silently
    # replace, so it is the one worth pinning.
    assert {:error, :candidate_destination_exists} =
             CandidateArtifact.publish(out, @source, descriptor())
  end

  @tag :tmp_dir
  test "a refused candidate leaves nothing behind", context do
    out = Path.join(context.tmp_dir, "candidate")

    assert {:ok, published} = CandidateArtifact.publish(out, @source, descriptor())
    assert :ok = CandidateArtifact.discard(published)

    refute File.exists?(out)
  end

  @tag :tmp_dir
  test "an oversized candidate is refused before anything is created", context do
    out = Path.join(context.tmp_dir, "candidate")

    assert {:error, :candidate_source_too_large} =
             CandidateArtifact.publish(out, String.duplicate("x", 1_048_577), descriptor())

    refute File.exists?(out)
  end

  defp descriptor do
    %{
      "component_id" => "helper",
      "base_source_hash" => ComponentOverride.hash("base")
    }
  end
end
