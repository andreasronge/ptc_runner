defmodule PtcRunner.SubAgent.Signature.TypeResolver do
  @moduledoc """
  Resolve paths against parsed signature types.

  Given a parsed signature and a path (like ["items", "name"]), determines the expected
  type at that path. Used for validating section fields in Mustache templates.
  """

  @doc """
  Resolve a path to its expected type from a parsed signature.

  Returns `{:ok, type}` if the path is valid, or `{:error, reason}` if not.

  ## Examples

      iex> sig = {:signature, [{"user", :string}], {:map, [{"result", :int}]}}
      iex> PtcRunner.SubAgent.Signature.TypeResolver.resolve_path(sig, ["user"])
      {:ok, :string}

      iex> sig = {:signature, [{"items", {:list, {:map, [{"name", :string}]}}}], :any}
      iex> PtcRunner.SubAgent.Signature.TypeResolver.resolve_path(sig, ["items"])
      {:ok, {:list, {:map, [{"name", :string}]}}}

  """
  @spec resolve_path({:signature, list(), term()}, [String.t()]) ::
          {:ok, term()} | {:error, term()}
  def resolve_path({:signature, params, _return_type}, [param_name]) do
    case find_param(params, param_name) do
      {:ok, type} -> {:ok, type}
      :not_found -> {:error, {:param_not_found, param_name}}
    end
  end

  def resolve_path({:signature, params, _return_type}, [param_name | rest]) do
    case find_param(params, param_name) do
      {:ok, type} -> resolve_nested_path(type, rest)
      :not_found -> {:error, {:param_not_found, param_name}}
    end
  end

  def resolve_path(_, []) do
    {:error, :empty_path}
  end

  @doc """
  Get the element type for a list parameter.

  Returns `{:ok, element_type}` if the parameter is a list, or `{:error, reason}` if not.

  ## Examples

      iex> sig = {:signature, [{"items", {:list, {:map, [{"name", :string}]}}}], :any}
      iex> PtcRunner.SubAgent.Signature.TypeResolver.list_element_type(sig, "items")
      {:ok, {:map, [{"name", :string}]}}

      iex> sig = {:signature, [{"tags", {:list, :string}}], :any}
      iex> PtcRunner.SubAgent.Signature.TypeResolver.list_element_type(sig, "tags")
      {:ok, :string}

      iex> sig = {:signature, [{"name", :string}], :any}
      iex> PtcRunner.SubAgent.Signature.TypeResolver.list_element_type(sig, "name")
      {:error, {:not_a_list, :string}}

  """
  @spec list_element_type({:signature, list(), term()}, String.t()) ::
          {:ok, term()} | {:error, term()}
  def list_element_type({:signature, params, _return_type}, param_name) do
    case find_param(params, param_name) do
      {:ok, {:list, element_type}} -> {:ok, element_type}
      {:ok, type} -> {:error, {:not_a_list, type}}
      :not_found -> {:error, {:param_not_found, param_name}}
    end
  end

  @doc """
  Check if a type is a scalar (can be used with {{.}} in sections).

  ## Examples

      iex> PtcRunner.SubAgent.Signature.TypeResolver.scalar_type?(:string)
      true

      iex> PtcRunner.SubAgent.Signature.TypeResolver.scalar_type?({:map, [{"x", :int}]})
      false

      iex> PtcRunner.SubAgent.Signature.TypeResolver.scalar_type?({:list, :string})
      false

  """
  @spec scalar_type?(term()) :: boolean()
  def scalar_type?(:string), do: true
  def scalar_type?(:int), do: true
  def scalar_type?(:float), do: true
  def scalar_type?(:bool), do: true
  def scalar_type?(:keyword), do: true
  def scalar_type?(:any), do: true
  def scalar_type?({:optional, inner}), do: scalar_type?(inner)
  def scalar_type?(_), do: false

  @doc """
  Check if a type is iterable (can be used with {{#section}}).

  ## Examples

      iex> PtcRunner.SubAgent.Signature.TypeResolver.iterable_type?({:list, :string})
      true

      iex> PtcRunner.SubAgent.Signature.TypeResolver.iterable_type?(:string)
      false

      iex> PtcRunner.SubAgent.Signature.TypeResolver.iterable_type?({:map, [{"x", :int}]})
      true

  """
  @spec iterable_type?(term()) :: boolean()
  def iterable_type?({:list, _}), do: true
  def iterable_type?({:map, _}), do: true
  def iterable_type?(:map), do: true
  def iterable_type?({:optional, inner}), do: iterable_type?(inner)
  def iterable_type?(_), do: false

  @doc """
  Get the fields of a map type.

  Returns `{:ok, fields}` where fields is a list of `{name, type}` tuples,
  or `{:error, reason}` if the type is not a map.

  ## Examples

      iex> PtcRunner.SubAgent.Signature.TypeResolver.map_fields({:map, [{"name", :string}, {"age", :int}]})
      {:ok, [{"name", :string}, {"age", :int}]}

      iex> PtcRunner.SubAgent.Signature.TypeResolver.map_fields(:string)
      {:error, {:not_a_map, :string}}

  """
  @spec map_fields(term()) :: {:ok, list()} | {:error, term()}
  def map_fields({:map, fields}), do: {:ok, fields}
  def map_fields({:optional, inner}), do: map_fields(inner)
  def map_fields(type), do: {:error, {:not_a_map, type}}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp find_param(params, name) do
    Enum.find_value(params, :not_found, fn
      {param_name, type} when param_name == name -> {:ok, type}
      _ -> nil
    end)
  end

  defp resolve_nested_path(type, []) do
    {:ok, type}
  end

  defp resolve_nested_path({:map, fields}, [field_name | rest]) do
    case find_param(fields, field_name) do
      {:ok, field_type} -> resolve_nested_path(field_type, rest)
      :not_found -> {:error, {:field_not_found, field_name}}
    end
  end

  defp resolve_nested_path({:list, element_type}, path) do
    # For list types, resolve within the element type
    resolve_nested_path(element_type, path)
  end

  defp resolve_nested_path({:optional, inner}, path) do
    resolve_nested_path(inner, path)
  end

  defp resolve_nested_path(type, [field_name | _]) do
    {:error, {:cannot_access_field, field_name, type}}
  end
end
