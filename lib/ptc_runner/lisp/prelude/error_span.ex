defmodule PtcRunner.Lisp.Prelude.ErrorSpan do
  @moduledoc ~S"""
  Resolves a `%PtcRunner.Lisp.Prelude.ValidationError{}` to the byte span of
  the top-level form it blames.

  `PtcRunner.Lisp.Prelude.Compiler` walks PARSED forms, which carry no source
  positions; `PtcRunner.Lisp.Prelude.FormScanner` walks the RAW TEXT and
  carries nothing else. This module is the single seam between them, applied
  once at the compile boundary so no error site has to know about byte offsets.

  ## How a failure is located

  In order of precision, using whichever locator the error already carries:

    1. `form_index` — the position of the top-level form the compiler was
       processing. `FormScanner.scan/1` cross-checks its own form list against
       `PtcRunner.Lisp.Parser` head-by-head and refuses to return at all on any
       disagreement, so a successful scan is positionally aligned with the
       parsed forms the compiler walked. That check is what makes indexing by
       position safe.
    2. `ref` (`"namespace/symbol"`) — for failures raised after the walk, when
       only the offending definition is known. Resolved to the first `def`,
       `defn`, or `defn-` form with that name under that namespace.
    3. `namespace` — resolved to the `(ns ...)` form that declares it.

  Resolution is best-effort and always fails OPEN to `nil`: a source this
  module cannot scan, an out-of-range index, or an unresolvable name leaves
  the error exactly as it was. A diagnostic without a span is the status quo;
  a diagnostic with a WRONG span would point a reader at innocent code.
  """

  alias PtcRunner.Lisp.Prelude.FormScanner
  alias PtcRunner.Lisp.Prelude.ValidationError

  @naming_heads ["def", "defn", "defn-"]

  @doc """
  Returns `error` with `span` filled in when the offending top-level form can
  be located in `source`, and unchanged otherwise.
  """
  @spec resolve(ValidationError.t(), binary()) :: ValidationError.t()
  def resolve(%ValidationError{} = error, source) when is_binary(source) do
    if locatable?(error) do
      case FormScanner.scan(source) do
        {:ok, %{forms: forms}} -> %{error | span: locate(error, forms)}
        {:error, _reason} -> error
      end
    else
      error
    end
  end

  defp locatable?(%ValidationError{form_index: index, ref: ref, namespace: namespace}),
    do: not is_nil(index) or not is_nil(ref) or not is_nil(namespace)

  defp locate(%ValidationError{form_index: index}, forms) when is_integer(index) do
    case Enum.at(forms, index) do
      %{span: span} -> span
      nil -> nil
    end
  end

  defp locate(%ValidationError{ref: ref, namespace: namespace}, forms) do
    case split_ref(ref) do
      {ref_namespace, symbol} -> definition_span(forms, ref_namespace, symbol)
      nil -> namespace_span(forms, namespace)
    end
  end

  # A ref is always built as "namespace/symbol", and neither part can itself
  # contain a "/" — a qualified symbol is not a legal definition name.
  defp split_ref(ref) when is_binary(ref) do
    case String.split(ref, "/") do
      [namespace, symbol] when namespace != "" and symbol != "" -> {namespace, symbol}
      _other -> nil
    end
  end

  defp split_ref(_ref), do: nil

  # Definitions belong to the namespace opened by the closest preceding
  # `(ns ...)` form, mirroring the compiler's `current_ns` walk.
  defp definition_span(forms, namespace, symbol) do
    forms
    |> Enum.reduce_while(nil, fn form, current_ns ->
      cond do
        form.head == "ns" -> {:cont, form.name}
        current_ns == namespace and definition?(form, symbol) -> {:halt, form.span}
        true -> {:cont, current_ns}
      end
    end)
    |> case do
      {_offset, _length} = span -> span
      _unresolved -> nil
    end
  end

  defp definition?(%{head: head, name: name}, symbol),
    do: head in @naming_heads and name == symbol

  defp namespace_span(_forms, nil), do: nil

  defp namespace_span(forms, namespace) do
    case Enum.find(forms, &(&1.head == "ns" and &1.name == namespace)) do
      %{span: span} -> span
      nil -> nil
    end
  end
end
