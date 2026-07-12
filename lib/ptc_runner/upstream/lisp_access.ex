defimpl PtcRunner.Lisp.UpstreamAccess, for: PtcRunner.Upstream.Runtime do
  alias PtcRunner.Upstream.Runtime

  def tool_grants(runtime), do: Runtime.upstream_tool_grants(runtime)
  def constrain(runtime, grants), do: Runtime.constrain_upstream_tool_grants(runtime, grants)
  def upstream(runtime, server), do: Runtime.upstream(runtime, server)
end
