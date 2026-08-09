defmodule PtcRunner.Kernel.OwnerHandoff do
  @moduledoc false

  @spec transfer_once(map(), pid()) :: {:ok, map()} | :error
  def transfer_once(
        %{owner_ref: owner_ref, owner_transferable?: true} = state,
        owner
      )
      when is_reference(owner_ref) and is_pid(owner) do
    if Process.alive?(owner) do
      Process.demonitor(owner_ref, [:flush])

      {:ok,
       %{
         state
         | owner: owner,
           owner_ref: Process.monitor(owner),
           owner_transferable?: false
       }}
    else
      :error
    end
  end
end
