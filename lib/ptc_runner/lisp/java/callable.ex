defmodule PtcRunner.Lisp.Java.Callable do
  @moduledoc """
  Native, closed reference to one admitted Java member.

  It carries no host function or open member name. Invocation always resolves
  the stable reference through `PtcRunner.Lisp.Java.Dispatch`.
  """

  alias PtcRunner.Lisp.Java.Condition
  alias PtcRunner.Lisp.Java.Dispatch
  alias PtcRunner.Lisp.Java.Surface

  @enforce_keys [:reference_id]
  defstruct [:reference_id]

  @type t :: %__MODULE__{reference_id: atom()}

  @spec new(atom()) :: {:ok, t()} | :error
  def new(reference_id) when is_atom(reference_id) do
    case Surface.fetch_reference(reference_id) do
      {:ok, %{callable?: true}} ->
        {:ok, %__MODULE__{reference_id: reference_id}}

      _ ->
        :error
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{reference_id: reference_id} = callable) do
    map_size(callable) == 2 and
      match?({:ok, %{callable?: true}}, Surface.fetch_reference(reference_id))
  end

  def valid?(_), do: false

  @doc "Invokes a first-class Java reference using its manifest-declared invocation kind."
  @spec invoke(term(), [term()]) :: Dispatch.result()
  def invoke(%__MODULE__{reference_id: reference_id} = callable, arguments)
      when is_list(arguments) do
    with true <- valid?(callable),
         {:ok, reference} <- Surface.fetch_reference(reference_id) do
      invoke_reference(reference, arguments)
    else
      _invalid ->
        {:error,
         Condition.new(
           :unsupported_java_member,
           reference_id,
           nil,
           "unsupported Java callable reference"
         )}
    end
  end

  def invoke(%{__struct__: __MODULE__} = callable, arguments) when is_list(arguments) do
    reference_id = Map.get(callable, :reference_id)

    {:error,
     Condition.new(
       :unsupported_java_member,
       reference_id,
       nil,
       "unsupported Java callable reference"
     )}
  end

  defp invoke_reference(%{kind: :static, reference_id: reference_id}, arguments),
    do: Dispatch.invoke(reference_id, :static, nil, arguments)

  defp invoke_reference(%{kind: :constructor, reference_id: reference_id}, arguments),
    do: Dispatch.invoke(reference_id, :constructor, nil, arguments)

  defp invoke_reference(%{kind: :instance, reference_id: reference_id}, [receiver | arguments]),
    do: Dispatch.invoke(reference_id, :instance, receiver, arguments)

  defp invoke_reference(%{reference_id: reference_id}, arguments) do
    {:error,
     Condition.new(
       :java_arity_error,
       reference_id,
       nil,
       "Java instance callable requires a receiver",
       %{actual: length(arguments), receiver_required?: true}
     )}
  end
end
