defmodule PtcRunner.Lisp.Prelude.ValidationError do
  @moduledoc """
  Compile-time validation failure for a deployment prelude.

  Returned as `{:error, %ValidationError{}}` from
  `PtcRunner.Lisp.Prelude.Compiler.compile/1` when the prelude SOURCE is
  malformed in a way that does not depend on a selected runtime (parse
  errors, reserved-namespace declarations, duplicate refs, bad visibility,
  invalid arity/signature metadata, and similar facts), and from
  `PtcRunner.Lisp.Prelude.Attach.validate_requires/2` with the
  `:prelude_attach_failed` reason when a public export requires a tool
  operation the selected runtime does not provide.

  ## Fields

    * `reason` — a stable, matchable atom. Compile-time reasons:
      `:reserved_namespace`, `:duplicate_ref`,
      `:invalid_visibility`, `:invalid_requires`, `:invalid_metadata`,
      `:qualified_self_reference`, `:missing_namespace`, `:invalid_namespace`,
      `:invalid_signature`, `:parse_error`, `:compile_error`,
      `:unrecognized_node`. Dependency
      reasons (declared prelude-to-prelude deps): `:unknown_dependency`,
      `:dep_ref_in_def`, `:dependency_cycle`. Attach-time reason:
      `:prelude_attach_failed`.
    * `message` — human-readable detail naming the offending namespace,
      symbol, or value. Must not contain secrets.
    * `namespace` — the declaring namespace when known, else `nil`.
    * `ref` — the offending export ref when known, else `nil`.
    * `form_index` — zero-based position of the offending TOP-LEVEL form in
      the compiled source, when the failure belongs to one form, else `nil`.
      The top-level walk records it directly on walk failures and carries it on
      definition specs for later validation phases.
    * `span` — `{offset, length}` byte span of that offending top-level form
      in the compiled source, or `nil` when the failure cannot be attributed
      to one form (parse errors, whole-bundle failures). Resolved once, at the
      compile boundary, by `PtcRunner.Lisp.Prelude.ErrorSpan`. Bundle
      compilation resolves it in a separate bounded worker so optional
      attribution cannot change the primary compile result.
  """

  @type reason ::
          :reserved_namespace
          | :duplicate_ref
          | :invalid_visibility
          | :invalid_requires
          | :invalid_metadata
          | :qualified_self_reference
          | :missing_namespace
          | :invalid_namespace
          | :invalid_signature
          | :parse_error
          | :compile_error
          | :unrecognized_node
          | :unknown_dependency
          | :dep_ref_in_def
          | :dependency_cycle
          | :prelude_attach_failed

  @type byte_span :: {non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          namespace: String.t() | nil,
          ref: String.t() | nil,
          form_index: non_neg_integer() | nil,
          span: byte_span() | nil
        }

  @enforce_keys [:reason, :message]
  defstruct reason: nil,
            message: nil,
            namespace: nil,
            ref: nil,
            form_index: nil,
            span: nil

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
