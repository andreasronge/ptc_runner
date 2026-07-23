defmodule PtcRunner.Lisp.Java.StringDispatchTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.Java.Dispatch
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Sandbox

  def handle_dispatch_attestation(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:java_dispatch, metadata})

  test "Java String indexes and lengths use UTF-16 code units" do
    assert {:ok, %{return: 3}} = Lisp.run(~S|(.length "😀a")|)
    assert {:ok, %{return: 2}} = Lisp.run(~S|(.indexOf "😀a" "a")|)
    assert {:ok, %{return: 3}} = Lisp.run(~S|(.lastIndexOf "😀a😀" "😀")|)
    assert {:ok, %{return: "a"}} = Lisp.run(~S|(.substring "😀a" 2)|)
    assert {:ok, %{return: "😀"}} = Lisp.run(~S|(.substring "😀a" 0 2)|)
  end

  test "Java String trim removes only code units from U+0000 through U+0020" do
    assert {:ok, %{return: "Ada"}} = Lisp.run(~S|(.trim "  Ada  ")|)

    assert {:ok, "Ada", :string_trim_0} =
             Dispatch.invoke(:string_trim, :instance, <<0, 9, 31, 32>> <> "Ada" <> <<32, 0>>, [])

    for codepoint <- [0x0085, 0x00A0, 0x1680, 0x2003, 0x2007, 0x202F] do
      boundary = <<codepoint::utf8>>
      value = boundary <> "Ada" <> boundary

      assert {:ok, ^value, :string_trim_0} =
               Dispatch.invoke(:string_trim, :instance, value, [])
    end
  end

  test "Java String trim retains the shared bounded receiver failures" do
    assert {:error, null_condition} = Dispatch.invoke(:string_trim, :instance, nil, [])
    assert null_condition.category == :java_domain_error
    assert null_condition.details.java_exception == :null_pointer_exception
    assert null_condition.overload_id == :string_trim_0

    assert {:error, invalid_condition} =
             Dispatch.invoke(:string_trim, :instance, <<0xFF>>, [])

    assert invalid_condition.category == :invalid_java_string
    assert invalid_condition.details.java_exception == :invalid_java_string
    assert invalid_condition.overload_id == :string_trim_0
  end

  test "indexOf fromIndex uses UTF-16 units and Java clamping" do
    assert {:ok, %{return: 3}} = Lisp.run(~S|(.indexOf "😀a😀" "😀" 1)|)
    assert {:ok, %{return: 0}} = Lisp.run(~S|(.indexOf "abc" "" -10)|)
    assert {:ok, %{return: 3}} = Lisp.run(~S|(.indexOf "abc" "" 10)|)
  end

  test "empty, absent, BMP, prefix, suffix, and containment cases retain Java behavior" do
    assert {:ok, %{return: [-1, -1, 0, 0, "", 4, 1, true, true, true, true]}} =
             Lisp.run(~S|[(.indexOf "hello" "x")
                  (.lastIndexOf "hello" "x")
                  (.indexOf "" "")
                  (.length "")
                  (.substring "abc" 3)
                  (.length "über")
                  (.indexOf "über" "b")
                  (.startsWith "über" "ü")
                  (.endsWith "über" "ber")
                  (.contains "über" "be")
                  (.contains "abc" "")]|)
  end

  test "Java floating primitives compose into admitted int index parameters" do
    assert {:ok, %{return: "cd"}} = Lisp.run(~S|(.substring "abcd" (Math/ceil 1.2))|)

    assert {:ok, %{return: 1}} =
             Lisp.run(~S|(.indexOf "ababa" "ba" (Math/ceil 0.2))|)
  end

  test "Java int coercion truncates before range validation and maps NaN to zero" do
    assert {:ok, %{return: "abc"}} = Lisp.run(~S|(.substring "abc" ##NaN)|)
    assert {:ok, %{return: "abc"}} = Lisp.run(~S|(.substring "abc" (Math/sqrt -1.0))|)

    assert {:error, step} = Lisp.run(~S|(.substring "abc" -2147483648.9)|)
    assert step.fail.reason == :java_domain_error
    assert step.fail.details.java_exception == :string_index_out_of_bounds_exception
  end

  test "lastIndexOf preserves overlapping matches" do
    assert {:ok, %{return: 1}} = Lisp.run(~S|(.lastIndexOf "aaa" "aa")|)
  end

  test "contains searches only aligned UTF-16 code-unit boundaries" do
    assert {:ok, %{return: false}} = Lisp.run(~S|(.contains "AB" "䄀")|)
  end

  test "UTF-16 searches remain within the sandbox deadline for adversarial inputs" do
    receiver = String.duplicate("A", 40_000)
    unaligned_needle = String.duplicate("䄀", 12_000)
    overlapping_needle = String.duplicate("A", 12_000)

    assert {:ok, {:ok, false, :string_contains_char_sequence}} =
             Sandbox.run_bounded(
               fn ->
                 Dispatch.invoke(:string_contains, :instance, receiver, [unaligned_needle])
               end,
               timeout: 1_000
             )

    assert {:ok, {:ok, %Primitive{value: 28_000}, :string_last_index_of_string}} =
             Sandbox.run_bounded(
               fn ->
                 Dispatch.invoke(:string_last_index_of, :instance, receiver, [
                   overlapping_needle
                 ])
               end,
               timeout: 1_000
             )
  end

  test "UTF-16 search stays within the sandbox heap at the input cap" do
    at_limit = String.duplicate("A", 256_000)

    assert {:ok, {:ok, %Primitive{value: 0}, :string_last_index_of_string}} =
             Sandbox.run_bounded(
               fn ->
                 Dispatch.invoke(:string_last_index_of, :instance, at_limit, [at_limit])
               end,
               timeout: 1_000
             )
  end

  test "substring reports an unpaired-surrogate result as an explicit divergence" do
    assert {:error, step} = Lisp.run(~S|(.substring "😀a" 0 1)|)
    assert step.fail.reason == :invalid_java_string
    assert step.fail.details.java_exception == :invalid_java_string
  end

  test "substring preserves Java bounds failures including an indexOf miss" do
    for source <- [
          ~S|(.substring "abc" -1)|,
          ~S|(.substring "abc" 4)|,
          ~S|(.substring "abc" -1 2)|,
          ~S|(.substring "abc" 0 4)|,
          ~S|(.substring "abc" 2 1)|,
          ~S|(let [s "abc"] (.substring s (.indexOf s "missing")))|
        ] do
      assert {:error, step} = Lisp.run(source)
      assert step.fail.reason == :java_domain_error
      assert step.fail.details.java_exception == :string_index_out_of_bounds_exception
    end
  end

  test "String arguments reject incompatible types through closed dispatch" do
    for source <- [
          ~S|(.contains "abc" 1)|,
          ~S|(.startsWith "abc" 1)|,
          ~S|(.endsWith "abc" 1)|,
          ~S|(.indexOf "abc" 1)|,
          ~S|(.substring "abc" "bad")|
        ] do
      assert {:error, step} = Lisp.run(source)
      assert step.fail.reason == :java_type_error
    end
  end

  test "invalid UTF-8 is rejected before the selected handler" do
    invalid = <<0xFF>>

    assert {:error, condition} =
             Dispatch.invoke(:string_contains, :instance, invalid, ["x"])

    assert condition.category == :invalid_java_string
    assert condition.overload_id == :string_contains_char_sequence

    assert {:error, condition} =
             Dispatch.invoke(:string_contains, :instance, "x", [invalid])

    assert condition.category == :invalid_java_string
    assert condition.overload_id == :string_contains_char_sequence
  end

  test "arity and type selection precede bounded String input validation" do
    oversized = String.duplicate("x", 256_001)

    assert {:error, condition} =
             Dispatch.invoke(:string_length, :instance, "x", [oversized])

    assert condition.category == :java_arity_error

    assert {:error, condition} =
             Dispatch.invoke(:string_substring, :instance, "abc", [<<0xFF>>])

    assert condition.category == :java_type_error
  end

  test "mixed String and int fallback reports the actual mismatched argument" do
    assert {:error, condition} =
             Dispatch.invoke(:string_index_of, :instance, "abc", ["a", 2_147_483_648])

    assert condition.category == :java_type_error
    assert condition.details.argument == 1
  end

  test "the bounded UTF-16 view limit is scoped to java.lang.String methods" do
    oversized = String.duplicate("x", 256_001)
    oversized_invalid = oversized <> <<0xFF>>

    assert {:ok, false, :boolean_parse_boolean_string} =
             Dispatch.invoke(:boolean_parse_boolean, :static, nil, [oversized])

    assert {:error, condition} =
             Dispatch.invoke(:string_length, :instance, oversized, [])

    assert condition.category == :invalid_java_string
    assert condition.details.reason == :too_large

    assert {:error, condition} =
             Dispatch.invoke(:string_length, :instance, oversized_invalid, [])

    assert condition.category == :invalid_java_string
    assert condition.details.reason == :too_large
  end

  test "closed String dispatch returns tagged Java primitives" do
    assert {:ok, %Primitive{kind: :int}, :string_length_0} =
             Dispatch.invoke(:string_length, :instance, "😀", [])

    assert {:ok, true, :string_contains_char_sequence} =
             Dispatch.invoke(:string_contains, :instance, "abc", ["b"])
  end

  test "direct instance reference invocation rejects a null receiver" do
    assert {:error, condition} = Dispatch.invoke(:string_length, :instance, nil, [])
    assert condition.category == :java_domain_error
    assert condition.details.java_exception == :null_pointer_exception
  end

  test "selected String overload identity is attested on bounded validation failures" do
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:ptc_runner, :lisp, :java, :dispatch],
        &__MODULE__.handle_dispatch_attestation/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, null_condition} = Dispatch.invoke(:string_length, :instance, nil, [])
    assert null_condition.overload_id == :string_length_0

    assert_receive {:java_dispatch,
                    %{reference_id: :string_length, overload_id: :string_length_0}}

    assert {:error, invalid_condition} =
             Dispatch.invoke(:string_length, :instance, <<0xFF>>, [])

    assert invalid_condition.overload_id == :string_length_0

    assert_receive {:java_dispatch,
                    %{reference_id: :string_length, overload_id: :string_length_0}}
  end

  test "direct dot calls and first-class String callables report the same receiver errors" do
    for {direct, first_class} <- [
          {~S|(.length 123)|, ~S|((fn [f] (f 123)) .length)|},
          {~S|(.length nil)|, ~S|((fn [f] (f nil)) .length)|}
        ] do
      assert {:error, direct_step} = Lisp.run(direct)
      assert {:error, callable_step} = Lisp.run(first_class)
      assert direct_step.fail == callable_step.fail
    end
  end

  test "admitted Java dot spellings cannot be rebound in call or value position" do
    for source <- [
          ~S|(let [.length (fn [_] 99)] (.length "x"))|,
          ~S|(let [.length (fn [_] 99)] .length)|,
          ~S|(do (def .length (fn [_] 99)) (.length "x"))|,
          ~S|(do (def .length (fn [_] 99)) .length)|
        ] do
      assert {:ok, raw} = Parser.parse(source)
      assert {:error, {:invalid_form, message}} = Analyze.analyze(raw)
      assert message == "Java member spelling .length is reserved and cannot be bound"
    end
  end

  test "admitted Java dot spellings cannot be introduced by destructuring" do
    for source <- [
          ~S|(let [{:strs [.length]} {".length" (fn [_] 99)}] (#'.length "x"))|,
          ~S|(let [{:keys [.length]} {}] (#'.length "x"))|,
          ~S|(let [{:keys [x] :as .length} {:x 1}] (#'.length "x"))|,
          ~S|((fn [{:strs [.length]}] (#'.length "x")) {".length" (fn [_] 99)})|,
          ~S|(for [{:strs [.length]} [{".length" (fn [_] 99)}]] (#'.length "x"))|
        ] do
      assert {:ok, raw} = Parser.parse(source)
      assert {:error, {:invalid_form, message}} = Analyze.analyze(raw)
      assert message == "Java member spelling .length is reserved and cannot be bound"
    end
  end

  test "a null receiver does not bypass Java callable arity selection" do
    assert {:error, step} = Lisp.run(~S|((fn [f] (f nil "extra")) .length)|)
    assert step.fail.reason == :java_arity_error
  end

  test "ordinary PTC string helpers retain grapheme semantics" do
    assert {:ok, %{return: [2, 1, 2, "a"]}} =
             Lisp.run(
               ~S|[(count "😀a") (clojure.string/index-of "😀a" "a") (clojure.string/last-index-of "😀a😀" "😀") (subs "😀a" 1)]|
             )
  end

  test "locale-sensitive no-argument casing is not admitted" do
    assert {:error, step} = Lisp.run(~S|(.toLowerCase "ABC")|)
    assert step.fail.reason == :unsupported_method

    assert step.fail.message ==
             "Unsupported method '.toLowerCase'. Supported interop methods: .after, .before, .contains, .endsWith, .getTime, .indexOf, .isAfter, .isBefore, .lastIndexOf, .length, .minusDays, .plusDays, .startsWith, .substring, .toDays, .toEpochDay, .toEpochMilli, .toMillis, .trim. Use (.method obj) syntax."

    assert {:error, step} = Lisp.run(~S|(.toUpperCase "abc")|)
    assert step.fail.reason == :unsupported_method
  end
end
