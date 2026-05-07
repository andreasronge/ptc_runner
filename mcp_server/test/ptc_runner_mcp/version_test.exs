defmodule PtcRunnerMcp.VersionTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Version

  doctest Version

  test "supports both 2025-11-25 and 2025-06-18" do
    assert "2025-11-25" in Version.supported()
    assert "2025-06-18" in Version.supported()
  end

  test "primary is 2025-11-25" do
    assert Version.primary() == "2025-11-25"
  end

  test "package_version returns a non-empty semver-ish string" do
    assert Version.package_version() =~ ~r/^\d+\.\d+\.\d+/
  end
end
