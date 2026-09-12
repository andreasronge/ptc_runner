defmodule PtcRunner.Kernel.ServingOutcome do
  @moduledoc """
  Closed public result of a provider-free serving call.

  `code(outcome)` returns exactly one of `:success`, `:invalid_input`,
  `:execution_failed`, `:invalid_result`, `:cancelled`, `:busy`,
  `:admission_unavailable`, `:publication_failed`, `:cleanup_failed`, or
  `:internal_error`. `value(outcome)` returns `{:ok, json_object}` only for
  success and `:error` otherwise. Objects are validated by the frozen result
  contract; `encode(outcome)` returns deterministic JSON for a successful value
  and `:error` otherwise.

  `metadata(outcome)` returns only `dispatched: true | false | :unknown` and
  `write_effects_possible: boolean`. Unknown means the session failed without
  proof of dispatch or its absence. A write declaration with dispatched or
  unknown execution conservatively reports possible writes even on failure.
  Refusal before execution-owner transfer reports false. Admission loss after
  activation reports unknown, including when cleanup failure becomes the final
  code: losing admission never proves that writes were absent.
  No reason, input, path, event, usage, credential or diagnostic is returned.
  Non-success outcomes retain no result value.

  Precedence, highest first: uncertain cleanup (which fences admission),
  cancellation/deadline, publication or sink failure, internal/session failure,
  invalid/oversized result, execution failure, success. Before activation,
  invalid input wins over deadline/admission refusal; deadline wins over busy
  or unavailable admission. Busy and unavailable are mutually exclusive atomic
  admission decisions. No outcome claims that cancellation rolled back writes.
  Construction failures are the separate atom-only ServingTemplate build surface.
  """
  alias PtcRunner.Kernel.DeterministicJSON
  @enforce_keys [:code, :value, :dispatched, :write_effects_possible]
  defstruct @enforce_keys

  @type code ::
          :success
          | :invalid_input
          | :execution_failed
          | :invalid_result
          | :cancelled
          | :busy
          | :admission_unavailable
          | :publication_failed
          | :cleanup_failed
          | :internal_error
  @opaque t :: %__MODULE__{
            code: code(),
            value: map() | nil,
            dispatched: boolean() | :unknown,
            write_effects_possible: boolean()
          }

  @doc false
  @spec new(code(), boolean() | :unknown, :read | :write, map() | nil) :: t()
  def new(code, dispatched, effect, value \\ nil) do
    %__MODULE__{
      code: code,
      value: if(code == :success, do: value),
      dispatched: dispatched,
      write_effects_possible: effect == :write and dispatched != false
    }
  end

  @spec code(t()) :: code()
  def code(%__MODULE__{code: code}), do: code

  @spec value(t()) :: {:ok, map()} | :error
  def value(%__MODULE__{code: :success, value: value}), do: {:ok, value}
  def value(%__MODULE__{}), do: :error

  @spec metadata(t()) :: %{dispatched: boolean() | :unknown, write_effects_possible: boolean()}
  def metadata(%__MODULE__{} = outcome),
    do: Map.take(outcome, [:dispatched, :write_effects_possible])

  @spec encode(t()) :: {:ok, binary()} | :error
  def encode(%__MODULE__{code: :success, value: value}),
    do: DeterministicJSON.encode(value)

  def encode(%__MODULE__{}), do: :error
end
