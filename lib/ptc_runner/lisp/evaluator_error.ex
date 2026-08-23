defmodule PtcRunner.Lisp.EvaluatorError do
  @moduledoc """
  Public-safe renderer for catalogued PTC-Lisp evaluator failures.

  Messages are built from admitted structured details or fixed literals. Raw
  evaluator text, BEAM names, internal reference IDs, and inspected values are
  never forwarded. An unadmitted reason or detail set fails closed.
  """

  alias PtcRunner.Lisp.EvaluatorErrorCatalog

  @type evidence :: %{kind: binary(), message: binary()}

  @max_public_name_bytes 128
  @max_public_message_bytes 1_024

  @java_messages %{
    unsupported_java_class: "Java class is outside the admitted interop surface",
    unsupported_java_member: "Java member is outside the admitted interop surface",
    java_arity_error: "Java member called with an arity that matches no admitted overload",
    java_type_error: "Java member argument does not match an admitted overload",
    java_domain_error: "Java member rejected an admitted argument for a domain reason",
    invalid_java_string: "Java string argument is not valid UTF-8",
    java_handler_contract_error: "Java handler violated its closed contract"
  }

  @spec public_evidence(atom(), map()) :: {:ok, evidence()} | :error
  def public_evidence(reason, details) when is_map(details) do
    with true <- EvaluatorErrorCatalog.kind?(reason),
         {:ok, message} <- public_message(reason, details),
         {:ok, kind} <- EvaluatorErrorCatalog.wire_name(reason) do
      {:ok, %{kind: kind, message: message}}
    else
      _closed -> :error
    end
  end

  def public_evidence(_reason, _details), do: :error

  @spec envelope_value(atom(), map()) :: {:ok, map()} | :error
  def envelope_value(reason, details) do
    case public_evidence(reason, details) do
      {:ok, %{kind: kind, message: message}} ->
        {:ok, %{"kind" => kind, "message" => message}}

      :error ->
        :error
    end
  end

  @spec format(atom(), map()) :: {:ok, binary()} | :error
  def format(reason, details) do
    case public_evidence(reason, details) do
      {:ok, %{kind: kind, message: message}} -> {:ok, "#{kind}: #{message}"}
      :error -> :error
    end
  end

  @spec lisp_message(atom(), map()) :: {:ok, binary()} | :error
  def lisp_message(:not_callable, details) when is_map(details) do
    case admitted_public_name(details) do
      {:ok, name} -> {:ok, "not callable: #{name}"}
      :error -> {:ok, "not callable: value"}
    end
  end

  def lisp_message(:arity_error, details) when is_map(details) do
    with {:ok, name} <- admitted_public_name(details),
         {:ok, actual} <- admitted_nonneg_integer(Map.get(details, :actual)),
         {:ok, sentence} <- arity_lisp_sentence(name, Map.get(details, :expected), actual) do
      {:ok, "arity error: " <> sentence}
    else
      _closed ->
        case public_evidence(:arity_error, details) do
          {:ok, %{message: message}} -> {:ok, "arity error: " <> message}
          :error -> :error
        end
    end
  end

  def lisp_message(reason, details) do
    case public_evidence(reason, details) do
      {:ok, %{kind: _kind, message: message}} ->
        prefix = lisp_prefix(reason)
        {:ok, prefix <> message}

      :error ->
        :error
    end
  end

  @doc false
  @spec retain_reason(term()) :: {:ok, term()} | :error
  def retain_reason({:arithmetic_error, token})
      when token in [:division_by_zero, :integer_overflow, :bad_argument],
      do: {:ok, {:arithmetic_error, token}}

  def retain_reason({:loop_limit_exceeded, limit})
      when is_integer(limit) and limit > 0 and limit <= 1_000_000,
      do: {:ok, {:loop_limit_exceeded, limit}}

  def retain_reason({:not_callable, {:data_ref, symbol}}) when is_binary(symbol),
    do: {:ok, {:not_callable, {:data_ref, symbol}}}

  def retain_reason({:not_callable, details}) when is_map(details) do
    case admitted_public_name(details) do
      {:ok, name} -> {:ok, {:not_callable, %{name: name}}}
      :error -> {:ok, {:not_callable, %{}}}
    end
  end

  def retain_reason({:not_callable, _value}), do: {:ok, {:not_callable, %{}}}

  def retain_reason({:arity_error, details}) when is_map(details) do
    retained = retain_arity_details(details)

    case public_evidence(:arity_error, retained) do
      {:ok, _} -> {:ok, {:arity_error, retained}}
      :error -> :error
    end
  end

  def retain_reason({kind, details}) when is_map(details) do
    retain_catalogued(kind, details)
  end

  def retain_reason({kind, _message, details}) when is_atom(kind) and is_map(details) do
    case retain_catalogued(kind, details) do
      {:ok, {^kind, retained_details}} ->
        case public_evidence(kind, retained_details) do
          {:ok, %{message: message}} -> {:ok, {kind, message, retained_details}}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  def retain_reason(_reason), do: :error

  defp retain_catalogued(kind, details) when is_map(details) do
    cond do
      not EvaluatorErrorCatalog.kind?(kind) ->
        :error

      match?({:ok, _}, public_evidence(kind, details)) ->
        {:ok, {kind, retain_public_details(kind, details)}}

      match?({:ok, _}, public_evidence(kind, %{})) ->
        {:ok, {kind, %{}}}

      true ->
        :error
    end
  end

  defp retain_public_details(:arithmetic_error, details) do
    case admitted_token(details) do
      token when token in [:division_by_zero, :integer_overflow, :bad_argument] ->
        %{token: token}

      _other ->
        %{}
    end
  end

  defp retain_public_details(:arity_error, details), do: retain_arity_details(details)

  defp retain_public_details(:not_callable, details) do
    case admitted_public_name(details) do
      {:ok, name} -> %{name: name}
      :error -> %{}
    end
  end

  defp retain_public_details(:loop_limit_exceeded, details) do
    case admitted_positive_integer(Map.get(details, :limit) || Map.get(details, "limit")) do
      {:ok, limit} -> %{limit: limit}
      :error -> %{}
    end
  end

  defp retain_public_details(_kind, _details), do: %{}

  defp retain_arity_details(details) when is_map(details) do
    %{}
    |> maybe_put_arity_name(details)
    |> maybe_put(:expected, Map.get(details, :expected) || Map.get(details, "expected"))
    |> maybe_put(:actual, Map.get(details, :actual) || Map.get(details, "actual"))
  end

  defp maybe_put_arity_name(map, details) do
    case admitted_public_name(details) do
      {:ok, name} -> Map.put(map, :name, name)
      :error -> map
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp lisp_prefix(:arity_error), do: "arity error: "
  defp lisp_prefix(_reason), do: ""

  defp public_message(:arithmetic_error, details) do
    case admitted_token(details) do
      :division_by_zero -> ok_message("division by zero")
      :integer_overflow -> ok_message("integer overflow")
      :bad_argument -> ok_message("bad argument in arithmetic expression")
      _other -> :error
    end
  end

  defp public_message(:arity_error, details) do
    with {:ok, name} <- admitted_public_name(details),
         {:ok, expected_text} <- format_expected_arity(Map.get(details, :expected)),
         {:ok, actual} <- admitted_nonneg_integer(Map.get(details, :actual)) do
      ok_message("#{name} expects #{expected_text}, got #{actual}")
    else
      _closed ->
        case {Map.get(details, :expected), Map.get(details, :actual)} do
          {nil, actual} ->
            with {:ok, actual} <- admitted_nonneg_integer(actual) do
              ok_message("function called with #{actual} argument(s)")
            end

          _other ->
            :error
        end
    end
  end

  defp public_message(:not_callable, details) do
    case admitted_public_name(details) do
      {:ok, name} -> ok_message("#{name} is not callable")
      :error -> ok_message("value is not callable")
    end
  end

  defp public_message(:loop_limit_exceeded, details) do
    with {:ok, limit} <- admitted_positive_integer(Map.get(details, :limit)) do
      ok_message(
        "Loop iteration limit exceeded (#{limit} iterations). Use reduce/map over a finite sequence instead, or split work across smaller loops."
      )
    end
  end

  defp public_message(reason, _details) do
    case Map.fetch(@java_messages, reason) do
      {:ok, message} -> ok_message(message)
      :error -> :error
    end
  end

  defp admitted_token(%{token: token})
       when token in [:division_by_zero, :integer_overflow, :bad_argument],
       do: token

  defp admitted_token(%{"token" => "division_by_zero"}), do: :division_by_zero
  defp admitted_token(%{"token" => "integer_overflow"}), do: :integer_overflow
  defp admitted_token(%{"token" => "bad_argument"}), do: :bad_argument
  defp admitted_token(_details), do: :error

  defp admitted_public_name(details) do
    name = Map.get(details, :name) || Map.get(details, "name")

    if is_binary(name) and String.valid?(name) and name != "" and
         byte_size(name) <= @max_public_name_bytes and public_name?(name) do
      {:ok, name}
    else
      :error
    end
  end

  defp public_name?(name) do
    String.match?(name, ~r/\A[A-Za-z*+\-\/!?_=<>'][A-Za-z0-9*+\-\/!?_=<>'.]{0,127}\z/)
  end

  defp arity_lisp_sentence(name, {:at_least, n}, actual)
       when is_integer(n) and n >= 0,
       do: {:ok, "#{name} requires at least #{n} argument, got #{actual}"}

  defp arity_lisp_sentence(name, expected, actual)
       when is_integer(expected) and expected >= 0,
       do: {:ok, "#{name} expects #{expected} argument(s), got #{actual}"}

  defp arity_lisp_sentence(name, [left, right], actual)
       when is_integer(left) and left >= 0 and is_integer(right) and right >= 0,
       do: {:ok, "#{name} expects #{left} or #{right} argument(s), got #{actual}"}

  defp arity_lisp_sentence(name, expected, actual)
       when is_list(expected) and expected != [] do
    if Enum.all?(expected, &(is_integer(&1) and &1 >= 0)) do
      {:ok, "#{name} expects #{Enum.join(expected, ", ")} argument(s), got #{actual}"}
    else
      :error
    end
  end

  defp arity_lisp_sentence(_name, _expected, _actual), do: :error

  defp format_expected_arity(expected) when is_integer(expected) and expected >= 0,
    do: {:ok, "#{expected} argument(s)"}

  defp format_expected_arity({:at_least, n}) when is_integer(n) and n >= 0,
    do: {:ok, "at least #{n} argument(s)"}

  defp format_expected_arity([left, right])
       when is_integer(left) and left >= 0 and is_integer(right) and right >= 0,
       do: {:ok, "#{left} or #{right} argument(s)"}

  defp format_expected_arity(expected) when is_list(expected) and expected != [] do
    if Enum.all?(expected, &(is_integer(&1) and &1 >= 0)) do
      {:ok, Enum.join(expected, ", ") <> " argument(s)"}
    else
      :error
    end
  end

  defp format_expected_arity(_expected), do: :error

  defp admitted_nonneg_integer(value)
       when is_integer(value) and value >= 0 and value <= 1_000_000,
       do: {:ok, value}

  defp admitted_nonneg_integer(_value), do: :error

  defp admitted_positive_integer(value)
       when is_integer(value) and value > 0 and value <= 1_000_000,
       do: {:ok, value}

  defp admitted_positive_integer(_value), do: :error

  defp ok_message(message) when is_binary(message) do
    if String.valid?(message) and message != "" and
         byte_size(message) <= @max_public_message_bytes do
      {:ok, message}
    else
      :error
    end
  end
end
