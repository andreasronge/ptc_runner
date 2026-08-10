defmodule PtcRunner.RepositoryInstructionsTest do
  use ExUnit.Case, async: true

  @instructions File.read!(Path.expand("../AGENTS.md", __DIR__))
  [_, commands_and_rest] = String.split(@instructions, "## Commands", parts: 2)
  [commands, _rest] = String.split(commands_and_rest, "### Fresh worktree setup", parts: 2)
  @commands commands

  test "ordinary generated-artifact guidance excludes release-only regeneration" do
    assert @commands =~ "`mix ptc.gen_docs`"
    refute @commands =~ "`mix regen`"
  end
end
