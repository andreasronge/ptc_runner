defmodule PtcRunner.Kernel.ProjectionError do
  @moduledoc false

  @lisp_value_errors [
    :invalid_keyword,
    :invalid_lisp_list,
    :invalid_symbol_ref,
    :symbol_ref_collision
  ]

  @java_errors [
    :inexact_java_boundary_conversion,
    :invalid_java_tool_contract,
    :invalid_java_value,
    :invalid_projection_list,
    :invalid_projection_struct,
    :java_projection_collision,
    :unsupported_java_boundary_value
  ]

  @spec kind(term()) :: atom()
  def kind({:public_projection_collision, _path, _collection}),
    do: :public_projection_collision

  def kind({reason, _path}) when reason in @lisp_value_errors, do: reason
  def kind({reason, _path, _collection}) when reason in @lisp_value_errors, do: reason
  def kind({reason, _details}) when reason in @java_errors, do: :java_projection_error
  def kind({reason, _path, _details}) when reason in @java_errors, do: :java_projection_error

  def kind({reason, _path, _boundary, _details}) when reason in @java_errors,
    do: :java_projection_error

  def kind(_reason), do: :projection_error
end
