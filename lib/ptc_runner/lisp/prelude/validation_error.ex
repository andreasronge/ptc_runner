defmodule PtcRunner.Lisp.Prelude.ValidationError do
  @moduledoc """
  Compile-time validation failure for a deployment prelude (Capability
  Prelude V1, plan §3 / §10).

  Returned as `{:error, %ValidationError{}}` from
  `PtcRunner.Lisp.Prelude.Compiler.compile/1` when the prelude SOURCE is
  malformed in a way that does not depend on a selected runtime (parse
  errors, reserved-namespace declarations, duplicate refs, bad visibility,
  invalid arity/signature metadata, and similar facts), and from
  `PtcRunner.Lisp.Prelude.Attach.validate_requires/2` with the
  `:prelude_attach_failed` reason when a public export `requires` an upstream
  operation the selected runtime does not provide (plan §3 / §6A).

  ## Fields

    * `reason` — a stable, matchable atom. Compile-time reasons:
      `:reserved_namespace`, `:reserved_name`, `:duplicate_ref`,
      `:invalid_visibility`, `:invalid_requires`, `:invalid_metadata`,
      `:missing_namespace`, `:invalid_namespace`, `:invalid_signature`,
      `:parse_error`, `:compile_error`. Attach-time reason:
      `:prelude_attach_failed`.
    * `message` — human-readable detail naming the offending namespace,
      symbol, or value. Must not contain secrets (plan §12).
    * `namespace` — the declaring namespace when known, else `nil`.
    * `ref` — the offending export ref when known, else `nil`.
  """

  @type reason ::
          :reserved_namespace
          | :reserved_name
          | :duplicate_ref
          | :invalid_visibility
          | :invalid_requires
          | :invalid_metadata
          | :missing_namespace
          | :invalid_namespace
          | :invalid_signature
          | :parse_error
          | :compile_error
          | :prelude_attach_failed

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          namespace: String.t() | nil,
          ref: String.t() | nil
        }

  @enforce_keys [:reason, :message]
  defstruct reason: nil, message: nil, namespace: nil, ref: nil

  @doc "Builds a validation error."
  @spec new(reason(), String.t(), keyword()) :: t()
  def new(reason, message, opts \\ []) do
    %__MODULE__{
      reason: reason,
      message: message,
      namespace: Keyword.get(opts, :namespace),
      ref: Keyword.get(opts, :ref)
    }
  end
end
