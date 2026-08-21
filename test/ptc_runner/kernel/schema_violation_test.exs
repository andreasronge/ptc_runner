defmodule PtcRunner.Kernel.SchemaViolationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.SchemaViolation

  test "oneOf with successful branches ignores invalidated branch metadata" do
    invalid_branch = %{
      kind: :type,
      data_path: [{:property, "value"}],
      args: [expected: :integer]
    }

    error = %{
      kind: :oneOf,
      data_path: [],
      args: [
        validated: [{0, %{}, %{}}, {1, %{}, %{}}],
        invalidated: [{2, %{errors: [invalid_branch]}}]
      ]
    }

    assert %SchemaViolation{rule: :one_of, path: []} =
             SchemaViolation.from_jsv([error], %{
               "oneOf" => [
                 %{"type" => "object"},
                 %{"type" => "object"},
                 %{"type" => "object", "properties" => %{"value" => %{"type" => "integer"}}}
               ]
             })
  end
end
