defmodule PtcRunner.Lisp.LookupErrorMessageTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Java.Surface

  # A failed name lookup should take the highest rung it can reach: name one
  # verified alternative, list the bounded set the name must have come from, or
  # point at search. The rungs are not interchangeable — the first two cost the
  # model no turns and the third costs one — and no rung may emit a name that
  # was not resolved first.

  defp message(source) do
    assert {:error, %{fail: %{message: message}}} = Lisp.run(source)
    message
  end

  describe "site 1: an unresolved bare name points at search, with the scope stated" do
    test "the message names a discovery form and says what it searches" do
      message = message("unresolved-name")

      assert message =~ "Undefined variable: unresolved-name"
      assert message =~ ~s|(apropos "unresolved-name")|
      assert message =~ "prelude exports"
    end

    test "it does not claim the search covers builtins or earlier definitions" do
      # apropos reads prelude exports only. An unqualified "search for it" would
      # send the model looking in three places the form cannot see.
      message = message("unresolved-name")

      assert message =~ "does not cover builtins"
      assert message =~ "earlier turns"
    end
  end

  describe "site 2: an underscore name suggests only a name that resolves" do
    test "a hyphenated form that is a builtin is named" do
      assert message("map_indexed") =~ "Did you mean: map-indexed"
    end

    test "a hyphenated form that is not a builtin falls through to a verified fuzzy match" do
      message = message("re_duce")

      assert message =~ "Did you mean: reduce"
      refute message =~ "re-duce"
    end

    test "a name with neither states the convention and asserts no binding" do
      message = message("zzz_qqq_www")

      assert message =~ "hyphens"
      assert message =~ "underscores"
      refute message =~ "Did you mean"
      refute message =~ "zzz-qqq-www"
    end
  end

  describe "site 3: an unsupported Java class lists the admitted classes" do
    test "the message lists admitted class names" do
      message = message("(java.util.Foo/bar 1)")

      assert message =~ "unsupported Java class java.util.Foo"
      assert message =~ "java.lang.Integer"
      assert message =~ "java.time.LocalDate"
    end

    test "the list holds no inventory-only class and no constructor spelling" do
      message = message("(java.util.Foo/bar 1)")

      # class_spellings/0 flat-maps every class in the manifest, including
      # inventory-only entries with no admitted reference, and carries
      # constructor spellings such as "java.util.Date.". Neither is a name the
      # model can call, so neither may be offered as an alternative.
      admitted =
        Surface.references()
        |> Enum.map(& &1.class_id)
        |> Enum.uniq()
        |> Enum.flat_map(fn class_id ->
          case Surface.fetch_class(class_id) do
            {:ok, %{name: name}} -> [name]
            :error -> []
          end
        end)
        |> MapSet.new()

      inventory_only = Enum.reject(Surface.classes(), &MapSet.member?(admitted, &1.name))

      assert inventory_only != [],
             "the manifest has no inventory-only class, so this test proves nothing"

      for class <- inventory_only do
        refute message =~ class.name
      end

      refute message =~ "java.util.Date."
    end
  end

  describe "site 4: a Java arity error names a callable spelling, not an internal ID" do
    test "a class/member reference names an admitted spelling and the arities" do
      message = message(~S|(Integer/parseInt "1" 2 3)|)

      assert message =~ "Integer/parseInt"
      assert message =~ "1"
      refute message =~ "integer_parse_int"
    end

    test "a direct-dot member family names its spelling" do
      message = message(~S|(.toEpochDay (LocalDate/parse "2020-01-01") 1 2)|)

      assert message =~ ".toEpochDay"
      refute message =~ "to_epoch_day"
    end

    test "the message does not promise the spelling the model typed" do
      # Short and fully qualified spellings collapse to one reference_id, so the
      # message names a canonical admitted spelling and cannot claim it is the
      # one that was written.
      message = message(~S|(java.time.LocalDate/parse "2020-01-01" "extra")|)

      assert message =~ "LocalDate/parse"
    end
  end

  describe "site 5: a receiver mismatch names the member without naming a type" do
    test "the message names the member and says the receiver was not accepted" do
      message = message("(.isBefore 5 6)")

      assert message =~ ".isBefore"
      assert message =~ "receiver"
    end

    test "it never renders the internal receiver profile as a type" do
      # receiver_profile/1 answers :unsupported for most wrong receivers, and
      # that atom is not a type the model can act on.
      refute message("(.isBefore 5 6)") =~ "unsupported Java member for receiver class"
      refute message("(.isBefore 5 6)") =~ ":unsupported"
    end
  end

  describe "site 6: forms absent by category say so instead of pointing at search" do
    # Pinned so that adding a category to the prompt's denial bullet fails here
    # and forces the alternatives map to be extended with it.
    @denial_bullet "- No ns/require/refer/import, user-defined macros, eval/read-string, or host file I/O.\n\n"

    @denied_forms %{
      "ns" => "component source only",
      "require" => "namespace loading",
      "refer" => "namespace loading",
      "import" => "import",
      "defmacro" => "macro",
      "eval" => "constructed source",
      "read-string" => "constructed source",
      "spit" => "file I/O",
      "slurp" => "file I/O"
    }

    test "the prompt's denial bullet still names exactly the mapped categories" do
      source = File.read!("priv/preludes/kernel/agent.prompt.clj")
      assert source =~ inspect(@denial_bullet)
    end

    test "every denied form receives a category-absent message, not search advice" do
      for {form, expected} <- @denied_forms do
        message = message(form)

        assert message =~ expected, "#{form}: expected a category-absent message, got: #{message}"

        refute message =~ "apropos",
               "#{form} is absent by category; pointing at search costs a turn and finds nothing"
      end
    end

    test "the import message does not deny Java interop the surface admits" do
      # The admitted bounded surface contradicts "no Java interop"; a model told
      # that stops writing Java-shaped calls that would have worked.
      refute message("import") =~ "no Java interop"
    end
  end

  describe "the alternatives table advertises no name that fails to resolve" do
    test "every key it answers for is genuinely unbound" do
      # format, re-find and re-seq were keys here while being builtins: the
      # entries were unreachable and told the model three available functions
      # were unavailable.
      for name <- Helpers.clojure_alternative_names() do
        assert {:error, %{fail: %{reason: :unbound_var}}} = Lisp.run(name),
               "#{name} resolves, so answering that it is unavailable is false"
      end
    end

    test "every name its hints offer resolves" do
      # `grep` was offered as the alternative to re-find and has never existed.
      # A suggestion that does not resolve costs the model the same turn twice.
      for source <- [
            ~S|(str 1 2)|,
            ~S|(println "x")|,
            ~S|(apropos "map")|,
            ~S|(defn offered [x] x)|
          ] do
        assert {:ok, _result} = Lisp.run(source), "#{source} does not resolve"
      end
    end
  end

  describe "a Java field called as a function is named as a field" do
    test "the message states the type problem and offers no alternative name" do
      message = message("(Double/NaN)")

      assert message =~ "Double/NaN"
      assert message =~ "field"
      refute message =~ "accepts arity ,"
      refute message =~ "Did you mean"
    end
  end

  describe "the carve-out: authority refusals state the refusal and stop" do
    test "a private tool denial may list the tools the caller does hold" do
      message =
        Lisp.format_error(
          {:private_tool_unauthorized, "secret",
           %{origin: "api/fetch", allowed_tools: ["search", "read"]}}
        )

      assert message =~ "search, read"
    end

    test "a transitive-call refusal names the namespace and offers no substitute" do
      message = Lisp.format_error({:transitive_call_unauthorized, "log/runs", "log", ["report"]})

      assert message =~ "attach it directly"
      refute message =~ "apropos"
      refute message =~ "Did you mean"
    end

    test "a grant-filtered export refusal states the reason and offers no substitute" do
      message = Lisp.format_error({:grant_filtered_prelude_export, "log/runs", :ptc_tool_denied})

      assert message =~ "ptc_tool_denied"
      refute message =~ "apropos"
      refute message =~ "Did you mean"
    end
  end
end
