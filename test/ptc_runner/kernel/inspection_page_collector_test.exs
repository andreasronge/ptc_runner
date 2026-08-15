defmodule PtcRunner.Kernel.InspectionPageCollectorTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ConversationProjection
  alias PtcRunner.Kernel.InspectionPageCollector
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.ProjectViewerAdapter

  test "collects every bounded page without presenting truncated data as complete" do
    items = Enum.map(1..1_250, &%{"item" => &1})

    query = fn
      %{"run_id" => "run", "limit" => 1_000, "cursor" => "next"} ->
        {:ok, page(Enum.drop(items, 1_000), nil, "snapshot")}

      %{"run_id" => "run", "limit" => 1_000} ->
        {:ok, page(Enum.take(items, 1_000), "next", "snapshot")}
    end

    assert {:ok, result} = InspectionPageCollector.collect(query, :turns, "run")
    assert result["items"] == items
    assert result["snapshot_hash"] == "snapshot"
    assert result["next_cursor"] == nil
    refute result["truncated"]
  end

  test "rejects an aggregate that crosses the one-megabyte response ceiling" do
    item = %{"value" => String.duplicate("x", 600_000)}

    query = fn
      %{"cursor" => "next"} -> {:ok, page([item], nil, "snapshot")}
      _first -> {:ok, page([item], "next", "snapshot")}
    end

    assert {:error, :result_limit_exceeded} =
             InspectionPageCollector.collect(query, :effective_preludes, "run")
  end

  test "charges final metadata against the response ceiling" do
    query = fn _arguments ->
      {:ok,
       page([], nil, "snapshot")
       |> Map.put("evidence", %{"value" => String.duplicate("x", 1_000_000)})}
    end

    assert {:error, :result_limit_exceeded} =
             InspectionPageCollector.collect(query, :turns, "run")
  end

  test "projected conversations retain the final one-megabyte response bound" do
    empty_page = conversation_page("")
    page_overhead = byte_size(Jason.encode!(empty_page))

    projected_overhead =
      empty_page
      |> ConversationProjection.present_page()
      |> Jason.encode!()
      |> byte_size()

    assert projected_overhead > page_overhead
    payload = String.duplicate("x", 1_000_000 - page_overhead)
    page = conversation_page(payload)
    assert byte_size(Jason.encode!(page)) == 1_000_000

    token = make_ref()
    pid = spawn(fn -> snapshot_loop(token, page) end)
    snapshot = %InspectionSnapshot{pid: pid, token: token}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    assert {:error, :result_limit_exceeded} =
             ProjectViewerAdapter.conversation({:inspection_snapshot, snapshot}, "run")
  end

  defp page(items, cursor, hash) do
    %{
      "items" => items,
      "next_cursor" => cursor,
      "omitted_count" => if(cursor, do: 1, else: 0),
      "truncated" => not is_nil(cursor),
      "snapshot_hash" => hash
    }
  end

  defp conversation_page(payload) do
    page(
      [
        %{
          "stream_id" => "stream",
          "run_id" => "run",
          "trace_id" => "trace",
          "turn" => 1,
          "response" => %{"value" => payload}
        }
      ],
      nil,
      "snapshot"
    )
    |> Map.put("evidence", %{"complete?" => true})
    |> Map.put("trace_snapshot_hash", "trace-snapshot")
  end

  defp snapshot_loop(token, page) do
    receive do
      {:"$gen_call", from, {^token, {:query, :turns, _arguments}}} ->
        GenServer.reply(from, {:ok, page})
        snapshot_loop(token, page)
    end
  end
end
