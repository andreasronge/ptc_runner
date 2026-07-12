defmodule PtcRunner.PreludeStore.ToolsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.FormScanner
  alias PtcRunner.Lisp.Result, as: Step
  alias PtcRunner.PreludeStore
  alias PtcRunner.PreludeStore.Tools
  alias PtcRunner.TraceLog.TurnEvent

  @paged_source """
  (ns paged "Paged helpers.")

  (defn inspect [] {:version 1})
  """

  @graph_source """
  (ns crm "CRM helpers." {:visibility :prompt})

  (defn- fetch-raw
    "Fetch the raw user record."
    [id]
    (tool/call {:server "crm" :tool "get_user" :args {:id id}}))

  (defn get-user
    "Return a CRM user by id."
    [id]
    (fetch-raw id))

  (defn- unused-helper
    "Never called by anything."
    []
    42)

  (def max-retries "Retry budget." 3)
  """

  test "host prelude compiles as public prelude wrappers over private store tools" do
    assert {:ok, %Prelude{} = prelude} = Tools.prelude()

    assert Prelude.namespaces(prelude) == ["prelude"]

    assert Enum.map(prelude.exports, & &1.ref) ==
             ~w(prelude/list prelude/history prelude/read prelude/source
                prelude/forms prelude/form-deps prelude/deps prelude/form
                prelude/write prelude/edit prelude/set-default)

    for ref <-
          ~w(prelude/list prelude/history prelude/read prelude/source
             prelude/forms prelude/form-deps prelude/deps prelude/form
             prelude/write prelude/edit prelude/set-default) do
      assert Prelude.export_tool_refs(prelude, ref) != []
    end

    effects = Map.new(prelude.exports, &{&1.ref, &1.effect})
    assert effects["prelude/list"] == :read
    assert effects["prelude/history"] == :read
    assert effects["prelude/read"] == :read
    assert effects["prelude/source"] == :read
    assert effects["prelude/forms"] == :read
    assert effects["prelude/form-deps"] == :read
    assert effects["prelude/deps"] == :read
    assert effects["prelude/form"] == :read
    assert effects["prelude/write"] == :write
    assert effects["prelude/edit"] == :write
    assert effects["prelude/set-default"] == :write
  end

  test "read prelude exposes only read-effect public wrappers" do
    assert {:ok, %Prelude{} = prelude} = Tools.read_prelude()

    assert Enum.map(prelude.exports, & &1.ref) ==
             ~w(prelude/list prelude/history prelude/read prelude/source
                prelude/forms prelude/form-deps prelude/deps prelude/form)

    assert Map.new(prelude.exports, &{&1.ref, &1.effect}) ==
             %{
               "prelude/list" => :read,
               "prelude/history" => :read,
               "prelude/read" => :read,
               "prelude/source" => :read,
               "prelude/forms" => :read,
               "prelude/form-deps" => :read,
               "prelude/deps" => :read,
               "prelude/form" => :read
             }
  end

  test "read backing tools omit write-authority private tools" do
    {:ok, store} = PreludeStore.new()

    read_tool_names = Tools.read_tools(store) |> Map.keys() |> Enum.sort()

    assert read_tool_names ==
             ~w(prelude_store_deps prelude_store_form prelude_store_form_deps
                prelude_store_forms prelude_store_history prelude_store_list
                prelude_store_read)

    refute "prelude_store_write" in read_tool_names
    refute "prelude_store_edit" in read_tool_names
    refute "prelude_store_set_default" in read_tool_names
  end

  test "direct private store tool calls fail during analysis" do
    {:ok, store} = PreludeStore.new()
    test_pid = self()

    tools =
      Tools.tools(store,
        base_tools: %{
          "visible" => fn _args ->
            send(test_pid, :visible_tool_ran)
            "ok"
          end
        }
      )

    assert {:error, %Step{} = step} =
             Lisp.run(~S|(do (tool/visible {}) (tool/prelude_store_list {}))|, tools: tools)

    assert step.fail.reason == :private_tool_unauthorized
    assert step.fail.message =~ "prelude_store_list"
    refute_received :visible_tool_ran
  end

  test "public wrappers write, list, read, and source stored candidates" do
    {:ok, store} = PreludeStore.new()
    {:ok, prelude} = Tools.prelude()

    assert {:ok, %Step{return: write_result}} =
             Lisp.run(
               ~S|(prelude/write {:id "paged" :source data/source :metadata {:reason "initial"}})|,
               context: %{source: @paged_source},
               prelude: prelude,
               tools: Tools.tools(store)
             )

    assert %{
             "status" => "ok",
             "id" => "paged",
             "version" => 1,
             "checksum" => checksum,
             "exports" => ["inspect"],
             "metadata" => %{"reason" => "initial"}
           } = write_result

    assert checksum =~ ~r/\A[0-9a-f]{64}\z/

    assert {:ok, %Step{return: [listed]}} =
             Lisp.run(~S|(prelude/list)|, prelude: prelude, tools: Tools.tools(store))

    assert listed["id"] == "paged"
    assert listed["latest_version"] == 1
    refute Map.has_key?(listed, "source")

    assert {:ok, %Step{return: read_result}} =
             Lisp.run(~S|(prelude/read "paged")|, prelude: prelude, tools: Tools.tools(store))

    assert read_result["status"] == "ok"
    assert read_result["source"] == @paged_source
    assert read_result["source_bytes"] == byte_size(@paged_source)
    assert read_result["source_truncated"] == false
    refute Map.has_key?(read_result, "compiled")

    assert {:ok, %Step{return: @paged_source}} =
             Lisp.run(~S|(prelude/source "paged")|, prelude: prelude, tools: Tools.tools(store))
  end

  test "public wrappers expose history and explicit default selection" do
    {:ok, store} = PreludeStore.new()
    {:ok, prelude} = Tools.prelude()

    paged_v2 = """
    (ns paged "Paged helpers.")

    (defn inspect [] {:version 2})
    """

    assert {:ok, _} = PreludeStore.write(store, "paged", @paged_source)
    assert {:ok, second} = PreludeStore.write(store, "paged", paged_v2)

    assert {:ok, %Step{return: before_history}} =
             Lisp.run(~S|(prelude/history "paged")|, prelude: prelude, tools: Tools.tools(store))

    assert Enum.map(before_history, & &1["version"]) == [1, 2]
    assert Enum.map(before_history, & &1["current"]) == [false, true]

    assert {:ok, %Step{return: selected}} =
             Lisp.run(
               ~S|(prelude/set-default {:id "paged" :version 1 :metadata {:reason "rollback after verification"}})|,
               prelude: prelude,
               tools: Tools.tools(store)
             )

    assert selected["status"] == "ok"
    assert selected["current_version"] == 1
    assert selected["latest_version"] == 2
    assert selected["metadata"] == %{"reason" => "rollback after verification"}

    assert {:ok, %Step{return: [listed]}} =
             Lisp.run(~S|(prelude/list)|, prelude: prelude, tools: Tools.tools(store))

    assert listed["current_version"] == 1
    assert listed["latest_version"] == 2

    assert {:ok, %Step{return: after_history}} =
             Lisp.run(~S|(prelude/history "paged")|, prelude: prelude, tools: Tools.tools(store))

    assert Enum.map(after_history, & &1["current"]) == [true, false]

    assert {:ok, %Step{return: mismatch}} =
             Lisp.run(
               ~s|(prelude/set-default {"id" "paged" "version" 1 "checksum" "#{second.checksum}"})|,
               prelude: prelude,
               tools: Tools.tools(store)
             )

    assert mismatch["status"] == "error"
    assert mismatch["reason"] == "checksum_mismatch"
  end

  test "source wrapper propagates read errors" do
    {:ok, store} = PreludeStore.new()
    {:ok, prelude} = Tools.prelude()

    assert {:ok, %Step{return: {:__ptc_fail__, details}}} =
             Lisp.run(~S|(prelude/source "missing")|, prelude: prelude, tools: Tools.tools(store))

    assert details["status"] == "error"
    assert details["reason"] == "not_found"
    assert details["message"] =~ "missing"
  end

  test "public wrapper error messages are bounded" do
    {:ok, store} = PreludeStore.new()
    {:ok, prelude} = Tools.prelude()
    huge_id = "bad@" <> String.duplicate("x", 200_000)

    assert {:ok, %Step{return: result}} =
             Lisp.run(
               ~S|(prelude/read data/id)|,
               context: %{id: huge_id},
               prelude: prelude,
               tools: Tools.tools(store)
             )

    assert result["status"] == "error"
    assert result["reason"] == "invalid_ref"
    assert byte_size(result["message"]) <= 1_024
    assert result["message"] =~ "truncated"
    refute result["message"] =~ String.duplicate("x", 2_048)
  end

  test "source wrapper fails closed instead of returning truncated source text" do
    {:ok, store} = PreludeStore.new()
    {:ok, prelude} = Tools.prelude()

    source = """
    (ns paged)
    #{String.duplicate(" ", 70_000)}
    (defn inspect [] {:ok true})
    """

    assert {:ok, _} = PreludeStore.write(store, "paged", source)

    assert {:ok, %Step{return: read_result}} =
             Lisp.run(~S|(prelude/read "paged")|, prelude: prelude, tools: Tools.tools(store))

    assert read_result["source_truncated"] == true
    assert read_result["source_bytes"] == byte_size(source)
    assert byte_size(read_result["source"]) <= 64 * 1024

    assert {:ok, %Step{return: {:__ptc_fail__, details}}} =
             Lisp.run(~S|(prelude/source "paged")|, prelude: prelude, tools: Tools.tools(store))

    assert details["reason"] == "source_truncated"
    assert details["message"] =~ "public read bound"
    assert details["source_bytes"] == byte_size(source)
  end

  test "compile failures return public error maps and do not store versions" do
    {:ok, store} = PreludeStore.new()
    {:ok, prelude} = Tools.prelude()

    assert {:ok, %Step{return: result}} =
             Lisp.run(
               ~S|(prelude/write {:id "paged" :source "(ns paged" :metadata {}})|,
               prelude: prelude,
               tools: Tools.tools(store)
             )

    assert result["status"] == "error"
    assert result["reason"] == "prelude_compile_error"
    assert result["compile_reason"] == "parse_error"

    assert PreludeStore.list(store) == []
  end

  describe "prelude/forms, prelude/form-deps, prelude/deps" do
    setup do
      {:ok, store} = PreludeStore.new()
      {:ok, prelude} = Tools.prelude()
      assert {:ok, _} = PreludeStore.write(store, "crm", @graph_source)
      %{store: store, prelude: prelude}
    end

    test "forms lists every top-level form, including a dead private, sorted by name", %{
      store: store,
      prelude: prelude
    } do
      assert {:ok, %Step{return: rows}} =
               Lisp.run(~S|(prelude/forms "crm")|, prelude: prelude, tools: Tools.tools(store))

      assert Enum.map(rows, & &1["name"]) ==
               ["fetch-raw", "get-user", "max-retries", "unused-helper"]

      by_name = Map.new(rows, &{&1["name"], &1})
      byte_size = form_byte_size(@graph_source, "fetch-raw")

      assert by_name["fetch-raw"] == %{
               "name" => "fetch-raw",
               "visibility" => "private",
               "kind" => "function",
               "arity" => 1,
               "doc" => "Fetch the raw user record.",
               "byte_size" => byte_size
             }

      assert by_name["get-user"] == %{
               "name" => "get-user",
               "visibility" => "public",
               "kind" => "function",
               "arity" => 1,
               "doc" => "Return a CRM user by id.",
               "byte_size" => form_byte_size(@graph_source, "get-user")
             }

      assert by_name["max-retries"] == %{
               "name" => "max-retries",
               "visibility" => "public",
               "kind" => "constant",
               "arity" => 0,
               "doc" => "Retry budget.",
               "byte_size" => form_byte_size(@graph_source, "max-retries")
             }

      assert by_name["unused-helper"] == %{
               "name" => "unused-helper",
               "visibility" => "private",
               "kind" => "function",
               "arity" => 0,
               "doc" => "Never called by anything.",
               "byte_size" => form_byte_size(@graph_source, "unused-helper")
             }
    end

    test "forms resolves an id@version ref", %{store: store, prelude: prelude} do
      assert {:ok, %Step{return: rows}} =
               Lisp.run(~S|(prelude/forms "crm@1")|, prelude: prelude, tools: Tools.tools(store))

      assert Enum.map(rows, & &1["name"]) ==
               ["fetch-raw", "get-user", "max-retries", "unused-helper"]
    end

    test "forms returns a public not_found error for an unknown id", %{
      store: store,
      prelude: prelude
    } do
      assert {:ok, %Step{return: result}} =
               Lisp.run(~S|(prelude/forms "missing")|,
                 prelude: prelude,
                 tools: Tools.tools(store)
               )

      assert result["status"] == "error"
      assert result["reason"] == "not_found"
    end

    test "form-deps splits direct (own body) from transitive (through called siblings) authority",
         %{store: store, prelude: prelude} do
      assert {:ok, %Step{return: helper}} =
               Lisp.run(~S|(prelude/form-deps "crm" "fetch-raw")|,
                 prelude: prelude,
                 tools: Tools.tools(store)
               )

      assert helper == %{
               "name" => "fetch-raw",
               "visibility" => "private",
               "calls" => [],
               "requires" => %{
                 "direct" => ["upstream:crm/get_user"],
                 "transitive" => ["upstream:crm/get_user"]
               },
               "tool_refs" => %{"direct" => ["call"], "transitive" => ["call"]},
               "dep_calls" => %{"direct" => [], "transitive" => []}
             }

      assert {:ok, %Step{return: caller}} =
               Lisp.run(~S|(prelude/form-deps "crm" "get-user")|,
                 prelude: prelude,
                 tools: Tools.tools(store)
               )

      assert caller == %{
               "name" => "get-user",
               "visibility" => "public",
               "calls" => [%{"name" => "fetch-raw", "visibility" => "private"}],
               "requires" => %{
                 "direct" => [],
                 "transitive" => ["upstream:crm/get_user"]
               },
               "tool_refs" => %{"direct" => [], "transitive" => ["call"]},
               "dep_calls" => %{"direct" => [], "transitive" => []}
             }
    end

    test "form-deps returns a public form_not_found error for an unknown form name", %{
      store: store,
      prelude: prelude
    } do
      assert {:ok, %Step{return: result}} =
               Lisp.run(~S|(prelude/form-deps "crm" "nonexistent")|,
                 prelude: prelude,
                 tools: Tools.tools(store)
               )

      assert result["status"] == "error"
      assert result["reason"] == "form_not_found"
      assert result["id"] == "crm"
      assert result["name"] == "nonexistent"
    end

    test "deps covers every form in the namespace, including the dead private", %{
      store: store,
      prelude: prelude
    } do
      assert {:ok, %Step{return: graph}} =
               Lisp.run(~S|(prelude/deps "crm")|, prelude: prelude, tools: Tools.tools(store))

      assert graph == %{
               "fetch-raw" => [],
               "get-user" => ["fetch-raw"],
               "max-retries" => [],
               "unused-helper" => []
             }
    end
  end

  describe "prelude/form" do
    setup do
      {:ok, store} = PreludeStore.new()
      {:ok, prelude} = Tools.prelude()
      assert {:ok, _} = PreludeStore.write(store, "crm", @graph_source)
      %{store: store, prelude: prelude}
    end

    test "returns the exact byte slice of a named form's source", %{
      store: store,
      prelude: prelude
    } do
      assert {:ok, %Step{return: result}} =
               Lisp.run(~S|(prelude/form "crm" "fetch-raw")|,
                 prelude: prelude,
                 tools: Tools.tools(store)
               )

      assert result["name"] == "fetch-raw"
      assert result["visibility"] == "private"

      {:ok, scan} = FormScanner.scan(@graph_source)
      form = Enum.find(scan.forms, &(&1.name == "fetch-raw"))
      {offset, length} = form.span

      assert result["source"] == binary_part(@graph_source, offset, length)
    end

    test "returns a public form_not_found error for an unknown form name", %{
      store: store,
      prelude: prelude
    } do
      assert {:ok, %Step{return: result}} =
               Lisp.run(~S|(prelude/form "crm" "nonexistent")|,
                 prelude: prelude,
                 tools: Tools.tools(store)
               )

      assert result["status"] == "error"
      assert result["reason"] == "form_not_found"
    end
  end

  describe "prelude/edit" do
    test "public wrapper applies a form-keyed edit batch end-to-end, marshaling the edits list of maps" do
      {:ok, store} = PreludeStore.new()
      {:ok, prelude} = Tools.prelude()
      assert {:ok, _} = PreludeStore.write(store, "crm", @graph_source)

      program = ~S"""
      (prelude/edit
        {:id "crm"
         :edits [{:op :remove_form :name "unused-helper"}
                 {:op :add_form :source "(defn- extra-helper [] 99)" :placement :end}]
         :metadata {:reason "cleanup"}})
      """

      assert {:ok, %Step{return: result} = step} =
               Lisp.run(program, prelude: prelude, tools: Tools.tools(store))

      assert result["status"] == "ok"
      assert result["id"] == "crm"
      assert result["version"] == 2
      assert result["base_version"] == 1
      assert result["parent_checksum"] == result["metadata"]["parent_checksum"]
      assert result["metadata"]["reason"] == "cleanup"

      assert result["forms"] == %{
               "replaced" => [],
               "added" => ["extra-helper"],
               "removed" => ["unused-helper"],
               "ns_doc_set" => false
             }

      assert %{"added" => added, "removed" => removed} = result["public_surface"]
      assert Enum.map(added, & &1["name"]) == ["extra-helper"]
      assert Enum.map(removed, & &1["name"]) == ["unused-helper"]

      assert [%{name: "prelude_store_edit", private: true} = call] = step.tool_calls

      # The existing source-redaction rule (see "private source args are
      # summarized" below) applies recursively to a "source" key nested
      # inside the edits LIST OF MAPS too, not just a top-level arg.
      new_form_source = "(defn- extra-helper [] 99)"

      assert call.args["edits"] == [
               %{"op" => "remove_form", "name" => "unused-helper"},
               %{
                 "op" => "add_form",
                 "source" => %{
                   "redacted" => true,
                   "bytes" => byte_size(new_form_source),
                   "sha256" => sha256(new_form_source)
                 },
                 "placement" => "end"
               }
             ]
    end

    test "public wrapper surfaces conflicting-batch and form-not-found errors as plain error maps" do
      {:ok, store} = PreludeStore.new()
      {:ok, prelude} = Tools.prelude()
      assert {:ok, _} = PreludeStore.write(store, "crm", @graph_source)

      assert {:ok, %Step{return: result}} =
               Lisp.run(
                 ~S|(prelude/edit {:id "crm" :edits [{:op :remove_form :name "nonexistent"}]})|,
                 prelude: prelude,
                 tools: Tools.tools(store)
               )

      assert result["status"] == "error"
      assert result["reason"] == "form_not_found"
    end
  end

  test "forms bounds a long docstring with a truncation marker" do
    {:ok, store} = PreludeStore.new()
    {:ok, prelude} = Tools.prelude()

    long_doc = String.duplicate("x", 2_000)

    source = """
    (ns docs "Docstring stress test.")

    (defn verbose
      "#{long_doc}"
      []
      1)
    """

    assert {:ok, _} = PreludeStore.write(store, "docs", source)

    assert {:ok, %Step{return: [row]}} =
             Lisp.run(~S|(prelude/forms "docs")|, prelude: prelude, tools: Tools.tools(store))

    assert row["name"] == "verbose"
    assert byte_size(row["doc"]) <= 1_024
    assert row["doc"] =~ "truncated"
    refute row["doc"] =~ long_doc
  end

  test "reserved store tool collisions fail before merge" do
    {:ok, store} = PreludeStore.new()

    assert_raise ArgumentError, ~r/prelude_store_write/, fn ->
      Tools.tools(store, base_tools: %{"prelude_store_write" => fn _args -> :bad end})
    end

    assert_raise ArgumentError, ~r/prelude_store_read/, fn ->
      Tools.tools(store, base_tools: %{prelude_store_read: fn _args -> :bad end})
    end
  end

  test "private source args are summarized before tool ledger and trace projections" do
    {:ok, store} = PreludeStore.new()
    {:ok, prelude} = Tools.prelude()

    assert {:ok, %Step{} = step} =
             Lisp.run(
               ~S|(prelude/write {:id "paged" :source data/source :metadata {:reason "initial"}})|,
               context: %{source: @paged_source},
               prelude: prelude,
               tools: Tools.tools(store)
             )

    assert [%{name: "prelude_store_write", private: true} = call] = step.tool_calls
    source_summary = call.args["source"]

    assert source_summary == %{
             "redacted" => true,
             "bytes" => byte_size(@paged_source),
             "sha256" => sha256(@paged_source)
           }

    refute inspect(step.tool_calls) =~ @paged_source

    projection = TurnEvent.tool_call_summary(call)
    refute inspect(projection) =~ @paged_source
    assert projection["args_hash"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "private set-default metadata is public-filtered before tool ledger and traces" do
    {:ok, store} = PreludeStore.new()
    {:ok, prelude} = Tools.prelude()
    assert {:ok, _} = PreludeStore.write(store, "paged", @paged_source)

    assert {:ok, %Step{} = step} =
             Lisp.run(
               ~S|(prelude/set-default {:id "paged" :version 1 :metadata {:reason "verified" :private "secret"}})|,
               prelude: prelude,
               tools: Tools.tools(store)
             )

    assert [%{name: "prelude_store_set_default", private: true} = call] = step.tool_calls
    assert call.args["metadata"] == %{"reason" => "verified"}
    refute inspect(step.tool_calls) =~ "secret"

    projection = TurnEvent.tool_call_summary(call)
    refute inspect(projection) =~ "secret"
    assert projection["args_hash"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "private non-map metadata is removed before tool ledger and traces" do
    {:ok, store} = PreludeStore.new()
    {:ok, prelude} = Tools.prelude()

    assert {:ok, %Step{} = write_step} =
             Lisp.run(
               ~S|(prelude/write {:id "paged" :source data/source :metadata "secret"})|,
               context: %{source: @paged_source},
               prelude: prelude,
               tools: Tools.tools(store)
             )

    assert [%{name: "prelude_store_write", private: true} = write_call] =
             write_step.tool_calls

    assert write_call.args["metadata"] == %{}
    refute inspect(write_step.tool_calls) =~ "secret"
    refute inspect(TurnEvent.tool_call_summary(write_call)) =~ "secret"

    assert {:ok, %Step{} = set_default_step} =
             Lisp.run(
               ~S|(prelude/set-default {:id "paged" :version 1 :metadata ["secret"]})|,
               prelude: prelude,
               tools: Tools.tools(store)
             )

    assert [%{name: "prelude_store_set_default", private: true} = set_default_call] =
             set_default_step.tool_calls

    assert set_default_call.args["metadata"] == %{}
    refute inspect(set_default_step.tool_calls) =~ "secret"
    refute inspect(TurnEvent.tool_call_summary(set_default_call)) =~ "secret"
  end

  test "private nested metadata is removed before tool ledger and traces" do
    {:ok, store} = PreludeStore.new()
    {:ok, prelude} = Tools.prelude()

    assert {:ok, %Step{} = write_step} =
             Lisp.run(
               ~S|(prelude/write {:id "paged" :source data/source :metadata {:reason {:private "secret"}}})|,
               context: %{source: @paged_source},
               prelude: prelude,
               tools: Tools.tools(store)
             )

    assert [%{name: "prelude_store_write", private: true} = write_call] =
             write_step.tool_calls

    assert write_call.args["metadata"] == %{}
    refute inspect(write_step.tool_calls) =~ "secret"
    refute inspect(TurnEvent.tool_call_summary(write_call)) =~ "secret"

    assert {:ok, %Step{} = set_default_step} =
             Lisp.run(
               ~S|(prelude/set-default {:id "paged" :version 1 :metadata {:reason {:private "secret"}}})|,
               prelude: prelude,
               tools: Tools.tools(store)
             )

    assert [%{name: "prelude_store_set_default", private: true} = set_default_call] =
             set_default_step.tool_calls

    assert set_default_call.args["metadata"] == %{}
    refute inspect(set_default_step.tool_calls) =~ "secret"
    refute inspect(TurnEvent.tool_call_summary(set_default_call)) =~ "secret"
  end

  defp sha256(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end

  defp form_byte_size(source, name) do
    {:ok, scan} = FormScanner.scan(source)
    form = Enum.find(scan.forms, &(&1.name == name))
    elem(form.span, 1)
  end

  # ============================================================
  # Declared prelude-to-prelude dependencies (docs/plans/prelude-deps.md §2)
  # ============================================================

  describe "prelude/write with requires_preludes" do
    @dep_base_source """
    (ns base "Shared helpers.")

    (defn helper [x] (str "helper:" x))
    """

    @dep_audit_source """
    (ns audit "Audit checks.")

    (defn check [x] (base/helper x))
    """

    test "declares deps through the Lisp op and echoes pins" do
      {:ok, store} = PreludeStore.new()
      {:ok, prelude} = Tools.prelude()

      assert {:ok, %Step{return: base_result}} =
               Lisp.run(
                 ~S|(prelude/write {:id "base" :source data/source})|,
                 context: %{source: @dep_base_source},
                 prelude: prelude,
                 tools: Tools.tools(store)
               )

      assert base_result["status"] == "ok"

      assert {:ok, %Step{return: audit_result}} =
               Lisp.run(
                 ~S|(prelude/write {:id "audit"
                                    :source data/source
                                    :requires_preludes ["base"]})|,
                 context: %{source: @dep_audit_source},
                 prelude: prelude,
                 tools: Tools.tools(store)
               )

      assert audit_result["status"] == "ok"
      assert audit_result["metadata"]["requires_preludes"] == ["base"]

      assert [%{"id" => "base", "version" => 1, "checksum" => checksum}] =
               audit_result["metadata"]["prelude_deps"]

      assert checksum == base_result["checksum"]

      # prelude/read shows the pins too.
      assert {:ok, %Step{return: read_result}} =
               Lisp.run(~S|(prelude/read "audit")|, prelude: prelude, tools: Tools.tools(store))

      assert [%{"id" => "base"}] = read_result["metadata"]["prelude_deps"]
    end

    test "an unresolvable dep surfaces the store error through the op" do
      {:ok, store} = PreludeStore.new()
      {:ok, prelude} = Tools.prelude()

      assert {:ok, %Step{return: result}} =
               Lisp.run(
                 ~S|(prelude/write {:id "audit"
                                    :source data/source
                                    :requires_preludes ["base"]})|,
                 context: %{source: @dep_audit_source},
                 prelude: prelude,
                 tools: Tools.tools(store)
               )

      assert result["status"] == "error"
      assert result["reason"] == "unknown_dependency"
      assert result["message"] =~ "base"
    end

    test "prelude/edit inherits pins through the op surface" do
      {:ok, store} = PreludeStore.new()
      {:ok, prelude} = Tools.prelude()
      {:ok, _} = PreludeStore.write(store, "base", @dep_base_source)

      {:ok, _} =
        PreludeStore.write(store, "audit", @dep_audit_source, %{
          "requires_preludes" => ["base"]
        })

      assert {:ok, %Step{return: result}} =
               Lisp.run(
                 ~S|(prelude/edit {:id "audit"
                                   :edits [{:op "replace_form"
                                            :name "check"
                                            :source data/replacement}]})|,
                 context: %{replacement: ~S|(defn check [x] (base/helper (str x "!")))|},
                 prelude: prelude,
                 tools: Tools.tools(store)
               )

      assert result["status"] == "ok"
      assert result["metadata"]["requires_preludes"] == ["base@1"]
      assert [%{"id" => "base", "version" => 1}] = result["metadata"]["prelude_deps"]
    end
  end
end
