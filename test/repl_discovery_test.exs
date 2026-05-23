defmodule PtcRunner.ReplDiscoveryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  defp discovery_exec(overrides \\ %{}) do
    fn operation, args ->
      case Map.get(overrides, operation) do
        nil -> discovery_result(operation, args)
        result -> result
      end
    end
  end

  defp discovery_result(:servers, []),
    do:
      {:ok,
       [
         %{
           "name" => "github",
           "description" => "GitHub",
           "tool_count" => 2,
           "catalog_loaded" => true
         }
       ]}

  defp discovery_result(:apropos, ["github" | _]),
    do: {:ok, ["github.search(query) - Search repositories"]}

  defp discovery_result(:dir, ["github" | _]),
    do: {:ok, ["github.search(query) - Search repositories"]}

  defp discovery_result(:doc, [{:symbol_ref, "github/search"}]),
    do:
      {:ok,
       "github.search(query)\nUse:\n(tool/mcp-call {:server \"github\" :tool \"search\" :args {:query ...}})"}

  defp discovery_result(:doc, ["github/search"]),
    do: discovery_result(:doc, [{:symbol_ref, "github/search"}])

  defp discovery_result(:meta, ["github/search"]),
    do: {:ok, %{"kind" => "mcp-tool", "server" => "github", "tool" => "search"}}

  defp discovery_result(:meta, [{:symbol_ref, "github/search"}]),
    do: discovery_result(:meta, ["github/search"])

  defp discovery_result(operation, args),
    do: {:programmer_fault, "unexpected discovery call #{inspect({operation, args})}"}

  describe "REPL discovery forms" do
    test "mcp/servers dispatches through discovery_exec" do
      assert {:ok, step} = Lisp.run("(mcp/servers)", discovery_exec: discovery_exec())

      assert [%{"name" => "github"}] = step.return
      assert [%{operation: :servers, args: %{}}] = step.catalog_ops
    end

    test "apropos searches discovery backend" do
      assert {:ok, step} =
               Lisp.run(~s|(apropos "github" {:limit 5})|, discovery_exec: discovery_exec())

      assert ["github.search(query) - Search repositories"] = step.return

      assert [%{operation: :apropos, args: %{query: "github", opts: %{limit: 5}}}] =
               step.catalog_ops
    end

    test "dir accepts quoted symbols and strings" do
      exec = discovery_exec()

      assert {:ok, quoted} = Lisp.run("(dir 'github)", discovery_exec: exec)
      assert {:ok, string} = Lisp.run(~s|(dir "github")|, discovery_exec: exec)

      assert quoted.return == string.return
    end

    test "doc and meta accept tool references" do
      exec = discovery_exec()

      assert {:ok, doc_step} = Lisp.run("(doc 'github/search)", discovery_exec: exec)
      assert doc_step.return =~ "github.search"

      assert {:ok, meta_step} = Lisp.run(~s|(meta "github/search")|, discovery_exec: exec)
      assert meta_step.return["kind"] == "mcp-tool"
    end

    test "world faults return nil and record discovery op" do
      exec = discovery_exec(%{dir: {:world_fault, :catalog_cap_exhausted}})

      assert {:ok, step} = Lisp.run("(dir 'github)", discovery_exec: exec)

      assert step.return == nil

      assert [%{operation: :dir, outcome: :nil_world_fault, reason: :catalog_cap_exhausted}] =
               step.catalog_ops
    end

    test "programmer faults fail the program" do
      exec = discovery_exec(%{dir: {:programmer_fault, "no upstream 'github' configured"}})

      assert {:error, step} = Lisp.run("(dir 'github)", discovery_exec: exec)
      assert step.fail.message == "runtime_error: no upstream 'github' configured"
    end

    test "catalog namespace is no longer available" do
      assert {:error, step} = Lisp.run("(catalog/list-servers)", discovery_exec: discovery_exec())

      assert step.fail.message =~ "unknown namespace catalog/"
      refute step.fail.message =~ "catalog/list-servers"
    end
  end
end
