defmodule PtcRunner.Test.MCPOAuthUnloadedStore do
  @moduledoc false

  alias PtcRunner.Kernel.MCPOAuth.Store

  @behaviour Store

  @impl Store
  def transact(_state, _operation, _timeout), do: {:error, :unsupported}
end
