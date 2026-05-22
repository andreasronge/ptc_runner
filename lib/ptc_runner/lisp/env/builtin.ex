defmodule PtcRunner.Lisp.Env.Builtin do
  @moduledoc """
  Metadata wrapper for callable environment builtins.

  Runtime-created callables still use the raw tuple shapes; this wrapper is for
  Env bindings where we know the public builtin name and validation contract.
  """

  defstruct [:name, :binding, args: :unchecked]

  @callable_tags [:normal, :variadic, :variadic_nonempty, :multi_arity, :collect]

  @type raw_binding ::
          {:normal, function()}
          | {:variadic, function(), term()}
          | {:variadic_nonempty, atom(), function()}
          | {:multi_arity, atom(), tuple()}
          | {:collect, function()}

  @type t :: %__MODULE__{name: atom(), binding: raw_binding(), args: term()}

  @spec wrap(atom(), raw_binding(), term()) :: t()
  def wrap(name, binding, args \\ :unchecked)
      when is_atom(name) and is_tuple(binding) do
    %__MODULE__{name: name, binding: binding, args: args}
  end

  @spec unwrap(t() | term()) :: term()
  def unwrap(%__MODULE__{binding: binding}), do: binding
  def unwrap(other), do: other

  @spec name(t() | term()) :: atom() | nil
  def name(%__MODULE__{name: name}), do: name
  def name({:variadic_nonempty, name, _}) when is_atom(name), do: name
  def name({:multi_arity, name, _}) when is_atom(name), do: name
  def name(_), do: nil

  @spec args(t() | term()) :: term()
  def args(%__MODULE__{args: args}), do: args
  def args(_), do: :unchecked

  @spec builtin?(term()) :: boolean()
  def builtin?(%__MODULE__{}), do: true
  def builtin?({tag, _}) when tag in [:normal, :collect], do: true
  def builtin?({tag, _, _}) when tag in @callable_tags, do: true
  def builtin?(_), do: false
end
