defmodule PtcRunner.Lisp.StrictDataTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Eval.Helpers

  test "Lisp.run stays permissive for a missing data key" do
    assert {:ok, %{return: nil}} = Lisp.run("data/missing")
  end

  test "strict data without a grant list names the missing key" do
    assert {:error, step} = Lisp.run("data/missing", strict_data: true)
    assert step.fail.reason == :runtime_error
    assert step.fail.message =~ "runtime_error: data/missing is not bound"
  end

  test "strict data lists passed grants rather than context keys" do
    assert {:error, step} =
             Lisp.run("data/missing",
               context: %{"tickets" => ["SECRET_TICKET_SENTINEL"], "unused" => [1]},
               filter_context: true,
               strict_data: true,
               data_grants: ["data/tickets", "data/unused"]
             )

    assert step.fail.reason == :runtime_error
    assert step.fail.message =~ "data/missing is not a granted data name"
    assert step.fail.message =~ "data/tickets"
    assert step.fail.message =~ "data/unused"
    refute step.fail.message =~ "SECRET_TICKET_SENTINEL"
  end

  test "calling a granted data value is not_callable without rendering the value" do
    sentinel = "SECRET_TICKET_SENTINEL"

    assert {:error, step} =
             Lisp.run("(data/tickets)",
               context: %{"tickets" => [sentinel]},
               strict_data: true,
               data_grants: ["data/tickets"]
             )

    assert step.fail.reason == :not_callable
    assert step.fail.message == "not callable: data/tickets"
    refute step.fail.message =~ sentinel
  end

  test "calling a missing grant under strict data fails the lookup first" do
    assert {:error, step} =
             Lisp.run("(data/nosuch)",
               context: %{"tickets" => [1]},
               strict_data: true,
               data_grants: ["data/tickets"]
             )

    assert step.fail.reason == :runtime_error
    assert step.fail.message =~ "data/nosuch is not a granted data name"
    assert step.fail.message =~ "data/tickets"
    refute step.fail.reason == :not_callable
  end

  test "data/params uses the supplied diagnostic instead of a missing grant" do
    message =
      "data/params is not available because this evaluation supplied no params. " <>
        "Pass a params map through kernel/eval-with or kernel/eval-source-with."

    assert {:error, step} =
             Lisp.run("data/params",
               context: %{"tickets" => [1]},
               strict_data: true,
               data_grants: ["data/tickets"],
               missing_data_params_message: message
             )

    assert step.fail.reason == :runtime_error
    assert step.fail.message =~ "supplied no params"
    assert step.fail.message =~ "kernel/eval-with"
    refute step.fail.message =~ "granted"
    refute step.fail.message =~ "data/tickets"
  end

  test "private sanitization keeps the data symbol and drops the value payload" do
    assert Helpers.sanitize_private_error({:not_callable, {:data_ref, "data/tickets"}}) ==
             {:not_callable, {:data_ref, "data/tickets"}}

    assert Helpers.sanitize_private_error({:not_callable, ["SECRET"]}) ==
             {:not_callable, :private_prelude_value}
  end
end
