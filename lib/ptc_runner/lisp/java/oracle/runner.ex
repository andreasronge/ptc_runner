defmodule PtcRunner.Lisp.Java.Oracle.Runner do
  @moduledoc """
  Executes bounded Java behavior cases through pinned JVM Clojure, Babashka,
  or the PTC runtime for explicit compatibility-only operations.

  JVM execution resolves the exact manifest descriptor before invoking a
  member. Babashka is restricted to explicitly marked fast cases and its
  results never count as authoritative descriptor coverage.
  """

  import Bitwise

  alias PtcRunner.Lisp.ClojureValidator
  alias PtcRunner.Lisp.Java.Oracle.ClojureRuntime
  alias PtcRunner.Lisp.Java.Oracle.Config
  alias PtcRunner.Lisp.Java.Oracle.Fixtures
  alias PtcRunner.Lisp.Java.Oracle.Subprocess
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Java.Surface
  alias PtcRunner.Lisp.Java.Time.Duration
  alias PtcRunner.Lisp.Java.Time.Instant
  alias PtcRunner.Lisp.Java.Time.LocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate

  @source_limit 256_000
  @expanded_string_limit 256_000
  @timeout_ms 30_000
  @output_limit 1_000_000
  @result_value_limit 16_384
  @temporary_directory_attempts 10
  @meta_marker "__PTC_JAVA_META__"
  @result_marker "__PTC_JAVA_RESULT__"

  @type oracle :: :jvm | :babashka | :ptc

  @doc "Runs one oracle subset and returns canonical typed outcomes."
  @spec run(oracle(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(oracle, subset, opts \\ [])

  def run(:ptc, :closed_dispatch, opts) do
    cases = ptc_cases(:closed_dispatch)

    with :ok <- ensure_cases(cases, :closed_dispatch),
         {:ok, outcomes} <- run_ptc_cases(cases, opts),
         :ok <- validate_outcomes(outcomes, cases, :ptc) do
      {:ok, %{outcomes: outcomes}}
    end
  end

  def run(:ptc, subset, _opts) when is_atom(subset),
    do: {:error, {:unsupported_subset, :ptc, subset}}

  def run(oracle, subset, opts) when oracle in [:jvm, :babashka] and is_atom(subset) do
    cases =
      Fixtures.cases()
      |> Enum.filter(&(&1.oracle == :jvm and subset in &1.subsets))

    with :ok <- ensure_cases(cases, subset),
         {:ok, command, args_prefix} <- command(oracle, opts),
         {:ok, source} <- source(cases, oracle),
         {:ok, output} <- run_source(command, args_prefix, source, opts),
         {:ok, result} <- parse_output(output),
         :ok <- validate_metadata(result, oracle),
         :ok <- validate_outcomes(result.outcomes, cases, oracle) do
      {:ok, result}
    end
  end

  defp ptc_cases(:closed_dispatch) do
    Fixtures.cases()
  end

  @doc false
  @spec parse_output(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_output(output) when is_binary(output) do
    lines = String.split(output, "\n", trim: true)

    with {:ok, metadata} <- parse_metadata(lines),
         {:ok, outcomes} <- parse_outcomes(lines) do
      {:ok, Map.put(metadata, :outcomes, outcomes)}
    end
  end

  @doc false
  @spec source([map()]) :: {:ok, String.t()} | {:error, :source_limit_exceeded}
  def source(cases) do
    source(cases, :jvm)
  end

  defp source(cases, :jvm) do
    specs = case_specs(cases)
    source = clojure_source(edn(specs))

    if byte_size(source) <= @source_limit,
      do: {:ok, source},
      else: {:error, :source_limit_exceeded}
  end

  defp source(cases, :babashka) do
    source = babashka_source(cases)

    if byte_size(source) <= @source_limit,
      do: {:ok, source},
      else: {:error, :source_limit_exceeded}
  end

  defp ensure_cases([], subset), do: {:error, {:empty_subset, subset}}
  defp ensure_cases(_cases, _subset), do: :ok

  defp command(:jvm, opts) do
    java = Keyword.get(opts, :java, System.find_executable("java"))

    cond do
      is_nil(java) ->
        {:error, :java_not_found}

      not ClojureRuntime.installed?() ->
        {:error, :clojure_not_installed}

      true ->
        args = [
          "-Duser.language=en",
          "-Duser.country=US",
          "-Duser.timezone=UTC",
          "-cp",
          ClojureRuntime.classpath(),
          "clojure.main"
        ]

        {:ok, java, args}
    end
  end

  defp command(:babashka, opts) do
    case Keyword.get(opts, :babashka, ClojureValidator.bb_path()) do
      nil -> {:error, :babashka_not_found}
      path -> {:ok, path, []}
    end
  end

  defp run_source(command, args_prefix, source, opts) do
    dir = temporary_directory()
    source_path = Path.join(dir, "oracle.clj")
    File.write!(source_path, source)

    try do
      Subprocess.run(command, args_prefix ++ [source_path],
        timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms),
        output_limit: Keyword.get(opts, :output_limit, @output_limit),
        env: [
          {"LANG", Config.environment().locale <> ".UTF-8"},
          {"LC_ALL", Config.environment().locale <> ".UTF-8"},
          {"TZ", Config.environment().timezone}
        ]
      )
    after
      File.rm_rf(dir)
    end
  end

  defp parse_metadata(lines) do
    case Enum.filter(lines, &String.starts_with?(&1, @meta_marker <> "\t")) do
      [line] ->
        case String.split(line, "\t") do
          [@meta_marker, java, java_runtime, java_vendor, clojure, babashka, locale, timezone] ->
            {:ok,
             %{
               java_version: java,
               java_runtime_version: java_runtime,
               java_vendor: java_vendor,
               clojure_version: clojure,
               babashka_version: babashka,
               locale: locale,
               timezone: timezone
             }}

          _fields ->
            {:error, :invalid_metadata}
        end

      _lines ->
        {:error, :invalid_metadata}
    end
  end

  defp parse_outcomes(lines) do
    lines
    |> Enum.filter(&String.starts_with?(&1, @result_marker <> "\t"))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, outcomes} ->
      case parse_outcome(line) do
        {:ok, outcome} -> {:cont, {:ok, [outcome | outcomes]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, outcomes} -> {:ok, Enum.reverse(outcomes)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_outcome(line) do
    with [@result_marker, case_id, overload_id, descriptor, status, type, encoded] <-
           String.split(line, "\t"),
         {:ok, value} <- Base.decode64(encoded),
         true <- byte_size(value) <= @result_value_limit,
         {:ok, type_atom} <- outcome_type(type),
         {:ok, status_atom} <- outcome_status(status) do
      {:ok,
       %{
         case_id: case_id,
         overload_id: overload_id,
         descriptor: descriptor,
         status: status,
         expected: %{status: status_atom, type: type_atom, value: value}
       }}
    else
      _invalid -> {:error, {:invalid_outcome, line}}
    end
  end

  defp outcome_type(type)
       when type in ~w(boolean int long float double string local_date instant duration date error) do
    {:ok, String.to_existing_atom(type)}
  end

  defp outcome_type(_type), do: {:error, :unknown_outcome_type}

  defp outcome_status("ok"), do: {:ok, :ok}
  defp outcome_status("error"), do: {:ok, :error}
  defp outcome_status(_status), do: {:error, :unknown_outcome_status}

  @doc false
  @spec validate_metadata(map(), :jvm | :babashka) :: :ok | {:error, term()}
  def validate_metadata(result, :jvm) do
    versions = Config.versions()
    environment = Config.environment()
    java_version = versions.java.runtime |> String.split("+") |> hd()

    if result.java_version == java_version and
         result.java_runtime_version == versions.java.runtime <> "-LTS" and
         result.java_vendor == versions.java.vendor and
         result.clojure_version == versions.clojure and
         result.babashka_version == "" and
         result.locale == environment.locale and result.timezone == environment.timezone do
      :ok
    else
      {:error, {:oracle_version_mismatch, Map.drop(result, [:outcomes])}}
    end
  end

  def validate_metadata(result, :babashka) do
    environment = Config.environment()

    if result.babashka_version == Config.versions().babashka and
         result.locale in Config.babashka_locales() and
         result.timezone == environment.timezone,
       do: :ok,
       else: {:error, {:oracle_environment_mismatch, Map.drop(result, [:outcomes])}}
  end

  defp validate_outcomes(outcomes, cases, oracle) do
    expected = expected_outcomes(cases, oracle)

    comparable =
      if oracle in [:jvm, :ptc],
        do: outcomes,
        else: Enum.map(outcomes, &Map.delete(&1, :descriptor))

    expected =
      if oracle in [:jvm, :ptc],
        do: expected,
        else: Enum.map(expected, &Map.delete(&1, :descriptor))

    if comparable == expected,
      do: :ok,
      else: {:error, {:outcome_mismatch, expected, comparable}}
  end

  defp expected_outcomes(cases, oracle) do
    overloads = Map.new(Surface.overloads(), &{&1.overload_id, &1})

    Enum.map(cases, fn fixture ->
      overload = Map.fetch!(overloads, fixture.overload_id)
      expected = expected_for_oracle(fixture, oracle)

      outcome = %{
        case_id: fixture.case_id,
        overload_id: Atom.to_string(fixture.overload_id),
        descriptor: overload.descriptor,
        status: Atom.to_string(expected.status),
        expected: expected
      }

      if oracle == :ptc and not Map.get(fixture, :boundary_probe, false),
        do: Map.put(outcome, :selected_overload_id, Atom.to_string(fixture.overload_id)),
        else: outcome
    end)
  end

  defp expected_for_oracle(%{ptc_expected: expected}, :ptc), do: expected
  defp expected_for_oracle(fixture, _oracle), do: fixture.expected

  defp run_ptc_cases(cases, opts) do
    cases
    |> Enum.reduce_while({:ok, []}, fn fixture, {:ok, outcomes} ->
      case run_ptc_case(fixture, opts) do
        {:ok, outcome} -> {:cont, {:ok, [outcome | outcomes]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, outcomes} -> {:ok, Enum.reverse(outcomes)}
      {:error, _reason} = error -> error
    end
  end

  defp run_ptc_case(fixture, opts) do
    overloads = Map.new(Surface.overloads(), &{&1.overload_id, &1})
    references = Map.new(Surface.references(), &{&1.reference_id, &1})
    overload = Map.fetch!(overloads, fixture.overload_id)
    reference = Map.fetch!(references, overload.reference_id)
    {source, context} = ptc_invocation(fixture, reference)

    {result, selected_overload_id} =
      run_with_dispatch_attestation(source, context, opts, reference.reference_id)

    outcome = ptc_outcome(result, fixture, overload)

    outcome =
      if is_atom(selected_overload_id) and not is_nil(selected_overload_id),
        do: Map.put(outcome, :selected_overload_id, Atom.to_string(selected_overload_id)),
        else: outcome

    {:ok, outcome}
  rescue
    error -> {:error, {:ptc_case_failed, fixture.case_id, Exception.message(error)}}
  end

  defp run_with_dispatch_attestation(source, context, opts, reference_id) do
    owner = self()
    handler_id = {__MODULE__, owner, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:ptc_runner, :lisp, :java, :dispatch],
        &__MODULE__.handle_dispatch_attestation/4,
        {owner, handler_id, reference_id}
      )

    try do
      result =
        PtcRunner.Lisp.run_native(source,
          context: context,
          filter_context: false,
          timeout: Keyword.get(opts, :timeout_ms, @timeout_ms)
        )

      selected =
        receive do
          {:java_dispatch_attestation, ^handler_id, overload_id} -> overload_id
        after
          0 -> nil
        end

      {result, selected}
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc false
  def handle_dispatch_attestation(
        _event,
        _measurements,
        %{reference_id: reference_id, overload_id: overload_id},
        {owner, handler_id, reference_id}
      ) do
    send(owner, {:java_dispatch_attestation, handler_id, overload_id})
  end

  def handle_dispatch_attestation(_event, _measurements, _metadata, _state), do: :ok

  defp ptc_invocation(fixture, reference) do
    receiver = fixture.invocation.receiver
    arguments = fixture.invocation.arguments

    context =
      arguments
      |> Enum.with_index()
      |> Map.new(fn {argument, index} -> {"arg#{index}", decode_ptc_value(argument)} end)
      |> maybe_put_receiver(receiver)

    argument_sources =
      arguments
      |> Enum.with_index()
      |> Enum.map(fn {_argument, index} -> "data/arg#{index}" end)

    spelling = hd(reference.spellings)

    source =
      case reference.kind do
        :instance -> ptc_call(spelling, ["data/receiver" | argument_sources])
        kind when kind in [:static, :constructor] -> ptc_call(spelling, argument_sources)
        :field -> spelling
      end

    {source, context}
  end

  defp ptc_call(spelling, arguments), do: "(" <> Enum.join([spelling | arguments], " ") <> ")"

  defp maybe_put_receiver(context, nil), do: context

  defp maybe_put_receiver(context, receiver) do
    Map.put(context, "receiver", decode_ptc_value(receiver))
  end

  defp decode_ptc_value(%{
         type: :string,
         value: %{
           "encoding" => "repeat",
           "prefix" => prefix,
           "repeated" => repeated,
           "count" => count,
           "suffix" => suffix
         }
       })
       when is_binary(prefix) and is_binary(repeated) and is_integer(count) and count >= 0 and
              is_binary(suffix) do
    expanded_bytes = byte_size(prefix) + byte_size(repeated) * count + byte_size(suffix)

    if count <= @expanded_string_limit and expanded_bytes <= @expanded_string_limit,
      do: prefix <> String.duplicate(repeated, count) <> suffix,
      else: raise(ArgumentError, "oversized repeated Java oracle string")
  end

  defp decode_ptc_value(%{type: :string, value: value}), do: value

  defp decode_ptc_value(%{type: type, value: value})
       when type in [:int, :long, :float, :double] do
    {:ok, primitive} = Primitive.new(type, decode_primitive_value(value))
    primitive
  end

  defp decode_ptc_value(%{type: :local_date, value: value}) do
    {:ok, local_date} = LocalDate.parse([value])
    local_date
  end

  defp decode_ptc_value(%{type: :instant, value: value}) do
    {:ok, instant} = Instant.parse([value])
    instant
  end

  defp decode_ptc_value(%{type: :duration, value: value}) do
    {:ok, duration} = Duration.from_iso8601(value)
    duration
  end

  defp decode_ptc_value(%{type: :date, value: value}) do
    {:ok, date} = JavaDate.new(value)
    date
  end

  defp decode_primitive_value("NaN"), do: :nan
  defp decode_primitive_value("Infinity"), do: :infinity
  defp decode_primitive_value("-Infinity"), do: :negative_infinity
  defp decode_primitive_value(value), do: value

  defp ptc_outcome({:ok, step}, fixture, overload) do
    %{
      case_id: fixture.case_id,
      overload_id: Atom.to_string(fixture.overload_id),
      descriptor: overload.descriptor,
      status: "ok",
      expected: %{
        status: :ok,
        type: fixture.expected.type,
        value:
          canonical_ptc_value(
            Map.get(fixture, :normalizer, :exact),
            fixture.expected.type,
            step.return
          )
      }
    }
  end

  defp ptc_outcome({:error, step}, fixture, overload) do
    %{
      case_id: fixture.case_id,
      overload_id: Atom.to_string(fixture.overload_id),
      descriptor: overload.descriptor,
      status: "error",
      expected: %{
        status: :error,
        type: :error,
        value: canonical_ptc_error(step.fail)
      }
    }
  end

  defp canonical_ptc_value(:non_negative, :long, %Primitive{kind: :long, value: value})
       when is_integer(value) and value >= 0,
       do: "<non-negative>"

  defp canonical_ptc_value(:type_only, _type, _value), do: "<dynamic>"

  defp canonical_ptc_value(:exact, :boolean, value) when is_boolean(value), do: to_string(value)
  defp canonical_ptc_value(:exact, :string, value) when is_binary(value), do: value

  defp canonical_ptc_value(:exact, type, %Primitive{kind: type, value: value})
       when type in [:int, :long],
       do: Integer.to_string(value)

  defp canonical_ptc_value(:exact, type, %Primitive{kind: type, value: value})
       when type in [:float, :double],
       do: canonical_float(type, value)

  defp canonical_ptc_value(:exact, type, value)
       when type in [:int, :long] and is_integer(value),
       do: Integer.to_string(value)

  defp canonical_ptc_value(:exact, :local_date, %LocalDate{} = value),
    do: LocalDate.canonical(value)

  defp canonical_ptc_value(:exact, :instant, %Instant{} = value),
    do: Instant.canonical(value)

  defp canonical_ptc_value(:exact, :duration, %Duration{} = value),
    do: Duration.canonical(value)

  defp canonical_ptc_value(:exact, :date, %JavaDate{epoch_millis: epoch_millis} = value) do
    if JavaDate.valid?(value), do: Integer.to_string(epoch_millis), else: "<invalid>"
  end

  defp canonical_ptc_error(%{details: %{java_exception: :number_format_exception}}),
    do: "java.lang.NumberFormatException"

  defp canonical_ptc_error(%{details: %{java_exception: :null_pointer_exception}}),
    do: "java.lang.NullPointerException"

  defp canonical_ptc_error(%{details: %{java_exception: :date_time_exception}}),
    do: "java.time.DateTimeException"

  defp canonical_ptc_error(%{details: %{java_exception: :date_time_parse_exception}}),
    do: "java.time.format.DateTimeParseException"

  defp canonical_ptc_error(%{details: %{java_exception: :arithmetic_exception}}),
    do: "java.lang.ArithmeticException"

  defp canonical_ptc_error(%{details: %{java_exception: :illegal_argument_exception}}),
    do: "java.lang.IllegalArgumentException"

  defp canonical_ptc_error(%{reason: reason}), do: Atom.to_string(reason)

  defp canonical_float(_kind, :infinity), do: "Infinity"
  defp canonical_float(_kind, :negative_infinity), do: "-Infinity"
  defp canonical_float(_kind, :nan), do: "NaN"

  defp canonical_float(:double, value) do
    <<bits::unsigned-64>> = <<value::float-64>>
    sign = if bits >>> 63 == 1, do: "-", else: ""
    exponent = bits >>> 52 &&& 0x7FF
    fraction = bits &&& 0xFFFFFFFFFFFFF
    canonical_finite_float(sign, exponent, fraction, 1023, 52)
  end

  defp canonical_float(:float, value) do
    <<bits::unsigned-32>> = <<value::float-32>>
    sign = if bits >>> 31 == 1, do: "-", else: ""
    exponent = bits >>> 23 &&& 0xFF
    fraction = (bits &&& 0x7FFFFF) <<< 1
    canonical_finite_float(sign, exponent, fraction, 127, 24)
  end

  defp canonical_finite_float(sign, 0, 0, _bias, _fraction_bits), do: sign <> "0x0.0p0"

  defp canonical_finite_float(sign, 0, fraction, bias, fraction_bits) do
    sign <> "0x0." <> hexadecimal_fraction(fraction, fraction_bits) <> "p" <> to_string(1 - bias)
  end

  defp canonical_finite_float(sign, exponent, fraction, bias, fraction_bits) do
    sign <>
      "0x1." <>
      hexadecimal_fraction(fraction, fraction_bits) <>
      "p" <>
      to_string(exponent - bias)
  end

  defp hexadecimal_fraction(fraction, fraction_bits) do
    width = div(fraction_bits + 3, 4)

    fraction
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
    |> String.trim_trailing("0")
    |> case do
      "" -> "0"
      digits -> digits
    end
  end

  defp case_specs(cases) do
    overloads = Map.new(Surface.overloads(), &{&1.overload_id, &1})
    references = Map.new(Surface.references(), &{&1.reference_id, &1})
    classes = Map.new(Surface.classes(), &{&1.class_id, &1})

    Enum.map(cases, fn fixture ->
      overload = Map.fetch!(overloads, fixture.overload_id)
      reference = Map.fetch!(references, overload.reference_id)
      class = Map.fetch!(classes, reference.class_id)

      %{
        "case_id" => fixture.case_id,
        "overload_id" => Atom.to_string(fixture.overload_id),
        "class" => class.name,
        "kind" => Atom.to_string(reference.kind),
        "member" => reference.member,
        "descriptor" => overload.descriptor,
        "receiver" => encode_value(fixture.invocation.receiver),
        "arguments" => Enum.map(fixture.invocation.arguments, &encode_value/1),
        "return" => Atom.to_string(overload.return),
        "normalizer" => Atom.to_string(Map.get(fixture, :normalizer, :exact))
      }
    end)
  end

  defp encode_value(nil), do: nil

  defp encode_value(%{type: type, value: value}) do
    %{"type" => Atom.to_string(type), "value" => value}
  end

  defp temporary_directory do
    create_temporary_directory(@temporary_directory_attempts)
  end

  defp create_temporary_directory(0) do
    raise File.Error,
      reason: :eexist,
      action: "create exclusive Java oracle temporary directory",
      path: System.tmp_dir!()
  end

  defp create_temporary_directory(attempts_left) do
    suffix = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    dir = Path.join(System.tmp_dir!(), "ptc_java_oracle_#{suffix}")

    case File.mkdir(dir) do
      :ok -> dir
      {:error, :eexist} -> create_temporary_directory(attempts_left - 1)
      {:error, reason} -> raise File.Error, reason: reason, action: "create directory", path: dir
    end
  end

  defp edn(nil), do: "nil"
  defp edn(true), do: "true"
  defp edn(false), do: "false"
  defp edn(value) when is_integer(value), do: Integer.to_string(value)

  defp edn(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 16])

  defp edn(value) when is_binary(value), do: edn_string(value)
  defp edn(values) when is_list(values), do: "[" <> Enum.map_join(values, " ", &edn/1) <> "]"

  defp edn(map) when is_map(map) do
    entries =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(" ", fn {key, value} -> edn(key) <> " " <> edn(value) end)

    "{" <> entries <> "}"
  end

  defp edn_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end

  defp clojure_source(cases_edn) do
    """
    (import '[java.lang.reflect Constructor Field InvocationTargetException Method Modifier]
            '[java.nio.charset StandardCharsets]
            '[java.util Base64 Locale TimeZone])

    (Locale/setDefault Locale/US)
    (TimeZone/setDefault (TimeZone/getTimeZone "UTC"))

    (def cases #{cases_edn})
    (def encoder (Base64/getEncoder))

    (defn b64 [value]
      (.encodeToString encoder (.getBytes (str value) StandardCharsets/UTF_8)))

    (defn type-descriptor [^Class type]
      (cond
        (.isArray type) (.replace (.getName type) "." "/")
        (not (.isPrimitive type)) (str "L" (.replace (.getName type) "." "/") ";")
        (= type Void/TYPE) "V"
        (= type Boolean/TYPE) "Z"
        (= type Byte/TYPE) "B"
        (= type Character/TYPE) "C"
        (= type Double/TYPE) "D"
        (= type Float/TYPE) "F"
        (= type Integer/TYPE) "I"
        (= type Long/TYPE) "J"
        (= type Short/TYPE) "S"
        :else (throw (IllegalArgumentException. (str "unknown primitive " type)))))

    (defn parameter-descriptor [types]
      (str "(" (apply str (map type-descriptor types)) ")"))

    (defn method-descriptor [^Method method]
      (str (parameter-descriptor (.getParameterTypes method))
           (type-descriptor (.getReturnType method))))

    (defn constructor-descriptor [^Constructor constructor]
      (str (parameter-descriptor (.getParameterTypes constructor)) "V"))

    (defn exact-method [^Class klass member descriptor static?]
      (or (some (fn [^Method method]
                  (when (and (= member (.getName method))
                             (= static? (Modifier/isStatic (.getModifiers method)))
                             (= descriptor (method-descriptor method)))
                    method))
                (.getMethods klass))
          (throw (NoSuchMethodException. (str (.getName klass) "." member descriptor)))))

    (defn exact-constructor [^Class klass descriptor]
      (or (some (fn [^Constructor constructor]
                  (when (= descriptor (constructor-descriptor constructor)) constructor))
                (.getConstructors klass))
          (throw (NoSuchMethodException. (str (.getName klass) descriptor)))))

    (defn exact-field [^Class klass member descriptor]
      (let [^Field field (.getField klass member)]
        (when-not (and (Modifier/isStatic (.getModifiers field))
                       (= descriptor (type-descriptor (.getType field))))
          (throw (NoSuchFieldException. (str (.getName klass) "." member " " descriptor))))
        field))

    (def repeat-encoding-keys
      \#{"encoding" "prefix" "repeated" "count" "suffix"})

    (defn utf8-size [^String value]
      (alength (.getBytes value "UTF-8")))

    (defn valid-repeat-encoding? [raw]
      (let [prefix (get raw "prefix")
            repeated (get raw "repeated")
            repetitions (get raw "count")
            suffix (get raw "suffix")]
        (and (= repeat-encoding-keys (set (keys raw)))
             (= "repeat" (get raw "encoding"))
             (string? prefix)
             (string? repeated)
             (integer? repetitions)
             (<= 0 repetitions #{@expanded_string_limit})
             (string? suffix)
             (<= (+' (utf8-size prefix)
                      (*' (utf8-size repeated) repetitions)
                      (utf8-size suffix))
                 #{@expanded_string_limit}))))

    (defn decode-string [raw]
      (if (map? raw)
        (if (valid-repeat-encoding? raw)
          (let [^StringBuilder builder (StringBuilder.)]
            (.append builder (get raw "prefix"))
            (dotimes [_ (get raw "count")]
              (.append builder (get raw "repeated")))
            (.append builder (get raw "suffix"))
            (.toString builder))
          (throw (IllegalArgumentException. "invalid repeated string encoding")))
        raw))

    (defn decode-value [value]
      (when value
        (let [type (get value "type")
              raw (get value "value")]
          (case type
            "string" (decode-string raw)
            "int" (Integer/valueOf (str raw))
            "long" (Long/valueOf (str raw))
            "float" (Float/valueOf (str raw))
            "double" (Double/valueOf (str raw))
            "local_date" (java.time.LocalDate/parse raw)
            "instant" (java.time.Instant/parse raw)
            "duration" (java.time.Duration/parse raw)
            "date" (java.util.Date. (Long/valueOf (str raw)))
            (throw (IllegalArgumentException. (str "unknown fixture type " type)))))))

    (defn exact-value [profile value]
      (case profile
        "boolean" (if value "true" "false")
        "int" (Integer/toString (int value))
        "long" (Long/toString (long value))
        "float" (Float/toHexString (float value))
        "double" (Double/toHexString (double value))
        "string" value
        "local_date" (.toString value)
        "instant" (.toString value)
        "duration" (.toString value)
        "date" (Long/toString (.getTime ^java.util.Date value))
        (throw (IllegalArgumentException. (str "unknown return profile " profile)))))

    (defn normalized-value [case-data value]
      (case (get case-data "normalizer")
        "exact" (exact-value (get case-data "return") value)
        "non_negative" (if (neg? value)
                           (throw (IllegalStateException. "expected non-negative result"))
                           "<non-negative>")
        "type_only" "<dynamic>"
        (throw (IllegalArgumentException. "unknown result normalizer"))))

    (defn emit-result [case-data status type value]
      (println (str "#{@result_marker}\t"
                    (get case-data "case_id") "\t"
                    (get case-data "overload_id") "\t"
                    (get case-data "descriptor") "\t"
                    status "\t" type "\t" (b64 value))))

    (defn invoke-case [case-data]
      (try
        (let [^Class klass (Class/forName (get case-data "class"))
              kind (get case-data "kind")
              member (get case-data "member")
              descriptor (get case-data "descriptor")
              receiver (decode-value (get case-data "receiver"))
              arguments (object-array (map decode-value (get case-data "arguments")))
              value (case kind
                      "static" (.invoke ^Method (exact-method klass member descriptor true)
                                        nil arguments)
                      "instance" (.invoke ^Method (exact-method klass member descriptor false)
                                          receiver arguments)
                      "constructor" (.newInstance ^Constructor
                                                   (exact-constructor klass descriptor)
                                                   arguments)
                      "field" (.get ^Field (exact-field klass member descriptor) nil)
                      (throw (IllegalArgumentException. (str "unknown invocation kind " kind))))]
          (emit-result case-data "ok" (get case-data "return")
                       (normalized-value case-data value)))
        (catch Throwable error
          (let [cause (if (instance? InvocationTargetException error)
                        (.getTargetException ^InvocationTargetException error)
                        error)]
            (emit-result case-data "error" "error" (.getName (class cause)))))))

    (println (str "#{@meta_marker}\t"
                  (System/getProperty "java.version") "\t"
                  (System/getProperty "java.runtime.version") "\t"
                  (System/getProperty "java.vendor") "\t"
                  (clojure-version) "\t\t"
                  (.toString (Locale/getDefault)) "\t"
                  (.getID (TimeZone/getDefault))))

    (doseq [case-data cases] (invoke-case case-data))
    """
  end

  defp babashka_source(cases) do
    bodies = Enum.map_join(cases, "\n", &babashka_case_source/1)

    """
    (import '[java.nio.charset StandardCharsets]
            '[java.util Base64 Locale])

    (def encoder (Base64/getEncoder))

    (defn b64 [value]
      (.encodeToString encoder (.getBytes (str value) StandardCharsets/UTF_8)))

    (defn emit-result [case-id overload-id status type value]
      (println (str "#{@result_marker}\t" case-id "\t" overload-id
                    "\t<babashka-unattested>\t" status "\t" type "\t" (b64 value))))

    (println (str "#{@meta_marker}\t"
                  (System/getProperty "java.version") "\t"
                  (System/getProperty "java.runtime.version") "\t"
                  (System/getProperty "java.vendor") "\t"
                  (clojure-version) "\t"
                  (System/getProperty "babashka.version") "\t"
                  (.toString (Locale/getDefault)) "\t"
                  (.getId (java.time.ZoneId/systemDefault))))

    #{bodies}
    """
  end

  defp babashka_case_source(fixture) do
    expression = babashka_expression(fixture)
    type = Atom.to_string(fixture.expected.type)
    value = babashka_canonical_value(type, expression)

    """
    (try
      (emit-result #{edn(fixture.case_id)} #{edn(Atom.to_string(fixture.overload_id))}
                   "ok" #{edn(type)} #{value})
      (catch Throwable error
        (emit-result #{edn(fixture.case_id)} #{edn(Atom.to_string(fixture.overload_id))}
                     "error" "error" (.getName (class error)))))
    """
  end

  defp babashka_expression(%{overload_id: :boolean_parse_boolean_string} = fixture) do
    [argument] = fixture.invocation.arguments
    "(Boolean/parseBoolean #{edn(argument.value)})"
  end

  defp babashka_expression(%{overload_id: :math_pow_double} = fixture) do
    [left, right] = fixture.invocation.arguments
    "(Math/pow (double #{edn(left.value)}) (double #{edn(right.value)}))"
  end

  defp babashka_expression(%{overload_id: :math_sqrt_double} = fixture) do
    [argument] = fixture.invocation.arguments
    "(Math/sqrt (double #{edn(argument.value)}))"
  end

  defp babashka_canonical_value("boolean", expression),
    do: "(if #{expression} \"true\" \"false\")"

  defp babashka_canonical_value("double", expression) do
    "(Double/toHexString (double #{expression}))"
  end
end
