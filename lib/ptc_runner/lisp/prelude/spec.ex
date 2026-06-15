defmodule PtcRunner.Lisp.Prelude.Spec do
  @moduledoc """
  Internal raw-definition spec gathered by
  `PtcRunner.Lisp.Prelude.Compiler` during its AST walk, before
  host-boundary `%PtcRunner.Lisp.Prelude.Export{}` records are built and
  before the callable private env is captured.

  Not part of the public prelude artifact — it carries the raw parser forms
  (`params_form`, `body_form`) that the compiler needs to both build export
  metadata and reconstruct definition forms for env capture (fact #6).

  `metadata_form` is the **raw** `{:map, pairs}` parser node captured from a
  `defn`/`defn-` before `normalize_meta/1` flattens it into the (lossy,
  order-destroying) `metadata` map. It exists so `source` discovery can render
  the author's metadata Formatter-faithfully with original key order; `metadata`
  (normalized) still drives everything else. Always `nil` for constants — `(def
  ...)` carries no metadata syntax.
  """

  @type t :: %__MODULE__{
          namespace: String.t(),
          symbol: String.t(),
          private?: boolean(),
          arity: non_neg_integer() | :variadic,
          doc: String.t() | nil,
          metadata: map(),
          metadata_form: {:map, [term()]} | nil,
          params_form: term() | nil,
          body_form: [term()]
        }

  @enforce_keys [:namespace, :symbol, :private?, :arity, :doc, :metadata, :body_form]
  defstruct namespace: nil,
            symbol: nil,
            private?: false,
            arity: nil,
            doc: nil,
            metadata: %{},
            metadata_form: nil,
            params_form: nil,
            body_form: []
end
