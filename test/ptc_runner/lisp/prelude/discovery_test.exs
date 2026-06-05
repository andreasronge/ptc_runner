defmodule PtcRunner.Lisp.Prelude.DiscoveryTest do
  @moduledoc """
  Slice-2 (P4) discovery: prelude export records flow into the Lisp-facing
  discovery forms (`ns-publics`, `doc`, `meta`, `dir`, `apropos`) and the new
  namespace-reflection forms (`all-ns`, `ns-name`) — consulting the SAME
  `%Export{}` records the analyzer/evaluator use, with no separate registry.

  Exact prelude refs resolve through the export table and must NOT fall through
  to MCP discovery. `:discoverable` exports are findable but absent from the
  prompt inventory; private helpers (`defn-`) have no export record and must not
  appear in any discovery surface. `apropos` merges prelude + local/built-in +
  MCP matches with a PINNED stable source order (prelude > local > MCP).
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Step

  # A prelude with: a :prompt export (`get-user`), a :discoverable export
  # (`list-users`), and a PRIVATE helper (`normalize-id`) with no export record.
  @crm_source """
  (ns crm
    "CRM helpers."
    {:visibility :prompt})

  (defn- normalize-id
    "Trim and lowercase a raw id."
    [raw]
    (str "norm:" raw))

  (defn get-user
    "Return a CRM user by id."
    [id]
    (tool/call {:server "crm" :tool "get_user" :args {:id (normalize-id id)}}))

  (defn list-users
    "List CRM users."
    {:visibility :discoverable}
    []
    (tool/call {:server "crm" :tool "list_users" :args {}}))

  (defn combine-users
    "Combine a required pair and any extra ids."
    [first-id second-id & extra-ids]
    [first-id second-id extra-ids])
  """

  setup do
    {:ok, prelude} = Compiler.compile(@crm_source)
    %{prelude: prelude}
  end

  defp run_return(program, prelude) do
    assert {:ok, %Step{} = step} = PtcRunner.Lisp.run(program, prelude: prelude)
    step.return
  end

  describe "ns-publics" do
    test "returns a map keyed by public symbol strings, including discoverable exports",
         %{prelude: prelude} do
      publics = run_return("(ns-publics 'crm)", prelude)

      assert is_map(publics)
      # Both the :prompt and :discoverable exports are public and discoverable.
      assert Map.has_key?(publics, "get-user")
      assert Map.has_key?(publics, "list-users")
      # The private helper has no export record and must NOT appear.
      refute Map.has_key?(publics, "normalize-id")
    end

    test "carries doc/arglist metadata for each public export", %{prelude: prelude} do
      publics = run_return("(ns-publics 'crm)", prelude)
      entry = Map.fetch!(publics, "get-user")

      assert entry[:doc] == "Return a CRM user by id."
      assert entry[:name] == "get-user"
      assert entry[:arglists] == ["(get-user id)"]

      variadic_entry = Map.fetch!(publics, "combine-users")
      assert variadic_entry[:arglists] == ["(combine-users first-id second-id & extra-ids)"]
    end

    test "accepts a string namespace ref", %{prelude: prelude} do
      publics = run_return(~s|(ns-publics "crm")|, prelude)
      assert Map.has_key?(publics, "get-user")
    end

    test "an unknown prelude namespace still errors", %{prelude: prelude} do
      assert {:error, %Step{} = step} = PtcRunner.Lisp.run("(ns-publics 'nope)", prelude: prelude)
      assert step.fail.reason in [:runtime_error, :analysis_error]
    end
  end

  describe "doc" do
    test "resolves an exact prelude export ref to its docstring", %{prelude: prelude} do
      doc = run_return("(doc 'crm/get-user)", prelude)
      assert is_binary(doc)
      assert doc =~ "crm/get-user"
      assert doc =~ "Return a CRM user by id."
      assert doc =~ "(get-user id)"
    end

    test "resolves a :discoverable export too", %{prelude: prelude} do
      doc = run_return("(doc 'crm/list-users)", prelude)
      assert doc =~ "crm/list-users"
      assert doc =~ "List CRM users."
    end

    test "a private helper is not user-visible through doc", %{prelude: prelude} do
      # No prelude export record exists for the private helper; without an MCP
      # backend the form raises an unknown-ref runtime fault.
      assert {:error, %Step{} = step} =
               PtcRunner.Lisp.run("(doc 'crm/normalize-id)", prelude: prelude)

      assert step.fail.reason == :runtime_error
    end
  end

  describe "meta" do
    test "resolves an exact prelude export ref to a metadata map", %{prelude: prelude} do
      meta = run_return("(meta 'crm/get-user)", prelude)
      assert is_map(meta)
      assert meta[:ref] == "crm/get-user"
      assert meta[:namespace] == "crm"
      assert meta[:name] == "get-user"
      assert meta[:doc] == "Return a CRM user by id."
      assert meta[:arglists] == ["(get-user id)"]
    end
  end

  describe "dir" do
    test "lists the public exports of a prelude namespace (no private helpers)",
         %{prelude: prelude} do
      lines = run_return("(dir 'crm)", prelude)
      assert is_list(lines)

      # Each line carries the export's signature (arity-bearing) and short doc.
      assert Enum.any?(lines, &String.starts_with?(&1, "(get-user id)"))
      assert Enum.any?(lines, &String.starts_with?(&1, "(list-users)"))

      assert Enum.any?(
               lines,
               &String.starts_with?(&1, "(combine-users first-id second-id & extra-ids)")
             )

      # The private helper has no export record and must NOT appear.
      refute Enum.any?(lines, &String.contains?(&1, "normalize-id"))
    end
  end

  describe "all-ns" do
    test "returns a sorted list of curated namespace-name strings that includes prelude namespaces",
         %{prelude: prelude} do
      names = run_return("(all-ns)", prelude)

      assert is_list(names)
      assert Enum.all?(names, &is_binary/1)
      # Sorted.
      assert names == Enum.sort(names)
      # The prelude namespace appears.
      assert "crm" in names
      # Curated Lisp-facing namespaces appear; BEAM/Java/impl internals do not.
      assert "clojure.core" in names
      refute Enum.any?(names, &String.starts_with?(&1, "Elixir."))
      refute "java.lang.Math" in names
    end

    test "works without a prelude attached (curated builtins only)" do
      assert {:ok, %Step{} = step} = PtcRunner.Lisp.run("(all-ns)")
      assert is_list(step.return)
      refute "crm" in step.return
      assert "clojure.core" in step.return
    end
  end

  describe "ns-name" do
    test "returns the namespace name string for a quoted symbol", %{prelude: prelude} do
      assert run_return("(ns-name 'crm)", prelude) == "crm"
    end

    test "accepts a string ref", %{prelude: prelude} do
      assert run_return(~s|(ns-name "crm")|, prelude) == "crm"
    end
  end

  describe "apropos source order is pinned (prelude exact ranks first)" do
    # Capability Prelude V1 inserts prelude exports at the TOP of the unified
    # apropos order (source rank -1). The pre-existing MCP-vs-local relationship
    # is preserved unchanged (MCP/upstream rank 0 outranks local/built-in rank
    # 2), so the full order is: prelude exact > MCP > local/built-in.
    test "an exact prelude match outranks both an MCP match and local builtins" do
      # A prelude whose export name collides lexically with a local builtin AND
      # an MCP tool on the query token "users".
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})
      (defn list-users "List users." [] (tool/call {:server "crm" :tool "list_users" :args {}}))
      """

      {:ok, prelude} = Compiler.compile(source)

      # MCP backend that returns a structured match for the same query token.
      exec = fn
        :apropos_matches, ["users", _opts] ->
          {:ok,
           [
             %{
               source_kind: "mcp",
               score: 100,
               server: "search",
               name: "users",
               ref: "search/users",
               line: "search/users - MCP users tool"
             }
           ]}

        _operation, _args ->
          {:programmer_fault, "unexpected"}
      end

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(~s|(apropos "users" {:limit 10})|,
                 prelude: prelude,
                 discovery_exec: exec
               )

      lines = step.return
      assert is_list(lines)

      # The FIRST line is the prelude export, regardless of the (higher) MCP
      # score — source rank dominates the sort.
      assert hd(lines) =~ "crm/list-users"

      prelude_idx = Enum.find_index(lines, &(&1 =~ "crm/list-users"))
      mcp_idx = Enum.find_index(lines, &(&1 =~ "search/users"))
      assert prelude_idx == 0
      assert is_integer(mcp_idx)
      # Prelude exact ranks ahead of MCP.
      assert prelude_idx < mcp_idx

      # The preserved MCP-before-local relationship: any local builtin line
      # ("local: ...") comes AFTER the MCP match.
      local_idx = Enum.find_index(lines, &String.starts_with?(&1, "local:"))

      if is_integer(local_idx) do
        assert prelude_idx < local_idx
        assert mcp_idx < local_idx
      end
    end

    test "apropos surfaces prelude exports even with no MCP backend", %{prelude: prelude} do
      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(~s|(apropos "get-user")|, prelude: prelude)

      assert Enum.any?(step.return, &(&1 =~ "crm/get-user"))
    end
  end
end
