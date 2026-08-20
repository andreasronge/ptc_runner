defmodule PtcRunner.Lisp.IntrospectionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Introspection
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.Export

  @source """
  (ns alpha "Alpha helpers." {:visibility :prompt})

  (defn greet
    "Greets a name."
    {:signature "(name :string) -> :string" :effect :read}
    [name]
    (str "hi " name))

  (defn shout [name] (str name "!"))

  (defn- helper [x] x)

  (def limit "Default page size." {:type ":int"} 10)

  (ns beta "Beta helpers." {:visibility :discoverable})

  (defn hidden
    "Reachable only by discovery."
    [x]
    x)

  (defn collect
    "Collects any number of items."
    [& items]
    items)

  (ns private-only "Nothing public here." {:visibility :prompt})

  (defn- secret [x] x)
  """

  setup_all do
    {:ok, prelude} = Compiler.compile(@source)
    {:ok, prelude: prelude}
  end

  defp eval!(source, prelude, opts \\ []) do
    {:ok, result} = Lisp.run(source, [prelude: prelude] ++ opts)
    result
  end

  defp fail(source, prelude, opts \\ []) do
    {:error, result} = Lisp.run(source, [prelude: prelude] ++ opts)
    result.fail
  end

  describe "dir" do
    test "lists namespaces holding public exports", %{prelude: prelude} do
      assert eval!("(dir)", prelude).return == ["alpha", "beta"]
    end

    test "omits a namespace whose definitions are all private", %{prelude: prelude} do
      # `private-only` declares a namespace but exports nothing callable.
      # Listing it would advertise a namespace `(dir "private-only")` reports
      # as empty.
      refute "private-only" in eval!("(dir)", prelude).return
    end

    test "lists the refs of one namespace", %{prelude: prelude} do
      assert eval!(~S|(dir "alpha")|, prelude).return ==
               ["alpha/greet", "alpha/limit", "alpha/shout"]
    end

    test "accepts unquoted and quoted namespace symbols", %{prelude: prelude} do
      assert eval!("(dir alpha)", prelude).return == eval!(~S|(dir "alpha")|, prelude).return
      assert eval!("(dir 'alpha)", prelude).return == eval!(~S|(dir "alpha")|, prelude).return
    end

    test "omits private helpers from a namespace listing", %{prelude: prelude} do
      refute "alpha/helper" in eval!(~S|(dir "alpha")|, prelude).return
    end

    test "an unknown namespace is empty, not an error", %{prelude: prelude} do
      assert eval!(~S|(dir "nope")|, prelude).return == []
    end
  end

  describe "apropos" do
    test "matches on ref", %{prelude: prelude} do
      assert "beta/hidden" in eval!(~S|(apropos "hidden")|, prelude).return
    end

    test "accepts a quoted symbol query (Piece-1 normalization)", %{prelude: prelude} do
      # `apropos` stays an ordinary function: bare symbols evaluate. Quoted
      # symbols become `{:symbol_ref, _}` and normalize like strings.
      assert eval!("(apropos 'hidden)", prelude).return ==
               eval!(~S|(apropos "hidden")|, prelude).return
    end

    test "matches on docstring", %{prelude: prelude} do
      assert eval!(~S|(apropos "page size")|, prelude).return == ["alpha/limit"]
    end

    test "is case-insensitive", %{prelude: prelude} do
      assert eval!(~S|(apropos "GREETS")|, prelude).return == ["alpha/greet"]
    end

    test "matches an export with no docstring on its ref alone", %{prelude: prelude} do
      assert eval!(~S|(apropos "shout")|, prelude).return == ["alpha/shout"]
    end

    test "a blank query matches nothing rather than everything", %{prelude: prelude} do
      # An empty search is not a request for the whole surface.
      assert eval!(~S|(apropos "")|, prelude).return == []
      assert eval!(~S|(apropos "   ")|, prelude).return == []
    end

    test "never returns private helpers", %{prelude: prelude} do
      refute "alpha/helper" in eval!(~S|(apropos "helper")|, prelude).return
    end

    test "merges registry and visible prelude matches into sorted unique names", %{
      prelude: prelude
    } do
      assert eval!(~S|(apropos "map")|, prelude).return ==
               eval!(~S|(apropos "map")|, prelude).return |> Enum.uniq() |> Enum.sort()

      assert "map" in eval!(~S|(apropos "map")|, prelude).return
      assert "alpha/greet" in eval!(~S|(apropos "greets")|, prelude).return

      assert "Duration/between" in eval!(~S|(apropos "java.time.Duration/between")|, prelude).return

      assert eval!(~S|(apropos "[invalid")|, prelude).return == []
    end
  end

  describe "export-meta" do
    test "reports the calling contract of a signed function", %{prelude: prelude} do
      assert eval!(~S|(export-meta "alpha/greet")|, prelude).return == %{
               ref: "alpha/greet",
               namespace: "alpha",
               symbol: "greet",
               kind: :function,
               arity: 1,
               params: ["name"],
               call: "(alpha/greet name)",
               doc: "Greets a name.",
               visibility: :prompt,
               effect: :read,
               signature: "(name :string) -> :string"
             }
    end

    test "accepts unquoted and quoted refs", %{prelude: prelude} do
      assert eval!("(export-meta alpha/greet)", prelude).return ==
               eval!(~S|(export-meta "alpha/greet")|, prelude).return

      assert eval!("(export-meta 'alpha/greet)", prelude).return ==
               eval!(~S|(export-meta "alpha/greet")|, prelude).return
    end

    test "omits the signature key entirely when unsigned", %{prelude: prelude} do
      meta = eval!(~S|(export-meta "alpha/shout")|, prelude).return

      refute Map.has_key?(meta, :signature)
      assert meta.doc == nil
    end

    test "a constant reports its type and bare-ref call form", %{prelude: prelude} do
      meta = eval!(~S|(export-meta "alpha/limit")|, prelude).return

      assert meta.kind == :constant
      assert meta.call == "alpha/limit"
      assert meta.type == ":int"
      refute Map.has_key?(meta, :arity)
      refute Map.has_key?(meta, :params)
    end

    test "a variadic function keeps its rest marker", %{prelude: prelude} do
      meta = eval!(~S|(export-meta "beta/collect")|, prelude).return

      assert meta.arity == :variadic
      assert "&" in meta.params
    end

    test "reports a discoverable export's visibility", %{prelude: prelude} do
      assert eval!(~S|(export-meta "beta/hidden")|, prelude).return.visibility == :discoverable
    end

    test "does not report capability wiring or compiler internals", %{prelude: prelude} do
      meta = eval!(~S|(export-meta "alpha/greet")|, prelude).return

      for key <- [:tool_refs, :requires, :min_arity, :declared_effect, :parsed_signature] do
        refute Map.has_key?(meta, key)
      end
    end

    test "never reports :read for an export that reaches a capability", %{prelude: _} do
      # This layer cannot see a capability's installed effect, so a wrapper
      # declaring :read over a :write capability would read as safe. The
      # authoritative value is the mission-resolved effect; the most this can
      # honestly say about a capability-touching export is :unknown.
      {:ok, prelude} =
        Compiler.compile("""
        (ns alpha "Alpha." {:visibility :prompt})

        (defn calc "Touches nothing." {:effect :read} [x] x)

        (defn fetch "Reads through a capability." {:effect :read} [] (tool/probe {}))

        (defn store "Writes through a capability." {:effect :write} [] (tool/probe {}))
        """)

      opts = [tools: %{"probe" => {fn _args -> "ok" end, "() -> :string"}}]

      effect = fn ref ->
        eval!(~s|(export-meta "#{ref}")|, prelude, opts).return.effect
      end

      assert effect.("alpha/calc") == :read
      assert effect.("alpha/fetch") == :unknown
      assert effect.("alpha/store") == :write
    end

    test "a private helper, unknown ref, or malformed ref is a miss", %{prelude: prelude} do
      for ref <- ["alpha/helper", "alpha/nope", "nope/nope", "alpha", "", "/", "alpha/"] do
        assert eval!(~s|(export-meta "#{ref}")|, prelude).return == nil
      end
    end
  end

  describe "doc" do
    test "prints and returns nil", %{prelude: prelude} do
      result = eval!(~S|(doc "alpha/greet")|, prelude)

      assert result.return == nil

      assert result.prints == [
               """
               alpha/greet
               (alpha/greet name)
                 (name :string) -> :string
                 effect: read

                 Greets a name.\
               """
             ]
    end

    test "accepts unquoted, quoted, and string refs identically (issue #1094)", %{
      prelude: prelude
    } do
      string = eval!(~S|(doc "alpha/greet")|, prelude)
      quoted = eval!("(doc 'alpha/greet)", prelude)
      unquoted = eval!("(doc alpha/greet)", prelude)

      assert string.prints == quoted.prints
      assert string.prints == unquoted.prints
      assert string.return == nil
    end

    test "accepts an unquoted builtin name", %{prelude: prelude} do
      assert eval!("(doc str)", prelude).prints == eval!(~S|(doc "str")|, prelude).prints
    end

    test "a missing namespaced ref is a clean miss, not an analysis fault", %{prelude: prelude} do
      result = eval!("(doc missing/ns)", prelude)
      assert result.return == nil
      assert Enum.join(result.prints, "\n") =~ ~s(No documentation found for "missing/ns")
    end

    test "computed refs still evaluate", %{prelude: prelude} do
      assert eval!(~S|(doc (str "alpha/" "greet"))|, prelude).prints ==
               eval!(~S|(doc "alpha/greet")|, prelude).prints
    end

    test "short-fn params keep evaluating (not auto-quoted)", %{prelude: prelude} do
      # `#(doc %)` desugars to `(fn [p1] (doc p1))`. The local must evaluate so
      # mapping over string refs still works.
      result = eval!(~S|(mapv #(doc %) ["alpha/greet" "str"])|, prelude)
      assert result.return == [nil, nil]
      assert Enum.join(result.prints, "\n") =~ "alpha/greet"
      assert Enum.join(result.prints, "\n") =~ "str"
    end

    test "renders a constant with its type and bare ref", %{prelude: prelude} do
      assert eval!(~S|(doc "alpha/limit")|, prelude).prints == [
               """
               alpha/limit
               alpha/limit
                 :int
                 effect: unknown

                 Default page size.\
               """
             ]
    end

    test "omits the contract and doc blocks when undeclared", %{prelude: prelude} do
      assert eval!(~S|(doc "alpha/shout")|, prelude).prints == [
               """
               alpha/shout
               (alpha/shout name)
                 effect: unknown\
               """
             ]
    end

    test "a miss prints a not-found line and still returns nil", %{prelude: prelude} do
      result = eval!(~S|(doc "alpha/nope")|, prelude)

      assert result.return == nil
      assert result.prints == [~s(No documentation found for "alpha/nope".)]
    end

    test "output is subject to the print budget", %{prelude: prelude} do
      result = eval!(~S|(doc "alpha/greet")|, prelude, max_print_length: 12)

      assert [printed] = result.prints
      assert String.starts_with?(printed, "alpha/greet\n")
      assert printed =~ "12/"
    end

    test "falls back to registry documentation and applies the same print budget", %{
      prelude: prelude
    } do
      result = eval!(~S|(doc "map")|, prelude, max_print_length: 20)

      assert result.return == nil
      assert [printed] = result.prints
      assert String.starts_with?(printed, "(map f coll)")
      assert printed =~ "20/"
    end
  end

  describe "no attached prelude" do
    test "prelude listings are empty while doc and apropos still expose built-ins", %{prelude: _} do
      {:ok, result} = Lisp.run(~S|[(dir) (dir "alpha") (apropos "greet")]|)
      assert result.return == [[], [], []]

      {:ok, apropos} = Lisp.run(~S|(apropos "sort")|)
      assert "sort" in apropos.return

      {:ok, meta} = Lisp.run(~S|(export-meta "alpha/greet")|)
      assert meta.return == nil

      {:ok, doc} = Lisp.run(~S|(doc "map")|)
      assert [printed] = doc.prints
      assert printed =~ "(map f coll)"
    end
  end

  describe "higher-order position" do
    # `Runtime.Callable.call/2` has no `{:special, _}` clause, so each of these
    # forms needs its own `closure_to_fun/3` bridge. Without one the raw
    # binding tuple reaches collection dispatch and the call fails.
    test "map over export-meta", %{prelude: prelude} do
      refs =
        eval!(~S|(mapv :ref (map export-meta (dir "beta")))|, prelude).return

      assert refs == ["beta/collect", "beta/hidden"]
    end

    test "map over dir and apropos", %{prelude: prelude} do
      assert eval!(~S|(map dir (dir))|, prelude).return == [
               ["alpha/greet", "alpha/limit", "alpha/shout"],
               ["beta/collect", "beta/hidden"]
             ]

      [hidden_matches, shout_matches] =
        eval!(~S|(map apropos ["hidden" "shout"])|, prelude).return

      assert "beta/hidden" in hidden_matches
      assert shout_matches == ["alpha/shout"]
    end

    test "map over doc captures every print in order", %{prelude: prelude} do
      result = eval!(~S|(map doc (dir "beta"))|, prelude)

      assert result.return == [nil, nil]
      assert [first, second] = result.prints
      assert String.starts_with?(first, "beta/collect\n")
      assert String.starts_with?(second, "beta/hidden\n")
    end

    test "conversion preserves both of dir's arities", %{prelude: prelude} do
      # A BEAM function has one arity, so converting `dir` to one would drop a
      # documented overload. It stays a binding tuple and dispatches on args.
      assert eval!(~S|(let [f (identity dir)] (f))|, prelude).return == ["alpha", "beta"]

      assert eval!(~S|(let [f (identity dir)] (f "beta"))|, prelude).return ==
               ["beta/collect", "beta/hidden"]
    end

    test "dir is a valid pcalls thunk and the unary forms are not", %{prelude: prelude} do
      assert eval!("(pcalls dir)", prelude).return == [["alpha", "beta"]]
      assert fail(~S|(pcalls doc)|, prelude)
    end

    test "apply, comp, partial, and pmap", %{prelude: prelude} do
      assert eval!(~S|(apply dir ["beta"])|, prelude).return == ["beta/collect", "beta/hidden"]

      assert eval!(~S|(map (comp :ref export-meta) (dir "beta"))|, prelude).return ==
               ["beta/collect", "beta/hidden"]

      assert eval!(~S|((partial dir) "beta")|, prelude).return == ["beta/collect", "beta/hidden"]

      assert eval!(~S|(mapv :ref (pmap export-meta (dir "beta")))|, prelude).return ==
               ["beta/collect", "beta/hidden"]
    end

    test "an argument fault raises the same reason as a direct call", %{prelude: prelude} do
      direct = fail(~S|(dir 5)|, prelude)
      via_hof = fail(~S|(map dir [5])|, prelude)

      assert direct.reason == :type_error
      assert via_hof.reason == direct.reason
      assert via_hof.message == direct.message
    end
  end

  describe "callable values" do
    test "render as builtins rather than leaking their binding tuple", %{prelude: prelude} do
      assert %PtcRunner.Lisp.Format.Builtin{} = eval!("dir", prelude).return
      assert eval!("(println dir)", prelude).prints == ["#<builtin>"]
    end

    test "work as an fnil replacement target", %{prelude: prelude} do
      assert eval!(~S|((fnil dir "alpha") nil)|, prelude).return ==
               ["alpha/greet", "alpha/limit", "alpha/shout"]
    end

    test "are recognized as functions", %{prelude: prelude} do
      assert eval!(
               ~S|[(fn? dir) (fn? apropos) (fn? doc) (fn? export-meta) (fn? source)]|,
               prelude
             ).return == [true, true, true, true, true]

      assert eval!(~S|[(ifn? dir) (ifn? export-meta) (ifn? source)]|, prelude).return ==
               [true, true, true]

      assert eval!(~S|(get (describe doc) :type)|, prelude).return == "function"
    end

    test "apply stays a non-function because it has no value position", %{prelude: prelude} do
      # `apply` shares the two-element `{:special, _}` binding shape but has no
      # higher-order dispatch, so classifying it callable would promise a
      # position it cannot be used in.
      assert eval!(~S|(fn? apply)|, prelude).return == false
    end
  end

  describe "binding-aware discovery refs" do
    test "defn params are not auto-quoted", %{prelude: prelude} do
      assert eval!(
               ~S|(do (defn show [r] (doc r)) (show "alpha/greet"))|,
               prelude
             ).prints == eval!(~S|(doc "alpha/greet")|, prelude).prints
    end

    test "if-let bindings are not auto-quoted", %{prelude: prelude} do
      assert eval!(
               ~S|(if-let [r "alpha/greet"] (doc r) nil)|,
               prelude
             ).prints == eval!(~S|(doc "alpha/greet")|, prelude).prints
    end
  end

  describe "source visibility" do
    test "an export mask hides source the same way as doc", %{prelude: prelude} do
      mask = [prelude_export_mask: %{"alpha" => MapSet.new(["alpha/greet"])}]

      assert Enum.join(eval!(~S|(doc "alpha/shout")|, prelude, mask).prints, "\n") =~
               "No documentation found"

      assert Enum.join(eval!(~S|(source "alpha/shout")|, prelude, mask).prints, "\n") =~
               ~s(No source available for "alpha/shout")

      assert Enum.join(eval!(~S|(source "alpha/greet")|, prelude, mask).prints, "\n") =~
               "(defn greet"
    end
  end

  describe "source" do
    test "prints the defining form with an effective header and returns nil", %{prelude: prelude} do
      result = eval!("(source alpha/greet)", prelude)

      assert result.return == nil
      text = Enum.join(result.prints, "\n")
      assert text =~ ";; alpha/greet"
      assert text =~ "visibility: prompt"
      assert text =~ "(effective)"
      assert text =~ "(defn greet"
      assert text =~ ~s("Greets a name.")
      assert text =~ "[name]"
    end

    test "quoted, unquoted, and string refs are identical", %{prelude: prelude} do
      quoted = eval!("(source 'alpha/greet)", prelude)
      unquoted = eval!("(source alpha/greet)", prelude)
      string = eval!(~S|(source "alpha/greet")|, prelude)

      assert quoted.prints == unquoted.prints
      assert quoted.prints == string.prints
    end

    test "renders author metadata distinct from the effective header" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "CRM." {:visibility :prompt})

        (defn list-users
          "List users."
          {:visibility :discoverable}
          []
          [])
        """)

      text = Enum.join(eval!("(source crm/list-users)", prelude).prints, "\n")
      assert text =~ "{:visibility :discoverable}"
      assert text =~ "(defn list-users"
    end

    test "a reachable private helper is source-addressable but stays out of doc" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "CRM." {:visibility :prompt})

        (defn- normalize-id "Normalize." [id] (str id))

        (defn get-user "Return a user." [id] (normalize-id id))
        """)

      text = Enum.join(eval!("(source crm/normalize-id)", prelude).prints, "\n")
      assert text =~ "(defn- normalize-id"
      assert text =~ "visibility: private"

      doc = Enum.join(eval!("(doc crm/normalize-id)", prelude).prints, "\n")
      assert doc =~ "No documentation found"
      refute "crm/normalize-id" in eval!(~S|(dir "crm")|, prelude).return
    end

    test "an unreferenced private helper is not source-addressable" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns crm "CRM." {:visibility :prompt})

        (defn- live-helper [x] (str x))
        (defn- dead-helper [x] (str x))
        (defn get-user [id] (live-helper id))
        """)

      assert Enum.join(eval!("(source crm/live-helper)", prelude).prints, "\n") =~
               "(defn- live-helper"

      assert Enum.join(eval!("(source crm/dead-helper)", prelude).prints, "\n") =~
               ~s(No source available for "crm/dead-helper")
    end

    test "renders constants", %{prelude: prelude} do
      text = Enum.join(eval!("(source alpha/limit)", prelude).prints, "\n")
      assert text =~ ~s[(def limit "Default page size." 10)]
    end

    test "unknown refs and builtins print a miss notice without raising", %{prelude: prelude} do
      assert Enum.join(eval!("(source map)", prelude).prints, "\n") =~
               ~s(No source available for "map")

      assert Enum.join(eval!("(source missing/ns)", prelude).prints, "\n") =~
               ~s(No source available for "missing/ns")
    end

    test "unavailable when no prelude is attached" do
      {:ok, result} = Lisp.run("(source alpha/greet)")
      assert result.return == nil
      assert Enum.join(result.prints, "\n") =~ ~s(No source available for "alpha/greet")
    end
  end

  describe "argument faults" do
    test "wrong arity", %{prelude: prelude} do
      assert fail(~S|(dir "a" "b")|, prelude).reason == :arity_error
      assert fail(~S|(doc)|, prelude).reason == :arity_error
      assert fail(~S|(apropos)|, prelude).reason == :arity_error
      assert fail(~S|(export-meta "a" "b")|, prelude).reason == :arity_error
      assert fail(~S|(source)|, prelude).reason == :arity_error
      assert fail(~S|(source "a" "b")|, prelude).reason == :arity_error
    end

    test "arity message names the accepted counts", %{prelude: prelude} do
      assert fail(~S|(dir "a" "b")|, prelude).message =~ "dir expects 0 or 1 argument(s), got 2"
    end

    test "non-string references", %{prelude: prelude} do
      for source <- [
            ~S|(dir 5)|,
            ~S|(apropos :kw)|,
            ~S|(doc nil)|,
            ~S|(export-meta [])|,
            ~S|(source 5)|
          ] do
        assert fail(source, prelude).reason == :type_error
      end
    end
  end

  describe "one prelude reading another" do
    # The goal case. A prelude export resolves documentation for a namespace it
    # does not depend on and never calls, including a `:discoverable` one that
    # no prompt inventory would have shown it.
    @cross_source """
    (ns beta "Beta helpers." {:visibility :discoverable})

    (defn thing "The thing beta does." [x] x)

    (ns alpha "Alpha helpers." {:visibility :prompt})

    (defn probe [] (export-meta "beta/thing"))

    (defn describe-beta [] (doc "beta/thing"))

    (defn survey [] (dir "beta"))
    """

    setup do
      {:ok, prelude} = Compiler.compile(@cross_source)
      {:ok, cross: prelude}
    end

    test "returns another namespace's metadata as data", %{cross: prelude} do
      meta = eval!("(alpha/probe)", prelude).return

      assert meta.ref == "beta/thing"
      assert meta.doc == "The thing beta does."
      assert meta.visibility == :discoverable
    end

    test "prints another namespace's documentation", %{cross: prelude} do
      # `doc` returns nil, so the documentation is only observable as a print.
      result = eval!("(alpha/describe-beta)", prelude)

      assert result.return == nil
      assert [printed] = result.prints
      assert printed =~ "beta/thing"
      assert printed =~ "The thing beta does."
    end

    test "lists another namespace's exports", %{cross: prelude} do
      assert eval!("(alpha/survey)", prelude).return == ["beta/thing"]
    end
  end

  describe "visibility restrictions" do
    # Introspection must answer with exactly what the running program may call.
    # These guard the two mechanisms that can narrow that set; if either grows
    # a producer, an unfiltered introspection would advertise uncallable refs.
    test "an export mask hides refs from every form", %{prelude: prelude} do
      mask = [prelude_export_mask: %{"alpha" => MapSet.new(["alpha/greet"])}]

      assert eval!(~S|(dir "alpha")|, prelude, mask).return == ["alpha/greet"]
      assert eval!(~S|(apropos "shout")|, prelude, mask).return == []
      assert eval!(~S|(export-meta "alpha/shout")|, prelude, mask).return == nil

      assert eval!(~S|(doc "alpha/shout")|, prelude, mask).prints ==
               [~s(No documentation found for "alpha/shout".)]

      assert eval!(~S|(source "alpha/shout")|, prelude, mask).prints ==
               [~s(No source available for "alpha/shout".)]
    end

    test "a hidden qualified alias does not suppress a callable registry name", %{prelude: _} do
      {:ok, collision} =
        Compiler.compile("""
        (ns core "Collision." {:visibility :prompt})
        (defn map "Attached map." [f xs] xs)
        """)

      mask = [prelude_export_mask: %{"core" => MapSet.new()}]

      assert "map" in eval!(~S|(apropos "map")|, collision, mask).return

      assert eval!(~S|(doc "core/map")|, collision, mask).prints ==
               [~s(No documentation found for "core/map".)]

      assert eval!(~S|(doc "map")|, collision, mask).prints |> hd() =~ "(map f coll)"

      strict = [
        strict_transitive_calls: true,
        direct_namespaces: [],
        transitive_namespace_requirers: %{"core" => ["alpha"]}
      ]

      assert "map" in eval!(~S|(apropos "map")|, collision, strict).return

      assert eval!(~S|(doc "core/map")|, collision, strict).prints ==
               [~s(No documentation found for "core/map".)]
    end

    test "a hidden exact ref suppresses its registry collision" do
      prelude = %Prelude{
        namespaces: ["Duration"],
        exports: [
          %Export{
            ref: "Duration/between",
            namespace: "Duration",
            symbol: "between",
            arity: 2,
            visibility: :prompt
          }
        ],
        private_env: %{},
        source_hash: "synthetic-collision"
      }

      refute "Duration/between" in Introspection.apropos(prelude, "between", fn _ -> false end)
    end

    test "a namespace absent from the mask stays unrestricted", %{prelude: prelude} do
      # The mask is an overlay, not an allowlist.
      mask = [prelude_export_mask: %{"alpha" => MapSet.new(["alpha/greet"])}]

      assert eval!(~S|(dir "beta")|, prelude, mask).return == ["beta/collect", "beta/hidden"]
    end

    test "strict transitive calls hide what the program may not call", %{prelude: prelude} do
      strict = [
        strict_transitive_calls: true,
        direct_namespaces: ["alpha"],
        transitive_namespace_requirers: %{"beta" => ["alpha"]}
      ]

      assert eval!("(dir)", prelude, strict).return == ["alpha"]
      assert eval!(~S|(dir "beta")|, prelude, strict).return == []
      refute "beta/hidden" in eval!(~S|(apropos "hidden")|, prelude, strict).return

      # ...and the hidden namespace is genuinely uncallable, so discovery and
      # callability agree rather than merely both being restricted.
      assert fail(~S|(beta/hidden 1)|, prelude, strict)
    end

    test "a prelude-converted callback does not carry the prelude's view", %{prelude: _} do
      # A privileged export can convert an introspection value and hand the
      # result to session code. If the filter were bound when the value was
      # converted rather than when it runs, that code would inherit the
      # prelude's unrestricted view and enumerate a namespace it cannot call.
      {:ok, prelude} =
        Compiler.compile("""
        (ns alpha "Alpha." {:visibility :prompt})

        (defn echo [x] (identity x))

        (ns beta "Beta." {:visibility :prompt})

        (defn hidden "Hidden." [x] x)
        """)

      strict = [
        strict_transitive_calls: true,
        direct_namespaces: ["alpha"],
        transitive_namespace_requirers: %{"beta" => ["alpha"]}
      ]

      assert eval!(~S|((alpha/echo dir) "beta")|, prelude, strict).return == []
      assert eval!(~S|((alpha/echo dir) "alpha")|, prelude, strict).return == ["alpha/echo"]
    end

    test "every ref discovered under strict mode is callable", %{prelude: prelude} do
      strict = [
        strict_transitive_calls: true,
        direct_namespaces: ["alpha"],
        transitive_namespace_requirers: %{"beta" => ["alpha"]}
      ]

      for ref <- eval!(~S|(dir "alpha")|, prelude, strict).return, ref != "alpha/limit" do
        assert {:ok, _} = Lisp.run(~s|(#{ref} "x")|, [prelude: prelude] ++ strict)
      end
    end
  end
end
