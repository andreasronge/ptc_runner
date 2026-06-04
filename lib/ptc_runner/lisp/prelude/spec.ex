defmodule PtcRunner.Lisp.Prelude.Spec do
  @moduledoc """
  Internal raw-definition spec gathered by
  `PtcRunner.Lisp.Prelude.Compiler` during its AST walk, before
  host-boundary `%PtcRunner.Lisp.Prelude.Export{}` records are built and
  before the callable private env is captured.

  Not part of the public prelude artifact — it carries the raw parser forms
  (`params_form`, `body_form`) that the compiler needs to both build export
  metadata and reconstruct definition forms for env capture (fact #6).
  """

  @type t :: %__MODULE__{
          namespace: String.t(),
          symbol: String.t(),
          private?: boolean(),
          arity: non_neg_integer() | :variadic,
          doc: String.t() | nil,
          metadata: map(),
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
            params_form: nil,
            body_form: []
end
