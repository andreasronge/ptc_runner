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
       only the offending definition is known. Resolved to the `def`, `defn`,
       or `defn-` form with that name under that namespace, but only when
       exactly one form matches: a name is unique only once duplicates have
       been rejected, and some ref-carrying failures are raised before that
       check runs. `:duplicate_ref` is the one exception, because it IS the
       duplicate report — it resolves to the last matching form, the
       redefinition that collided.
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

  # `Enum.at/2` counts a negative index from the END of the list, which would
  # turn a nonsense index into a valid-looking span for an unrelated form.
  defp locate(%ValidationError{form_index: index}, forms) when is_integer(index) and index >= 0 do
    case Enum.at(forms, index) do
      %{span: span} -> span
      nil -> nil
    end
  end

  defp locate(%ValidationError{form_index: index}, _forms) when is_integer(index), do: nil

  defp locate(%ValidationError{reason: reason, ref: ref, namespace: namespace}, forms) do
    case split_ref(ref) do
      {ref_namespace, symbol} -> definition_span(reason, forms, ref_namespace, symbol)
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

  # A ref names a definition, and a name is only unique once the compiler has
  # rejected duplicates — a check that runs AFTER some ref-carrying failures.
  # So resolve a ref only when it matches exactly one definition. The one
  # exception is the duplicate itself: `:duplicate_ref` exists precisely
  # because the name was redefined, and the redefinition is the later form.
  defp definition_span(reason, forms, namespace, symbol) do
    case definition_spans(forms, namespace, symbol) do
      [span] -> span
      [_first | _rest] = spans when reason == :duplicate_ref -> List.last(spans)
      _ambiguous_or_missing -> nil
    end
  end

  # Definitions belong to the namespace opened by the closest preceding
  # `(ns ...)` form, mirroring the compiler's `current_ns` walk.
  defp definition_spans(forms, namespace, symbol) do
    forms
    |> Enum.reduce({nil, []}, fn form, {current_ns, spans} ->
      cond do
        form.head == "ns" -> {form.name, spans}
        current_ns == namespace and definition?(form, symbol) -> {current_ns, [form.span | spans]}
        true -> {current_ns, spans}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
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
