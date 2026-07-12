defimpl PtcRunner.Lisp.UpstreamAccess, for: Atom do
  alias PtcRunner.Lisp.UpstreamGrants
  alias PtcRunner.Upstream.Runtime

  def tool_grants(nil), do: :all
  def tool_grants(runtime), do: Runtime.upstream_tool_grants(runtime)

  def constrain(nil, grants), do: UpstreamGrants.normalize(grants)
  def constrain(runtime, grants), do: Runtime.constrain_upstream_tool_grants(runtime, grants)

  def upstream(nil, _server), do: nil
  def upstream(runtime, server), do: Runtime.upstream(runtime, server)
end
