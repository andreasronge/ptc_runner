defimpl Inspect, for: PtcRunner.Kernel.MCPOAuth.TokenManager do
  import Inspect.Algebra

  def inspect(_manager, _opts),
    do: concat(["#PtcRunner.MCPOAuth.TokenManager<redacted>"])
end
