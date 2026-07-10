defmodule PtcRunner.Kernel.Eval.OracleTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Eval
  alias PtcRunner.Kernel.Eval.Oracle

  test "accepts every supported type and constraint family" do
    cases = [
      {%{expect: :integer, constraint: {:eq, 3}}, 3},
      {%{expect: :number, constraint: {:gt, 2}}, 3.0},
      {%{expect: :integer, constraint: {:gte, 3}}, 3},
      {%{expect: :integer, constraint: {:lt, 4}}, 3},
      {%{expect: :float, constraint: {:between, 2.5, 3.5}}, 3.0},
      {%{expect: :list, constraint: {:length, 2}}, [1, 2]},
      {%{expect: :string, constraint: {:gt_length, 2}}, "abc"},
      {%{expect: :string, constraint: {:starts_with, "ab"}}, "abc"},
      {%{expect: :boolean, constraint: {:one_of, [true]}}, true},
      {%{expect: :map, constraint: {:has_keys, [:id, "name"]}}, %{"id" => 1, name: "A"}},
      {%{expect: nil, constraint: {:eq, nil}}, nil},
      {%{expect: :any, constraint: {:one_of, [:ok]}}, :ok}
    ]

    for {eval_case, value} <- cases do
      assert :ok = Oracle.verify(eval_case, value)
    end
  end

  test "fails closed for missing and unknown oracle terms" do
    assert {:error, "missing_oracle"} = Oracle.verify(%{}, 1)
    assert {:error, "missing_constraint"} = Oracle.verify(%{expect: :integer}, 1)
    assert {:error, "missing_expect"} = Oracle.verify(%{constraint: {:eq, 1}}, 1)

    assert {:error, "unknown_expect"} =
             Oracle.verify(%{expect: :decimal, constraint: {:eq, 1}}, 1)

    assert {:error, "unknown_constraint"} =
             Oracle.verify(%{expect: :integer, constraint: {:approximately, 1}}, 1)
  end

  test "reports stable type and constraint failures" do
    assert {:error, "expect_type_mismatch:integer"} =
             Oracle.verify(%{expect: :integer, constraint: {:eq, 1}}, "1")

    assert {:error, "constraint_failed:has_keys"} =
             Oracle.verify(%{expect: :map, constraint: {:has_keys, ["missing"]}}, %{})
  end

  test "fails closed for invalid UTF-8 string results" do
    invalid_utf8 = <<255>>

    assert {:error, "expect_type_mismatch:string"} =
             Oracle.verify(%{expect: :string, constraint: {:length, 1}}, invalid_utf8)

    assert {:error, "expect_type_mismatch:string"} =
             Oracle.verify(%{expect: :string, constraint: {:gt_length, 0}}, invalid_utf8)
  end

  test "fails closed and projects an improper tool-returned list without raising" do
    improper = [1 | 2]

    assert {:error, "expect_type_mismatch:list"} =
             Oracle.verify(%{expect: :list, constraint: {:length, 1}}, improper)

    assert %{type: "improper_list", hash: hash} = Eval.project_result(improper)
    assert hash =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "fails closed for malformed cross-type constraint values and operands" do
    improper = [1 | 2]
    invalid_utf8 = <<255>>

    assert {:error, "invalid_value:length"} =
             Oracle.verify(%{expect: :any, constraint: {:length, 1}}, improper)

    assert {:error, "invalid_value:gt_length"} =
             Oracle.verify(%{expect: :any, constraint: {:gt_length, 0}}, invalid_utf8)

    assert {:error, "invalid_constraint:one_of"} =
             Oracle.verify(%{expect: :any, constraint: {:one_of, improper}}, 1)

    assert {:error, "invalid_constraint:has_keys"} =
             Oracle.verify(%{expect: :map, constraint: {:has_keys, improper}}, %{})
  end

  test "fails closed without raising for malformed constraint operands" do
    malformed = [
      {%{expect: :integer, constraint: {:gt, "bad"}}, 3, "invalid_constraint:gt"},
      {%{expect: :integer, constraint: {:gte, nil}}, 3, "invalid_constraint:gte"},
      {%{expect: :integer, constraint: {:lt, %{}}}, 3, "invalid_constraint:lt"},
      {%{expect: :integer, constraint: {:between, 4, 2}}, 3, "invalid_constraint:between"},
      {%{expect: :list, constraint: {:length, -1}}, [], "invalid_constraint:length"},
      {%{expect: :string, constraint: {:starts_with, 1}}, "abc",
       "invalid_constraint:starts_with"},
      {%{expect: :map, constraint: {:has_keys, [%{}]}}, %{"id" => 1},
       "invalid_constraint:has_keys"}
    ]

    for {eval_case, value, reason} <- malformed do
      assert {:error, ^reason} = Oracle.verify(eval_case, value)
    end
  end

  test "expected projection is total and redacts malformed oracle terms" do
    secret = "EXPECTED-SECRET"

    projection =
      Oracle.expected_projection(%{
        expect: secret,
        constraint: {:unsupported, secret, self(), make_ref()}
      })

    assert projection.expect.type == "invalid"
    assert projection.expect.hash =~ ~r/\A[0-9a-f]{64}\z/
    assert projection.constraint.kind == "invalid"
    assert projection.constraint.hash =~ ~r/\A[0-9a-f]{64}\z/
    refute inspect(projection) =~ secret
  end
end
