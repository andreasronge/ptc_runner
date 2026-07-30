defimpl Inspect, for: PtcRunner.Kernel.MCPOAuth.Context do
  import Inspect.Algebra

  def inspect(_context, _opts), do: concat(["#PtcRunner.MCPOAuth.Context<redacted>"])
end
