defmodule PtcRunner.RepositoryInstructionsTest do
  use ExUnit.Case, async: true

  # `mix regen` rewrites `priv/semantic_build_projection.json`, whose hashes
  # cannot be merged and which only the release gate checks. AGENTS.md once
  # offered it as ordinary staleness remediation, which would have had agents
  # poisoning the projection from feature branches. The correct guidance lives
  # in `docs/development-setup.md`, scoped to tagging a release on `main`.
  test "the repository instructions never recommend release-only regeneration" do
    refute File.read!(Path.expand("../AGENTS.md", __DIR__)) =~ "mix regen"
  end
end
