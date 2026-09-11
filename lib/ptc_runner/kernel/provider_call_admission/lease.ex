defmodule PtcRunner.Kernel.ProviderCallAdmission.Lease do
  @moduledoc """
  Opaque single-use lease granted to one provider-call guardian.

  Lease values are created and consumed only by
  `PtcRunner.Kernel.ProviderCallAdmission`; callers must not inspect or alter
  their representation.
  """

  alias PtcRunner.Kernel.ProviderCallAdmission

  @enforce_keys [:admission, :reference, :owner, :completion]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            admission: ProviderCallAdmission.t(),
            reference: reference(),
            owner: pid(),
            completion: :atomics.atomics_ref()
          }
end
