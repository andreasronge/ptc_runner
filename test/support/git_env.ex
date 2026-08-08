defmodule PtcRunner.TestSupport.GitEnv do
  @moduledoc """
  Environment scrubbing for tests that drive Git against a throwaway repository.

  Git exports these to any process it spawns, so a test running under a hook —
  or under a `mix test` that a hook invoked — inherits pointers to the *outer*
  repository. A nested `git init` then looks correct while `git config` and
  `git rev-parse` answer for the parent, which turns a hermetic fixture into a
  reader of whatever the developer's clone happens to be configured with.
  """

  @inherited ~w(
    GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIT_CONFIG
    GIT_CONFIG_PARAMETERS
    GIT_CONFIG_COUNT
    GIT_OBJECT_DIRECTORY
    GIT_DIR
    GIT_WORK_TREE
    GIT_IMPLICIT_WORK_TREE
    GIT_GRAFT_FILE
    GIT_INDEX_FILE
    GIT_NO_REPLACE_OBJECTS
    GIT_REPLACE_REF_BASE
    GIT_PREFIX
    GIT_SHALLOW_FILE
    GIT_COMMON_DIR
  )

  @doc """
  Returns a `System.cmd/3` `:env` list that clears every inherited Git variable.

  Pass `extra` to set variables on top of the cleared ones.
  """
  @spec clear(keyword() | [{String.t(), String.t() | nil}]) :: [{String.t(), String.t() | nil}]
  def clear(extra \\ []) do
    Enum.map(@inherited, &{&1, nil}) ++
      Enum.map(extra, fn {key, value} -> {to_string(key), value} end)
  end
end
