defmodule PtcRunnerMcp.CredentialsApplyTest do
  @moduledoc """
  Tests for `PtcRunnerMcp.Credentials.apply_emitter/2` — pure function
  that converts a materialization + auth emitter spec into a
  `%RedactedHeaders{}` wrapper.

  `async: true` because `apply_emitter/2` does NOT route through the
  Credentials GenServer or touch any global state.

  Spec: `Plans/http-transport-credentials.md` §7.3.
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.RedactedHeaders

  # ---- helpers --------------------------------------------------------------

  defp materialization(raw, hint) do
    %{raw: raw, scheme_hint: hint, expires_at: :never}
  end

  defp bearer_emitter(binding \\ "tok") do
    %{scheme: :bearer, binding: binding, header: nil}
  end

  defp basic_emitter(binding \\ "creds") do
    %{scheme: :basic, binding: binding, header: nil}
  end

  defp custom_emitter(header, binding \\ "key") do
    %{scheme: :custom_header, binding: binding, header: header}
  end

  # ---- bearer ---------------------------------------------------------------

  test "bearer happy path with :bearer scheme_hint" do
    mat = materialization("tok-abc", :bearer)
    assert {:ok, %RedactedHeaders{} = rh} = Credentials.apply_emitter(mat, bearer_emitter())
    assert RedactedHeaders.headers(rh) == [{"authorization", "Bearer tok-abc"}]
  end

  test "bearer happy path with :raw scheme_hint" do
    mat = materialization("tok-abc", :raw)
    assert {:ok, rh} = Credentials.apply_emitter(mat, bearer_emitter())
    assert RedactedHeaders.headers(rh) == [{"authorization", "Bearer tok-abc"}]
  end

  # ---- custom_header --------------------------------------------------------

  test "custom_header happy path lowercases the header name" do
    mat = materialization("key-xyz", :raw)
    emitter = custom_emitter("X-Api-Key")
    assert {:ok, rh} = Credentials.apply_emitter(mat, emitter)
    assert RedactedHeaders.headers(rh) == [{"x-api-key", "key-xyz"}]
  end

  test "custom_header header field is lowercased even when mixed-case" do
    mat = materialization("v", :raw)
    emitter = custom_emitter("X-Custom-Foo")
    assert {:ok, rh} = Credentials.apply_emitter(mat, emitter)
    assert [{name, _}] = RedactedHeaders.headers(rh)
    assert name == "x-custom-foo"
  end

  # ---- basic — happy paths --------------------------------------------------

  test "basic with user:pass string" do
    mat = materialization("alice:secret", :basic)
    assert {:ok, rh} = Credentials.apply_emitter(mat, basic_emitter())

    expected_b64 = Base.encode64("alice:secret")
    assert RedactedHeaders.headers(rh) == [{"authorization", "Basic " <> expected_b64}]
  end

  test "basic with JSON-shaped binary" do
    mat = materialization(~s({"user":"alice","pass":"secret"}), :basic)
    assert {:ok, rh} = Credentials.apply_emitter(mat, basic_emitter())

    expected_b64 = Base.encode64("alice:secret")
    assert RedactedHeaders.headers(rh) == [{"authorization", "Basic " <> expected_b64}]
  end

  test "basic splits on the FIRST colon — password may contain colons" do
    mat = materialization("user:pass:with:colons", :basic)
    assert {:ok, rh} = Credentials.apply_emitter(mat, basic_emitter())

    expected_b64 = Base.encode64("user:pass:with:colons")
    assert RedactedHeaders.headers(rh) == [{"authorization", "Basic " <> expected_b64}]
  end

  test "basic accepts empty user (':pass' form)" do
    # RFC 7617 permits empty userid; some upstreams use this as
    # "API token in password position with empty user".
    mat = materialization(":pass", :basic)
    assert {:ok, rh} = Credentials.apply_emitter(mat, basic_emitter())

    expected_b64 = Base.encode64(":pass")
    assert RedactedHeaders.headers(rh) == [{"authorization", "Basic " <> expected_b64}]
  end

  test "basic accepts empty pass ('user:' form)" do
    # RFC 7617 permits empty password; Stripe-style "API token in
    # user position, empty password" is a real-world pattern.
    mat = materialization("user:", :basic)
    assert {:ok, rh} = Credentials.apply_emitter(mat, basic_emitter())

    expected_b64 = Base.encode64("user:")
    assert RedactedHeaders.headers(rh) == [{"authorization", "Basic " <> expected_b64}]
  end

  # ---- basic — failure modes ------------------------------------------------

  test "basic with malformed raw (no colon, no leading {) is :unencodable" do
    mat = materialization("bare-string", :basic)

    assert {:error, :unencodable, "basic_shape_invalid"} =
             Credentials.apply_emitter(mat, basic_emitter())
  end

  test "basic with bad JSON is :unencodable" do
    mat = materialization("{not valid json", :basic)

    assert {:error, :unencodable, "basic_shape_invalid"} =
             Credentials.apply_emitter(mat, basic_emitter())
  end

  test "basic JSON without user/pass keys is :unencodable" do
    mat = materialization(~s({"foo":"bar"}), :basic)

    assert {:error, :unencodable, "basic_shape_invalid"} =
             Credentials.apply_emitter(mat, basic_emitter())
  end

  # ---- scheme_hint mismatch -------------------------------------------------

  test "scheme_mismatch: :bearer hint with :basic emitter" do
    mat = materialization("alice:secret", :bearer)

    assert {:error, :scheme_mismatch, detail} =
             Credentials.apply_emitter(mat, basic_emitter())

    assert detail =~ "bearer"
    assert detail =~ "basic"
  end

  test "scheme_mismatch: :basic hint with :bearer emitter" do
    mat = materialization("tok-abc", :basic)

    assert {:error, :scheme_mismatch, detail} =
             Credentials.apply_emitter(mat, bearer_emitter())

    assert detail =~ "basic"
    assert detail =~ "bearer"
  end

  test "scheme_mismatch: :bearer hint with :custom_header emitter" do
    mat = materialization("tok-abc", :bearer)

    assert {:error, :scheme_mismatch, detail} =
             Credentials.apply_emitter(mat, custom_emitter("X-Api-Key"))

    assert detail =~ "bearer"
    assert detail =~ "custom_header"
  end

  # ---- :raw hint feeds any scheme without error -----------------------------

  test ":raw hint feeds bearer without error" do
    mat = materialization("tok", :raw)
    assert {:ok, _rh} = Credentials.apply_emitter(mat, bearer_emitter())
  end

  test ":raw hint feeds basic without error (when raw is well-shaped)" do
    mat = materialization("user:pass", :raw)
    assert {:ok, _rh} = Credentials.apply_emitter(mat, basic_emitter())
  end

  test ":raw hint feeds custom_header without error" do
    mat = materialization("v", :raw)
    assert {:ok, _rh} = Credentials.apply_emitter(mat, custom_emitter("X-Foo"))
  end
end
