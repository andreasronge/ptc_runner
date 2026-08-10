defmodule PtcRunner.Lisp.Java.TemporalDispatchTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Java.Time.Duration
  alias PtcRunner.Lisp.Java.Time.Instant
  alias PtcRunner.Lisp.Java.Time.LocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.Lisp.Runtime.Collection
  alias PtcRunner.Lisp.Runtime.Describe
  alias PtcRunner.Lisp.TypeVocabulary

  test "temporal calls retain class identity, precision, and exact Date milliseconds" do
    assert {:ok, step} =
             Lisp.run_native(~S|[(LocalDate/parse "2024-01-02")
                   (Instant/parse "2024-01-02T03:04:05.123456789Z")
                   (Duration/between
                     (Instant/parse "2024-01-01T00:00:00Z")
                     (Instant/parse "2024-01-01T00:00:01.500000001Z"))
                   (java.util.Date. 1)]|)

    [local_date, instant, duration, legacy_date] = step.return

    assert local_date.__struct__ == PtcRunner.Lisp.Java.Time.LocalDate
    assert instant.__struct__ == PtcRunner.Lisp.Java.Time.Instant
    assert duration.__struct__ == PtcRunner.Lisp.Java.Time.Duration
    assert legacy_date.__struct__ == PtcRunner.Lisp.Java.Util.Date

    assert {:ok,
            %{
              return: [
                %Primitive{kind: :long, value: 19_724},
                "2024-01-04",
                true,
                %Primitive{kind: :long, value: 1_704_164_645_123},
                "PT1.500000001S",
                %Primitive{kind: :long, value: 1_500},
                %Primitive{kind: :long, value: 1},
                %Primitive{kind: :long, value: 1},
                true,
                true
              ]
            }} =
             Lisp.run_native(
               ~S|[(.toEpochDay local-date)
                   (str (.plusDays local-date 2))
                   (.isBefore local-date (.plusDays local-date 1))
                   (.toEpochMilli instant)
                   (str duration)
                   (.toMillis duration)
                   (.toDays (Duration/between
                     (Instant/parse "1970-01-01T00:00:00Z")
                     (Instant/parse "1970-01-02T12:00:00Z")))
                   (.getTime legacy-date)
                   (.before legacy-date (java.util.Date. 2))
                   (.after (java.util.Date. 2) legacy-date)]|,
               memory: %{
                 "local-date" => local_date,
                 "instant" => instant,
                 "duration" => duration,
                 "legacy-date" => legacy_date
               }
             )
  end

  test "temporal aliases and raw host temporal structs do not bypass class dispatch" do
    for source <- [
          ~S|(parse "2024-01-02")|,
          ~S|(.getTime (Instant/parse "1970-01-01T00:00:01Z"))|,
          ~S|(.isBefore (java.util.Date. 0) (java.util.Date. 1))|
        ] do
      assert {:error, _step} = Lisp.run(source)
    end

    assert {:error, _step} =
             Lisp.run_native("(.toEpochDay host-date)", memory: %{"host-date" => ~D[2024-01-02]})

    assert {:error, _step} =
             Lisp.run_native("(.getTime host-datetime)",
               memory: %{"host-datetime" => ~U[2024-01-02 00:00:00Z]}
             )
  end

  test "public projection emits canonical inert temporal values" do
    assert {:ok,
            %{
              return: [
                "2024-01-02",
                "2024-01-02T03:04:05.123456789Z",
                "PT1.5S",
                "1970-01-01T00:00:00.001Z"
              ]
            }} =
             Lisp.run(~S|[(LocalDate/parse "2024-01-02")
                   (Instant/parse "2024-01-02T03:04:05.123456789Z")
                   (Duration/between
                     (Instant/parse "1970-01-01T00:00:00Z")
                     (Instant/parse "1970-01-01T00:00:01.500Z"))
                   (java.util.Date. 1)]|)
  end

  test "strict parsers and canonical rendering cover Java temporal edge forms" do
    assert {:ok, min_date} = LocalDate.parse(["-999999999-01-01"])
    assert {:ok, max_date} = LocalDate.parse(["+999999999-12-31"])
    assert LocalDate.canonical(min_date) == "-999999999-01-01"
    assert LocalDate.canonical(max_date) == "+999999999-12-31"
    assert {:error, _condition} = LocalDate.parse(["2024-01-02T00:00:00"])
    assert {:error, _condition} = LocalDate.parse(["+0000000000010000-01-01"])
    assert {:error, _condition} = Instant.parse(["+0000000001000000000-01-01T00:00:00Z"])

    assert {:ok, zero_year_date} = LocalDate.parse(["+00000-01-01"])
    assert LocalDate.canonical(zero_year_date) == "0000-01-01"

    assert {:ok, zero_year_instant} = Instant.parse(["+00000-01-01T00:00:00Z"])
    assert Instant.canonical(zero_year_instant) == "0000-01-01T00:00:00Z"

    assert {:ok, empty_fraction_instant} = Instant.parse(["1970-01-01T00:00:00.Z"])
    assert Instant.canonical(empty_fraction_instant) == "1970-01-01T00:00:00Z"

    assert {:ok, parsed_duration} = Duration.from_iso8601("PT1H30M0.25S")
    assert Duration.canonical(parsed_duration) == "PT1H30M0.25S"

    assert {:ok, negative_duration} = Duration.from_iso8601("PT-1.5S")
    assert Duration.canonical(negative_duration) == "PT-1.5S"

    assert {:ok, negative_minute_fraction} = Duration.new(-60, 500_000_000)
    assert Duration.canonical(negative_minute_fraction) == "PT-59.5S"

    assert {:ok, negative_hour_fraction} = Duration.new(-3_600, 500_000_000)
    assert Duration.canonical(negative_hour_fraction) == "PT-59M-59.5S"

    assert :error = Duration.from_iso8601("PT")

    for {source, expected} <- [
          {~S|(str (Instant/parse "2016-12-31T23:59:60.5Z"))|, "2016-12-31T23:59:59.500Z"},
          {~S|(str (Instant/parse "1970-01-01T24:00:00Z"))|, "1970-01-02T00:00:00Z"},
          {~S|(str (Instant/parse "1970-01-01t00:00:00z"))|, "1970-01-01T00:00:00Z"},
          {~S|(str (Instant/parse "1970-01-01T00:00:00+00:00:30"))|, "1969-12-31T23:59:30Z"},
          {~S|(str (Duration/between (Instant/parse "1970-01-01T00:00:01.5Z") (Instant/parse "1970-01-01T00:00:00Z")))|,
           "PT-1.5S"},
          {~S|(.getTime (java.util.Date. "Thu Jan 01 00:00:01 UTC 1970"))|, 1_000},
          {~S|(.getTime (java.util.Date. "Wed, 8 Jan 2026 14:30:00 UTC"))|, 1_767_882_600_000},
          {~S|(.toEpochDay (.plusDays (LocalDate/parse "2024-01-01") (Double/parseDouble "1.9")))|,
           19_724},
          {~S|(.toEpochDay (.plusDays (LocalDate/parse "2024-01-01") (Integer/parseInt "1")))|,
           19_724}
        ] do
      assert {:ok, %{return: ^expected}} = Lisp.run(source)
    end

    for source <- [
          ~S|(Instant/parse "1970-01-01T24:00:00.000000001Z")|,
          ~S|(Instant/parse "1970-01-01T00:00:00+00")|,
          ~S|(Instant/parse "1970-01-01T00:00:00+0000")|,
          ~S|(Instant/parse "1970-01-01T00:00:00+000000")|,
          ~S|(Instant/parse "1970-01-01T00:00:00.0000000000Z")|
        ] do
      assert {:error, %{fail: %{reason: :java_domain_error}}} = Lisp.run(source)
    end
  end

  test "LocalDate day coercion rejects non-finite and out-of-range doubles" do
    for source <- [
          ~S|(.plusDays (LocalDate/parse "2024-01-01") Double/POSITIVE_INFINITY)|,
          ~S|(.minusDays (LocalDate/parse "2024-01-01") Double/NEGATIVE_INFINITY)|,
          ~S|(.plusDays (LocalDate/parse "2024-01-01") (Double/parseDouble "1e30"))|,
          ~S|(.minusDays (LocalDate/parse "2024-01-01") (Double/parseDouble "-1e30"))|
        ] do
      assert {:error, %{fail: %{reason: :java_type_error}}} = Lisp.run(source)
    end
  end

  test "public run memory retains temporal identity across evaluations" do
    assert {:ok, first} = Lisp.run(~S|(def date (LocalDate/parse "2024-01-01"))|)

    assert {:ok, %{return: "2024-01-02"}} =
             Lisp.run(~S|(.plusDays date 1)|, memory: first.memory)
  end

  test "natural comparison orders Duration values while numeric predicates reject them" do
    source = ~S"""
    (let [epoch (Instant/parse "1970-01-01T00:00:00Z")
          shorter (Duration/between epoch (Instant/parse "1970-01-01T00:00:00.999999999Z"))
          longer (Duration/between epoch (Instant/parse "1970-01-01T00:00:01Z"))]
      [(compare shorter longer)
       (sort [longer shorter])
       (min-by identity longer shorter)
       (max-by identity shorter longer)])
    """

    assert {:ok, %{return: [-1, ["PT0.999999999S", "PT1S"], "PT0.999999999S", "PT1S"]}} =
             Lisp.run(source)

    assert {:error, %{fail: %{reason: :type_error}}} =
             Lisp.run(~S|(let [epoch (Instant/parse "1970-01-01T00:00:00Z")]
                     (< (Duration/between epoch (Instant/parse "1970-01-01T00:00:01Z"))
                        (Duration/between epoch (Instant/parse "1970-01-01T00:00:02Z"))))|)
  end

  test "natural sorting preserves Java primitive infinity ordering" do
    assert {:ok, %{return: [:negative_infinity, 0, :infinity]}} =
             Lisp.run(~S|(sort [Double/NEGATIVE_INFINITY 0 Double/POSITIVE_INFINITY])|)
  end

  test "key-based ordering preserves Java primitive infinity ordering" do
    source = ~S"""
    [(sort-by identity [Double/POSITIVE_INFINITY 0 Double/NEGATIVE_INFINITY])
     (min-by identity Double/NEGATIVE_INFINITY 0)
     (max-by identity Double/POSITIVE_INFINITY 0)]
    """

    assert {:ok, %{return: [[:negative_infinity, 0, :infinity], :negative_infinity, :infinity]}} =
             Lisp.run(source)
  end

  test "sort-by applies Java temporal ordering to generic seqables" do
    {:ok, shorter} = Duration.new(0, 999_999_999)
    {:ok, longer} = Duration.new(1, 0)
    values = Stream.map([%{duration: longer}, %{duration: shorter}], & &1)

    assert Collection.sort_by(:duration, values) == [
             %{duration: shorter},
             %{duration: longer}
           ]
  end

  test "explicit ascending and descending aliases retain Java temporal ordering" do
    {:ok, shorter} = Duration.new(0, 999_999_999)
    {:ok, longer} = Duration.new(1, 0)

    assert Collection.sort(:asc, [longer, shorter]) == [shorter, longer]
    assert Collection.sort(:desc, [shorter, longer]) == [longer, shorter]

    values = [%{duration: longer}, %{duration: shorter}]

    assert Collection.sort_by(:duration, :asc, values) == [
             %{duration: shorter},
             %{duration: longer}
           ]

    assert Collection.sort_by(:duration, :desc, Enum.reverse(values)) == [
             %{duration: longer},
             %{duration: shorter}
           ]
  end

  test "type reports validated native temporal wrappers as Java objects" do
    assert {:ok, %{return: [:java_object, :java_object, :java_object, :java_object]}} =
             Lisp.run_native(~S|[(type (LocalDate/parse "2024-01-02"))
                   (type (Instant/parse "2024-01-02T00:00:00Z"))
                   (type (Duration/between
                     (Instant/parse "2024-01-02T00:00:00Z")
                     (Instant/parse "2024-01-02T00:00:01Z")))
                   (type (java.util.Date. 0))]|)
  end

  test "cross-class temporal sorting is rejected" do
    {:ok, local_date} = LocalDate.parse(["2024-01-02"])
    {:ok, instant} = Instant.parse(["2024-01-02T00:00:00Z"])

    assert {:error, %{fail: %{reason: :type_error}}} =
             Lisp.run_native("(sort [instant nil local-date])",
               memory: %{"instant" => instant, "local-date" => local_date}
             )
  end

  test "mixed comparisons reject malformed temporal wrappers" do
    forged = %Instant{epoch_second: 0, nano: -1}

    for source <- [
          "(= data/value 0)",
          "(compare data/value 0)",
          "(compare data/value Double/NaN)",
          "(<= data/value Double/NaN)",
          "(>= Double/NaN data/value)"
        ] do
      assert {:error, %{fail: %{reason: :invalid_java_value}}} =
               Lisp.run(source, context: %{"value" => forged})
    end
  end

  test "Duration.toMillis truncates negative sub-millisecond values toward zero" do
    assert {:ok, %{return: 0}} =
             Lisp.run(
               ~S|(.toMillis (Duration/between (Instant/parse "1970-01-01T00:00:00Z") (Instant/parse "1969-12-31T23:59:59.999999999Z")))|
             )
  end

  test "bounded Date parsing rejects unknown weekday and month tokens" do
    for source <- [
          ~S|(java.util.Date. "Nonsense Jan 01 1970")|,
          ~S|(java.util.Date. "Junk 01 1970")|
        ] do
      assert {:error, %{fail: %{reason: :java_domain_error}}} = Lisp.run(source)
    end
  end

  test "bounded Date parsing accepts an admitted clock without seconds" do
    assert {:ok, %{return: 1_767_882_600_000}} =
             Lisp.run(~S|(.getTime (java.util.Date. "Wed, 8 Jan 2026 14:30 UTC"))|)
  end

  test "bounded Date parsing defaults an omitted zone to UTC in Java field order" do
    assert {:ok, %{return: 1_000}} =
             Lisp.run(~S|(.getTime (java.util.Date. "Thu Jan 01 00:00:01 1970"))|)
  end

  test "bounded Date parsing excludes Java's historical hybrid-calendar range" do
    assert {:error, %{fail: %{reason: :java_domain_error}}} =
             Lisp.run(~S|(java.util.Date. "Jan 1 00:00:00 UTC 1500")|)
  end

  test "Date(long) widens a tagged Java int" do
    assert {:ok, %{return: 1}} =
             Lisp.run(~S|(.getTime (java.util.Date. (Integer/parseInt "1")))|)
  end

  test "temporal domain and null failures stay bounded and class-owned" do
    for source <- [
          ~S|(.plusDays (LocalDate/parse "+999999999-12-31") 1)|,
          ~S|(.toEpochMilli (Instant/parse "+1000000000-12-31T23:59:59.999999999Z"))|,
          ~S|(LocalDate/parse nil)|,
          ~S|(Instant/parse nil)|,
          ~S|(Duration/between nil (Instant/parse "1970-01-01T00:00:00Z"))|,
          ~S|(.isBefore (LocalDate/parse "2024-01-01") nil)|,
          ~S|(.before (java.util.Date. 0) nil)|
        ] do
      assert {:error, %{fail: %{reason: :java_domain_error}}} = Lisp.run(source)
    end

    assert {:error,
            %{
              fail: %{
                reason: :java_domain_error,
                details: %{java_exception: :illegal_argument_exception}
              }
            }} = Lisp.run(~S|(java.util.Date. nil)|)

    assert {:error, %{fail: %{reason: :java_type_error}}} =
             Lisp.run(
               ~S|(Duration/between (LocalDate/parse "2024-01-01") (LocalDate/parse "2024-01-02"))|
             )

    assert {:error, %{fail: %{reason: :unsupported_java_member}}} =
             Lisp.run(~S|(.isBefore (java.util.Date. 0) (java.util.Date. 1))|)

    for source <- [
          ~S|(.toEpochDay nil)|,
          ~S|(.isBefore nil (LocalDate/parse "2024-01-01"))|
        ] do
      assert {:error,
              %{
                fail: %{
                  reason: :java_domain_error,
                  details: %{java_exception: :null_pointer_exception}
                }
              }} =
               Lisp.run(source)
    end

    assert {:error,
            %{
              fail: %{
                reason: :java_domain_error,
                details: %{java_exception: :arithmetic_exception}
              }
            }} =
             Lisp.run(
               ~S|(.plusDays (LocalDate/parse "1970-01-02") (Long/parseLong "9223372036854775807"))|
             )

    assert {:error,
            %{
              fail: %{
                reason: :java_domain_error,
                details: %{java_exception: :arithmetic_exception}
              }
            }} =
             Lisp.run(
               ~S|(.minusDays (LocalDate/parse "1970-01-02") (Long/parseLong "-9223372036854775808"))|
             )

    assert {:error,
            %{
              fail: %{
                reason: :java_domain_error,
                details: %{java_exception: :date_time_exception}
              }
            }} =
             Lisp.run(
               ~S|(.minusDays (LocalDate/parse "1970-01-01") (Long/parseLong "-9223372036854775808"))|
             )
  end

  test "native temporal wrappers do not enter generic map or collection dispatch" do
    sources = [
      ~S|(LocalDate/parse "2024-01-02")|,
      ~S|(Instant/parse "2024-01-02T03:04:05Z")|,
      ~S|(Duration/between (Instant/parse "1970-01-01T00:00:00Z") (Instant/parse "1970-01-01T00:00:01Z"))|,
      ~S|(java.util.Date. 0)|
    ]

    for source <- sources,
        operation <- [
          fn value -> "(empty #{value})" end,
          fn value -> "(entries #{value})" end,
          fn value -> "(assoc-in #{value} [:x] 1)" end,
          fn value -> "((identity #{value}) :epoch_day)" end
        ] do
      assert {:error, %{fail: %{reason: reason}}} = Lisp.run_native(operation.(source))
      assert reason in [:type_error, :not_callable]
    end
  end

  test "keyword mapping treats native temporal wrappers as scalar values" do
    assert {:ok, %{return: [nil]}} =
             Lisp.run(~S|(map :x [(LocalDate/parse "2024-01-02")])|)
  end

  test "collection key shortcuts consistently treat temporal wrappers as scalar values" do
    {:ok, local_date} = LocalDate.parse(["2024-01-02"])

    assert Collection.sort_by(:x, [local_date]) == [local_date]
    assert Collection.sum_by(:x, [local_date]) == 0
    assert Collection.avg_by(:x, [local_date]) == nil
    assert Collection.min_by(:x, [local_date]) == nil
    assert Collection.max_by(:x, [local_date]) == nil
    assert Collection.distinct_by(:x, [local_date, local_date]) == [local_date]
    assert Collection.group_by(:x, [local_date]) == %{nil => [local_date]}
    assert Collection.tree_seq(:x, :x, local_date) == [local_date]
    assert Collection.mapcat(:x, [local_date]) == []
  end

  test "max-by and min-by treat native temporal wrappers as scalar values" do
    for function <- ["max-by", "min-by"] do
      assert {:ok, %{return: "2024-01-02T03:04:05Z"}} =
               Lisp.run("(#{function} identity (Instant/parse \"2024-01-02T03:04:05Z\"))")
    end
  end

  test "describe treats native temporal wrappers as scalar Java values" do
    assert {:ok, instant} = Instant.parse(["2024-01-02T03:04:05Z"])

    assert %{type: "java.time.Instant", sample: sample} = Describe.describe(instant)
    assert sample == "#java[java.time.Instant 2024-01-02T03:04:05Z]"

    assert %{item_types: %{"java.time.Instant" => 1}} = Describe.describe([instant])
  end

  test "formatting, predicates, type vocabulary, and retained size handle wrappers" do
    {:ok, local_date} = LocalDate.parse(["2024-01-02"])
    {:ok, instant} = Instant.parse(["2024-01-02T03:04:05.123456789Z"])
    {:ok, duration} = Duration.new(-2, 500_000_000)
    {:ok, date} = JavaDate.new(1)

    values = [local_date, instant, duration, date]

    assert Enum.map(values, &RetainedSize.bytes/1) |> Enum.all?(&is_integer/1)
    assert Helpers.describe_type(local_date) == "java.time.LocalDate"
    assert Helpers.describe_type(instant) == "java.time.Instant"
    assert TypeVocabulary.type_of(duration) == "java.time.Duration"
    assert TypeVocabulary.type_of(date) == "java.util.Date"

    assert {:ok, %{return: [true, true, true, true]}} =
             Lisp.run_native("[(some? a) (some? b) (some? c) (some? d)]",
               memory: %{"a" => local_date, "b" => instant, "c" => duration, "d" => date}
             )

    rendered = Format.to_string(values)
    assert rendered =~ "#java[java.time.LocalDate 2024-01-02]"
    assert rendered =~ "#java[java.time.Instant 2024-01-02T03:04:05.123456789Z]"
    assert rendered =~ "#java[java.time.Duration PT-1.5S]"
    assert rendered =~ "#java[java.util.Date 1970-01-01T00:00:00.001Z]"

    forged = %Instant{epoch_second: 0, nano: -1}
    assert Format.to_string(forged) == ~S("#<invalid-java-value>")
  end
end
