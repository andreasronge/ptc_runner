unless System.get_env("PTC_LLM_HTTP_PATH"),
  do: raise("set PTC_LLM_HTTP_PATH to the tested pilot checkout")

Code.require_file("../../../test/support/mcp_http_fixture.ex", __DIR__)
Code.require_file("../../../test/support/test_helpers.ex", __DIR__)
Code.require_file("../../../test/support/run_lifecycle.ex", __DIR__)
Code.require_file("../../../test/support/eventually.ex", __DIR__)
Code.require_file("support/http_adapter.exs", __DIR__)
Code.require_file("support/workflow_probe.exs", __DIR__)
Code.require_file("support/baseline.exs", __DIR__)
Code.require_file("support/serving_host.exs", __DIR__)
Code.require_file("support/comparison_test.exs", __DIR__)
