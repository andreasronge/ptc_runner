defmodule PtcRunner.PreludeStoreTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.PreludeCandidate
  alias PtcRunner.PreludeStore

  @paged_v1 """
  (ns paged "Paged helpers.")

  (defn inspect [] {:version 1})
  """

  @paged_v2 """
  (ns paged "Paged helpers.")

  (defn inspect [] {:version 2})
  (defn profile [] {:ok true})
  """

  test "write/list/read store versioned compiled candidates" do
    {:ok, store} = PreludeStore.new()

    assert {:ok, result} =
             PreludeStore.write(store, "paged", @paged_v1, %{
               "reason" => "initial",
               "ignored" => "not public"
             })

    assert result.id == "paged"
    assert result.version == 1
    assert result.checksum =~ ~r/\A[0-9a-f]{64}\z/
    assert result.namespaces == ["paged"]
    assert result.exports == ["inspect"]
    assert result.metadata == %{"reason" => "initial"}
    refute Map.has_key?(Map.from_struct(store), :table)

    assert [
             %{
               id: "paged",
               current_version: 1,
               latest_version: 1,
               versions_count: 1,
               checksum: checksum,
               namespaces: ["paged"],
               exports: ["inspect"],
               metadata: %{"reason" => "initial"},
               origin: "memory",
               created_at: %DateTime{},
               updated_at: %DateTime{}
             }
           ] = PreludeStore.list(store)

    assert checksum == result.checksum

    assert {:ok, %PreludeCandidate{} = candidate} = PreludeStore.read(store, "paged")
    assert candidate.id == "paged"
    assert candidate.version == 1
    assert PreludeCandidate.checksum(candidate) == result.checksum
    assert candidate.source == @paged_v1
    assert candidate.metadata == %{"reason" => "initial", "ignored" => "not public"}
    assert %Prelude{} = candidate.compiled

    assert PreludeCandidate.public_view(candidate).source == @paged_v1
    assert PreludeCandidate.public_view(candidate).source_bytes == byte_size(@paged_v1)
    assert PreludeCandidate.public_view(candidate).source_truncated == false
    assert PreludeCandidate.public_view(candidate).origin == "memory"
    refute Map.has_key?(PreludeCandidate.public_view(candidate), :compiled)
  end

  test "writes assign monotonic versions and bare reads resolve current latest" do
    {:ok, store} = PreludeStore.new()

    assert {:ok, first} = PreludeStore.write(store, "paged", @paged_v1)
    assert {:ok, second} = PreludeStore.write(store, "paged", @paged_v2)

    assert first.version == 1
    assert second.version == 2

    assert {:ok, current} = PreludeStore.read(store, "paged")
    assert current.version == 2

    assert {:ok, pinned} = PreludeStore.read(store, "paged@1")
    assert pinned.version == 1

    assert {:ok, checked} =
             PreludeStore.read(store, %{id: "paged", version: 1, checksum: first.checksum})

    assert checked.version == 1

    assert {:error, %{reason: :checksum_mismatch}} =
             PreludeStore.read(store, %{id: "paged", version: 1, checksum: second.checksum})
  end

  test "set_default pins bare reads while latest tracking remains monotonic" do
    {:ok, store} = PreludeStore.new()

    assert {:ok, first} = PreludeStore.write(store, "paged", @paged_v1)
    assert {:ok, _second} = PreludeStore.write(store, "paged", @paged_v2)

    v3 = """
    (ns paged "Paged helpers.")

    (defn inspect [] {:version 3})
    """

    assert {:ok, third} = PreludeStore.write(store, "paged", v3)

    assert {:ok, selected} =
             PreludeStore.set_default(store, "paged", 1, %{
               "reason" => "verifier preferred the smaller helper",
               "ignored" => "not public"
             })

    assert selected.id == "paged"
    assert selected.current_version == 1
    assert selected.latest_version == 3
    assert selected.checksum == first.checksum
    assert selected.metadata == %{"reason" => "verifier preferred the smaller helper"}
    assert %DateTime{} = selected.updated_at

    assert [%{current_version: 1, latest_version: 3, versions_count: 3, checksum: checksum}] =
             PreludeStore.list(store)

    assert checksum == first.checksum

    assert {:ok, current} = PreludeStore.read(store, "paged")
    assert current.version == 1

    assert {:ok, latest} = PreludeStore.read(store, "paged@3")
    assert latest.version == third.version

    assert {:ok,
            [
              %{version: 1, current: true, checksum: first_checksum},
              %{version: 2, current: false},
              %{version: 3, current: false, checksum: third_checksum}
            ]} = PreludeStore.history(store, "paged")

    assert first_checksum == first.checksum
    assert third_checksum == third.checksum
  end

  test "set_default rejects missing versions and checksum mismatches" do
    {:ok, store} = PreludeStore.new()

    assert {:ok, first} = PreludeStore.write(store, "paged", @paged_v1)
    assert {:ok, second} = PreludeStore.write(store, "paged", @paged_v2)

    assert {:error, %{reason: :not_found}} = PreludeStore.set_default(store, "paged", 3)

    assert {:error, %{reason: :checksum_mismatch}} =
             PreludeStore.set_default(store, %{id: "paged", version: 1, checksum: second.checksum})

    assert {:ok, current} = PreludeStore.read(store, "paged")
    assert current.version == 2

    assert {:ok, selected} =
             PreludeStore.set_default(store, %{
               id: "paged",
               version: 1,
               checksum: first.checksum
             })

    assert selected.current_version == 1
  end

  test "history validates ids and unknown ids return not_found" do
    {:ok, store} = PreludeStore.new()

    assert {:error, %{reason: :not_found}} = PreludeStore.history(store, "paged")

    assert {:error, %{reason: :prelude_namespace_violation}} =
             PreludeStore.history(store, "bad@id")

    assert {:error, %{reason: :invalid_ref}} = PreludeStore.set_default(store, "paged")
  end

  test "write rejects wrong namespace, invalid ids, and curated namespace collisions" do
    {:ok, store} = PreludeStore.new()

    assert {:error, %{reason: :prelude_namespace_violation, message: id_message}} =
             PreludeStore.write(store, "bad@id", @paged_v1)

    assert id_message =~ "invalid prelude id"

    assert {:error, %{reason: :prelude_namespace_violation, message: mismatch_message}} =
             PreludeStore.write(store, "other", @paged_v1)

    assert mismatch_message =~ "compiled namespaces must be exactly [\"other\"]"

    curated = """
    (ns clojure.string)
    (defn trim2 [x] x)
    """

    assert {:error, %{reason: :prelude_namespace_violation, message: curated_message}} =
             PreludeStore.write(store, "clojure.string", curated)

    assert curated_message =~ "reserved or curated"

    java = """
    (ns Math)
    (defn plus-one [x] x)
    """

    assert {:error, %{reason: :prelude_namespace_violation, message: java_message}} =
             PreludeStore.write(store, "Math", java)

    assert java_message =~ "reserved or curated"
  end

  test "stale parent checksum fails without storing a new version" do
    {:ok, store} = PreludeStore.new()

    assert {:ok, first} = PreludeStore.write(store, "paged", @paged_v1)
    assert {:ok, _second} = PreludeStore.write(store, "paged", @paged_v2)

    assert {:error, %{reason: :stale_base}} =
             PreludeStore.write(store, "paged", @paged_v1, %{"parent_checksum" => first.checksum})

    assert [%{versions_count: 2, latest_version: 2}] = PreludeStore.list(store)
  end

  test "source byte bounds and compile failures return store error maps" do
    {:ok, store} = PreludeStore.new(max_source_bytes: 10)

    assert {:error, %{reason: :source_too_large, limit_bytes: 10}} =
             PreludeStore.write(store, "paged", @paged_v1)

    {:ok, store} = PreludeStore.new()

    assert {:error, %{reason: :prelude_compile_error, compile_reason: :parse_error}} =
             PreludeStore.write(store, "paged", "(ns paged")
  end

  test "version retention prunes superseded rows instead of blocking writes" do
    {:ok, store} = PreludeStore.new(max_versions: 2)

    assert {:ok, first} = PreludeStore.write(store, "paged", @paged_v1)
    assert {:ok, second} = PreludeStore.write(store, "paged", @paged_v2)

    v3 = """
    (ns paged "Paged helpers.")

    (defn inspect [] {:version 3})
    """

    assert {:ok, third} = PreludeStore.write(store, "paged", v3)

    assert first.version == 1
    assert second.version == 2
    assert third.version == 3

    assert [%{latest_version: 3, versions_count: 2}] = PreludeStore.list(store)
    assert {:error, %{reason: :not_found}} = PreludeStore.read(store, "paged@1")

    assert {:ok, [%{version: 2}, %{version: 3, latest: true}]} =
             PreludeStore.history(store, "paged")

    assert {:ok, candidate} = PreludeStore.read(store, "paged")
    assert candidate.version == 3

    {:ok, store} = PreludeStore.new(max_versions: 1)

    assert {:ok, _first} = PreludeStore.write(store, "paged", @paged_v1)
    assert {:ok, second} = PreludeStore.write(store, "paged", @paged_v2)

    assert [%{latest_version: 2, versions_count: 1}] = PreludeStore.list(store)
    assert {:error, %{reason: :not_found}} = PreludeStore.read(store, "paged@1")
    assert {:ok, [%{version: 2}]} = PreludeStore.history(store, "paged")
    assert {:ok, current} = PreludeStore.read(store, "paged")
    assert PreludeCandidate.checksum(current) == second.checksum
  end

  test "version retention preserves an explicitly pinned older default" do
    {:ok, store} = PreludeStore.new(max_versions: 1)

    assert {:ok, first} = PreludeStore.write(store, "paged", @paged_v1)
    assert {:ok, _selected} = PreludeStore.set_default(store, "paged", 1)
    assert {:ok, _second} = PreludeStore.write(store, "paged", @paged_v2)

    v3 = """
    (ns paged "Paged helpers.")

    (defn inspect [] {:version 3})
    """

    assert {:ok, third} = PreludeStore.write(store, "paged", v3)

    assert [%{current_version: 3, latest_version: 3, versions_count: 2}] =
             PreludeStore.list(store)

    assert {:ok, current} = PreludeStore.read(store, "paged")
    assert PreludeCandidate.checksum(current) == third.checksum

    assert {:ok, pinned} = PreludeStore.read(store, "paged@1")
    assert PreludeCandidate.checksum(pinned) == first.checksum

    assert {:error, %{reason: :not_found}} = PreludeStore.read(store, "paged@2")

    assert {:ok, [%{version: 1, current: false}, %{version: 3, current: true, latest: true}]} =
             PreludeStore.history(store, "paged")
  end

  test "public view source bounds are enforced" do
    {:ok, store} = PreludeStore.new()

    assert {:ok, _first} = PreludeStore.write(store, "paged", @paged_v1)

    assert {:ok, candidate} = PreludeStore.read(store, "paged")
    view = PreludeCandidate.public_view(candidate, max_source_bytes: 8)

    assert byte_size(view.source) == 8
    assert view.source_bytes == byte_size(@paged_v1)
    assert view.source_truncated == true
    refute Map.has_key?(view, :compiled)
  end

  test "invalid store bounds fail at construction instead of crashing later" do
    for opts <- [
          [max_source_bytes: "10"],
          [max_versions: nil],
          [max_ids: 0],
          [max_total_bytes: :infinity],
          [max_metadata_bytes: -1],
          [compile_timeout: 0],
          [compile_max_heap: -1]
        ] do
      assert {:error, %{reason: :invalid_config}} = PreludeStore.new(opts)
    end
  end

  test "store id, total byte, and metadata bounds fail closed" do
    {:ok, store} = PreludeStore.new(max_ids: 1)

    assert {:ok, _} = PreludeStore.write(store, "paged", @paged_v1)

    other = """
    (ns other)
    (defn inspect [] {:version 1})
    """

    assert {:error, %{reason: :id_limit_exceeded, limit: 1}} =
             PreludeStore.write(store, "other", other)

    assert [%{id: "paged"}] = PreludeStore.list(store)

    {:ok, store} = PreludeStore.new(max_total_bytes: 1)

    assert {:error, %{reason: :store_bytes_exceeded, limit_bytes: 1}} =
             PreludeStore.write(store, "paged", @paged_v1)

    assert PreludeStore.list(store) == []

    {:ok, store} = PreludeStore.new(max_metadata_bytes: 8)

    assert {:error, %{reason: :metadata_too_large, limit_bytes: 8}} =
             PreludeStore.write(store, "paged", @paged_v1, %{
               "reason" => String.duplicate("x", 100)
             })

    assert PreludeStore.list(store) == []
  end

  test "public origin projection is bounded and serializable" do
    {:ok, store} = PreludeStore.new(origin: {:memory, self()})
    assert {:ok, _} = PreludeStore.write(store, "paged", @paged_v1)
    assert [%{origin: "memory"}] = PreludeStore.list(store)

    {:ok, store} = PreludeStore.new(origin: {:upstream, {:secret, String.duplicate("x", 200)}})
    assert {:ok, _} = PreludeStore.write(store, "paged", @paged_v1)
    assert [%{origin: origin}] = PreludeStore.list(store)

    assert is_binary(origin)
    assert byte_size(origin) <= 128
    assert {:ok, _} = Jason.encode(%{origin: origin})
  end

  test "public projections keep bounds even with bad options and preserve utf-8" do
    source = """
    (ns paged)
    (defn emoji [] "🙂")
    """

    {:ok, store} =
      PreludeStore.new(
        origin: {:upstream, "αβγ"},
        max_source_bytes: 1_000
      )

    assert {:ok, _} =
             PreludeStore.write(store, "paged", source, %{
               "reason" => "🙂🙂",
               "private" => "secret"
             })

    assert {:ok, candidate} = PreludeStore.read(store, "paged")

    bad_opts_view =
      PreludeCandidate.public_view(candidate,
        max_source_bytes: nil,
        max_metadata_bytes: "4",
        max_origin_bytes: :bad
      )

    assert byte_size(bad_opts_view.source) <= 64 * 1024
    assert bad_opts_view.metadata == %{"reason" => "🙂🙂"}
    assert String.valid?(bad_opts_view.origin)

    utf8_view =
      PreludeCandidate.public_view(candidate,
        max_source_bytes: byte_size("(ns paged)\n(defn emoji [] \"") + 1,
        max_metadata_bytes: 5,
        max_origin_bytes: 12
      )

    assert String.valid?(utf8_view.source)
    assert String.valid?(utf8_view.metadata["reason"])
    assert String.valid?(utf8_view.origin)
  end

  test "unknown reads return not_found errors" do
    {:ok, store} = PreludeStore.new()

    assert {:error, %{reason: :not_found}} = PreludeStore.read(store, "paged")
    assert {:error, %{reason: :not_found}} = PreludeStore.read(store, "paged@1")
  end

  test "same-id concurrent writes produce contiguous versions" do
    {:ok, store} = PreludeStore.new()

    versions =
      1..10
      |> Task.async_stream(
        fn n ->
          source = """
          (ns paged)
          (defn v [] #{n})
          """

          {:ok, result} = PreludeStore.write(store, "paged", source)
          result.version
        end,
        max_concurrency: 10,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, version} -> version end)
      |> Enum.sort()

    assert versions == Enum.to_list(1..10)
    assert [%{latest_version: 10, versions_count: 10}] = PreludeStore.list(store)
  end
end
