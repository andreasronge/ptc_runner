defmodule PtcRunner.BuildIdentityTest do
  use ExUnit.Case, async: true

  alias PtcRunner.BuildIdentity

  test "exposes the source identity embedded in the application metadata" do
    assert %{
             version: version,
             source_revision: revision,
             source_dirty: dirty?
           } = BuildIdentity.current()

    assert version == Application.spec(:ptc_runner, :vsn) |> List.to_string()
    assert revision =~ ~r/^[0-9a-f]{40}$/
    assert is_boolean(dirty?)
  end

  test "renders a compact human identity" do
    assert BuildIdentity.human(%{
             version: "1.2.3",
             source_revision: "0123456789abcdef0123456789abcdef01234567",
             source_dirty: true
           }) == "1.2.3 (01234567, dirty)"
  end
end
