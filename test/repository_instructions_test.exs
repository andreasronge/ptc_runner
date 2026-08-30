defmodule PtcRunner.RepositoryInstructionsTest do
  use ExUnit.Case, async: true

  # `mix regen` rewrites `priv/semantic_build_projection.json`, whose hashes
  # cannot be merged and which only the release gate checks. AGENTS.md once
  # offered it as ordinary staleness remediation, which would have had agents
  # poisoning the projection from feature branches. The correct guidance lives
  # in `docs/maintainers/development-setup.md`, scoped to tagging a release on `main`.
  test "the repository instructions never recommend release-only regeneration" do
    refute File.read!(Path.expand("../AGENTS.md", __DIR__)) =~ "mix regen"
  end

  test "package integration rules ship separately from repository instructions" do
    package_files = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)
    rules = File.read!(Path.expand("../usage-rules.md", __DIR__))
    normalized_rules = String.replace(rules, ~r/\s+/, " ")

    assert "usage-rules.md" in package_files
    assert normalized_rules =~ "integrating the published `ptc_runner` Hex package"
    assert normalized_rules =~ "not instructions for models running inside PtcRunner"
    refute rules =~ "mix precommit"
    refute rules =~ "scripts/worktree.sh"
  end

  test "repository instructions inline documentation lookup guidance" do
    instructions = File.read!(Path.expand("../AGENTS.md", __DIR__))

    assert instructions =~ "mix usage_rules.docs"
    assert instructions =~ "mix usage_rules.search_docs"
    refute instructions =~ "[usage_rules usage rules](deps/usage_rules/usage-rules.md)"
    assert instructions =~ "[usage_rules:elixir usage rules]"
    assert instructions =~ "[usage_rules:otp usage rules]"
  end
end
