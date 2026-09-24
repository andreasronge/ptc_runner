defmodule PtcRunner.Kernel.ExampleLibraryGlobalStateTest do
  # async: false — sets OPENROUTER_API_KEY and loads a .env file into the OS environment
  # (class D).
  use ExUnit.Case, async: false
  @moduletag :operator

  alias PtcRunner.Dotenv
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome

  @tag :tmp_dir
  test "model-backed examples keep inherited credentials through comment-only env stubs", %{
    tmp_dir: directory
  } do
    key = "OPENROUTER_API_KEY"
    previous = System.get_env(key)
    sentinel = "inherited-sentinel"
    System.put_env(key, sentinel)

    on_exit(fn ->
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end)

    for example <- ["kernel-tutorial", "support-triage"] do
      target = Path.join(directory, example)

      assert {:ok, %CommandOutcome{}} =
               CommandEngine.dispatch(["init", target, "--example", example])

      env_file = Path.join(target, ".env")
      contents = File.read!(env_file)
      assert contents =~ "# #{key}"
      refute contents =~ ~r/^#{key}=/m
      assert :ok = Dotenv.load_file(env_file)
      assert System.get_env(key) == sentinel
    end
  end
end
