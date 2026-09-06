Code.require_file("support/preflight.exs", __DIR__)
Code.require_file("../../../test/support/mcp_http_fixture.ex", __DIR__)
Code.require_file("../../../test/support/test_helpers.ex", __DIR__)
Code.require_file("support/baseline.exs", __DIR__)

Logger.configure(level: :critical)
report = PtcRunner.Labs.LLMTransportBaseline.run()
json = Jason.encode!(report, pretty: true)

case System.argv() do
  [] -> IO.puts(json)
  [output] -> File.write!(output, json <> "\n")
  _ -> raise "usage: mix run scripts/labs/llm-transport/run.exs [REPORT_JSON]"
end
