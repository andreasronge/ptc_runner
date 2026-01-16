defmodule ReproduceIssue do
  use ExUnit.Case
  alias PtcRunner.Lisp

  test "println inside closure ignores max_print_length" do
    source = """
    (do
      ((fn [] (println "This is a long message that should be truncated")))
      nil)
    """

    # Set a very small limit
    {:ok, step} = Lisp.run(source, max_print_length: 5)

    # Expected: "This ..." (length 8)
    # Actual: "This is a long message that should be truncated" (if closure uses default 2000)
    [output] = step.prints
    assert String.length(output) == 8
  end

  test "println inside pcalls task ignores max_print_length" do
    source = """
    (pcalls [(fn [] (println "This is a long message in pcalls"))])
    """

    {:ok, step} = Lisp.run(source, max_print_length: 5)
    # Note: prints in pcalls are currently lost (GH-669)
    # Let's check pcalls implementation in eval.ex
  end
end
