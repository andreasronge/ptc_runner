defmodule PtcRunner.Test.MCPOAuthUnloadedStore do
  @moduledoc false

  alias PtcRunner.Kernel.MCPOAuth.Store

  @behaviour Store

  @impl Store
  def local_fence(_state, _operation), do: {:error, :authorization_required}

  @impl Store
  def transact(_state, _operation, _deadline), do: {:error, :unsupported}
end
