defmodule PtcRunner.DotenvTest do
  # async: false — these tests mutate the real process environment and the
  # current working directory.
  use ExUnit.Case, async: false

  alias PtcRunner.Dotenv

  @moduletag :tmp_dir

  # Track every env var a test touches so we can restore it afterward.
  defp track_env(keys) do
    saved = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  describe "find_dotenv/1" do
    test "returns the .env in the starting directory", %{tmp_dir: dir} do
      env = Path.join(dir, ".env")
      File.write!(env, "")
      assert Dotenv.find_dotenv(dir) == env
    end

    test "walks up the directory tree to the nearest .env", %{tmp_dir: dir} do
      far = Path.join(dir, ".env")
      File.write!(far, "")
      mid = Path.join([dir, "a", "b"])
      File.mkdir_p!(mid)
      File.write!(Path.join(mid, ".env"), "")
      nested = Path.join([dir, "a", "b", "c", "d"])
      File.mkdir_p!(nested)

      # Picks the closest .env, not the one further up.
      assert Dotenv.find_dotenv(nested) == Path.join(mid, ".env")
    end

    test "stops at the filesystem root and returns nil" do
      assert Dotenv.find_dotenv("/") == nil
    end
  end

  describe "load_file/1" do
    test "parses KEY=VALUE pairs", %{tmp_dir: dir} do
      track_env(["PTC_DOTENV_TEST_A", "PTC_DOTENV_TEST_B"])
      path = Path.join(dir, ".env")
      File.write!(path, "PTC_DOTENV_TEST_A=hello\nPTC_DOTENV_TEST_B=world\n")

      Dotenv.load_file(path)

      assert System.get_env("PTC_DOTENV_TEST_A") == "hello"
      assert System.get_env("PTC_DOTENV_TEST_B") == "world"
    end

    test "skips blank lines and # comments", %{tmp_dir: dir} do
      track_env(["PTC_DOTENV_TEST_C"])
      path = Path.join(dir, ".env")
      File.write!(path, "# a comment\n\n   \nPTC_DOTENV_TEST_C=value\n# trailing comment\n")

      Dotenv.load_file(path)

      assert System.get_env("PTC_DOTENV_TEST_C") == "value"
    end

    test "strips surrounding double and single quotes", %{tmp_dir: dir} do
      track_env(["PTC_DOTENV_TEST_DQ", "PTC_DOTENV_TEST_SQ"])
      path = Path.join(dir, ".env")

      File.write!(
        path,
        ~s|PTC_DOTENV_TEST_DQ="quoted value"\nPTC_DOTENV_TEST_SQ='single quoted'\n|
      )

      Dotenv.load_file(path)

      assert System.get_env("PTC_DOTENV_TEST_DQ") == "quoted value"
      assert System.get_env("PTC_DOTENV_TEST_SQ") == "single quoted"
    end

    test "keeps '=' characters inside the value", %{tmp_dir: dir} do
      track_env(["PTC_DOTENV_TEST_EQ"])
      path = Path.join(dir, ".env")
      File.write!(path, "PTC_DOTENV_TEST_EQ=a=b=c\n")

      Dotenv.load_file(path)

      assert System.get_env("PTC_DOTENV_TEST_EQ") == "a=b=c"
    end

    test "does not overwrite an env var that is already set", %{tmp_dir: dir} do
      track_env(["PTC_DOTENV_TEST_EXISTING"])
      System.put_env("PTC_DOTENV_TEST_EXISTING", "original")
      path = Path.join(dir, ".env")
      File.write!(path, "PTC_DOTENV_TEST_EXISTING=from_file\n")

      Dotenv.load_file(path)

      assert System.get_env("PTC_DOTENV_TEST_EXISTING") == "original"
    end
  end

  describe "load/0" do
    test "loads the .env from the current working directory", %{tmp_dir: dir} do
      track_env(["PTC_DOTENV_TEST_LOAD"])
      # load/0 is once-per-VM; reset the guard so this test actually loads.
      :persistent_term.erase({Dotenv, :dotenv_loaded})
      on_exit(fn -> :persistent_term.erase({Dotenv, :dotenv_loaded}) end)

      File.write!(Path.join(dir, ".env"), "PTC_DOTENV_TEST_LOAD=yep\n")

      original_cwd = File.cwd!()
      File.cd!(dir)

      try do
        assert Dotenv.load() == :ok
        assert System.get_env("PTC_DOTENV_TEST_LOAD") == "yep"
      after
        File.cd!(original_cwd)
      end
    end

    test "is a no-op on the second call (once per VM)", %{tmp_dir: dir} do
      track_env(["PTC_DOTENV_TEST_ONCE"])
      :persistent_term.erase({Dotenv, :dotenv_loaded})
      on_exit(fn -> :persistent_term.erase({Dotenv, :dotenv_loaded}) end)

      File.write!(Path.join(dir, ".env"), "PTC_DOTENV_TEST_ONCE=first\n")
      original_cwd = File.cwd!()
      File.cd!(dir)

      try do
        Dotenv.load()
        assert System.get_env("PTC_DOTENV_TEST_ONCE") == "first"

        # Change the var and the file; a second load/0 must not re-read it.
        System.delete_env("PTC_DOTENV_TEST_ONCE")
        File.write!(Path.join(dir, ".env"), "PTC_DOTENV_TEST_ONCE=second\n")

        assert Dotenv.load() == :ok
        assert System.get_env("PTC_DOTENV_TEST_ONCE") == nil
      after
        File.cd!(original_cwd)
      end
    end
  end
end
