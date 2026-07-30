defimpl Inspect, for: PtcRunner.Kernel.MCPOAuth.PendingAuthorization do
  import Inspect.Algebra

  def inspect(_pending, _opts),
    do: concat(["#PtcRunner.MCPOAuth.PendingAuthorization<redacted>"])
end
