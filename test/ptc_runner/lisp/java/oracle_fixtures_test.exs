defmodule PtcRunner.Lisp.Java.OracleFixturesTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp.Java.Oracle.Config
  alias PtcRunner.Lisp.Java.Oracle.Fixtures
  alias PtcRunner.Lisp.Java.Oracle.Runner
  alias PtcRunner.Lisp.Java.Oracle.Subprocess
  alias PtcRunner.Lisp.Java.Surface

  test "the fixture source has typed coverage for every admitted overload" do
    cases = Fixtures.cases()
    overloads = Surface.overloads()

    assert Enum.map(cases, & &1.case_id) == Enum.uniq(Enum.map(cases, & &1.case_id))

    assert MapSet.new(cases, & &1.overload_id) ==
             MapSet.new(overloads, & &1.overload_id)

    overloads_by_id = Map.new(overloads, &{&1.overload_id, &1})

    for fixture <- cases do
      overload = Map.fetch!(overloads_by_id, fixture.overload_id)

      assert fixture.divergence_ids == overload.divergence_ids

      assert fixture.oracle ==
               if(overload.attestation == :jvm, do: :jvm, else: :ptc_only)

      assert %{status: status, type: type} = fixture.expected
      assert status in [:ok, :error]
      assert is_atom(type)
    end

    assert length(cases) > length(overloads)
    assert Enum.any?(cases, &(&1.expected.status == :error))
  end

  test "the checked-in JVM baseline covers every JVM-attested overload exactly" do
    baseline = Fixtures.baseline()

    assert baseline.versions == Config.versions()
    assert baseline.environment == Config.environment()
    assert baseline.provenance.clojure_version == Config.versions().clojure
    assert baseline.provenance.java_runtime_version =~ Config.versions().java.runtime
    assert is_binary(baseline.provenance.command)

    jvm_overloads =
      Surface.overloads()
      |> Enum.filter(&(&1.attestation == :jvm))
      |> Map.new(&{Atom.to_string(&1.overload_id), &1.descriptor})

    baseline_overloads = Map.new(baseline.outcomes, &{&1.overload_id, &1.descriptor})

    assert baseline_overloads == jvm_overloads

    assert MapSet.new(baseline.outcomes, & &1.case_id) ==
             MapSet.new(Fixtures.cases() |> Enum.filter(&(&1.oracle == :jvm)), & &1.case_id)
  end

  test "packaged oracle resources resolve independently of the caller working directory" do
    assert Path.type(Fixtures.cases_path()) == :absolute
    assert Path.type(Fixtures.baseline_path()) == :absolute
    assert File.regular?(Fixtures.cases_path())
    assert File.regular?(Fixtures.baseline_path())
  end

  test "Duration/between records and executes its excluded LocalDate boundary" do
    {:ok, overload} = Surface.fetch_overload(:duration_between_temporal)
    fixture = Enum.find(Fixtures.cases(), &(&1.case_id == "duration-between-local-date-boundary"))

    assert overload.divergence_ids == ["DIV-52"]
    assert fixture.divergence_ids == ["DIV-52"]

    assert fixture.invocation.arguments == [
             %{status: :ok, type: :local_date, value: "2024-01-01"},
             %{status: :ok, type: :local_date, value: "2024-01-02"}
           ]

    assert fixture.expected == %{
             status: :error,
             type: :error,
             value: "java.time.temporal.UnsupportedTemporalTypeException"
           }

    assert fixture.ptc_expected == %{
             status: :error,
             type: :error,
             value: "java_type_error"
           }
  end

  test "closed dispatch cases attest the selected PTC overload" do
    assert {:ok, %{outcomes: outcomes}} = Runner.run(:ptc, :closed_dispatch)

    assert MapSet.new(outcomes, & &1.case_id) ==
             MapSet.new(~w(
                 boolean-parse-boolean-string
                 double-parse-double-string
                 double-parse-double-string-direct-rounding
                 double-parse-double-string-max-finite
                 double-parse-double-string-overflow-tie
                 double-parse-double-string-underflow-tie
                 double-parse-double-string-subnormal
                 double-parse-double-string-signed-zero-whitespace-suffix
                 double-parse-double-string-zero-padded-decimal-exponent
                 double-parse-double-string-zero-padded-hex-negative-exponent
                 double-parse-double-string-large-exponent-cancellation
                 double-parse-double-string-negative-infinity
                 double-parse-double-string-signed-nan
                 double-parse-double-string-invalid
                 double-parse-double-string-null
                 double-positive-infinity-field
                 double-negative-infinity-field
                 double-nan-field
                 float-parse-float-string
                 float-parse-float-string-direct-rounding
                 float-parse-float-string-max-finite
                 float-parse-float-string-overflow-tie
                 float-parse-float-string-underflow-tie
                 float-parse-float-string-subnormal
                 float-parse-float-string-signed-zero-whitespace-suffix
                 float-parse-float-string-zero-padded-decimal-exponent
                 float-parse-float-string-zero-padded-hex-negative-exponent
                 float-parse-float-string-positive-infinity
                 float-parse-float-string-signed-nan
                 float-parse-float-string-invalid
                 float-parse-float-string-null
                 integer-parse-int-string
                 integer-parse-int-string-min-value
                 integer-parse-int-string-overflow
                 integer-parse-int-string-null
                 integer-parse-int-string-unicode-digits
                 long-parse-long-string
                 long-parse-long-string-min-value
                 long-parse-long-string-underflow
                 long-parse-long-string-null
                 long-parse-long-string-unicode-digits
                 math-abs-int
                 math-abs-int-min-value
                 math-abs-long
                 math-abs-long-min-value
                 math-abs-float
                 math-abs-float-negative-zero
                 math-abs-double
                 math-abs-double-nan
                 math-ceil-double
                 math-ceil-double-negative-zero
                 math-floor-double
                 math-floor-double-positive-zero
                 math-max-int
                 math-max-int-boundaries
                 math-max-long
                 math-max-float
                 math-max-float-signed-zero
                 math-max-double
                 math-max-double-nan
                 math-min-int
                 math-min-long
                 math-min-float
                 math-min-float-signed-zero
                 math-min-double
                 math-min-double-nan
                 math-pow-double
                 math-pow-double-negative-fractional
                 math-round-float
                 math-round-float-nan
                 math-round-float-positive-infinity
                 math-round-double
                 math-round-double-exact-integer-above-two-to-the-52
                 math-round-double-negative-infinity
                 math-sqrt-double
                 math-sqrt-double-negative
                 math-sqrt-double-negative-zero
                 system-current-time-millis-0
                 string-contains-char-sequence
                 string-index-of-string
                 string-index-of-string-from
                 string-last-index-of-string
                 string-starts-with-string
                 string-ends-with-string
                 string-length-0
                 string-substring-begin
                 string-substring-begin-end
                 string-trim-0
                 string-trim-preserves-unicode-whitespace
                 local-date-parse-char-sequence
                 local-date-parse-positive-zero-extended-year
                 local-date-parse-invalid
                 local-date-to-epoch-day-0
                 local-date-plus-days-long
                 local-date-minus-days-long
                 local-date-minus-days-long-min-at-epoch
                 local-date-is-before-chrono-local-date
                 local-date-is-after-chrono-local-date
                 instant-parse-char-sequence
                 instant-parse-positive-zero-extended-year
                 instant-parse-empty-fraction
                 instant-parse-hour-offset
                 instant-parse-compact-minute-offset
                 instant-parse-compact-second-offset
                 instant-parse-invalid
                 instant-is-before-instant
                 instant-is-after-instant
                 instant-to-epoch-milli-0
                 duration-between-temporal
                 duration-between-local-date-boundary
                 duration-to-millis-0
                 duration-to-millis-negative-submillisecond
                 duration-to-millis-overflow
                 duration-to-days-0
                 date-new-0
                 date-new-long
                         date-new-string
                         date-new-string-null
                         date-new-string-without-seconds
                         date-new-string-without-zone
                 date-new-string-invalid-weekday
                 date-new-string-invalid-month
                 date-get-time-0
                 date-before-date
                 date-after-date
               ))

    {boundary_probes, admitted_cases} =
      Enum.split_with(outcomes, &(&1.case_id == "duration-between-local-date-boundary"))

    assert [%{status: "error", expected: %{value: "java_type_error"}} = boundary] =
             boundary_probes

    refute Map.has_key?(boundary, :selected_overload_id)
    assert Enum.all?(admitted_cases, &(&1.selected_overload_id == &1.overload_id))
  end

  test "dispatch attestation ignores unrelated Java references" do
    handler_id = make_ref()
    state = {self(), handler_id, :boolean_parse_boolean}

    Runner.handle_dispatch_attestation(
      [:ptc_runner, :lisp, :java, :dispatch],
      %{},
      %{reference_id: :double_parse_double, overload_id: :double_parse_double_string},
      state
    )

    refute_receive {:java_dispatch_attestation, ^handler_id, _overload_id}

    Runner.handle_dispatch_attestation(
      [:ptc_runner, :lisp, :java, :dispatch],
      %{},
      %{reference_id: :boolean_parse_boolean, overload_id: :boolean_parse_boolean_string},
      state
    )

    assert_receive {:java_dispatch_attestation, ^handler_id, :boolean_parse_boolean_string}
  end

  @tag :clojure
  test "Babashka reports the locale and timezone it actually observes" do
    assert {:ok, result} = Runner.run(:babashka, :fast)
    assert result.locale in Config.babashka_locales()
    assert result.timezone == Config.environment().timezone
  end

  test "Babashka accepts the language-only English locale from its Linux native image" do
    result = %{
      babashka_version: Config.versions().babashka,
      locale: "en",
      timezone: Config.environment().timezone,
      outcomes: []
    }

    assert :ok = Runner.validate_metadata(result, :babashka)
  end

  test "fixture validation rejects drift from manifest descriptors and divergence IDs" do
    [fixture | fixtures] = Fixtures.cases()

    invalid_fixture = %{fixture | divergence_ids: ["GAP-NOT-REAL"]}

    assert_raise ArgumentError, ~r/divergence IDs/, fn ->
      Fixtures.validate_cases!([invalid_fixture | fixtures], Surface.manifest())
    end

    [outcome | outcomes] = Fixtures.baseline().outcomes
    invalid_outcome = %{outcome | descriptor: "()V"}

    assert_raise ArgumentError, ~r/descriptor/, fn ->
      Fixtures.validate_baseline!(
        %{Fixtures.baseline() | outcomes: [invalid_outcome | outcomes]},
        Fixtures.cases(),
        Surface.manifest()
      )
    end
  end

  test "fixture validation rejects argument and oracle provenance drift" do
    fixtures = Fixtures.cases()
    fixture = Enum.find(fixtures, &(&1.overload_id == :boolean_parse_boolean_string))
    invalid_fixture = put_in(fixture, [:invocation, :arguments], [%{type: :int, value: 1}])

    assert_raise ArgumentError, ~r/argument type/, fn ->
      Fixtures.validate_cases!(
        [invalid_fixture | List.delete(fixtures, fixture)],
        Surface.manifest()
      )
    end

    baseline = Fixtures.baseline()
    invalid_baseline = put_in(baseline, [:provenance, :java_vendor], "Unpinned Java")

    assert_raise ArgumentError, ~r/provenance/, fn ->
      Fixtures.validate_baseline!(invalid_baseline, fixtures, Surface.manifest())
    end
  end

  test "fixture validation bounds compact repeated string expansion" do
    fixtures = Fixtures.cases()
    fixture = Enum.find(fixtures, &(&1.overload_id == :double_parse_double_string))

    oversized =
      put_in(fixture, [:invocation, :arguments], [
        %{
          type: :string,
          value: %{
            "encoding" => "repeat",
            "prefix" => "",
            "repeated" => "",
            "count" => 256_001,
            "suffix" => ""
          }
        }
      ])

    assert_raise ArgumentError, ~r/invalid or oversized repeated string encoding/, fn ->
      Fixtures.validate_cases!(
        [oversized | List.delete(fixtures, fixture)],
        Surface.manifest()
      )
    end
  end

  test "fixture validation rejects malformed compact string encodings" do
    fixtures = Fixtures.cases()
    fixture = Enum.find(fixtures, &(&1.overload_id == :double_parse_double_string))

    for value <- [
          %{"encoding" => "repeat", "prefix" => "", "repeated" => "1", "count" => 1},
          %{
            "encoding" => "unknown",
            "prefix" => "",
            "repeated" => "1",
            "count" => 1,
            "suffix" => ""
          },
          1
        ] do
      invalid = put_in(fixture, [:invocation, :arguments], [%{type: :string, value: value}])

      assert_raise ArgumentError, ~r/invalid string value/, fn ->
        Fixtures.validate_cases!(
          [invalid | List.delete(fixtures, fixture)],
          Surface.manifest()
        )
      end
    end
  end

  test "oracle output carries selected descriptors and typed outcomes" do
    payload = Base.encode64("true")

    output = """
    __PTC_JAVA_META__\t21.0.11\t21.0.11+10-LTS\tEclipse Adoptium\t1.12.5\t\ten_US\tUTC
    __PTC_JAVA_RESULT__\tboolean-parse-boolean-string\tboolean_parse_boolean_string\t(Ljava/lang/String;)Z\tok\tboolean\t#{payload}
    """

    assert {:ok, result} = Runner.parse_output(output)
    assert result.java_version == "21.0.11"
    assert result.java_runtime_version == "21.0.11+10-LTS"
    assert result.java_vendor == "Eclipse Adoptium"
    assert result.clojure_version == "1.12.5"
    assert result.babashka_version == ""

    assert [outcome] = result.outcomes
    assert outcome.descriptor == "(Ljava/lang/String;)Z"
    assert outcome.expected == %{status: :ok, type: :boolean, value: "true"}
  end

  test "oracle pins stay aligned with developer and CI toolchains" do
    versions = Config.versions()
    mise = File.read!("mise.toml")
    test_workflow = File.read!(".github/workflows/test.yml")
    release_workflow = File.read!(".github/workflows/release.yml")
    setup = File.read!(".github/actions/setup-elixir/action.yml")

    assert mise =~ ~s|java = "#{versions.java.mise}"|
    assert test_workflow =~ ~r/^permissions:\n  contents: read$/m

    assert setup_java_pins(test_workflow) ==
             List.duplicate(
               {versions.java.distribution, versions.java.setup_java},
               2
             )

    assert setup_java_pins(release_workflow) ==
             [{versions.java.distribution, versions.java.setup_java}]

    assert setup =~
             "babashka-${{ runner.os }}-${{ runner.arch }}-#{versions.babashka}-sha256-v1"

    assert setup =~
             "${{ runner.os }}-${{ runner.arch }}-mix-${{ inputs.project-directory }}-env"

    assert setup =~ "hashFiles(format('{0}/mix.lock', inputs.project-directory))"
    assert setup =~ "plt-${{ runner.os }}-${{ runner.arch }}-otp"
  end

  test "oracle subprocesses enforce their output bound" do
    elixir = System.find_executable("elixir")

    assert {:error, :output_limit_exceeded} =
             Subprocess.run(elixir, ["-e", "IO.write(String.duplicate(\"x\", 100))"],
               output_limit: 10
             )
  end

  defp setup_java_pins(workflow) do
    ~r/uses: actions\/setup-java@v5\s+with:\s+distribution: ([^\s]+)\s+java-version: "([^"]+)"/
    |> Regex.scan(workflow, capture: :all_but_first)
    |> Enum.map(&List.to_tuple/1)
  end
end
