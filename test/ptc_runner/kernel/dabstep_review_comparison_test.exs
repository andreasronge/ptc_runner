defmodule PtcRunner.Kernel.DabstepReviewComparisonTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.InspectOnlyRepl
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ReplSession

  @application Path.expand("../../../examples/dabstep-fraud/ptc.json", __DIR__)

  @be ~s|{"ip_country" "BE" "fraudulent_volume" 263833.85 "total_volume" 2150473.54}|
  @nl ~s|{"ip_country" "NL" "fraudulent_volume" 329134.08 "total_volume" 2701907.13}|

  test "measurements agree only to the cent, once per country, in any order" do
    {:ok, limits} = Limits.installed(%{evaluation_heap_words: 5_000_000})
    assert {:ok, session} = InspectOnlyRepl.open(@application, installed_limits: limits)

    noise =
      ~s|{"ip_country" "BE" "fraudulent_volume" 263833.8500000002 "total_volume" 2150473.540000013}|

    under = ~s|{"ip_country" "BE" "fraudulent_volume" 263833.854 "total_volume" 2150473.54}|
    cent = ~s|{"ip_country" "BE" "fraudulent_volume" 263833.86 "total_volume" 2150473.54}|
    total = ~s|{"ip_country" "BE" "fraudulent_volume" 263833.85 "total_volume" 2150473.55}|

    {results, session} =
      Enum.map_reduce(
        [
          {"summation noise", "[#{@be}]", "[#{noise}]", true},
          {"under half a cent", "[#{@be}]", "[#{under}]", true},
          {"one cent of fraud", "[#{@be}]", "[#{cent}]", false},
          {"one cent of total", "[#{@be}]", "[#{total}]", false},
          {"reordered countries", "[#{@be} #{@nl}]", "[#{@nl} #{@be}]", true},
          {"missing country", "[#{@be} #{@nl}]", "[#{@be}]", false},
          {"duplicate country", "[#{@be} #{@be}]", "[#{@be}]", false},
          {"duplicate on the other side", "[#{@be}]", "[#{@be} #{@be}]", false}
        ],
        session,
        fn {label, left, right, expected}, session ->
          expression = "(dabstep.review/same-measurements? #{left} #{right})"
          assert {:ok, result, session} = ReplSession.eval(session, expression)
          {{label, result.return, expected}, session}
        end
      )

    assert {:ok, top, _session} =
             ReplSession.eval(session, "(dabstep.review/top-country [#{@nl} #{@be}])")

    assert top.return == "BE"

    for {label, actual, expected} <- results do
      assert actual == expected, "#{label}: expected #{expected}, got #{inspect(actual)}"
    end
  end
end
