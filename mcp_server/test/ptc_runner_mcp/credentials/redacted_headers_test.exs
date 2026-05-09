defmodule PtcRunnerMcp.Credentials.RedactedHeadersTest do
  @moduledoc """
  Tests for `PtcRunnerMcp.Credentials.RedactedHeaders` — the opaque
  wrapper whose `Inspect` impl renders `[REDACTED]` to keep
  auth-bearing header bytes out of accidental log / trace output.

  Spec: `Plans/http-transport-credentials.md` §7.3.
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Credentials.RedactedHeaders

  test "new/1 wraps a list into a struct" do
    headers = [{"authorization", "Bearer xyz"}]
    rh = RedactedHeaders.new(headers)
    assert %RedactedHeaders{} = rh
    assert rh.headers == headers
  end

  test "headers/1 unwraps the inner list back unchanged" do
    headers = [{"authorization", "Bearer xyz"}, {"x-extra", "v"}]
    rh = RedactedHeaders.new(headers)
    assert RedactedHeaders.headers(rh) == headers
  end

  test "Inspect impl renders [REDACTED] and does not leak secret bytes" do
    secret = "sk-live-VERY-SECRET-abc123"
    rh = RedactedHeaders.new([{"authorization", "Bearer " <> secret}])

    str = inspect(rh)

    assert str == "#Credentials.RedactedHeaders<[REDACTED]>"
    refute str =~ secret
    refute str =~ "Bearer"
    refute str =~ "authorization"
  end

  test "Inspect impl scrubs nested occurrences inside containing structs" do
    secret = "tok-DO-NOT-LEAK-zzz"
    rh = RedactedHeaders.new([{"authorization", "Bearer " <> secret}])

    # Simulate a GenServer state map that transitively holds the
    # wrapper. Inspecting the parent must not reveal the inner bytes.
    state = %{conn_id: "abc", req_headers: rh, retries: 0}

    str = inspect(state)

    refute str =~ secret
    refute str =~ "Bearer"
    refute str =~ "authorization"
    assert str =~ "#Credentials.RedactedHeaders<[REDACTED]>"
  end

  test "Inspect impl scrubs even when struct is inside a list / tuple" do
    secret = "p@ssw0rd-secret"
    rh = RedactedHeaders.new([{"authorization", "Basic " <> Base.encode64("u:" <> secret)}])

    str = inspect({:ok, [rh, rh]})

    refute str =~ secret
    refute str =~ Base.encode64("u:" <> secret)
    assert str =~ "#Credentials.RedactedHeaders<[REDACTED]>"
  end
end
