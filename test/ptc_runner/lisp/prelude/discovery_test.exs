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

  alias PtcRunner.Lisp.Parser
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

  # `(doc ...)` prints and returns nil (clojure.repl/doc semantics, P1): the
  # rendered docstring lands in `step.prints`, not the result channel.
  defp run_doc(program, prelude) do
    assert {:ok, %Step{} = step} = PtcRunner.Lisp.run(program, prelude: prelude)
    assert step.return == nil
    Enum.join(step.prints, "\n")
  end

  # `(source ...)` mirrors `doc`: prints the rendered form (or the miss notice)
  # and returns nil, so the rendered text lands in `step.prints`.
  defp run_source(program, prelude) do
    assert {:ok, %Step{} = step} = PtcRunner.Lisp.run(program, prelude: prelude)
    assert step.return == nil
    Enum.join(step.prints, "\n")
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

    test "accepts an unquoted namespace symbol (Clojure-style)", %{prelude: prelude} do
      publics = run_return("(ns-publics crm)", prelude)
      assert Map.has_key?(publics, "get-user")
    end

    test "an unknown prelude namespace still errors", %{prelude: prelude} do
      assert {:error, %Step{} = step} = PtcRunner.Lisp.run("(ns-publics 'nope)", prelude: prelude)
      assert step.fail.reason in [:runtime_error, :analysis_error]
    end
  end

  describe "doc" do
    test "resolves an exact prelude export ref to its docstring", %{prelude: prelude} do
      doc = run_doc("(doc 'crm/get-user)", prelude)
      assert is_binary(doc)
      assert doc =~ "crm/get-user"
      assert doc =~ "Return a CRM user by id."
      assert doc =~ "(get-user id)"
    end

    test "resolves a :discoverable export too", %{prelude: prelude} do
      doc = run_doc("(doc 'crm/list-users)", prelude)
      assert doc =~ "crm/list-users"
      assert doc =~ "List CRM users."
    end

    test "accepts an unquoted namespaced symbol (Clojure-style, issue #1094)",
         %{prelude: prelude} do
      # `(doc crm/get-user)` must not evaluate the symbol to its closure first;
      # the docstring matches the quoted form exactly.
      assert run_doc("(doc crm/get-user)", prelude) ==
               run_doc("(doc 'crm/get-user)", prelude)
    end

    test "a non-symbol arg still evaluates — the runtime-computed-ref escape hatch",
         %{prelude: prelude} do
      # Auto-quoting is intentionally limited to bare/namespaced *symbols*
      # (Clojure macro semantics). Any other form — here a computed string —
      # still evaluates, so a ref can be built at runtime.
      assert run_doc(~s|(doc (str "crm/" "get-user"))|, prelude) ==
               run_doc("(doc 'crm/get-user)", prelude)
    end

    test "a private helper is not user-visible through doc", %{prelude: prelude} do
      # No prelude export record exists for the private helper; without an MCP
      # backend the form raises an unknown-ref runtime fault.
      assert {:error, %Step{} = step} =
               PtcRunner.Lisp.run("(doc 'crm/normalize-id)", prelude: prelude)

      assert step.fail.reason == :runtime_error
    end
  end

  # A docstring that renders to MORE than the MCP `:slim` result-channel preview
  # budget (512 chars) but LESS than the default per-entry print cap
  # (`:max_print_length` = 2000) — exactly the case the old result-channel `doc`
  # path truncated to uselessness.
  @midsize_doc "BEGIN-DOC " <> String.duplicate("lorem ipsum dolor sit amet ", 24) <> "END-DOC"

  describe "doc routes through the print channel (P1)" do
    test "a >512 / <2000 docstring arrives complete in prints, untruncated" do
      {:ok, prelude} = Compiler.compile(midsize_prelude_source())

      assert {:ok, %Step{return: nil, prints: prints}} =
               PtcRunner.Lisp.run("(doc 'big/wide)", prelude: prelude)

      text = Enum.join(prints, "\n")
      assert String.length(@midsize_doc) > 512
      assert String.length(@midsize_doc) < 2000
      # Full docstring present end-to-end, with no append_print truncation suffix.
      assert text =~ "BEGIN-DOC"
      assert text =~ "END-DOC"
      refute text =~ "chars)"
    end

    test "a docstring longer than the default cap is truncated unless the host raises :max_print_length" do
      {:ok, prelude} = Compiler.compile(oversize_prelude_source())

      # Default per-entry cap (2000): the print is truncated with a suffix.
      assert {:ok, %Step{return: nil, prints: [capped]}} =
               PtcRunner.Lisp.run("(doc 'big/wide)", prelude: prelude)

      assert capped =~ "(2000/"
      refute capped =~ "TAIL-MARKER"

      # Host raises the cap: the full docstring (incl. its tail) arrives.
      assert {:ok, %Step{return: nil, prints: [full]}} =
               PtcRunner.Lisp.run("(doc 'big/wide)", prelude: prelude, max_print_length: 6000)

      assert full =~ "TAIL-MARKER"
      refute full =~ "chars)"
    end
  end

  defp midsize_prelude_source do
    """
    (ns big "Big docs namespace." {:visibility :prompt})

    (defn wide
      "#{@midsize_doc}"
      [x]
      x)
    """
  end

  defp oversize_prelude_source do
    # ~2400-char docstring ending in a unique tail marker; > the 2000 default
    # print cap, < a raised 6000 cap.
    body = String.duplicate("padding ", 300)

    """
    (ns big "Big docs namespace." {:visibility :prompt})

    (defn wide
      "HEAD-MARKER #{body} TAIL-MARKER"
      [x]
      x)
    """
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

    test "accepts an unquoted namespaced symbol (Clojure-style, issue #1094)",
         %{prelude: prelude} do
      assert run_return("(meta crm/get-user)", prelude) ==
               run_return("(meta 'crm/get-user)", prelude)
    end
  end

  describe "source" do
    test "dispatches to discovery — `source` is not an undefined variable (L3 P1 guard)",
         %{prelude: prelude} do
      # Without the SourceAtoms registration, `source` stays a binary and the
      # analyzer never reaches the discovery clause: the call would fail as an
      # undefined-variable / unknown-call. This pins the wiring.
      assert {:ok, %Step{return: nil}} =
               PtcRunner.Lisp.run("(source crm/get-user)", prelude: prelude)
    end

    test "renders the defining form with the effective header and returns nil",
         %{prelude: prelude} do
      src = run_source("(source 'crm/get-user)", prelude)

      # Effective-metadata header (visibility ns-inherited :prompt — get-user
      # carries NO defn metadata, so visibility surfaces only via this header).
      assert src =~ ";; crm/get-user"
      assert src =~ "visibility: prompt"
      assert src =~ "(effective)"
      # Faithful defining form: head, docstring, params, body.
      assert src =~ "(defn get-user"
      assert src =~ ~s("Return a CRM user by id.")
      assert src =~ "[id]"
      assert src =~ "normalize-id"
    end

    test "quoted, unquoted, and string refs are byte-identical (macro-like parity)",
         %{prelude: prelude} do
      quoted = run_source("(source 'crm/get-user)", prelude)
      unquoted = run_source("(source crm/get-user)", prelude)
      string = run_source(~s|(source "crm/get-user")|, prelude)

      assert quoted == unquoted
      assert quoted == string
    end

    test "renders author-literal metadata distinct from the effective header",
         %{prelude: prelude} do
      # `list-users` carries `{:visibility :discoverable}` ON the defn, so the
      # rendered FORM contains that author map — separate from the header line.
      src = run_source("(source 'crm/list-users)", prelude)

      assert src =~ "{:visibility :discoverable}"
      assert src =~ "(defn list-users"
    end

    test "preserves multi-key author metadata and key order via metadata_form" do
      {:ok, prelude} = Compiler.compile(meta_order_source())
      src = run_source("(source 'crm/search-users)", prelude)

      # The raw metadata map renders Formatter-faithfully with ORIGINAL key
      # order (the normalized `metadata` map is order-destroying). `:since` is a
      # non-interpreted key — proves arbitrary metadata round-trips, not just the
      # bounded enums the export pipeline reads.
      assert src =~ ~s({:visibility :discoverable :since "1.0"})
    end

    test "a reachable private helper is source-addressable but stays out of doc/ns-publics",
         %{prelude: prelude} do
      # `normalize-id` is a `defn-` referenced by the public `get-user`, so it is
      # transitively reachable → in the index, rendered with `defn-`.
      src = run_source("(source 'crm/normalize-id)", prelude)
      assert src =~ "(defn- normalize-id"
      assert src =~ "visibility: private"

      # But it remains invisible to doc/ns-publics (no %Export{}).
      assert {:error, %Step{}} =
               PtcRunner.Lisp.run("(doc 'crm/normalize-id)", prelude: prelude)

      refute Map.has_key?(run_return("(ns-publics 'crm)", prelude), "normalize-id")
    end

    test "renders reader-macro literals (#(), #\"re\", 'sym) in a body without crashing compile" do
      # The source precompute renders the captured body form via Formatter. A body
      # using #() / #"re" / 'sym must not crash compilation (Formatter lacked
      # clauses for these raw nodes).
      {:ok, prelude} = Compiler.compile(reader_macro_source())

      src = run_source("(source 'lit/transform)", prelude)
      assert src =~ "#(* % 2)"
      assert src =~ ~S(#"ab")
      assert src =~ "'flag"
    end

    test "a private helper reached only through a #() short-fn is reachable" do
      # The call graph must descend into short-fn bodies; otherwise a live private
      # called only inside #() is wrongly treated as dead (and its requires would
      # not propagate to the public export).
      {:ok, prelude} = Compiler.compile(short_fn_reach_source())
      assert run_source("(source 'lit/double-it)", prelude) =~ "(defn- double-it"
    end

    test "an unreferenced (dead) private helper is NOT source-addressable (oracle guard)" do
      {:ok, prelude} = Compiler.compile(dead_private_source())

      # Reachable private → available.
      assert run_source("(source 'crm/live-helper)", prelude) =~ "(defn- live-helper"

      # Dead private → unavailable, even though it exists in the source text.
      assert run_source("(source 'crm/dead-helper)", prelude) =~
               "no source available for crm/dead-helper"
    end

    test "a doseq/for loop variable colliding with a dead private does not expose it (oracle guard)" do
      # Codex P2: collect_refs must model for/doseq bindings. A public body that
      # binds a loop variable named like a dead private must NOT make that
      # private's source addressable — the loop var is bound, not a call edge.
      {:ok, prelude} = Compiler.compile(loop_shadow_source())

      assert run_source("(source 'crm/ghost)", prelude) =~
               "no source available for crm/ghost"
    end

    test "a shadowed for/doseq is treated as a call, keeping a referenced private reachable" do
      # Codex P2 (2nd round): when a local binds `for`, `(for [helper []])` is an
      # ordinary call to that local — `helper` is a real same-namespace ref, not
      # a loop binding — so the private `helper` must stay source-addressable.
      {:ok, prelude} = Compiler.compile(shadowed_for_source())

      assert run_source("(source 'crm/helper)", prelude) =~ "(defn- helper"
    end

    test "renders a bare constant and a documented constant" do
      {:ok, prelude} = Compiler.compile(const_source())

      bare = run_source("(source 'cfg/limit)", prelude)
      assert bare =~ "(def limit 42)"

      documented = run_source("(source 'cfg/answer)", prelude)
      assert documented =~ ~s[(def answer "The answer." 42)]
    end

    test "a local binding shadows the discovery form", %{prelude: prelude} do
      # The local `source` fn is called instead of discovery; the keyword
      # `:shadowed` evaluates to its string value, confirming the local won.
      assert run_return("(let [source (fn [_] :shadowed)] (source 1))", prelude) == "shadowed"
    end

    test "wrong arity is an analyzer error", %{prelude: prelude} do
      assert {:error, %Step{} = none} = PtcRunner.Lisp.run("(source)", prelude: prelude)
      assert none.fail.reason == :invalid_arity

      assert {:error, %Step{} = two} =
               PtcRunner.Lisp.run("(source 'crm/get-user 'crm/list-users)", prelude: prelude)

      assert two.fail.reason == :invalid_arity
    end

    test "an unknown ref prints `no source available` and returns nil, never raising",
         %{prelude: prelude} do
      # A core builtin and a missing namespace both land on the uniform miss
      # shape — no tool-discovery fallthrough.
      assert run_source("(source map)", prelude) =~ "no source available for map"

      assert run_source("(source 'missing/ns)", prelude) =~
               "no source available for missing/ns"
    end

    test "never falls through to a configured discovery backend (no MCP source in V1)",
         %{prelude: prelude} do
      # With a discovery_exec stub that would RAISE if invoked, an unknown source
      # ref must still resolve to the local miss shape (plan D2).
      exploding = fn _op, _args -> raise "discovery_exec must not be called for source" end

      assert {:ok, %Step{return: nil, prints: prints}} =
               PtcRunner.Lisp.run("(source 'missing/ns)",
                 prelude: prelude,
                 discovery_exec: exploding
               )

      assert Enum.join(prints, "\n") =~ "no source available for missing/ns"
    end

    test "unavailable when no prelude is attached" do
      assert {:ok, %Step{return: nil, prints: prints}} =
               PtcRunner.Lisp.run("(source crm/get-user)")

      assert Enum.join(prints, "\n") =~ "no source available for crm/get-user"
    end

    test "the rendered form (minus the header) re-parses and metadata survives",
         %{prelude: prelude} do
      src = run_source("(source 'crm/list-users)", prelude)

      # Drop the leading `;;` provenance header; the remainder is real Lisp.
      [_header | form_lines] = String.split(src, "\n")
      form_text = Enum.join(form_lines, "\n")

      assert {:ok, _ast} = Parser.parse(form_text)
      assert form_text =~ "{:visibility :discoverable}"
    end

    test "an oversized form truncates at :max_print_length and is full when the cap is raised" do
      {:ok, prelude} = Compiler.compile(oversize_source_const())

      assert {:ok, %Step{return: nil, prints: [capped]}} =
               PtcRunner.Lisp.run("(source 'cfg/blob)", prelude: prelude)

      assert capped =~ "(2000/"
      refute capped =~ "TAIL-MARKER"

      assert {:ok, %Step{return: nil, prints: [full]}} =
               PtcRunner.Lisp.run("(source 'cfg/blob)", prelude: prelude, max_print_length: 6000)

      assert full =~ "TAIL-MARKER"
      refute full =~ "chars)"
    end
  end

  defp meta_order_source do
    """
    (ns crm "CRM helpers." {:visibility :prompt})

    (defn search-users
      "Search users by query."
      {:visibility :discoverable :since "1.0"}
      [query]
      (tool/call {:server "crm" :tool "search_users" :args {:q query}}))
    """
  end

  defp dead_private_source do
    """
    (ns crm "CRM helpers." {:visibility :prompt})

    (defn- live-helper "Reachable." [x] (str x))

    (defn- dead-helper "Never referenced by a public export." [x] (str x))

    (defn get-user "Return a CRM user by id." [id] (live-helper id))
    """
  end

  defp loop_shadow_source do
    # `ghost` is a dead private (never CALLED), but a public export binds a
    # doseq loop variable named `ghost`. Without modeling for/doseq bindings the
    # reachability pass would treat that loop var as a call and expose `ghost`.
    """
    (ns crm "CRM helpers." {:visibility :prompt})

    (defn- ghost "Never called by any public export." [x] (str x))

    (defn list-ids
      "List ids."
      [xs]
      (doseq [ghost xs] (println ghost)))
    """
  end

  defp shadowed_for_source do
    # `run` binds a param named `for`, so `(for [helper []])` is a CALL to that
    # local with `helper` as a value ref — not a comprehension. `helper` must
    # therefore count as a reachable same-namespace reference.
    """
    (ns crm "CRM helpers." {:visibility :prompt})

    (defn- helper "Referenced through a shadowed for-call." [x] (str x))

    (defn run
      "Apply the supplied fn to a one-element vector."
      [for]
      (for [helper []]))
    """
  end

  defp const_source do
    """
    (ns cfg "Config." {:visibility :prompt})

    (def limit 42)

    (def answer "The answer." 42)
    """
  end

  defp reader_macro_source do
    """
    (ns lit
      "Literal-bearing helpers."
      {:visibility :prompt})

    (defn transform
      "Body uses reader-macro literals."
      [xs]
      [#"ab" 'flag (map #(* % 2) xs)])
    """
  end

  defp short_fn_reach_source do
    """
    (ns lit
      "Short-fn reachability."
      {:visibility :prompt})

    (defn- double-it "Private, called only inside a short-fn." [x] (* x 2))

    (defn transform
      "Reaches the private helper only via a #() short-fn."
      [xs]
      (map #(double-it %) xs))
    """
  end

  defp oversize_source_const do
    # A constant whose rendered string blows past the 2000 default print cap but
    # fits a raised 6000 cap, ending in a unique tail marker.
    body = String.duplicate("padding ", 300)

    """
    (ns cfg "Config." {:visibility :prompt})

    (def blob "HEAD-MARKER #{body} TAIL-MARKER")
    """
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

    test "accepts an unquoted namespace symbol (Clojure-style)", %{prelude: prelude} do
      assert run_return("(dir crm)", prelude) == run_return("(dir 'crm)", prelude)
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

    test "accepts an unquoted namespace symbol (Clojure-style)", %{prelude: prelude} do
      assert run_return("(ns-name crm)", prelude) == "crm"
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
