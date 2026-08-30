defmodule PtcRunner.Lisp.EvaluatorErrorCatalog do
  @moduledoc """
  Closed public catalog of PTC-Lisp evaluator error kinds.

  These kinds may appear in a V4 command envelope's `last_evaluation_error`
  object. The catalog is the single owner of the wire names, schema enum, and
  REPL kind spelling. Compilation, timeout, and memory failures stay on their
  existing command codes and are not members of this table.
  """

  @kinds [
    :arithmetic_error,
    :arity_error,
    :not_callable,
    :loop_limit_exceeded,
    :unsupported_java_class,
    :unsupported_java_member,
    :java_arity_error,
    :java_type_error,
    :java_domain_error,
    :invalid_java_string,
    :java_handler_contract_error
  ]

  @wire_names Enum.map(@kinds, &Atom.to_string/1)

  @descriptions %{
    arithmetic_error: "Arithmetic operation error (for example integer division by zero)",
    arity_error: "Wrong number of arguments to a function or builtin",
    not_callable: "Attempt to call a non-callable value",
    loop_limit_exceeded: "loop/recur iteration limit exceeded",
    unsupported_java_class: "Java class is outside the admitted interop surface",
    unsupported_java_member: "Java member is outside the admitted interop surface",
    java_arity_error: "Java member called with an arity that matches no admitted overload",
    java_type_error: "Java member argument does not match an admitted overload",
    java_domain_error: "Java member rejected an admitted argument for a domain reason",
    invalid_java_string: "Java string argument is not valid UTF-8",
    java_handler_contract_error: "Java handler violated its closed contract"
  }

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @spec kind?(term()) :: boolean()
  def kind?(kind), do: kind in @kinds

  @spec wire_names() :: [binary()]
  def wire_names, do: @wire_names

  @spec wire_name(atom()) :: {:ok, binary()} | :error
  def wire_name(kind) when kind in @kinds, do: {:ok, Atom.to_string(kind)}
  def wire_name(_kind), do: :error

  @spec description(atom()) :: {:ok, binary()} | :error
  def description(kind), do: Map.fetch(@descriptions, kind)
end
