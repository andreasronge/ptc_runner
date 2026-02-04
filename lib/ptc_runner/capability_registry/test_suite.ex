defmodule PtcRunner.CapabilityRegistry.TestSuite do
  @moduledoc """
  Test suite for tool verification.

  Each tool can have an associated test suite that verifies its behavior.
  Test suites are append-only - every production failure becomes a permanent
  test case to prevent regressions.

  ## Test Case Tags

  - `:smoke` - Quick pre-flight checks (run before linking)
  - `:regression` - Added from production failures
  - `:edge_case` - Edge case tests

  ## Example

      %TestSuite{
        tool_id: "parse_csv",
        cases: [
          %{
            input: %{"text" => "a,b,c\\n1,2,3"},
            expected: [%{"a" => "1", "b" => "2", "c" => "3"}],
            tags: [:smoke]
          }
        ]
      }

  """

  @type test_case :: %{
          input: map(),
          expected: term() | :should_not_crash,
          tags: [atom()],
          description: String.t() | nil,
          added_reason: String.t() | nil
        }

  @type test_result :: :pass | {:fail, term()}

  @type run_result :: %{
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          results: [{test_case(), test_result()}]
        }

  @type t :: %__MODULE__{
          tool_id: String.t(),
          cases: [test_case()],
          inherited_from: String.t() | nil,
          created_at: DateTime.t(),
          last_run: DateTime.t() | nil,
          last_result: :green | :red | :flaky | nil
        }

  defstruct [
    :tool_id,
    :inherited_from,
    :created_at,
    :last_run,
    :last_result,
    cases: []
  ]

  @doc """
  Creates a new test suite for a tool.

  ## Examples

      iex> suite = PtcRunner.CapabilityRegistry.TestSuite.new("parse_csv")
      iex> suite.tool_id
      "parse_csv"

  """
  @spec new(String.t(), keyword()) :: t()
  def new(tool_id, opts \\ []) when is_binary(tool_id) do
    %__MODULE__{
      tool_id: tool_id,
      cases: Keyword.get(opts, :cases, []),
      inherited_from: Keyword.get(opts, :inherited_from),
      created_at: DateTime.utc_now(),
      last_run: nil,
      last_result: nil
    }
  end

  @doc """
  Adds a test case to the suite.
  """
  @spec add_case(t(), map(), term(), keyword()) :: t()
  def add_case(suite, input, expected, opts \\ []) do
    test_case = %{
      input: input,
      expected: expected,
      tags: Keyword.get(opts, :tags, []),
      description: Keyword.get(opts, :description),
      added_reason: Keyword.get(opts, :added_reason)
    }

    %{suite | cases: suite.cases ++ [test_case]}
  end

  @doc """
  Adds a regression test case from a production failure.
  """
  @spec add_regression(t(), map(), String.t()) :: t()
  def add_regression(suite, failure_input, diagnosis) do
    add_case(suite, failure_input, :should_not_crash,
      tags: [:regression, :from_production],
      added_reason: diagnosis
    )
  end

  @doc """
  Gets all smoke test cases (tagged with :smoke).
  """
  @spec smoke_cases(t()) :: [test_case()]
  def smoke_cases(suite) do
    Enum.filter(suite.cases, fn c -> :smoke in c.tags end)
  end

  @doc """
  Gets test cases by tag.
  """
  @spec cases_by_tag(t(), atom()) :: [test_case()]
  def cases_by_tag(suite, tag) do
    Enum.filter(suite.cases, fn c -> tag in c.tags end)
  end

  @doc """
  Returns the count of test cases.
  """
  @spec case_count(t()) :: non_neg_integer()
  def case_count(suite) do
    length(suite.cases)
  end

  @doc """
  Merges two test suites, combining cases.

  Used when creating a repair tool that inherits tests from the original.
  """
  @spec merge(t(), t()) :: t()
  def merge(base, new_cases) do
    %{base | cases: base.cases ++ new_cases.cases}
  end

  @doc """
  Records a test run result.
  """
  @spec record_run(t(), :green | :red | :flaky) :: t()
  def record_run(suite, result) do
    %{suite | last_run: DateTime.utc_now(), last_result: result}
  end

  @doc """
  Converts to a JSON-serializable map.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = suite) do
    %{
      tool_id: suite.tool_id,
      cases: Enum.map(suite.cases, &case_to_json/1),
      inherited_from: suite.inherited_from,
      created_at: DateTime.to_iso8601(suite.created_at),
      last_run: if(suite.last_run, do: DateTime.to_iso8601(suite.last_run)),
      last_result: if(suite.last_result, do: Atom.to_string(suite.last_result))
    }
  end

  defp case_to_json(test_case) do
    %{
      input: test_case.input,
      expected: serialize_expected(test_case.expected),
      tags: Enum.map(test_case.tags, &Atom.to_string/1),
      description: test_case.description,
      added_reason: test_case.added_reason
    }
  end

  defp serialize_expected(:should_not_crash), do: "should_not_crash"
  defp serialize_expected(other), do: other

  defp deserialize_expected("should_not_crash"), do: :should_not_crash
  defp deserialize_expected(other), do: other

  @doc """
  Creates from a JSON map.
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(data) do
    {:ok, created_at, _} = DateTime.from_iso8601(data["created_at"])

    last_run =
      case data["last_run"] do
        nil -> nil
        iso -> elem(DateTime.from_iso8601(iso), 1)
      end

    last_result =
      case data["last_result"] do
        nil -> nil
        str -> String.to_existing_atom(str)
      end

    # Convert case tags from strings to atoms
    cases =
      Enum.map(data["cases"] || [], fn c ->
        %{
          input: c["input"],
          expected: deserialize_expected(c["expected"]),
          tags: Enum.map(c["tags"] || [], &String.to_existing_atom/1),
          description: c["description"],
          added_reason: c["added_reason"]
        }
      end)

    {:ok,
     %__MODULE__{
       tool_id: data["tool_id"],
       cases: cases,
       inherited_from: data["inherited_from"],
       created_at: created_at,
       last_run: last_run,
       last_result: last_result
     }}
  rescue
    e -> {:error, {:deserialization_failed, e}}
  end
end
