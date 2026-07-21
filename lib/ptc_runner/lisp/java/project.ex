defmodule PtcRunner.Lisp.Java.Project do
  @moduledoc """
  Total, recursive projection for native Java values at bounded host edges.

  The projector validates Java leaves before converting them, tracks a bounded
  structural path, and rejects collection collisions introduced by projection.
  It never exposes an executable callable or a forged primitive.
  """

  alias PtcRunner.Lisp.Java.Callable
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Java.Surface
  alias PtcRunner.Lisp.Java.Time.Duration
  alias PtcRunner.Lisp.Java.Time.Instant
  alias PtcRunner.Lisp.Java.Time.LocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate
  alias PtcRunner.Lisp.KeyNormalizer
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Signature

  @type boundary ::
          :native | :continuation | :public | :tool_argument | :tool_result | :kernel_json
  @type path_segment ::
          {:list, non_neg_integer()}
          | {:tuple, non_neg_integer()}
          | {:map_key, non_neg_integer()}
          | {:map_value, non_neg_integer()}
          | {:set, non_neg_integer()}
          | {:struct_field, atom()}
  @type error ::
          {:invalid_java_value, [path_segment()], atom() | nil}
          | {:invalid_projection_struct, [path_segment()], module()}
          | {:java_projection_collision, [path_segment()], :map | :set}
          | {:invalid_java_tool_contract, String.t()}
          | {:inexact_java_boundary_conversion, [path_segment()], boundary(), atom()}
          | {:unsupported_java_boundary_value, [path_segment()], boundary(), atom()}

  @spec project(term(), boundary(), term()) :: {:ok, term()} | {:error, error()}
  def project(value, boundary, contract \\ nil)
      when boundary in [
             :native,
             :continuation,
             :public,
             :tool_argument,
             :tool_result,
             :kernel_json
           ] do
    with {:ok, prepared_contract} <- prepare_contract(value, boundary, contract) do
      do_project(value, boundary, prepared_contract, [])
    end
  end

  defp do_project(%Callable{reference_id: reference_id} = callable, boundary, _contract, path) do
    cond do
      not Callable.valid?(callable) ->
        {:error, {:invalid_java_value, path, reference_id}}

      boundary == :native ->
        {:ok, callable}

      boundary in [:continuation, :public] ->
        case Surface.reference_label(reference_id) do
          {:ok, label} -> {:ok, label}
          :error -> {:error, {:invalid_java_value, path, reference_id}}
        end

      true ->
        {:error, {:unsupported_java_boundary_value, path, boundary, reference_id}}
    end
  end

  defp do_project(%{__struct__: Primitive} = primitive, boundary, contract, path) do
    kind = Map.get(primitive, :kind)

    case Primitive.unwrap(primitive) do
      {:ok, value} when boundary in [:continuation, :public, :kernel_json] ->
        {:ok, value}

      {:ok, value} when boundary == :tool_argument ->
        project_tool_primitive(primitive, value, unwrap_optional(contract), path)

      {:ok, _value} when boundary == :tool_result ->
        {:error, {:unsupported_java_boundary_value, path, boundary, kind}}

      {:ok, _value} when boundary == :native ->
        {:ok, primitive}

      {:error, :invalid_java_value} ->
        {:error, {:invalid_java_value, path, kind}}
    end
  end

  defp do_project(%{__struct__: Callable} = callable, _boundary, _contract, path),
    do: {:error, {:invalid_java_value, path, Map.get(callable, :reference_id)}}

  defp do_project(%LocalDate{} = value, boundary, contract, path),
    do: project_object(value, LocalDate, :local_date, boundary, contract, path)

  defp do_project(%Instant{} = value, boundary, contract, path),
    do: project_object(value, Instant, :instant, boundary, contract, path)

  defp do_project(%Duration{} = value, boundary, contract, path),
    do: project_object(value, Duration, :duration, boundary, contract, path)

  defp do_project(%JavaDate{} = value, boundary, contract, path),
    do: project_object(value, JavaDate, :date, boundary, contract, path)

  defp do_project(%{__struct__: module}, _boundary, _contract, path)
       when module in [LocalDate, Instant, Duration, JavaDate],
       do: {:error, {:invalid_java_value, path, object_profile(module)}}

  defp do_project(value, boundary, contract, path) when is_list(value) do
    project_list(value, boundary, contract, path, :list)
  end

  defp do_project(value, boundary, contract, path) when is_tuple(value) do
    with {:ok, items} <- project_list(Tuple.to_list(value), boundary, contract, path, :tuple) do
      {:ok, List.to_tuple(items)}
    end
  end

  defp do_project(%MapSet{} = value, boundary, contract, path) do
    value
    |> Enum.to_list()
    |> project_list(boundary, contract, path, :set)
    |> case do
      {:ok, items} ->
        projected = MapSet.new(items)

        if MapSet.size(projected) == length(items),
          do: {:ok, projected},
          else: {:error, {:java_projection_collision, path, :set}}

      {:error, _reason} = error ->
        error
    end
  end

  defp do_project(value, boundary, contract, path) when is_struct(value) do
    module = value.__struct__
    fields = Map.delete(value, :__struct__)

    with {:ok, template} <- struct_template(module, path),
         :ok <- validate_struct_fields(fields, template, module, path),
         {:ok, projected_fields} <- project_struct_fields(fields, boundary, contract, path) do
      {:ok, Map.merge(template, Map.new(projected_fields))}
    end
  end

  defp do_project(value, boundary, contract, path) when is_map(value) and not is_struct(value) do
    value
    |> Enum.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{key, item}, index}, {:ok, acc} ->
      with {:ok, projected_key} <-
             project_map_key(key, boundary, child(path, {:map_key, index})),
           {:ok, projected_item} <-
             do_project(
               item,
               boundary,
               map_value_contract(contract, key),
               child(path, {:map_value, index})
             ) do
        {:cont, {:ok, [{projected_key, projected_item} | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} ->
        projected = Map.new(pairs)

        if map_size(projected) == length(pairs),
          do: {:ok, projected},
          else: {:error, {:java_projection_collision, path, :map}}

      {:error, _reason} = error ->
        error
    end
  end

  defp do_project(value, _boundary, _contract, _path), do: {:ok, value}

  defp project_map_key(key, boundary, path) do
    with {:ok, projected} <- do_project(key, boundary, nil, path) do
      if boundary == :tool_argument,
        do: {:ok, stringify_tool_key(projected)},
        else: {:ok, projected}
    end
  end

  defp stringify_tool_key(%LispKeyword{name: name}), do: KeyNormalizer.normalize_key(name)
  defp stringify_tool_key(key) when is_atom(key), do: KeyNormalizer.normalize_key(key)
  defp stringify_tool_key(key) when is_binary(key), do: KeyNormalizer.normalize_key(key)
  defp stringify_tool_key(key), do: inspect(key)

  defp struct_template(module, path) do
    case module.__struct__() do
      %{__struct__: ^module} = template -> {:ok, template}
      _invalid -> {:error, {:invalid_projection_struct, path, module}}
    end
  rescue
    _exception -> {:error, {:invalid_projection_struct, path, module}}
  catch
    _kind, _reason -> {:error, {:invalid_projection_struct, path, module}}
  end

  defp validate_struct_fields(fields, template, module, path) do
    actual_fields = fields |> Map.keys() |> MapSet.new()
    valid_fields = template |> Map.delete(:__struct__) |> Map.keys() |> MapSet.new()

    if MapSet.equal?(actual_fields, valid_fields),
      do: :ok,
      else: {:error, {:invalid_projection_struct, path, module}}
  end

  defp project_struct_fields(fields, boundary, contract, path) do
    Enum.reduce_while(fields, {:ok, []}, fn {field, item}, {:ok, acc} ->
      field_contract = map_value_contract(contract, field)

      case do_project(item, boundary, field_contract, child(path, {:struct_field, field})) do
        {:ok, projected} -> {:cont, {:ok, [{field, projected} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp project_list(values, boundary, contract, path, collection) do
    item_contract = list_item_contract(contract)

    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      segment = {collection, index}

      case do_project(value, boundary, item_contract, child(path, segment)) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_contract(value, :tool_argument, contract) when is_binary(contract) do
    if contains_valid_java_value?(value), do: parse_contract(contract), else: {:ok, nil}
  end

  defp prepare_contract(_value, _boundary, contract), do: {:ok, contract}

  defp parse_contract(contract) do
    case Signature.parse(contract) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, message} -> {:error, {:invalid_java_tool_contract, message}}
    end
  end

  defp contains_valid_java_value?(%Primitive{} = primitive), do: Primitive.valid?(primitive)
  defp contains_valid_java_value?(%LocalDate{} = value), do: LocalDate.valid?(value)
  defp contains_valid_java_value?(%Instant{} = value), do: Instant.valid?(value)
  defp contains_valid_java_value?(%Duration{} = value), do: Duration.valid?(value)
  defp contains_valid_java_value?(%JavaDate{} = value), do: JavaDate.valid?(value)

  defp contains_valid_java_value?(%MapSet{} = set),
    do: Enum.any?(set, &contains_valid_java_value?/1)

  defp contains_valid_java_value?(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> Map.values()
    |> Enum.any?(&contains_valid_java_value?/1)
  end

  defp contains_valid_java_value?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      contains_valid_java_value?(key) or contains_valid_java_value?(item)
    end)
  end

  defp contains_valid_java_value?(value) when is_list(value),
    do: Enum.any?(value, &contains_valid_java_value?/1)

  defp contains_valid_java_value?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&contains_valid_java_value?/1)

  defp contains_valid_java_value?(_value), do: false

  defp project_tool_primitive(_primitive, value, contract, _path)
       when contract in [nil, :any],
       do: {:ok, value}

  defp project_tool_primitive(_primitive, value, :int, _path) when is_integer(value),
    do: {:ok, value}

  defp project_tool_primitive(_primitive, value, :float, _path)
       when is_integer(value) or is_float(value),
       do: {:ok, value}

  defp project_tool_primitive(primitive, _value, _contract, path),
    do: {:error, {:unsupported_java_boundary_value, path, :tool_argument, primitive.kind}}

  defp project_object(value, module, profile, boundary, contract, path) do
    if module.valid?(value) do
      case boundary do
        :native ->
          {:ok, value}

        :continuation ->
          {:ok, value}

        boundary when boundary in [:public, :kernel_json] ->
          {:ok, module.canonical(value)}

        :tool_argument ->
          project_tool_object(value, module, profile, unwrap_optional(contract), path)

        :tool_result ->
          {:error, {:unsupported_java_boundary_value, path, boundary, profile}}
      end
    else
      {:error, {:invalid_java_value, path, profile}}
    end
  end

  defp project_tool_object(value, module, _profile, contract, _path)
       when contract in [nil, :any, :string],
       do: {:ok, module.canonical(value)}

  defp project_tool_object(value, module, profile, :datetime, path)
       when module in [Instant, JavaDate] do
    case module.to_datetime(value) do
      {:ok, datetime} -> {:ok, datetime}
      :error -> {:error, {:inexact_java_boundary_conversion, path, :tool_argument, profile}}
    end
  end

  defp project_tool_object(_value, _module, profile, _contract, path),
    do: {:error, {:unsupported_java_boundary_value, path, :tool_argument, profile}}

  defp object_profile(LocalDate), do: :local_date
  defp object_profile(Instant), do: :instant
  defp object_profile(Duration), do: :duration
  defp object_profile(JavaDate), do: :date

  defp map_value_contract({:optional, contract}, key),
    do: map_value_contract(contract, key)

  defp map_value_contract({:signature, fields, _return_type}, key),
    do: find_field_contract(fields, key)

  defp map_value_contract({kind, fields}, key) when kind in [:map, :closed_map],
    do: find_field_contract(fields, key)

  defp map_value_contract(:map, _key), do: :any

  defp map_value_contract(contract, _key), do: contract

  defp find_field_contract(fields, key) do
    key_name = contract_key_name(key)

    case Enum.find(fields, fn {name, _type} -> KeyNormalizer.normalize_key(name) == key_name end) do
      {_name, type} -> type
      nil -> :any
    end
  end

  defp contract_key_name(%LispKeyword{name: name}), do: KeyNormalizer.normalize_key(name)

  defp contract_key_name(key) when is_atom(key) or is_binary(key),
    do: KeyNormalizer.normalize_key(key)

  defp contract_key_name(_key), do: nil

  defp list_item_contract({:optional, contract}), do: list_item_contract(contract)
  defp list_item_contract({:list, item_contract}), do: item_contract
  defp list_item_contract(contract), do: contract

  defp unwrap_optional({:optional, contract}), do: unwrap_optional(contract)
  defp unwrap_optional(contract), do: contract

  defp child(path, segment), do: Enum.take(path ++ [segment], 32)
end
