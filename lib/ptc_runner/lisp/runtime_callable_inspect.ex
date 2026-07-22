defimpl Inspect, for: PtcRunner.Lisp.RuntimeCallable do
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext

  @tool_name ~r|\A[a-z][a-z0-9._/-]{0,127}\z|

  def inspect(callable, _opts) do
    "#PtcRunner.Lisp.RuntimeCallable<label: #{safe_label(callable)}, " <>
      "bound?: #{bound?(callable)}>"
  end

  defp safe_label(%{namespace: :tool, name: name}) when is_atom(name),
    do: safe_tool_label(Atom.to_string(name))

  defp safe_label(%{namespace: :tool, name: name}) when is_binary(name),
    do: safe_tool_label(name)

  defp safe_label(_callable), do: "invalid"

  defp safe_tool_label(name) do
    if byte_size(name) in 1..128 and String.valid?(name) and name =~ @tool_name,
      do: "tool/" <> name,
      else: "invalid"
  end

  defp bound?(%{eval_ctx: %EvalContext{}, do_eval: do_eval}) when is_function(do_eval, 2),
    do: true

  defp bound?(_callable), do: false
end
