# `:soak` is excluded for the same reason the root suite excludes it: its
# signal is a slope measured over thousands of cycles, not a per-commit gate,
# and it measures VM-wide counters that a parallel suite would perturb. Run it
# with `mix soak` from this directory.
ExUnit.start(exclude: [:nightly, :soak])
Code.require_file("../support/conformance_proxy.exs", __DIR__)
Code.require_file("../support/gateway_fixture.exs", __DIR__)
Code.require_file("../support/gateway_load.exs", __DIR__)
Code.require_file("../../test/support/mcp_http_fixture.ex", __DIR__)
