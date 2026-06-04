defmodule Mix.Tasks.Ptc.ReplPreludeTest do
  @moduledoc """
  P5 (plan §11): `mix ptc.repl --prelude file.clj` compiles the file into the
  SAME `%PtcRunner.Lisp.Prelude{}` artifact and passes it through the same
  `Lisp.run(prelude:)` execution path used by direct Lisp and SubAgent
  execution. `--show-prompt-inventory` reuses the SAME renderer. The prelude
  path is SEPARATE from `-l/--load` (user-code loading).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Repl
  alias PtcRunner.Lisp.Prelude

  @crm_source """
  (ns crm
    "CRM helpers."
    {:visibility :prompt})

  (defn get-user
    "Return a CRM user by id."
    [id]
    (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "ptc_repl_prelude_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "crm.clj")
    File.write!(path, @crm_source)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{prelude_path: path}
  end

  describe "compile_prelude!/1 reuses the prelude compiler" do
    test "produces the same artifact shape the compiler does", %{prelude_path: path} do
      prelude = Repl.compile_prelude!(path)
      assert %Prelude{} = prelude
      assert "crm" in prelude.namespaces
      assert {:ok, _export} = Prelude.fetch_export(prelude, "crm/get-user")
    end
  end

  describe "--prelude file.clj -e \"(ns-publics 'crm)\"" do
    test "discovers the prelude export through the same Lisp.run path", %{prelude_path: path} do
      Mix.Task.reenable("ptc.repl")

      output =
        capture_io(fn ->
          Repl.run(["--prelude", path, "-e", "(ns-publics 'crm)"])
        end)

      # ns-publics resolves the attached prelude's public export.
      assert output =~ "get-user"
    end

    test "the alias -p works the same", %{prelude_path: path} do
      Mix.Task.reenable("ptc.repl")

      output =
        capture_io(fn ->
          Repl.run(["-p", path, "-e", "(ns-publics 'crm)"])
        end)

      assert output =~ "get-user"
    end

    test "a qualified prelude call resolves and runs", %{prelude_path: path} do
      Mix.Task.reenable("ptc.repl")

      output =
        capture_io(fn ->
          Repl.run(["--prelude", path, "-e", "(doc 'crm/get-user)"])
        end)

      assert output =~ "Return a CRM user by id."
    end
  end

  describe "--show-prompt-inventory reuses the renderer" do
    test "prints the compact prompt inventory before evaluating", %{prelude_path: path} do
      Mix.Task.reenable("ptc.repl")

      output =
        capture_io(fn ->
          Repl.run(["--prelude", path, "--show-prompt-inventory", "-e", "(+ 1 2)"])
        end)

      assert output =~ "prelude capabilities"
      assert output =~ "crm/get-user"
      assert output =~ "(get-user arg1)"
      # And it still evaluates the expression.
      assert output =~ "3"
    end

    test "is a no-op without a prelude" do
      Mix.Task.reenable("ptc.repl")

      output =
        capture_io(fn ->
          Repl.run(["--show-prompt-inventory", "-e", "(+ 1 2)"])
        end)

      refute output =~ "prelude capabilities"
      assert output =~ "3"
    end
  end
end
