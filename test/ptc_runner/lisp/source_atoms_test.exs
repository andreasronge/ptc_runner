defmodule PtcRunner.Lisp.SourceAtomsTest do
  @moduledoc """
  Regression coverage for `PtcRunner.Lisp.SourceAtoms` — the bounded
  vocabulary the parser is allowed to intern as atoms (issue #953).

  Two flavors of test:

    1. **Sanity** — every entry in the table must round-trip through
       `intern/1` as the same atom.

    2. **Coverage** — every atom literal the analyzer pattern-matches
       on as a `:keyword`/`:symbol`/`:ns_symbol` element MUST be in
       the table. This is the regression guard: when someone adds a
       new analyzer clause like `{:keyword, :foo}`, this test fails
       unless they also add `:foo` to the allowlist.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.SourceAtoms

  describe "intern/1" do
    test "returns the atom for bounded vocabulary entries" do
      for {name_bin, atom} <- SourceAtoms.table() do
        assert SourceAtoms.intern(name_bin) == atom,
               "expected #{inspect(name_bin)} to intern as #{inspect(atom)}"
      end
    end

    test "returns the binary unchanged for unknown names" do
      assert SourceAtoms.intern("definitely_not_in_table_xyz") == "definitely_not_in_table_xyz"
      assert SourceAtoms.intern("my_unique_var_1") == "my_unique_var_1"
      assert SourceAtoms.intern("ctx_key_42") == "ctx_key_42"
    end

    test "does not create a new atom for unknown names" do
      name = "a_truly_novel_string_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      assert SourceAtoms.intern(name) == name
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "covers core analyzer special forms" do
      assert SourceAtoms.intern("let") == :let
      assert SourceAtoms.intern("fn") == :fn
      assert SourceAtoms.intern("defn") == :defn
      assert SourceAtoms.intern("if") == :if
      assert SourceAtoms.intern("cond") == :cond
      assert SourceAtoms.intern("when-let") == :"when-let"
      assert SourceAtoms.intern("if-some") == :"if-some"
    end

    test "covers bounded namespaces (including fully-qualified Java)" do
      assert SourceAtoms.intern("data") == :data
      assert SourceAtoms.intern("tool") == :tool
      assert SourceAtoms.intern("catalog") == :catalog
      assert SourceAtoms.intern("java.time.LocalDate") == :"java.time.LocalDate"
      assert SourceAtoms.intern("LocalDate") == :LocalDate
      assert SourceAtoms.intern("Double") == :Double
    end

    test "covers qualified analyzer keys" do
      assert SourceAtoms.intern("search-tools") == :"search-tools"
      assert SourceAtoms.intern("describe-tool") == :"describe-tool"
      assert SourceAtoms.intern("list-tools") == :"list-tools"
    end

    test "covers analyzer-dispatched source forms outside the core list" do
      assert SourceAtoms.intern("task") == :task
      assert SourceAtoms.intern("step-done") == :"step-done"
      assert SourceAtoms.intern("task-reset") == :"task-reset"
      assert SourceAtoms.intern("juxt") == :juxt
      assert SourceAtoms.intern("pmap") == :pmap
      assert SourceAtoms.intern("pcalls") == :pcalls
      assert SourceAtoms.intern(".") == :.
    end

    test "covers short-fn param atoms" do
      for i <- 1..20 do
        assert SourceAtoms.intern("p#{i}") == String.to_atom("p#{i}")
      end
    end
  end

  describe "table coverage of analyzer atom-literal dispatch" do
    # When the parser flip for #953 lands, every atom literal matched
    # in analyze.ex / analyze/*.ex pattern clauses must resolve via
    # `SourceAtoms.intern/1`. This list is the manual audit — if a new
    # analyzer clause uses an atom literal not listed here, add it to
    # `SourceAtoms` AND extend this list so future analyzer additions
    # trip the test rather than silently falling through to binary.
    @required_atoms [
      # special forms
      :return,
      :fail,
      :let,
      :fn,
      :def,
      :defn,
      :defonce,
      :if,
      :"if-let",
      :"if-not",
      :"if-some",
      :when,
      :"when-let",
      :"when-not",
      :"when-some",
      :"when-first",
      :cond,
      :case,
      :condp,
      :do,
      :and,
      :or,
      :not,
      :->,
      :"->>",
      :"as->",
      :"cond->",
      :"cond->>",
      :"some->",
      :"some->>",
      :loop,
      :recur,
      :doseq,
      :for,
      :comment,
      :task,
      :"step-done",
      :"task-reset",
      :juxt,
      :pmap,
      :pcalls,
      :.,
      # destructuring + iteration modifiers
      :else,
      :keys,
      :strs,
      :as,
      :while,
      # bounded namespaces
      :data,
      :tool,
      :catalog,
      :budget,
      :json,
      :mcp,
      :str,
      :string,
      :set,
      :regex,
      :Math,
      :Interop,
      :System,
      :Double,
      :LocalDate,
      :Instant,
      :"java.time.LocalDate",
      :"java.time.Instant",
      :"java.util.Date.",
      # qualified analyzer keys
      :summary,
      :remaining,
      :"list-servers",
      :"list-tools",
      :"describe-tool",
      :"search-tools",
      :"parse-string",
      :"generate-string",
      :text,
      :json,
      :"re-pattern"
    ]

    test "every required atom literal is in the SourceAtoms table" do
      table = SourceAtoms.table()
      missing = Enum.reject(@required_atoms, fn atom -> table[Atom.to_string(atom)] == atom end)

      assert missing == [],
             "Missing from SourceAtoms.table/0: #{inspect(missing)}.\n" <>
               "These atoms appear in analyzer pattern matches; the parser flip " <>
               "(#953) would break dispatch unless they're added."
    end

    test "table is non-trivially populated from Env.initial" do
      # Sanity: the builtin vocabulary should contribute hundreds of
      # entries. If this drops to <100 someone broke `build_table/0`.
      assert map_size(SourceAtoms.table()) > 100
    end
  end
end
