defmodule PtcRunnerMcp.ReplTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunnerMcp.Repl
  alias PtcRunnerMcp.ResponseProfile

  setup do
    previous_profile = ResponseProfile.current()
    ResponseProfile.set(:slim)

    on_exit(fn ->
      ResponseProfile.set(previous_profile)
    end)

    :ok
  end

  test "eval renders lisp_eval success text" do
    assert {:ok, "user=> 3"} = Repl.eval("(+ 1 2)", session: false)
  end

  test "eval can render the full pretty MCP response envelope" do
    assert {:ok, text} = Repl.eval("(+ 1 2)", session: false, display: :envelope)
    assert text =~ ~s("isError": false)
    assert text =~ ~s("content")
    assert text =~ "user=> 3"
  end

  test "eval can render the full compact MCP response envelope as json" do
    assert {:ok, text} = Repl.eval("(+ 1 2)", session: false, display: :json)
    assert %{"isError" => false, "content" => [%{"text" => "user=> 3"} | _]} = Jason.decode!(text)
  end

  test "eval renders lisp_eval error text" do
    assert {:error, text} = Repl.eval("(/ 1 0)", session: false)
    assert text =~ "runtime_error"
    assert text =~ "division"
  end

  test "interactive display command switches to full envelope rendering" do
    output =
      capture_io(":display envelope\n(+ 1 2)\n:quit\n", fn ->
        Repl.start(session: false)
      end)

    assert output =~ "Display: envelope"
    assert output =~ ~s("isError": false)
    assert output =~ "user=> 3"
  end

  test "interactive reader ignores delimiters inside strings" do
    output =
      capture_io("(println \"(\")\n:quit\n", fn ->
        Repl.start(session: false)
      end)

    assert output =~ "ptc> <prints>\n("
    refute output =~ "...>"
  end

  test "interactive reader ignores delimiters inside comments" do
    output =
      capture_io("(do ; ) ignored\n  (+ 1 2))\n:quit\n", fn ->
        Repl.start(session: false)
      end)

    assert output =~ "...> user=> 3"
  end

  test "interactive reader ignores delimiter character literals" do
    output =
      capture_io("(= \\) \")\")\n:quit\n", fn ->
        Repl.start(session: false)
      end)

    assert output =~ "ptc> user=> true"
    refute output =~ "...>"
  end

  test "interactive reader handles named character literals" do
    output =
      capture_io("(= \\newline \"\\n\")\n:quit\n", fn ->
        Repl.start(session: false)
      end)

    assert output =~ "ptc> user=> true"
  end
end
