defmodule PtcRunner.PreludeStoreTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.FormScanner
  alias PtcRunner.PreludeCandidate
  alias PtcRunner.PreludeStore
  alias PtcRunner.PreludeStore.FormEdit

  @paged_v1 """
  (ns paged "Paged helpers.")

  (defn inspect [] {:version 1})
  """

  @paged_v2 """
  (ns paged "Paged helpers.")

  (defn inspect [] {:version 2})
  (defn profile [] {:ok true})
  """

  @edit_base """
  (ns store-edit
    "Store edit test namespace.")

  ;; Fetch the raw record from upstream.
  (defn- fetch-raw
    "Fetch the raw record."
    [id]
    (tool/call {:server "crm" :tool "get_user" :args {:id id}}))

  (defn get-user
    "Return a user by id."
    [id]
    (fetch-raw id))

  (defn- unused-helper
    "Never called."
    []
    42)

  (def max-retries "Retry budget." 3)
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

    prelude_wrapper = """
    (ns prelude)
    (defn list2 [] [])
    """

    assert {:error, %{reason: :prelude_namespace_violation, message: prelude_message}} =
             PreludeStore.write(store, "prelude", prelude_wrapper)

    assert prelude_message =~ "reserved or curated"
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

  test "same-id concurrent writes produce contiguous versions and leave bare reads on latest" do
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

    assert [%{current_version: 10, latest_version: 10, versions_count: 10}] =
             PreludeStore.list(store)

    assert {:ok, current} = PreludeStore.read(store, "paged")
    assert current.version == 10
  end

  test "same-parent concurrent writes allow one append and reject stale contenders" do
    {:ok, store} = PreludeStore.new()
    assert {:ok, base} = PreludeStore.write(store, "paged", @paged_v1)

    results =
      2..8
      |> Task.async_stream(
        fn n ->
          source = """
          (ns paged)
          (defn v [] #{n})
          """

          PreludeStore.write(store, "paged", source, %{"parent_checksum" => base.checksum})
        end,
        max_concurrency: 7,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    successes = Enum.filter(results, &match?({:ok, _}, &1))
    stale_errors = Enum.filter(results, &match?({:error, %{reason: :stale_base}}, &1))

    assert [{:ok, written}] = successes
    assert length(stale_errors) == 6
    assert written.version == 2

    assert [%{current_version: 2, latest_version: 2, versions_count: 2}] =
             PreludeStore.list(store)

    assert {:ok, current} = PreludeStore.read(store, "paged")
    assert current.version == 2
  end

  describe "PreludeStore.edit/3,4" do
    test "applies a multi-op batch as one version bump and echoes base_version/parent_checksum/forms" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, base} = PreludeStore.write(store, "store-edit", @edit_base)

      edits = [
        %{
          op: :replace_form,
          name: "get-user",
          source: ~S"""
          (defn get-user
            "Return a user by id (v2)."
            [id]
            (fetch-raw id))
          """
        },
        %{op: :add_form, source: ~S|(defn list-users "List users." [] [])|},
        %{op: :remove_form, name: "unused-helper"},
        %{op: :set_ns_doc, doc: "Updated store edit test namespace."}
      ]

      assert {:ok, result} = PreludeStore.edit(store, "store-edit", edits)

      assert result.id == "store-edit"
      assert result.version == 2
      assert result.base_version == 1
      assert result.parent_checksum == base.checksum

      assert result.forms == %{
               replaced: ["get-user"],
               added: ["list-users"],
               removed: ["unused-helper"],
               ns_doc_set: true
             }

      assert [%{versions_count: 2, latest_version: 2}] = PreludeStore.list(store)
    end

    test "untouched forms are byte-identical after an edit batch" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      edits = [
        %{
          op: :replace_form,
          name: "get-user",
          source: ~S|(defn get-user "v2" [id] (fetch-raw id))|
        },
        %{op: :remove_form, name: "unused-helper"}
      ]

      assert {:ok, result} = PreludeStore.edit(store, "store-edit", edits)
      assert {:ok, new_candidate} = PreludeStore.read(store, "store-edit@#{result.version}")

      {:ok, old_scan} = FormScanner.scan(@edit_base)
      {:ok, new_scan} = FormScanner.scan(new_candidate.source)

      old_fetch_raw = Enum.find(old_scan.forms, &(&1.name == "fetch-raw"))
      new_fetch_raw = Enum.find(new_scan.forms, &(&1.name == "fetch-raw"))

      assert slice(@edit_base, old_fetch_raw.gap) ==
               slice(new_candidate.source, new_fetch_raw.gap)

      assert slice(@edit_base, old_fetch_raw.span) ==
               slice(new_candidate.source, new_fetch_raw.span)

      old_max_retries = Enum.find(old_scan.forms, &(&1.name == "max-retries"))
      new_max_retries = Enum.find(new_scan.forms, &(&1.name == "max-retries"))

      assert slice(@edit_base, old_max_retries.span) ==
               slice(new_candidate.source, new_max_retries.span)
    end

    test "a replace_form visibility flip (defn -> defn-) surfaces in public_surface.changed" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      edits = [
        %{
          op: :replace_form,
          name: "get-user",
          source: ~S|(defn- get-user "now private" [id] (fetch-raw id))|
        }
      ]

      assert {:ok, result} = PreludeStore.edit(store, "store-edit", edits)

      assert %{added: [], removed: [], changed: changed} = result.public_surface
      assert [%{name: "get-user", before: before, after: aft}] = changed
      assert before.visibility == :public
      assert aft.visibility == :private
      assert before.kind == aft.kind
      assert before.arity == aft.arity
    end

    # An authority-only change: swapping a private helper's literal tool/call
    # target leaves visibility/kind/arity/effect equal everywhere, so a diff
    # over those fields alone would report `changed: []` — hiding exactly the
    # capability change the human gate most needs to see. Both the helper and
    # the public fn that transitively inherits its requires must surface.
    test "swapping a helper's upstream target surfaces as an authority change" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      edits = [
        %{
          op: :replace_form,
          name: "fetch-raw",
          source: ~S|(defn- fetch-raw
            "Fetch the raw record."
            [id]
            (tool/call {:server "crm" :tool "list_users" :args {:id id}}))|
        }
      ]

      assert {:ok, result} = PreludeStore.edit(store, "store-edit", edits)

      assert %{added: [], removed: [], changed: changed} = result.public_surface
      changed_by_name = Map.new(changed, &{&1.name, &1})
      assert %{before: helper_before, after: helper_after} = changed_by_name["fetch-raw"]
      assert helper_before.requires == ["upstream:crm/get_user"]
      assert helper_after.requires == ["upstream:crm/list_users"]
      assert helper_before.visibility == helper_after.visibility

      assert %{before: caller_before, after: caller_after} = changed_by_name["get-user"]
      assert caller_before.requires == ["upstream:crm/get_user"]
      assert caller_after.requires == ["upstream:crm/list_users"]
    end

    # Export-metadata-only change: body, visibility (public), kind, and arity
    # are all identical — only explicit `{:requires [...]}` metadata and the
    # prompt-surface `:visibility` flip. The compiled Export (requires union,
    # :prompt/:discoverable) is authoritative for publics, so this must land
    # in `changed`, not compare equal on graph-derived fields alone.
    test "an export-metadata-only replace surfaces in public_surface.changed" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      edits = [
        %{
          op: :replace_form,
          name: "get-user",
          source: ~S|(defn get-user
            "Return a user by id."
            {:requires ["upstream:audit/log"] :visibility :discoverable}
            [id]
            (fetch-raw id))|
        }
      ]

      assert {:ok, result} = PreludeStore.edit(store, "store-edit", edits)

      assert %{added: [], removed: [], changed: changed} = result.public_surface
      assert [%{name: "get-user", before: before, after: aft}] = changed
      assert before.visibility == aft.visibility
      assert before.arity == aft.arity
      assert before.requires == ["upstream:crm/get_user"]
      assert aft.requires == ["upstream:audit/log", "upstream:crm/get_user"]
      assert before.export_visibility == :prompt
      assert aft.export_visibility == :discoverable
    end

    # The size bound must reject an oversized edit payload BEFORE any
    # scanner/parser work runs on it — the write-time max_source_bytes check
    # alone would let a huge replace_form source burn unbounded CPU first.
    test "rejects an oversized edit source before scanning it" do
      {:ok, store} = PreludeStore.new(max_source_bytes: byte_size(@edit_base) + 100)
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      oversized = "(defn get-user [id] " <> String.duplicate(";x", 2_000) <> " id)"

      assert {:error, %{reason: :source_too_large, limit_bytes: _}} =
               PreludeStore.edit(store, "store-edit", [
                 %{op: :replace_form, name: "get-user", source: oversized}
               ])

      assert {:error, %{reason: :source_too_large}} =
               PreludeStore.edit(store, "store-edit", [
                 %{op: :set_ns_doc, doc: String.duplicate("d", byte_size(@edit_base) + 200)}
               ])
    end

    test "rejects a batch where two ops target the same form name" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      edits = [
        %{op: :replace_form, name: "unused-helper", source: "(defn- unused-helper [] 1)"},
        %{op: :remove_form, name: "unused-helper"}
      ]

      assert {:error, %{reason: :conflicting_edit_batch}} =
               PreludeStore.edit(store, "store-edit", edits)
    end

    test "rejects an add_form anchored to a form the same batch removes" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      edits = [
        %{op: :remove_form, name: "unused-helper"},
        %{
          op: :add_form,
          placement: :before,
          anchor: "unused-helper",
          source: "(defn- extra [] 1)"
        }
      ]

      assert {:error, %{reason: :conflicting_edit_batch}} =
               PreludeStore.edit(store, "store-edit", edits)
    end

    test "rejects replace_form when the source's derived name does not match the declared name" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      edits = [%{op: :replace_form, name: "get-user", source: "(defn other-name [] 1)"}]

      assert {:error, %{reason: :form_name_mismatch}} =
               PreludeStore.edit(store, "store-edit", edits)
    end

    test "rejects add_form whose name already exists" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      edits = [%{op: :add_form, source: "(defn get-user [] 1)"}]

      assert {:error, %{reason: :form_already_exists}} =
               PreludeStore.edit(store, "store-edit", edits)
    end

    test "rejects a replace_form/remove_form target or an add_form anchor that does not exist" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      assert {:error, %{reason: :form_not_found}} =
               PreludeStore.edit(store, "store-edit", [%{op: :remove_form, name: "nonexistent"}])

      assert {:error, %{reason: :form_not_found}} =
               PreludeStore.edit(store, "store-edit", [
                 %{op: :replace_form, name: "nonexistent", source: "(defn nonexistent [] 1)"}
               ])

      assert {:error, %{reason: :form_not_found}} =
               PreludeStore.edit(store, "store-edit", [
                 %{
                   op: :add_form,
                   placement: :after,
                   anchor: "nonexistent",
                   source: "(defn extra [] 1)"
                 }
               ])
    end

    test "concurrent edit races a direct write/4 for the same base and rejects the stale contender" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, base} = PreludeStore.write(store, "paged", @paged_v1)

      other_source = """
      (ns paged)
      (defn inspect [] {:version 99})
      """

      results =
        [
          fn ->
            {:edit,
             PreludeStore.edit(store, "paged", [%{op: :add_form, source: "(defn extra [] 1)"}])}
          end,
          fn ->
            {:write,
             PreludeStore.write(store, "paged", other_source, %{
               "parent_checksum" => base.checksum
             })}
          end
        ]
        |> Task.async_stream(& &1.(), max_concurrency: 2, timeout: 5_000)
        |> Enum.map(fn {:ok, result} -> result end)

      successes = Enum.filter(results, fn {_kind, result} -> match?({:ok, _}, result) end)
      failures = Enum.filter(results, fn {_kind, result} -> match?({:error, _}, result) end)

      assert length(successes) == 1
      assert [{_kind, {:error, %{reason: :stale_base}}}] = failures

      assert [%{versions_count: 2, latest_version: 2}] = PreludeStore.list(store)
    end

    test "removing a private helper still referenced by a public fn fails the existing compile gate" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      assert {:error,
              %{reason: :prelude_compile_error, compile_reason: :compile_error, message: message}} =
               PreludeStore.edit(store, "store-edit", [%{op: :remove_form, name: "fetch-raw"}])

      assert message =~ "fetch-raw"
      assert [%{versions_count: 1, latest_version: 1}] = PreludeStore.list(store)
    end

    test "set_ns_doc replaces an existing docstring, preserving surrounding bytes" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      assert {:ok, result} =
               PreludeStore.edit(store, "store-edit", [%{op: :set_ns_doc, doc: "New ns doc."}])

      assert {:ok, new_candidate} = PreludeStore.read(store, "store-edit@#{result.version}")

      assert get_in(new_candidate.compiled.metadata, [:namespaces, "store-edit", :doc]) ==
               "New ns doc."

      {:ok, old_scan} = FormScanner.scan(@edit_base)
      {:ok, new_scan} = FormScanner.scan(new_candidate.source)
      old_ns = Enum.find(old_scan.forms, &(&1.head == "ns"))
      new_ns = Enum.find(new_scan.forms, &(&1.head == "ns"))

      # Bytes up to "(ns store-edit\n  " (before the docstring token) are
      # untouched by the doc replacement.
      prefix = "(ns store-edit\n  "
      prefix_len = byte_size(prefix)

      assert binary_part(@edit_base, elem(old_ns.span, 0), prefix_len) ==
               binary_part(new_candidate.source, elem(new_ns.span, 0), prefix_len)
    end

    test "set_ns_doc inserts a docstring when the ns form has none" do
      {:ok, store} = PreludeStore.new()
      bare = "(ns bare)\n\n(defn f [] 1)\n"
      assert {:ok, _base} = PreludeStore.write(store, "bare", bare)

      assert {:ok, result} =
               PreludeStore.edit(store, "bare", [%{op: :set_ns_doc, doc: "Added doc."}])

      assert {:ok, new_candidate} = PreludeStore.read(store, "bare@#{result.version}")

      assert get_in(new_candidate.compiled.metadata, [:namespaces, "bare", :doc]) == "Added doc."
    end

    test "add_form supports :before, :after, and :end placements in one batch" do
      {:ok, store} = PreludeStore.new()
      assert {:ok, _base} = PreludeStore.write(store, "store-edit", @edit_base)

      edits = [
        %{
          op: :add_form,
          placement: :before,
          anchor: "get-user",
          source: "(defn- before-helper [] 1)"
        },
        %{
          op: :add_form,
          placement: :after,
          anchor: "get-user",
          source: "(defn- after-helper [] 2)"
        },
        %{op: :add_form, placement: :end, source: "(defn- end-helper [] 3)"}
      ]

      assert {:ok, result} = PreludeStore.edit(store, "store-edit", edits)
      assert {:ok, new_candidate} = PreludeStore.read(store, "store-edit@#{result.version}")

      {:ok, new_scan} = FormScanner.scan(new_candidate.source)
      order = Enum.map(new_scan.forms, & &1.name)

      before_idx = Enum.find_index(order, &(&1 == "before-helper"))
      get_user_idx = Enum.find_index(order, &(&1 == "get-user"))
      after_idx = Enum.find_index(order, &(&1 == "after-helper"))
      end_idx = Enum.find_index(order, &(&1 == "end-helper"))

      assert before_idx == get_user_idx - 1
      assert after_idx == get_user_idx + 1
      assert end_idx == length(order) - 1
    end

    test "replace_form of a name coinciding with the namespace's own symbol never touches the (ns ...) form" do
      {:ok, store} = PreludeStore.new()

      source = """
      (ns dup "original ns doc.")

      (defn dup [] 42)
      """

      assert {:ok, _base} = PreludeStore.write(store, "dup", source)

      assert {:ok, result} =
               PreludeStore.edit(store, "dup", [
                 %{op: :replace_form, name: "dup", source: "(defn dup [] 43)"}
               ])

      assert {:ok, new_candidate} = PreludeStore.read(store, "dup@#{result.version}")

      assert get_in(new_candidate.compiled.metadata, [:namespaces, "dup", :doc]) ==
               "original ns doc."

      {:ok, new_scan} = FormScanner.scan(new_candidate.source)
      assert Enum.count(new_scan.forms, &(&1.head == "ns")) == 1
      assert Enum.count(new_scan.forms, &(&1.head == "defn" and &1.name == "dup")) == 1
    end
  end

  describe "FormEdit.apply/2 (unit)" do
    test "fails closed when the base source itself fails to scan" do
      assert {:error, %{reason: :base_scan_failed}} =
               FormEdit.apply("(defn foo [] 1", [%{op: :remove_form, name: "foo"}])
    end

    test "rejects an empty edits list and non-map edits" do
      assert {:error, %{reason: :invalid_argument}} = FormEdit.apply("(ns x)\n", [])
      assert {:error, %{reason: :invalid_argument}} = FormEdit.apply("(ns x)\n", ["not-a-map"])
    end
  end

  defp slice(source, {offset, length}), do: binary_part(source, offset, length)

  # ============================================================
  # Declared prelude-to-prelude dependencies (docs/plans/prelude-deps.md §2)
  # ============================================================

  describe "write/4 with requires_preludes" do
    @dep_base """
    (ns base "Shared helpers.")

    (defn helper [x] (str "helper:" x))

    (defn fetch [id]
      (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
    """

    @dep_base_v2 """
    (ns base "Shared helpers, v2.")

    (defn helper [x] (str "helper2:" x))
    """

    @dep_audit """
    (ns audit "Audit checks.")

    (defn check [id] (base/fetch id))
    """

    defp store_with_base(opts \\ []) do
      {:ok, store} = PreludeStore.new(opts)
      {:ok, base} = PreludeStore.write(store, "base", @dep_base)
      {store, base}
    end

    test "a write with deps resolves, records pins, and echoes them" do
      {store, base} = store_with_base()

      assert {:ok, result} =
               PreludeStore.write(store, "audit", @dep_audit, %{
                 "requires_preludes" => ["base"]
               })

      assert result.metadata["requires_preludes"] == ["base"]

      assert result.metadata["prelude_deps"] == [
               %{"id" => "base", "version" => 1, "checksum" => base.checksum}
             ]

      # The dependent's export unions the dep's authority.
      assert {:ok, candidate} = PreludeStore.read(store, "audit")
      {:ok, check} = Prelude.fetch_export(candidate.compiled, "audit/check")
      assert "upstream:crm/get_user" in check.requires
    end

    test "a bare id pins the version that was current at write time" do
      {store, base} = store_with_base()

      assert {:ok, _} =
               PreludeStore.write(store, "audit", @dep_audit, %{
                 "requires_preludes" => ["base"]
               })

      # base moves on; audit's pin does not.
      assert {:ok, base_v2} = PreludeStore.write(store, "base", @dep_base_v2)
      assert base_v2.version == 2

      assert {:ok, audit} = PreludeStore.read(store, "audit")

      assert PreludeCandidate.dep_pins(audit) == [
               %{id: "base", version: 1, checksum: base.checksum}
             ]
    end

    test "an explicit id@version pins that version" do
      {store, base} = store_with_base()
      assert {:ok, _} = PreludeStore.write(store, "base", @dep_base_v2)

      assert {:ok, result} =
               PreludeStore.write(store, "audit", @dep_audit, %{
                 "requires_preludes" => ["base@1"]
               })

      assert result.metadata["prelude_deps"] == [
               %{"id" => "base", "version" => 1, "checksum" => base.checksum}
             ]
    end

    test "an unknown dependency fails with :unknown_dependency" do
      {:ok, store} = PreludeStore.new()

      assert {:error, error} =
               PreludeStore.write(store, "audit", @dep_audit, %{
                 "requires_preludes" => ["base"]
               })

      assert error.reason == :unknown_dependency
      assert error.message =~ "base"
    end

    test "caller-supplied prelude_deps metadata is overridden by computed pins" do
      {store, base} = store_with_base()

      forged = [%{"id" => "base", "version" => 999, "checksum" => "forged"}]

      assert {:ok, result} =
               PreludeStore.write(store, "audit", @dep_audit, %{
                 "requires_preludes" => ["base"],
                 "prelude_deps" => forged
               })

      assert result.metadata["prelude_deps"] == [
               %{"id" => "base", "version" => 1, "checksum" => base.checksum}
             ]

      # And without a declaration, a forged pins key is dropped entirely.
      assert {:ok, plain} =
               PreludeStore.write(store, "plain", "(ns plain \"P.\")\n(defn go [] 1)", %{
                 "prelude_deps" => forged
               })

      refute Map.has_key?(plain.metadata, "prelude_deps")
    end

    test "self-dependency, duplicates, and malformed refs are rejected" do
      {store, _base} = store_with_base()

      assert {:error, %{reason: :invalid_metadata}} =
               PreludeStore.write(store, "audit", @dep_audit, %{
                 "requires_preludes" => ["audit"]
               })

      assert {:error, %{reason: :invalid_metadata, message: message}} =
               PreludeStore.write(store, "audit", @dep_audit, %{
                 "requires_preludes" => ["base", "base@1"]
               })

      assert message =~ "duplicate"

      for bad <- [["base@0"], ["base@x"], ["@1"], [42], "base"] do
        assert {:error, %{reason: :invalid_metadata}} =
                 PreludeStore.write(store, "audit", @dep_audit, %{
                   "requires_preludes" => bad
                 })
      end
    end

    test "an undeclared cross-namespace ref fails at write with a hint" do
      {store, _base} = store_with_base()

      assert {:error, error} = PreludeStore.write(store, "audit", @dep_audit)
      assert error.reason == :prelude_compile_error
      assert error.message =~ "unknown namespace"
      assert error.message =~ "requires_preludes"
    end

    test "a write whose dependency closure reaches back to the written id is rejected" do
      # Regression (codex review): a@1, then b@1 pinning a@1, then a@2
      # declaring b would persist a@2 -> b@1 -> a@1 — written successfully
      # but never attachable (id-level conflict at selection). Reject at
      # write so "written" keeps implying "attachable".
      {:ok, store} = PreludeStore.new()

      {:ok, _} = PreludeStore.write(store, "a", "(ns a \"A.\")\n(defn fa [x] x)")

      {:ok, _} =
        PreludeStore.write(store, "b", "(ns b \"B.\")\n(defn fb [x] (a/fa x))", %{
          "requires_preludes" => ["a"]
        })

      assert {:error, %{reason: :dependency_cycle, message: message}} =
               PreludeStore.write(store, "a", "(ns a \"A2.\")\n(defn fa [x] (b/fb x))", %{
                 "requires_preludes" => ["b"]
               })

      assert message =~ "reach back to `a`"
      assert message =~ "a@1"
    end

    test "a write whose deps pin conflicting versions of a shared dep is rejected" do
      {store, _base} = store_with_base()

      {:ok, _} =
        PreludeStore.write(store, "c", "(ns c \"C.\")\n(defn fc [x] (base/helper x))", %{
          "requires_preludes" => ["base"]
        })

      {:ok, _} = PreludeStore.write(store, "base", @dep_base_v2)

      {:ok, _} =
        PreludeStore.write(store, "d", "(ns d \"D.\")\n(defn fd [x] (base/helper x))", %{
          "requires_preludes" => ["base"]
        })

      # c pins base@1, d pins base@2 — a dependent of both could never attach.
      assert {:error, %{reason: :dependency_conflict, message: message}} =
               PreludeStore.write(store, "e", "(ns e \"E.\")\n(defn fe [x] (c/fc (d/fd x)))", %{
                 "requires_preludes" => ["c", "d"]
               })

      assert message =~ "base"
    end

    test "the metadata bound applies to the FINAL metadata including computed pins" do
      # Regression (codex review): the bound was checked on caller metadata
      # BEFORE the store added prelude_deps pins, so stored rows could exceed
      # :max_metadata_bytes. Pick a bound the declaration passes but the
      # pin-enriched metadata (a ~64-hex checksum per dep) cannot.
      declaration = %{"requires_preludes" => ["base"]}
      bound = :erlang.external_size(declaration) + 40

      {store, _base} = store_with_base(max_metadata_bytes: bound)

      assert {:error, %{reason: :metadata_too_large}} =
               PreludeStore.write(store, "audit", @dep_audit, declaration)
    end

    test "pruning retains dep-pinned versions" do
      {store, base} = store_with_base(max_versions: 1)

      assert {:ok, _} =
               PreludeStore.write(store, "audit", @dep_audit, %{
                 "requires_preludes" => ["base@1"]
               })

      # Two more base versions; max_versions: 1 would normally prune v1.
      assert {:ok, _} = PreludeStore.write(store, "base", @dep_base_v2)
      assert {:ok, _} = PreludeStore.write(store, "base", @dep_base)

      # The dep-pinned version survives the ring.
      assert {:ok, pinned} = PreludeStore.read(store, %{id: "base", version: 1})
      assert PreludeCandidate.checksum(pinned) == base.checksum
    end
  end

  describe "edit/4 dependency pin inheritance" do
    @edit_dep_base """
    (ns base "Shared helpers.")

    (defn helper [x] (str "helper:" x))
    """

    @edit_dep_audit """
    (ns audit "Audit checks.")

    (defn check [x] (base/helper x))
    """

    defp store_with_audit do
      {:ok, store} = PreludeStore.new()
      {:ok, base} = PreludeStore.write(store, "base", @edit_dep_base)

      {:ok, _} =
        PreludeStore.write(store, "audit", @edit_dep_audit, %{
          "requires_preludes" => ["base"]
        })

      {store, base}
    end

    test "an edit inherits the base version's resolved pins" do
      {store, base} = store_with_audit()

      # base gets a new current version; the edit must keep the v1 pin
      # (inheriting the raw declaration would re-resolve to v2 — float).
      {:ok, _} = PreludeStore.write(store, "base", "(ns base \"B2.\")\n(defn helper [x] x)")

      edits = [
        %{
          "op" => "replace_form",
          "name" => "check",
          "source" => "(defn check [x] (base/helper (str x \"!\")))"
        }
      ]

      assert {:ok, result} = PreludeStore.edit(store, "audit", edits)
      assert result.metadata["requires_preludes"] == ["base@1"]

      assert result.metadata["prelude_deps"] == [
               %{"id" => "base", "version" => 1, "checksum" => base.checksum}
             ]
    end

    test "an explicit requires_preludes on edit overrides inheritance" do
      {store, _base} = store_with_audit()
      {:ok, base_v2} = PreludeStore.write(store, "base", "(ns base \"B2.\")\n(defn helper [x] x)")

      edits = [
        %{
          "op" => "replace_form",
          "name" => "check",
          "source" => "(defn check [x] (base/helper x))"
        }
      ]

      assert {:ok, result} =
               PreludeStore.edit(store, "audit", edits, %{"requires_preludes" => ["base@2"]})

      assert result.metadata["prelude_deps"] == [
               %{"id" => "base", "version" => 2, "checksum" => base_v2.checksum}
             ]
    end

    test "an explicit empty requires_preludes drops deps (and the edit must compile alone)" do
      {store, _base} = store_with_audit()

      edits = [
        %{
          "op" => "replace_form",
          "name" => "check",
          "source" => "(defn check [x] x)"
        }
      ]

      assert {:ok, result} =
               PreludeStore.edit(store, "audit", edits, %{"requires_preludes" => []})

      refute Map.has_key?(result.metadata, "prelude_deps")
      refute Map.has_key?(result.metadata, "requires_preludes")
    end
  end
end
