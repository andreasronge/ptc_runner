defmodule PtcRunnerMcp.SessionsProjectionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunnerMcp.Sessions.{Config, Projection}

  test "session start bounds prelude namespace docstrings" do
    huge_doc = String.duplicate("huge doc ", 20_000)

    source = """
    (ns leak "#{huge_doc}" {:visibility :prompt})
    (defn sample [] :ok)
    """

    assert {:ok, prelude} = Compiler.compile(source)

    projected =
      Projection.start(%{
        id: "session-1",
        expires_at: DateTime.utc_now(),
        limits: Config.session_limits(),
        runtime_prelude: prelude
      })

    assert [%{"namespace" => "leak", "doc" => doc}] = projected["preludes"]
    assert byte_size(doc) <= 1_024
    assert doc =~ "truncated"
    refute doc =~ String.duplicate("huge doc ", 1_000)
  end
end
