defmodule PtcRunnerMcp.Http.AuthClaims do
  @moduledoc false

  @marker :erlang.unique_integer([:positive])

  @enforce_keys [:subject_id, :subject_hash, :allowed_roles, :marker]
  defstruct [:subject_id, :subject_hash, :allowed_roles, :marker]

  @type t :: %__MODULE__{
          subject_id: String.t(),
          subject_hash: String.t(),
          allowed_roles: [String.t()],
          marker: integer()
        }

  @spec new(String.t(), String.t(), [String.t()]) :: t()
  def new(subject_id, subject_hash, allowed_roles)
      when is_binary(subject_id) and is_binary(subject_hash) and is_list(allowed_roles) do
    %__MODULE__{
      subject_id: subject_id,
      subject_hash: subject_hash,
      allowed_roles: allowed_roles,
      marker: @marker
    }
  end

  @spec trusted?(term()) :: boolean()
  def trusted?(%__MODULE__{marker: @marker}), do: true
  def trusted?(_claims), do: false
end
