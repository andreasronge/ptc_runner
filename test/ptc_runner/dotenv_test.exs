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

  describe "load_file/1" do
    test "distinguishes common file failures", %{tmp_dir: dir} do
      assert Dotenv.load_file(Path.join(dir, "missing.env")) ==
               {:error, :environment_file_not_found}

      directory = Path.join(dir, "directory.env")
      File.mkdir!(directory)

      assert Dotenv.load_file(directory) ==
               {:error, :environment_file_not_regular}

      invalid_utf8 = Path.join(dir, "invalid.env")
      File.write!(invalid_utf8, <<255>>)

      assert Dotenv.load_file(invalid_utf8) ==
               {:error, :environment_file_invalid_utf8}

      oversized = Path.join(dir, "large.env")
      File.write!(oversized, String.duplicate("x", 1_000_001))

      assert Dotenv.load_file(oversized) ==
               {:error, :environment_file_too_large}
    end

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
end
