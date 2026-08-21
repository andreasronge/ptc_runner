if Code.ensure_loaded?(PtcRunner.LLM.PtcLlmHttpPreparedModel) do
  defimpl Inspect, for: PtcRunner.LLM.PtcLlmHttpPreparedModel do
    def inspect(_prepared, _opts), do: "#PtcRunner.LLM.PtcLlmHttpPreparedModel<redacted>"
  end
end
