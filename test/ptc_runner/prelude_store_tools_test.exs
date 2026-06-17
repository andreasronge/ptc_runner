defmodule PtcRunner.PreludeStore.ToolsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.PreludeStore
  alias PtcRunner.PreludeStore.Tools
  alias PtcRunner.Step
  alias PtcRunner.SubAgent.Namespace.Tool, as: ToolNamespace
  alias PtcRunner.SubAgent.ToolSchema
  alias PtcRunner.TraceLog.TurnEvent

  @paged_source """
  (ns paged "Paged helpers.")

  (defn inspect [] {:version 1})
  """

  test "host prelude compiles as public prelude wrappers over private store tools" do
    assert {:ok, %Prelude{} = prelude} = Tools.prelude()

    assert Prelude.namespaces(prelude) == ["prelude"]

    assert Enum.map(prelude.exports, & &1.ref) ==
             ~w(prelude/list prelude/history prelude/read prelude/source prelude/write prelude/set-default)

    for ref <-
          ~w(prelude/list prelude/history prelude/read prelude/source prelude/write prelude/set-default) do
      assert Prelude.export_tool_refs(prelude, ref) != []
    end

    effects = Map.new(prelude.exports, &{&1.ref, &1.effect})
    assert effects["prelude/list"] == :read
    assert effects["prelude/history"] == :read
    assert effects["prelude/read"] == :read
    assert effects["prelude/source"] == :read
    assert effects["prelude/write"] == :write
    assert effects["prelude/set-default"] == :write
  end

  test "private backing tools are hidden from native schema and prompt namespace projections" do
    {:ok, store} = PreludeStore.new()
    tools = Tools.tools(store, base_tools: %{"visible" => fn _args -> "ok" end})

    schema_names =
      tools
      |> ToolSchema.to_tool_definitions()
      |> Enum.map(&get_in(&1, ["function", "name"]))

    assert schema_names == ["visible"]

    rendered = ToolNamespace.render(tools)
    assert rendered =~ "tool/visible"

    for name <- Tools.reserved_names() do
      refute name in schema_names
      refute rendered =~ name
    end
  end

  test "direct private store tool calls fail closed" do
    {:ok, store} = PreludeStore.new()

    assert {:error, %Step{} = step} =
             Lisp.run(~S|(tool/prelude_store_list {})|, tools: Tools.tools(store))

    assert step.fail.reason == :private_tool_unauthorized
    assert step.fail.message =~ "prelude_store_list"
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
end
