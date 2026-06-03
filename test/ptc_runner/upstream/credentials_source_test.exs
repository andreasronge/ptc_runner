defmodule PtcRunner.Upstream.CredentialsSourceTest do
  # async: false — these tests mutate the OS environment and read a temp file.
  use ExUnit.Case, async: false

  alias PtcRunner.Upstream.Credentials

  describe "env source" do
    setup do
      var = "PTC_CRED_TEST_#{System.unique_integer([:positive])}"
      on_exit(fn -> System.delete_env(var) end)
      %{var: var}
    end

    test "resolves a set env var into a secret", %{var: var} do
      System.put_env(var, "env-secret")

      assert {:ok, c} = Credentials.new(%{"token" => %{"source" => "env", "var" => var}})
      assert Credentials.redaction_secrets(c) == ["env-secret"]
    end

    test "rejects an unset env var with a pointed message", %{var: var} do
      System.delete_env(var)

      assert {:error, :upstream_unavailable, msg} =
               Credentials.new(%{"token" => %{"source" => "env", "var" => var}})

      assert msg =~ "credential token env #{var} is not set"
    end

    test "rejects an empty env var", %{var: var} do
      System.put_env(var, "")

      assert {:error, :upstream_unavailable, msg} =
               Credentials.new(%{"token" => %{"source" => "env", "var" => var}})

      assert msg =~ "is not set"
    end
  end

  describe "file source" do
    setup do
      dir = System.tmp_dir!()
      path = Path.join(dir, "ptc_cred_#{System.unique_integer([:positive])}.txt")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "reads a file and trims the trailing newline", %{path: path} do
      File.write!(path, "file-secret\n")

      assert {:ok, c} = Credentials.new(%{"token" => %{"source" => "file", "path" => path}})
      assert Credentials.redaction_secrets(c) == ["file-secret"]
    end

    test "rejects a missing file with a formatted error", %{path: path} do
      refute File.exists?(path)

      assert {:error, :upstream_unavailable, msg} =
               Credentials.new(%{"token" => %{"source" => "file", "path" => path}})

      assert msg =~ "credential token:"
    end
  end
end
