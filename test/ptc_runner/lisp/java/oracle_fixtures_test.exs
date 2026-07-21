defmodule PtcRunner.Lisp.Java.OracleFixturesTest do
  use ExUnit.Case, async: true

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

  test "PTC-only cases are executable behavior checks" do
    assert {:ok, result} = Runner.run(:ptc, :ptc_only)

    assert MapSet.new(result.outcomes, & &1.case_id) ==
             MapSet.new(Fixtures.cases() |> Enum.filter(&(&1.oracle == :ptc_only)), & &1.case_id)

    assert Enum.all?(result.outcomes, &(&1.status == "ok"))
  end

  test "closed dispatch cases attest the selected PTC overload" do
    assert {:ok, %{outcomes: [outcome]}} = Runner.run(:ptc, :closed_dispatch)
    assert outcome.overload_id == "boolean_parse_boolean_string"
    assert outcome.selected_overload_id == outcome.overload_id
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
    assert result.locale == Config.environment().locale
    assert result.timezone == Config.environment().timezone
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

    assert setup_java_pins(test_workflow) ==
             List.duplicate(
               {versions.java.distribution, versions.java.setup_java},
               2
             )

    assert setup_java_pins(release_workflow) ==
             [{versions.java.distribution, versions.java.setup_java}]

    assert setup =~ "babashka-${{ runner.os }}-#{versions.babashka}-sha256-v1"
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
