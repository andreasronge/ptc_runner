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
       "github.search(query)\nUse:\n(tool/call {:server \"github\" :tool \"search\" :args {:query ...}})"}

  defp discovery_result(:doc, ["github/search"]),
    do: discovery_result(:doc, [{:symbol_ref, "github/search"}])

  defp discovery_result(:meta, ["github/search"]),
    do: {:ok, %{"kind" => "mcp-tool", "server" => "github", "tool" => "search"}}

  defp discovery_result(:meta, [{:symbol_ref, "github/search"}]),
    do: discovery_result(:meta, ["github/search"])

  defp discovery_result(operation, args),
    do: {:programmer_fault, "unexpected discovery call #{inspect({operation, args})}"}

  describe "REPL discovery forms" do
    test "tool/servers dispatches through discovery_exec" do
      assert {:ok, step} = Lisp.run("(tool/servers)", discovery_exec: discovery_exec())

      assert [%{"name" => "github"}] = step.return
      assert [%{operation: :servers, args: %{}}] = step.catalog_ops
    end

    test "apropos searches discovery backend" do
      assert {:ok, step} =
               Lisp.run(~s|(apropos "github" {:limit 5})|, discovery_exec: discovery_exec())

      assert hd(step.return) == "github.search(query) - Search repositories"

      assert [%{operation: :apropos, args: %{query: "github", opts: %{limit: 5}}}] =
               step.catalog_ops
    end

    test "local discovery works without discovery_exec" do
      assert {:ok, apropos_step} = Lisp.run(~s|(apropos "replace")|)
      assert Enum.any?(apropos_step.return, &String.contains?(&1, "replace"))

      assert {:ok, string_dir} = Lisp.run("(dir 'clojure.string)")
      assert Enum.any?(string_dir.return, &String.starts_with?(&1, "replace"))

      assert {:ok, date_dir} = Lisp.run("(dir 'java.time.LocalDate)")
      assert ".toEpochDay" in Enum.map(date_dir.return, &(&1 |> String.split(" - ") |> hd()))
      assert ".plusDays" in Enum.map(date_dir.return, &(&1 |> String.split(" - ") |> hd()))
      refute ".unsupported" in date_dir.return

      assert {:ok, math_dir} = Lisp.run("(dir 'Math)")
      assert Enum.any?(math_dir.return, &String.starts_with?(&1, "abs"))

      assert {:ok, fq_math_dir} = Lisp.run("(dir 'java.lang.Math)")
      assert Enum.any?(fq_math_dir.return, &String.starts_with?(&1, "abs"))

      assert {:ok, doc_step} = Lisp.run("(doc 'LocalDate/parse)")
      assert doc_step.return == nil
      assert Enum.join(doc_step.prints, "\n") =~ "LocalDate/parse"

      assert {:ok, meta_step} = Lisp.run("(meta 'java.time.Duration/between)")
      assert meta_step.return.kind in ["java-interop", "ptc-builtin"]

      assert {:ok, publics_step} = Lisp.run("(ns-publics 'clojure.string)")
      assert is_map(publics_step.return)
      assert Map.has_key?(publics_step.return, "replace")
    end

    test "local discovery does not expose non-executable fully-qualified java.lang refs" do
      assert {:error, step} = Lisp.run("(doc 'java.lang.Integer/parseInt)")
      assert step.fail.message =~ "REPL discovery forms are only available"

      assert {:ok, short_doc} = Lisp.run("(doc 'Integer/parseInt)")
      assert short_doc.return == nil
      assert Enum.join(short_doc.prints, "\n") =~ "Integer/parseInt"

      assert {:ok, apropos_step} = Lisp.run(~s|(apropos "parseInt")|)
      refute Enum.any?(apropos_step.return, &String.contains?(&1, "java.lang.Integer/parseInt"))
      assert Enum.any?(apropos_step.return, &String.contains?(&1, "Integer/parseInt"))
    end

    test "local apropos is lexical and does not treat query as regex" do
      assert {:ok, step} = Lisp.run(~s|(apropos "[invalid")|)
      assert step.return == []
    end

    test "unified apropos ranks MCP before local matches" do
      exec = fn
        :apropos_matches, ["replace", %{limit: 5}] ->
          {:ok,
           [
             %{
               source_kind: "mcp",
               source_rank: 0,
               score: 1,
               server: "search",
               name: "replace",
               ref: "search/replace",
               line: "search.replace - MCP replacement tool"
             }
           ]}

        operation, args ->
          discovery_result(operation, args)
      end

      assert {:ok, step} = Lisp.run(~s|(apropos "replace" {:limit 5})|, discovery_exec: exec)

      assert ["search.replace - MCP replacement tool" | rest] = step.return
      assert Enum.any?(rest, &String.starts_with?(&1, "local:"))
    end

    test "known local refs shadow MCP refs and unknown refs fall through" do
      exec = fn
        :doc, ["LocalDate/unknown"] -> {:ok, "mcp LocalDate/unknown"}
        :doc, ["LocalDate/parse"] -> {:ok, "mcp LocalDate/parse"}
        operation, args -> discovery_result(operation, args)
      end

      assert {:ok, local_step} = Lisp.run("(doc 'LocalDate/parse)", discovery_exec: exec)
      assert local_step.return == nil
      local_doc = Enum.join(local_step.prints, "\n")
      assert local_doc =~ "LocalDate/parse"
      refute local_doc =~ "mcp LocalDate/parse"

      assert {:ok, mcp_step} = Lisp.run("(doc 'LocalDate/unknown)", discovery_exec: exec)
      assert mcp_step.return == nil
      assert Enum.join(mcp_step.prints, "\n") =~ "mcp LocalDate/unknown"
    end

    test "mcp servers still requires discovery_exec" do
      assert {:error, step} = Lisp.run("(tool/servers)")
      assert step.fail.message =~ "REPL discovery forms are only available"
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
      assert doc_step.return == nil
      assert Enum.join(doc_step.prints, "\n") =~ "github.search"

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
