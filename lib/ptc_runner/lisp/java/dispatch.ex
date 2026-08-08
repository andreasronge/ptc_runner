defmodule PtcRunner.Lisp.Java.Dispatch do
  @moduledoc """
  Closed selector and postcondition boundary for admitted Java operations.

  Dispatch starts from stable manifest identities, selects one exact overload,
  invokes one code-owned implementation key, and validates the handler outcome.
  It never reflects, loads a class, or falls back to open host dispatch.
  """

  alias PtcRunner.Lisp.Java.Condition
  alias PtcRunner.Lisp.Java.Implementations
  alias PtcRunner.Lisp.Java.Lang.String, as: JavaString
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Java.Surface
  alias PtcRunner.Lisp.Java.Time.Duration
  alias PtcRunner.Lisp.Java.Time.Instant
  alias PtcRunner.Lisp.Java.Time.LocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate

  @long_min_float -9.223_372_036_854_776e18
  @long_max_exclusive_float 9.223_372_036_854_776e18

  @type invocation_kind :: :static | :constructor | :instance | :field
  @type result :: {:ok, term(), atom()} | {:error, Condition.t()}

  @spec invoke(atom(), invocation_kind(), term(), [term()]) :: result()
  def invoke(reference_id, kind, receiver, arguments)
      when is_atom(reference_id) and is_atom(kind) and is_list(arguments) do
    with {:ok, reference} <- fetch_reference(reference_id),
         :ok <- validate_kind(reference, kind),
         {:ok, overload, coerced} <- select_overload(reference, receiver, arguments),
         :ok <- attest_selection(reference_id, overload.overload_id),
         :ok <- validate_instance_receiver(reference, overload, kind, receiver),
         :ok <- validate_string_inputs(reference, overload, receiver, arguments),
         {:ok, outcome} <- invoke_handler(overload, coerced),
         {:ok, value} <- validate_handler_outcome(overload.overload_id, outcome) do
      {:ok, value, overload.overload_id}
    end
  end

  defp validate_instance_receiver(reference, overload, :instance, nil) do
    {:error,
     Condition.new(
       :java_domain_error,
       reference.reference_id,
       overload.overload_id,
       "Java instance receiver is null",
       %{java_exception: :null_pointer_exception, receiver_profile: :null}
     )}
  end

  defp validate_instance_receiver(_reference, _overload, _kind, _receiver), do: :ok

  defp validate_string_inputs(reference, %{receiver: :string} = overload, receiver, arguments) do
    values =
      maybe_string_input(overload.receiver, receiver) ++
        (overload.arguments
         |> Enum.zip(arguments)
         |> Enum.flat_map(fn {profile, value} -> maybe_string_input(profile, value) end))

    case Enum.find_value(values, fn value ->
           case JavaString.validate_input(value) do
             :ok -> nil
             {:error, reason} -> reason
           end
         end) do
      nil ->
        :ok

      reason ->
        {:error,
         Condition.new(
           :invalid_java_string,
           reference.reference_id,
           overload.overload_id,
           "Java String input cannot be represented by the bounded UTF-16 view",
           %{java_exception: :invalid_java_string, reason: reason}
         )}
    end
  end

  defp validate_string_inputs(_reference, _overload, _receiver, _arguments), do: :ok

  defp maybe_string_input(profile, value) when profile in [:string, :char_sequence], do: [value]
  defp maybe_string_input(_profile, _value), do: []

  @doc "Selects one closed instance reference from a finite manifest member family."
  @spec invoke_family(atom(), term(), [term()]) :: result()
  def invoke_family(member_family_id, receiver, arguments)
      when is_atom(member_family_id) and is_list(arguments) do
    references = Surface.member_family_references(member_family_id)

    case references do
      [reference] ->
        invoke(reference.reference_id, :instance, receiver, arguments)

      _ ->
        invoke_ambiguous_family(member_family_id, references, receiver, arguments)
    end
  end

  defp invoke_ambiguous_family(member_family_id, references, nil, _arguments)
       when references != [] do
    {:error,
     Condition.new(
       :java_domain_error,
       member_family_id,
       nil,
       "Java instance receiver is null",
       %{java_exception: :null_pointer_exception, receiver_profile: :null}
     )}
  end

  defp invoke_ambiguous_family(member_family_id, references, receiver, arguments) do
    profile = receiver_profile(receiver)
    candidates = Enum.filter(references, &reference_accepts_receiver?(&1, profile))

    case candidates do
      [reference] ->
        invoke(reference.reference_id, :instance, receiver, arguments)

      _ ->
        {:error,
         Condition.new(
           :unsupported_java_member,
           member_family_id,
           nil,
           "unsupported Java member for receiver class",
           %{receiver_profile: profile}
         )}
    end
  end

  defp attest_selection(reference_id, overload_id) do
    :telemetry.execute(
      [:ptc_runner, :lisp, :java, :dispatch],
      %{},
      %{reference_id: reference_id, overload_id: overload_id}
    )

    :ok
  end

  @doc false
  @spec validate_handler_outcome(atom(), term()) :: {:ok, term()} | {:error, Condition.t()}
  def validate_handler_outcome(overload_id, outcome) when is_atom(overload_id) do
    case Surface.fetch_overload(overload_id) do
      {:ok, overload} -> validate_outcome(overload, outcome)
      :error -> handler_contract(nil, overload_id, "handler referenced an unknown overload")
    end
  end

  @doc false
  @spec coerce_argument(atom(), term()) :: {:ok, term(), non_neg_integer()} | :error
  def coerce_argument(profile, value), do: coerce(profile, value)

  defp fetch_reference(reference_id) do
    case Surface.fetch_reference(reference_id) do
      {:ok, reference} ->
        {:ok, reference}

      :error ->
        {:error,
         Condition.new(
           :unsupported_java_member,
           reference_id,
           nil,
           "unsupported Java member",
           %{}
         )}
    end
  end

  defp validate_kind(%{kind: kind}, kind), do: :ok

  defp validate_kind(%{reference_id: reference_id, kind: expected}, actual) do
    {:error,
     Condition.new(
       :unsupported_java_member,
       reference_id,
       nil,
       "Java member does not support #{actual} invocation",
       %{expected_kind: expected, actual_kind: actual}
     )}
  end

  defp select_overload(reference, receiver, arguments) do
    overloads = Enum.map(reference.overload_ids, &fetch_overload!/1)
    arity = length(arguments)
    arity_candidates = Enum.filter(overloads, &(&1.arity == arity))

    case arity_candidates do
      [] -> arity_error(reference, overloads, arity)
      candidates -> select_by_types(reference, candidates, receiver, arguments)
    end
  end

  defp select_by_types(reference, candidates, receiver, arguments) do
    matches =
      Enum.flat_map(candidates, fn overload ->
        case coerce_overload(overload, receiver, arguments) do
          {:ok, coerced, score} -> [{score, overload, coerced}]
          :error -> []
        end
      end)

    case Enum.sort_by(matches, &elem(&1, 0), :desc) do
      [{_score, overload, coerced}] ->
        {:ok, overload, coerced}

      [{score, overload, coerced} | rest] ->
        if Enum.any?(rest, fn {other_score, _, _} -> other_score == score end) do
          type_error(reference, candidates, receiver, arguments)
        else
          {:ok, overload, coerced}
        end

      [] ->
        select_single_numeric_fallback(reference, candidates, receiver, arguments)
    end
  end

  defp select_single_numeric_fallback(reference, [overload], receiver, arguments) do
    with {:ok, coerced_arguments} <-
           coerce_single_numeric_arguments(overload.arguments, arguments),
         {:ok, coerced} <-
           prepend_fallback_receiver(overload.receiver, receiver, coerced_arguments) do
      {:ok, overload, coerced}
    else
      :error ->
        type_error(reference, [overload], receiver, arguments, &coerce_single_numeric_fallback/2)
    end
  end

  defp select_single_numeric_fallback(reference, candidates, receiver, arguments),
    do: type_error(reference, candidates, receiver, arguments)

  defp prepend_fallback_receiver(nil, nil, arguments), do: {:ok, arguments}

  defp prepend_fallback_receiver(profile, receiver, arguments) do
    case coerce(profile, receiver) do
      {:ok, coerced_receiver, _score} -> {:ok, [coerced_receiver | arguments]}
      :error -> :error
    end
  end

  defp coerce_single_numeric_arguments(profiles, arguments) do
    profiles
    |> Enum.zip(arguments)
    |> Enum.reduce_while({:ok, []}, fn {profile, value}, {:ok, acc} ->
      case coerce_single_numeric_fallback(profile, value) do
        {:ok, coerced} -> {:cont, {:ok, [coerced | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp coerce_single_numeric_fallback(profile, value) do
    case coerce(profile, value) do
      {:ok, coerced, _score} -> {:ok, coerced}
      :error -> coerce_single_numeric(profile, value)
    end
  end

  defp coerce_single_numeric(:double, value) when is_integer(value) do
    if Primitive.in_range?(:long, value), do: {:ok, value * 1.0}, else: :error
  end

  defp coerce_single_numeric(:double, value) when is_float(value), do: {:ok, value}

  defp coerce_single_numeric(:double, value)
       when value in [:infinity, :negative_infinity, :nan],
       do: {:ok, value}

  defp coerce_single_numeric(:double, %Primitive{} = primitive) do
    with true <- Primitive.valid?(primitive),
         {:ok, value} <- Primitive.unwrap(primitive) do
      widen_to_double(primitive.kind, value)
    else
      _invalid -> :error
    end
  end

  defp coerce_single_numeric(:int, value) when is_integer(value) do
    if Primitive.in_range?(:int, value), do: {:ok, value}, else: :error
  end

  defp coerce_single_numeric(:int, value) when is_float(value) do
    integer = trunc(value)
    if Primitive.in_range?(:int, integer), do: {:ok, integer}, else: :error
  end

  defp coerce_single_numeric(:int, :nan), do: {:ok, 0}

  defp coerce_single_numeric(:int, %Primitive{} = primitive) do
    with true <- Primitive.valid?(primitive),
         {:ok, value} <- Primitive.unwrap(primitive) do
      cond do
        is_integer(value) and Primitive.in_range?(:int, value) ->
          {:ok, value}

        is_float(value) ->
          integer = trunc(value)
          if Primitive.in_range?(:int, integer), do: {:ok, integer}, else: :error

        value == :nan and primitive.kind in [:float, :double] ->
          {:ok, 0}

        true ->
          :error
      end
    else
      _invalid -> :error
    end
  end

  defp coerce_single_numeric(:long, value) when is_float(value), do: checked_float_to_long(value)
  defp coerce_single_numeric(:long, :nan), do: {:ok, 0}

  defp coerce_single_numeric(:long, value) when value in [:infinity, :negative_infinity],
    do: :error

  defp coerce_single_numeric(:long, %Primitive{} = primitive) do
    with true <- Primitive.valid?(primitive),
         {:ok, value} <- Primitive.unwrap(primitive) do
      case {primitive.kind, value} do
        {kind, integer} when kind in [:int, :long] and is_integer(integer) ->
          {:ok, integer}

        {kind, float} when kind in [:float, :double] and is_float(float) ->
          checked_float_to_long(float)

        {kind, :nan} when kind in [:float, :double] ->
          {:ok, 0}

        {kind, infinity}
        when kind in [:float, :double] and
               infinity in [:infinity, :negative_infinity] ->
          :error

        _invalid ->
          :error
      end
    else
      _invalid -> :error
    end
  end

  defp coerce_single_numeric(_profile, _value), do: :error

  defp widen_to_double(kind, value) when kind in [:int, :long], do: {:ok, value * 1.0}
  defp widen_to_double(kind, value) when kind in [:float, :double], do: {:ok, value}
  defp widen_to_double(_kind, _value), do: :error

  defp coerce_overload(%{receiver: nil, arguments: profiles}, nil, arguments),
    do: coerce_arguments(profiles, arguments)

  defp coerce_overload(%{receiver: receiver_profile, arguments: profiles}, receiver, arguments) do
    with {:ok, coerced_receiver, receiver_score} <- coerce(receiver_profile, receiver),
         {:ok, coerced_arguments, arguments_score} <- coerce_arguments(profiles, arguments) do
      {:ok, [coerced_receiver | coerced_arguments], receiver_score + arguments_score}
    end
  end

  defp coerce_overload(_overload, _receiver, _arguments), do: :error

  defp coerce_arguments(profiles, arguments) do
    profiles
    |> Enum.zip(arguments)
    |> Enum.reduce_while({:ok, [], 0}, fn {profile, value}, {:ok, acc, score} ->
      case coerce(profile, value) do
        {:ok, coerced, value_score} ->
          {:cont, {:ok, [coerced | acc], score + value_score}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, coerced, score} -> {:ok, Enum.reverse(coerced), score}
      :error -> :error
    end
  end

  defp coerce(profile, nil)
       when profile in [
              :string,
              :char_sequence,
              :local_date,
              :instant,
              :duration,
              :temporal,
              :date
            ],
       do: {:ok, nil, 1}

  defp coerce(:string, value) when is_binary(value), do: {:ok, value, 4}
  defp coerce(:char_sequence, value) when is_binary(value), do: {:ok, value, 3}

  defp coerce(:local_date, %LocalDate{} = value) do
    if LocalDate.valid?(value), do: {:ok, value, 5}, else: :error
  end

  defp coerce(:instant, %Instant{} = value) do
    if Instant.valid?(value), do: {:ok, value, 5}, else: :error
  end

  defp coerce(:duration, %Duration{} = value) do
    if Duration.valid?(value), do: {:ok, value, 5}, else: :error
  end

  defp coerce(:date, %JavaDate{} = value) do
    if JavaDate.valid?(value), do: {:ok, value, 5}, else: :error
  end

  defp coerce(kind, %Primitive{kind: kind} = primitive) do
    case Primitive.unwrap(primitive) do
      {:ok, value} -> {:ok, value, 5}
      {:error, :invalid_java_value} -> :error
    end
  end

  defp coerce(:long, %Primitive{kind: :int} = primitive) do
    case Primitive.unwrap(primitive) do
      {:ok, value} -> {:ok, value, 4}
      {:error, :invalid_java_value} -> :error
    end
  end

  defp coerce(:long, value) when is_integer(value) do
    if Primitive.in_range?(:long, value), do: {:ok, value, 2}, else: :error
  end

  defp coerce(:double, value) when is_float(value), do: {:ok, value, 2}

  defp coerce(:double, value) when value in [:infinity, :negative_infinity, :nan],
    do: {:ok, value, 2}

  defp coerce(_profile, _value), do: :error

  defp receiver_profile(value) when is_binary(value), do: :string
  defp receiver_profile(%LocalDate{} = value), do: valid_profile(LocalDate, value, :local_date)
  defp receiver_profile(%Instant{} = value), do: valid_profile(Instant, value, :instant)
  defp receiver_profile(%Duration{} = value), do: valid_profile(Duration, value, :duration)
  defp receiver_profile(%JavaDate{} = value), do: valid_profile(JavaDate, value, :date)
  defp receiver_profile(_value), do: :unsupported

  defp reference_accepts_receiver?(reference, profile) do
    Enum.any?(reference.overload_ids, fn overload_id ->
      {:ok, overload} = Surface.fetch_overload(overload_id)
      overload.receiver == profile
    end)
  end

  defp invoke_handler(%{route: {:dispatch, implementation_key}} = overload, arguments) do
    if null_object_argument?(overload, arguments) do
      {:ok,
       {:error,
        Condition.new(
          :java_domain_error,
          overload.reference_id,
          overload.overload_id,
          "Java object argument is null",
          %{java_exception: :null_pointer_exception}
        )}}
    else
      case Implementations.fetch(implementation_key) do
        {:ok, {module, function}} ->
          try do
            {:ok, apply(module, function, [arguments])}
          rescue
            _exception ->
              handler_contract(
                overload.reference_id,
                overload.overload_id,
                "Java handler raised instead of returning a closed outcome"
              )
          catch
            _kind, _reason ->
              handler_contract(
                overload.reference_id,
                overload.overload_id,
                "Java handler exited instead of returning a closed outcome"
              )
          end

        :error ->
          handler_contract(
            overload.reference_id,
            overload.overload_id,
            "Java overload has no code-owned handler"
          )
      end
    end
  end

  defp invoke_handler(overload, _arguments) do
    handler_contract(
      overload.reference_id,
      overload.overload_id,
      "Java overload is not on closed dispatch"
    )
  end

  defp checked_float_to_long(value)
       when value >= @long_min_float and value < @long_max_exclusive_float,
       do: {:ok, trunc(value)}

  defp checked_float_to_long(_value), do: :error

  defp valid_profile(module, value, profile) do
    if module.valid?(value), do: profile, else: :unsupported
  end

  defp null_object_argument?(overload, arguments) do
    profiles =
      if is_nil(overload.receiver),
        do: overload.arguments,
        else: [overload.receiver | overload.arguments]

    profiles
    |> Enum.zip(arguments)
    |> Enum.any?(fn {profile, value} ->
      is_nil(value) and profile in [:local_date, :instant, :duration, :temporal, :date]
    end)
  end

  defp validate_outcome(overload, {:ok, value}) do
    if return_value?(overload.return, value) do
      {:ok, value}
    else
      handler_contract(
        overload.reference_id,
        overload.overload_id,
        "Java handler returned a value outside its manifest return profile"
      )
    end
  end

  defp validate_outcome(overload, {:error, %Condition{} = condition}) do
    if declared_condition?(overload, condition) do
      {:error,
       %{condition | reference_id: overload.reference_id, overload_id: overload.overload_id}}
    else
      handler_contract(
        overload.reference_id,
        overload.overload_id,
        "Java handler returned an undeclared condition"
      )
    end
  end

  defp validate_outcome(overload, _outcome) do
    handler_contract(
      overload.reference_id,
      overload.overload_id,
      "Java handler returned a malformed outcome"
    )
  end

  defp return_value?(:boolean, value), do: is_boolean(value)
  defp return_value?(:string, value), do: is_binary(value) and Elixir.String.valid?(value)
  defp return_value?(:local_date, value), do: LocalDate.valid?(value)
  defp return_value?(:instant, value), do: Instant.valid?(value)
  defp return_value?(:duration, value), do: Duration.valid?(value)
  defp return_value?(:date, value), do: JavaDate.valid?(value)
  defp return_value?(kind, %Primitive{kind: kind} = primitive), do: Primitive.valid?(primitive)
  defp return_value?(_profile, _value), do: false

  defp declared_condition?(overload, %Condition{details: %{java_exception: exception}}),
    do: exception in overload.errors

  defp declared_condition?(_overload, _condition), do: false

  defp arity_error(reference, overloads, actual) do
    expected = overloads |> Enum.map(& &1.arity) |> Enum.uniq() |> Enum.sort()

    {:error,
     Condition.new(
       :java_arity_error,
       reference.reference_id,
       nil,
       "Java member expects #{format_arities(expected)} argument(s), got #{actual}",
       %{expected: expected, actual: actual}
     )}
  end

  defp type_error(reference, candidates, receiver, arguments),
    do: type_error(reference, candidates, receiver, arguments, &coerce/2)

  defp type_error(reference, candidates, receiver, arguments, argument_coercer) do
    receiver_profiles =
      candidates |> Enum.map(& &1.receiver) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if receiver_profiles != [] and coerce_receiver_profiles(receiver_profiles, receiver) == :error do
      {:error,
       Condition.new(
         :java_type_error,
         reference.reference_id,
         nil,
         "Java member receiver does not match an admitted class",
         %{receiver: true, expected: receiver_profiles, actual: value_type(receiver)}
       )}
    else
      argument_type_error(reference, candidates, arguments, argument_coercer)
    end
  end

  defp argument_type_error(reference, candidates, arguments, argument_coercer) do
    case first_mismatch(candidates, arguments, argument_coercer) do
      {:argument, argument, actual, expected} ->
        {:error,
         Condition.new(
           :java_type_error,
           reference.reference_id,
           nil,
           "Java member argument #{argument} does not match an admitted overload",
           %{argument: argument, expected: expected, actual: value_type(actual)}
         )}

      :overload_combination ->
        {:error,
         Condition.new(
           :java_type_error,
           reference.reference_id,
           nil,
           "Java member argument types do not match a single admitted overload",
           %{
             expected: Enum.map(candidates, & &1.arguments),
             actual: Enum.map(arguments, &value_type/1)
           }
         )}
    end
  end

  defp first_mismatch(candidates, arguments, argument_coercer) do
    arguments
    |> Enum.with_index()
    |> Enum.find_value(:overload_combination, fn {value, index} ->
      profiles = candidates |> Enum.map(&Enum.at(&1.arguments, index)) |> Enum.uniq()

      if Enum.any?(profiles, &(argument_coercer.(&1, value) != :error)),
        do: nil,
        else: {:argument, index, value, profiles}
    end)
  end

  defp coerce_receiver_profiles(profiles, receiver) do
    if Enum.any?(profiles, &(coerce(&1, receiver) != :error)), do: :ok, else: :error
  end

  defp value_type(nil), do: nil
  defp value_type(value) when is_binary(value), do: :string
  defp value_type(value) when is_boolean(value), do: :boolean
  defp value_type(value) when is_integer(value), do: :integer
  defp value_type(value) when is_float(value), do: :float
  defp value_type(value) when value in [:infinity, :negative_infinity, :nan], do: :double
  defp value_type(%Primitive{kind: kind}), do: kind
  defp value_type(%LocalDate{}), do: :local_date
  defp value_type(%Instant{}), do: :instant
  defp value_type(%Duration{}), do: :duration
  defp value_type(%JavaDate{}), do: :date
  defp value_type(_value), do: :other

  defp format_arities([arity]), do: Integer.to_string(arity)
  defp format_arities(arities), do: Enum.join(arities, " or ")

  defp fetch_overload!(overload_id) do
    {:ok, overload} = Surface.fetch_overload(overload_id)
    overload
  end

  defp handler_contract(reference_id, overload_id, message) do
    {:error,
     Condition.new(
       :java_handler_contract_error,
       reference_id,
       overload_id,
       message,
       %{}
     )}
  end
end
