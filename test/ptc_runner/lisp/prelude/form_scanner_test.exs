defmodule PtcRunner.Lisp.Prelude.FormScannerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.FormScanner

  @root Path.expand("../../../..", __DIR__)

  # ============================================================
  # Corpus: every prelude-like source in the repo. This is the hard gate
  # from docs/plans/prelude-form-edit-and-introspection.md Phase 3 — the
  # scanner does not get to ship on hand-picked examples alone.
  # ============================================================

  describe "corpus: every prelude-like source in the repo" do
    test "scans, round-trips, and (where compilable) covers every export name" do
      Enum.each(corpus(), fn {label, source} ->
        assert {:ok, result} = FormScanner.scan(source), "#{label}: scan/1 should succeed"

        # scan/1's OWN cross-check (verify_cross_check/2) already refuses to
        # return {:ok, _} unless the scanned {head, name} list agrees with
        # PtcRunner.Lisp.Parser's parsed AST, so `{:ok, _}` above is already
        # the "names agree with the parse-derived list" assertion; re-deriving
        # the same list here would just duplicate the module under test.
        assert rebuild(source, result) == source,
               "#{label}: gaps + spans + trailing_gap must reconstruct the source byte-for-byte"

        case Compiler.compile(source) do
          {:ok, prelude} ->
            scanned_names = result.forms |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1)

            Enum.each(prelude.exports, fn export ->
              assert export.symbol in scanned_names,
                     "#{label}: export #{inspect(export.symbol)} missing from scanned names #{inspect(scanned_names)}"
            end)

          {:error, _not_a_compilable_prelude} ->
            :ok
        end
      end)
    end
  end

  defp corpus do
    file_sources =
      (Path.wildcard(Path.join(@root, "examples/**/*.clj")) ++
         Path.wildcard(Path.join(@root, "test/**/*.clj")))
      |> Enum.sort()
      |> Enum.reject(&generated_or_dependency_path?/1)
      |> Enum.map(fn path -> {Path.relative_to(path, @root), File.read!(path)} end)

    file_sources
  end

  defp generated_or_dependency_path?(path) do
    rel = Path.relative_to(path, @root)

    String.contains?(rel, "/_build/") or String.contains?(rel, "/deps/")
  end

  # ============================================================
  # Happy path: exact shape, hand-legible source
  # ============================================================

  test "scans a minimal ns+defn prelude with exact head/name/spans" do
    source = "(ns demo)\n\n(defn add [a b] (+ a b))\n"

    assert {:ok, result} = FormScanner.scan(source)
    assert [ns_form, defn_form] = result.forms

    assert ns_form.head == "ns"
    assert ns_form.name == "demo"
    assert slice(source, ns_form.gap) == ""
    assert slice(source, ns_form.span) == "(ns demo)"

    assert defn_form.head == "defn"
    assert defn_form.name == "add"
    assert slice(source, defn_form.gap) == "\n\n"
    assert slice(source, defn_form.span) == "(defn add [a b] (+ a b))"

    assert slice(source, result.trailing_gap) == "\n"
    assert rebuild(source, result) == source
  end

  test "a bare (let ...) top-level form (as in test/smoke scripts) has no name" do
    source = "(let [x 1] (+ x 1))"

    assert {:ok, result} = FormScanner.scan(source)
    assert [%{head: "let", name: nil}] = result.forms
  end

  # ============================================================
  # Adversarial reader-macro cases — each gets its own test.
  # ============================================================

  test "a form containing #(...) short-fn syntax scans correctly" do
    source = """
    (ns demo {:visibility :prompt})

    (defn double-all [xs] (map #(* 2 %) xs))
    """

    assert {:ok, result} = FormScanner.scan(source)
    assert Enum.map(result.forms, & &1.head) == ["ns", "defn"]
    assert Enum.map(result.forms, & &1.name) == ["demo", "double-all"]
    assert rebuild(source, result) == source
  end

  test "a form containing a \#{...} set literal scans correctly" do
    source = ~S"""
    (ns demo {:visibility :prompt})

    (defn vowel? [c] (contains? #{"a" "e" "i" "o" "u"} c))
    """

    assert {:ok, result} = FormScanner.scan(source)
    assert Enum.map(result.forms, & &1.head) == ["ns", "defn"]
    assert Enum.map(result.forms, & &1.name) == ["demo", "vowel?"]
    assert rebuild(source, result) == source
  end

  test "a regex literal #\"...\" whose body contains parens and semicolons is opaque" do
    source = """
    (ns demo {:visibility :prompt})

    (defn weird-pattern [] #"(foo);(bar)")
    """

    assert {:ok, result} = FormScanner.scan(source)
    assert Enum.map(result.forms, & &1.head) == ["ns", "defn"]
    assert Enum.map(result.forms, & &1.name) == ["demo", "weird-pattern"]
    assert rebuild(source, result) == source
  end

  test "quoted symbols scan as opaque tokens" do
    source = """
    (ns demo {:visibility :prompt})

    (defn describe [] (ns-name 'demo))
    """

    assert {:ok, result} = FormScanner.scan(source)
    assert Enum.map(result.forms, & &1.head) == ["ns", "defn"]
    assert Enum.map(result.forms, & &1.name) == ["demo", "describe"]
    assert rebuild(source, result) == source
  end

  test "a string literal containing prelude-looking text is not treated as a form" do
    source = """
    (ns demo {:visibility :prompt})

    (defn snippet [] "(defn fake [x] x)")
    """

    assert {:ok, result} = FormScanner.scan(source)
    assert Enum.map(result.forms, & &1.head) == ["ns", "defn"]
    assert Enum.map(result.forms, & &1.name) == ["demo", "snippet"]
    assert rebuild(source, result) == source
  end

  test "a line comment containing unbalanced parens does not perturb depth tracking" do
    source = """
    (ns demo {:visibility :prompt})

    ; a comment with only an unbalanced open paren (
    (defn ok [] 1)
    """

    assert {:ok, result} = FormScanner.scan(source)
    assert Enum.map(result.forms, & &1.head) == ["ns", "defn"]
    assert Enum.map(result.forms, & &1.name) == ["demo", "ok"]
    assert rebuild(source, result) == source
  end

  test ";; comments between top-level forms are captured in the following form's gap" do
    source = """
    (ns demo {:visibility :prompt})

    ;; a helper worth noting
    (defn helper [] 1)
    """

    assert {:ok, result} = FormScanner.scan(source)
    assert [_ns_form, helper_form] = result.forms
    assert slice(source, helper_form.gap) =~ ";; a helper worth noting"
    assert rebuild(source, result) == source
  end

  test "comment-only trailing content is captured in trailing_gap" do
    source = """
    (ns demo {:visibility :prompt})

    ; trailing remark, no more forms after this
    """

    assert {:ok, result} = FormScanner.scan(source)
    assert slice(source, result.trailing_gap) =~ "trailing remark, no more forms after this"
    assert rebuild(source, result) == source
  end

  test "source with no trailing newline scans cleanly" do
    source = "(ns demo {:visibility :prompt})"

    assert {:ok, result} = FormScanner.scan(source)
    assert [form] = result.forms
    assert slice(source, form.span) == source
    assert result.trailing_gap == {byte_size(source), 0}
    assert rebuild(source, result) == source
  end

  test "an unterminated string fails closed" do
    source = ~s|(defn bad [] "unterminated|

    assert {:error, %{reason: :unterminated_string}} = FormScanner.scan(source)
  end

  test "an unbalanced (unclosed) paren fails closed" do
    source = "(defn bad [] (+ 1 2)"

    assert {:error, %{reason: :unclosed_form}} = FormScanner.scan(source)
  end

  # ============================================================
  # Extra reader-macro coverage beyond the required adversarial list
  # ============================================================

  test "vars, character literals, and comma-as-whitespace all scan correctly" do
    source = """
    (ns demo {:visibility :prompt})

    (defn var-and-chars [x] {:v #'x, :c \\a, :items [1, 2, 3]})
    """

    assert {:ok, result} = FormScanner.scan(source)
    assert Enum.map(result.forms, & &1.head) == ["ns", "defn"]
    assert Enum.map(result.forms, & &1.name) == ["demo", "var-and-chars"]
    assert rebuild(source, result) == source
  end

  test "numeric literals including exponents and IEEE special values scan correctly" do
    source = """
    (ns demo {:visibility :prompt})

    (def limits [1 -2 3.14 -0.5 1.23e-4 ##Inf ##-Inf ##NaN nil true false])
    """

    assert {:ok, result} = FormScanner.scan(source)
    assert Enum.map(result.forms, & &1.head) == ["ns", "def"]
    assert Enum.map(result.forms, & &1.name) == ["demo", "limits"]
    assert rebuild(source, result) == source
  end

  test "a quoted collection fails closed, matching the reader's own rejection" do
    source = "(def bad '(1 2 3))"

    assert {:error, %{reason: :quoted_collection_not_supported}} = FormScanner.scan(source)
  end

  test "a stray closing paren between top-level forms fails closed" do
    # Diverges from FastParser's top-level `skip_extra_closers/1` leniency
    # (fast_parser.ex) on purpose — see the FormScanner moduledoc.
    source = "(defn a [] 1)\n)\n(defn b [] 2)"

    assert {:error, %{reason: :unexpected_byte}} = FormScanner.scan(source)
  end

  test "a bare top-level map (a smoke-test return value, not a definition) has a generic head and no name" do
    # test/smoke/04_definitions.clj ends in exactly this shape: a standalone
    # top-level map literal that is not wrapped in any enclosing list.
    source = """
    (def x 1)

    {:x x}
    """

    assert {:ok, result} = FormScanner.scan(source)
    assert [%{head: "def", name: "x"}, %{head: "map", name: nil}] = result.forms
  end

  test "empty source scans to zero forms and an empty trailing_gap" do
    assert {:ok, %{forms: [], trailing_gap: {0, 0}}} = FormScanner.scan("")
  end

  defp slice(source, {offset, length}), do: binary_part(source, offset, length)

  defp rebuild(source, %{forms: forms, trailing_gap: trailing_gap}) do
    parts =
      Enum.flat_map(forms, fn f -> [slice(source, f.gap), slice(source, f.span)] end) ++
        [slice(source, trailing_gap)]

    IO.iodata_to_binary(parts)
  end
end
