defmodule PtcRunner.Lisp.HostErrorPolicy do
  @moduledoc """
  Host-owned error projection at private prelude and parallel failure boundaries.

  Pass an implementing module as `:host_error_policy` to `PtcRunner.Lisp.run/2`.
  The host must rebuild errors and metadata from validated fields, using stable
  messages and bounded data. Evaluator diagnostics are retained independently.
  Without a policy, host errors become `private_prelude_error`; program-authored
  parallel `fail` values retain only a bounded scalar `kind` as `failure_kind`.

  Policies belong to the invocation context. Workers inherit them and closures
  never capture them. Prelude compilation does not require a host policy.
  Exceptions, throws, invalid shapes and oversized policy results fail closed.
  Sanitizers must be idempotent across nested private boundaries.

  Error projections have at most 32 nesting levels, 4,096 traversal nodes and
  262,144 scalar bytes. Metadata projections have at most four nesting levels,
  64 traversal nodes and 4,096 scalar bytes. Projections contain only data:
  atoms, int64 integers, floats, binaries, lists, tuples and maps (including
  host-validated diagnostic structs). Processes, references and functions are
  rejected. Retained binaries are detached from larger source buffers.
  """

  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.RetainedSize

  @doc "Rebuilds one host error as a stable message and validated details, or rejects it."
  @callback sanitize_private_error(term()) :: {:ok, {atom(), binary(), map()}} | :error
  @doc "Projects a program failure (`:extract`) or revalidates projected metadata (`:retain`)."
  @callback failure_metadata(term(), :extract | :retain) :: map()

  @fallback {:private_prelude_error, "private prelude evaluation failed"}

  @doc false
  @spec sanitize_error(module() | nil, term()) :: term()
  def sanitize_error(nil, _reason), do: @fallback

  def sanitize_error(policy, reason) when is_atom(policy) do
    case policy.sanitize_private_error(reason) do
      {:ok, {kind, message, details} = rebuilt}
      when is_atom(kind) and not is_nil(kind) and not is_boolean(kind) and is_binary(message) and
             is_map(details) ->
        if bounded?(rebuilt, 32, 4096, 262_144),
          do: RetainedSize.detach_binaries(rebuilt),
          else: @fallback

      _invalid ->
        @fallback
    end
  rescue
    _error -> @fallback
  catch
    _kind, _value -> @fallback
  end

  def sanitize_error(_policy, _reason), do: @fallback

  @doc false
  @spec project_failure_metadata(module() | nil, term(), :extract | :retain) :: map()
  def project_failure_metadata(nil, value, mode), do: program_metadata(value, mode)

  def project_failure_metadata(policy, value, mode) when is_atom(policy) do
    case policy.failure_metadata(value, mode) do
      rebuilt when is_map(rebuilt) and not is_struct(rebuilt) ->
        if bounded?(rebuilt, 4, 64, 4096), do: RetainedSize.detach_binaries(rebuilt), else: %{}

      _invalid ->
        %{}
    end
  rescue
    _error -> %{}
  catch
    _kind, _value -> %{}
  end

  def project_failure_metadata(_policy, _value, _mode), do: %{}

  defp program_metadata(value, mode) when is_map(value) and not is_struct(value) do
    kind =
      case mode do
        :extract ->
          Map.get(
            value,
            %LispKeyword{name: "kind"},
            Map.get(value, "kind", Map.get(value, :kind))
          )

        :retain ->
          Map.get(value, :failure_kind)
      end

    case scalar_name(kind) do
      name when is_binary(name) and byte_size(name) in 1..128 ->
        if Regex.match?(~r/\A[a-zA-Z0-9._\/-]+\z/, name),
          do: %{failure_kind: :binary.copy(name)},
          else: %{}

      _invalid ->
        %{}
    end
  end

  defp program_metadata(_value, _mode), do: %{}

  defp scalar_name(%LispKeyword{name: name}), do: name

  defp scalar_name(name) when is_atom(name) and not is_nil(name) and not is_boolean(name),
    do: Atom.to_string(name)

  defp scalar_name(name) when is_binary(name), do: name
  defp scalar_name(_name), do: nil

  # A shared node/byte budget bounds traversal as well as the retained value.
  # Reject entire invalid outputs rather than exposing a partially valid policy result.
  defp bounded?(value, depth, nodes, bytes),
    do: match?({:ok, _, _}, measure(value, depth, nodes, bytes))

  defp measure(_value, depth, nodes, bytes) when depth < 0 or nodes < 1 or bytes < 0,
    do: :error

  defp measure(value, _depth, nodes, bytes) when is_binary(value) do
    if byte_size(value) <= bytes, do: {:ok, nodes - 1, bytes - byte_size(value)}, else: :error
  end

  defp measure(value, _depth, nodes, bytes) when is_atom(value) do
    size = byte_size(Atom.to_string(value)) + 8
    if size <= bytes, do: {:ok, nodes - 1, bytes - size}, else: :error
  end

  defp measure(value, _depth, nodes, bytes)
       when (is_float(value) or
               (is_integer(value) and
                  value in -9_223_372_036_854_775_808..9_223_372_036_854_775_807)) and bytes >= 8,
       do: {:ok, nodes - 1, bytes - 8}

  defp measure(value, depth, nodes, bytes) when is_map(value) and map_size(value) <= nodes do
    Enum.reduce_while(Map.to_list(value), {:ok, nodes - 1, bytes}, fn {key, child}, {:ok, n, b} ->
      with {:ok, n, b} <- measure(key, depth - 1, n, b),
           {:ok, n, b} <- measure(child, depth - 1, n, b) do
        {:cont, {:ok, n, b}}
      else
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp measure(value, depth, nodes, bytes) when is_tuple(value) and tuple_size(value) <= nodes,
    do: measure(Tuple.to_list(value), depth, nodes - 1, bytes)

  defp measure([], _depth, nodes, bytes), do: {:ok, nodes - 1, bytes}

  defp measure([head | tail], depth, nodes, bytes) do
    with {:ok, nodes, bytes} <- measure(head, depth - 1, nodes - 1, bytes) do
      measure_list(tail, depth, nodes, bytes)
    end
  end

  defp measure(_value, _depth, _nodes, _bytes), do: :error

  defp measure_list([], depth, nodes, bytes), do: measure([], depth, nodes, bytes)
  defp measure_list([_ | _] = value, depth, nodes, bytes), do: measure(value, depth, nodes, bytes)
  defp measure_list(_improper, _depth, _nodes, _bytes), do: :error
end
