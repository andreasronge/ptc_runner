defmodule IncidentCompiler.StressCorpus do
  @moduledoc """
  Generates the `schema-migration-stall` stress corpus.

  The shipped incidents are 9-13 records, so every arm can fetch all of them
  and none of their retrieval assumptions is ever tested. This one is 320
  records across 8 sources, which the evidence server cannot return in one
  call: `search` caps at 50 and defaults a missing limit to 20.

  Nothing about the server is changed to accommodate that. Records are returned
  in `{observed_at, evidence_id}` order and truncated with `Enum.take`, so a
  capped search returns the *earliest* records — and this incident, like a real
  one, opens with hours of routine traffic before anything decisive happens.
  Each source therefore carries 24 pre-incident records ahead of its incident
  window. The consequences are arithmetic, not staging:

    * one unfiltered search (limit 50) sees 50 of 320, all pre-incident;
    * a per-source search with no limit sees 20 of ~40 per source, all
      pre-incident;
    * a per-source search passing limit 50 sees every record.

  A program that reads `truncated` learns which case it is in. None of the
  programs written so far does.

  The oracle is not shortcuttable: `required_fact_recall` demands both a
  citation of the named record *and* every `must_include` substring in the
  statement. Every such substring is asserted unique across all 320 bodies, so
  no decoy can supply one by accident.

      mix run incident_compiler/tools/gen_stress_corpus.exs
  """

  @incident "schema-migration-stall"
  @dir Path.join(["incident_compiler", "fixtures", "corpus", @incident])

  @sources [
    {"migration-log", "Statement-level output from the schema migration runner."},
    {"lock-monitor", "Database lock waits and holders sampled every 30 seconds."},
    {"pool-metrics", "Connection-pool utilisation samples for the orders service."},
    {"alerts", "Monitoring alerts raised against database and service objectives."},
    {"deployments", "Release and configuration-change events from the delivery pipeline."},
    {"chat", "Incident channel messages retained for the incident window."},
    {"tickets", "Incident and change tickets referenced during the response."},
    {"runbooks", "Runbook and configuration excerpts consulted by responders."}
  ]

  # Needles. Each is {source, minute_offset_from_0147, evidence_id, title, body}.
  # They sit in the incident window, after each source's routine tail, so a
  # truncated search cannot reach them.
  @needles [
    {"lock-monitor", 0, "lock-9001", "ACCESS SHARE holder on orders",
     "Session 8821 (application_name=analytics-nightly) has held ACCESS SHARE on public.orders since 01:47:22Z. Query text begins 'SELECT o.region, count(*) FROM orders o'. No statement_timeout is set on this session."},
    {"migration-log", 27, "mig-4410", "Migration waiting on lock",
     "Migration 2026-07-19-add-order-index requested ACCESS EXCLUSIVE on public.orders at 02:14:05Z and entered lock wait. The runner reports state=waiting and does not time out."},
    {"lock-monitor", 41, "lock-9044", "Queue depth behind the exclusive request",
     "1847 statements are queued behind the ACCESS EXCLUSIVE request on public.orders. Every queued statement targets that table; statements against other tables are unaffected."},
    {"pool-metrics", 75, "pool-3310", "Pool exhausted",
     "orders-service connection pool reached 40 of 40 in use at 03:02:11Z, with 96 requests waiting for a connection. Pool utilisation was below 55 percent until the lock wait began."},
    {"chat", 87, "chat-7788", "Pool scaled with no effect",
     "Scaled the orders-service pool from 40 to 120 connections at 03:14:40Z. Utilisation went straight to 120 of 120 and the waiting count kept climbing. Whatever this is, it is not pool sizing."},
    {"lock-monitor", 114, "lock-9102", "Analytics session terminated",
     "Session 8821 was terminated by an operator at 03:41:02Z, releasing ACCESS SHARE on public.orders."},
    {"migration-log", 114, "mig-4478", "Migration acquired lock and completed",
     "Migration 2026-07-19-add-order-index acquired ACCESS EXCLUSIVE and completed at 03:41:18Z, 87 minutes after requesting it. Index orders_region_created_idx created."},
    {"runbooks", 60, "run-2205", "Migration runner configuration",
     "Runner configuration for schema migrations: retries=0, statement_timeout=0, lock_timeout unset. The runbook notes that an unset lock_timeout means a blocked migration waits indefinitely rather than failing fast."}
  ]

  # Decoys that make the wrong hypothesis attractive: the pool did saturate, and
  # a release did go out. Neither caused anything.
  @plausible_decoys [
    {"deployments", 30, "dep-5501", "Release 4.22.0 deployed",
     "Release 4.22.0 deployed to orders-service. Changes: reporting export column widths, an unused feature flag, and a dependency bump. The release record lists no change to query paths or connection handling."},
    {"chat", 33, "chat-7702", "Suspect the release",
     "orders-service went bad right after 4.22.0 went out. Rolling it back first, then we can look at the database."},
    {"alerts", 78, "alert-6620", "Connection pool saturation",
     "Alert orders-service-pool-saturation fired. Pool in use 40 of 40, waiting 96. This alert measures pool utilisation only and does not distinguish a slow upstream from an undersized pool."},
    {"chat", 129, "chat-7810", "Rollback did not help",
     "4.22.0 rollback completed at 03:56:00Z. No change in behaviour — the queue had already drained by then. The rollback was not what fixed this."}
  ]

  def run do
    records = build_records()
    :ok = assert_unique_tokens!(records)

    File.mkdir_p!(Path.join(@dir, "evidence"))
    File.mkdir_p!(Path.join(@dir, "oracle"))

    write!(Path.join(@dir, "incident.json"), incident())
    write!(Path.join(@dir, "evidence/records.json"), records)
    write!(Path.join(@dir, "oracle/oracle.json"), oracle())

    by_source = Enum.frequencies_by(records, & &1["source"])

    IO.puts("wrote #{length(records)} records to #{@dir}")

    for {source, _} <- @sources do
      count = Map.fetch!(by_source, source)

      reachable =
        records
        |> Enum.filter(&(&1["source"] == source))
        |> Enum.sort_by(&{&1["observed_at"], &1["evidence_id"]})

      needles_in_source = Enum.count(reachable, &needle_id?(&1["evidence_id"]))
      first_20 = reachable |> Enum.take(20) |> Enum.count(&needle_id?(&1["evidence_id"]))
      first_50 = reachable |> Enum.take(50) |> Enum.count(&needle_id?(&1["evidence_id"]))

      IO.puts(
        "  #{String.pad_trailing(source, 14)} #{String.pad_leading(to_string(count), 3)} records" <>
          "   needles #{needles_in_source}  reachable@20 #{first_20}  reachable@50 #{first_50}"
      )
    end

    global =
      records |> Enum.sort_by(&{&1["observed_at"], &1["evidence_id"]}) |> Enum.take(50)

    IO.puts(
      "\n  one unfiltered search at limit 50 reaches " <>
        "#{Enum.count(global, &needle_id?(&1["evidence_id"]))} of #{length(@needles)} needles"
    )
  end

  defp needle_id?(id), do: Enum.any?(@needles, fn {_, _, nid, _, _} -> nid == id end)

  ## Records

  defp build_records do
    fixed =
      for {source, offset, id, title, body} <- @needles ++ @plausible_decoys do
        record(id, source, at(offset), title, body)
      end

    routine = Enum.flat_map(@sources, fn {source, _} -> routine_for(source) end)

    (fixed ++ routine)
    |> Enum.sort_by(&{&1["observed_at"], &1["evidence_id"]})
  end

  # 24 pre-incident records per source, then filler inside the incident window.
  # The pre-incident tail is what a truncated search returns.
  defp routine_for(source) do
    pre =
      for i <- 1..24 do
        record(
          "#{prefix(source)}-#{1000 + i}",
          source,
          at(-(360 - i * 14)),
          routine_title(source, i),
          routine_body(source, i)
        )
      end

    during =
      for i <- 25..40 do
        record(
          "#{prefix(source)}-#{1000 + i}",
          source,
          at(rem(i * 7, 130)),
          routine_title(source, i),
          routine_body(source, i)
        )
      end

    pre ++ during
  end

  defp prefix("migration-log"), do: "mig"
  defp prefix("lock-monitor"), do: "lock"
  defp prefix("pool-metrics"), do: "pool"
  defp prefix("alerts"), do: "alert"
  defp prefix("deployments"), do: "dep"
  defp prefix("chat"), do: "chat"
  defp prefix("tickets"), do: "tkt"
  defp prefix("runbooks"), do: "run"

  defp routine_title("migration-log", i), do: "Migration step #{i} applied"
  defp routine_title("lock-monitor", i), do: "Lock sample #{i}"
  defp routine_title("pool-metrics", i), do: "Pool sample #{i}"
  defp routine_title("alerts", i), do: "Objective check #{i}"
  defp routine_title("deployments", i), do: "Pipeline event #{i}"
  defp routine_title("chat", i), do: "Channel message #{i}"
  defp routine_title("tickets", i), do: "Ticket note #{i}"
  defp routine_title("runbooks", i), do: "Runbook section #{i}"

  # Deliberately mundane and interchangeable. These fill the early slots a
  # capped search returns, and none of them answers a required fact.
  defp routine_body("migration-log", i),
    do:
      "Statement #{i} of migration batch 2026-07-19 applied to a table other than public.orders. Duration #{41 + rem(i * 13, 55)}ms, rows affected #{rem(i * 31, 90)}. No lock wait recorded for this statement."

  defp routine_body("lock-monitor", i),
    do:
      "Lock sample: #{rem(i * 3, 9)} ACCESS SHARE holders across public.shipments, public.invoices and public.regions. Longest wait #{rem(i * 11, 40)}ms. No waiter on public.orders in this sample."

  defp routine_body("pool-metrics", i),
    do:
      "orders-service pool sample: #{12 + rem(i * 5, 21)} of 40 connections in use, 0 waiting, mean checkout #{2 + rem(i, 9)}ms. Within the configured objective."

  defp routine_body("alerts", i),
    do:
      "Objective evaluation #{i} for orders-service completed with no breach. Error ratio #{rem(i, 4)} in ten thousand, latency objective met."

  defp routine_body("deployments", i),
    do:
      "Pipeline event #{i}: configuration bundle promoted to staging. No production change. Artifact digest ends #{Integer.to_string(41 + rem(i * 7, 55), 16)}#{Integer.to_string(43 + rem(i * 11, 51), 16)}."

  defp routine_body("chat", i),
    do:
      "Routine channel traffic: shift handover note #{i}, no action outstanding. Nothing unusual reported on orders-service at this point."

  defp routine_body("tickets", i),
    do:
      "Ticket note #{i}: scheduled maintenance window request for an unrelated service. No relation to the orders database."

  defp routine_body("runbooks", i),
    do:
      "Runbook section #{i}: escalation contacts and paging policy for the orders service. Contains no database lock or migration guidance."

  defp record(id, source, observed_at, title, body) do
    %{
      "evidence_id" => id,
      "observed_at" => observed_at,
      "source" => source,
      "title" => title,
      "body" => body
    }
  end

  # Minute offsets from 2026-07-19T01:47:00Z.
  defp at(minutes) do
    base = DateTime.new!(~D[2026-07-19], ~T[01:47:00], "Etc/UTC")

    base
    |> DateTime.add(minutes * 60, :second)
    |> DateTime.to_iso8601()
    |> String.replace("+00:00", "Z")
  end

  ## Oracle

  defp required_facts do
    [
      {"lock-holder", ["lock-9001"], ["8821", "01:47:22"],
       "Analytics session 8821 held ACCESS SHARE on public.orders from 01:47:22Z."},
      {"migration-blocked", ["mig-4410"], ["02:14:05"],
       "The migration requested ACCESS EXCLUSIVE on public.orders at 02:14:05Z and entered lock wait."},
      {"queue-depth", ["lock-9044"], ["1847"],
       "1847 statements queued behind the exclusive lock request."},
      {"pool-is-symptom", ["pool-3310"], ["03:02:11"],
       "The pool reached 40 of 40 at 03:02:11Z, after the lock wait began."},
      {"scaling-no-effect", ["chat-7788"], ["03:14:40", "120"],
       "Scaling the pool to 120 connections at 03:14:40Z did not change the saturation."},
      {"recovery-cause", ["lock-9102"], ["03:41:02"],
       "Recovery followed termination of session 8821 at 03:41:02Z."},
      {"no-lock-timeout", ["run-2205"], ["lock_timeout"],
       "The migration runner had lock_timeout unset, so a blocked migration waits indefinitely."}
    ]
  end

  defp oracle do
    %{
      "incident_id" => @incident,
      "injected_faults" => [
        %{
          "summary" =>
            "A long-running analytics session held ACCESS SHARE on public.orders. A schema migration requested ACCESS EXCLUSIVE on the same table, blocked, and every subsequent statement against that table queued behind it. Pool exhaustion was a downstream symptom.",
          "evidence_ids" => ["lock-9001", "mig-4410", "lock-9044", "lock-9102"]
        }
      ],
      "required_facts" =>
        for {id, ids, tokens, claim} <- required_facts() do
          %{"id" => id, "claim" => claim, "evidence_ids" => ids, "must_include" => tokens}
        end,
      "contradicted_hypotheses" => [
        %{
          "must_include" => ["pool"],
          "evidence_ids" => ["chat-7788"],
          "note" =>
            "An undersized connection pool is the attractive wrong answer. Scaling it three-fold changed nothing, which the report must carry as evidence against the hypothesis rather than omit."
        },
        %{
          "must_include" => ["4.22.0"],
          "evidence_ids" => ["chat-7810", "dep-5501"],
          "note" =>
            "Release 4.22.0 is coincident and unrelated; its rollback completed after recovery had already begun."
        }
      ],
      "open_questions" => [
        %{
          "must_include" => ["analytics"],
          "note" => "No record names an owner for the analytics-nightly job."
        },
        %{
          "must_include" => ["impact"],
          "note" => "No record estimates customer impact during the 87-minute stall."
        }
      ]
    }
  end

  defp incident do
    %{
      "incident_id" => @incident,
      "title" => "Schema migration stalled behind a long-running analytics session",
      "opened_at" => "2026-07-19T03:05:00Z",
      "origin" => "synthesized-stress",
      "sources" =>
        for {source, description} <- @sources do
          %{"source" => source, "description" => description}
        end
    }
  end

  ## Integrity

  # Every `must_include` substring must appear in exactly the records the oracle
  # names, so no decoy can satisfy a requirement by accident and no requirement
  # can be met without reading its own record.
  defp assert_unique_tokens!(records) do
    authored =
      MapSet.new(for {_, _, id, _, _} <- @needles ++ @plausible_decoys, do: id)

    for {id, evidence_ids, tokens, _claim} <- required_facts(), token <- tokens do
      holders =
        records
        |> Enum.filter(&String.contains?(&1["body"], token))
        |> Enum.map(& &1["evidence_id"])
        |> Enum.sort()

      # The record the oracle names must actually carry the token, or the
      # requirement is unsatisfiable.
      for wanted <- evidence_ids, wanted not in holders do
        raise "required fact #{inspect(id)} names #{inspect(wanted)}, which does not contain #{inspect(token)}"
      end

      # No routine or filler record may carry it. A token appearing in another
      # hand-written record is fine and realistic — session 8821 is named both
      # where it takes the lock and where it is terminated — but a decoy
      # supplying one by accident would let a report satisfy a requirement
      # without reading the record the oracle points at.
      case Enum.reject(holders, &MapSet.member?(authored, &1)) do
        [] ->
          :ok

        leaked ->
          raise """
          token #{inspect(token)} for required fact #{inspect(id)} leaks into filler records.
            leaked into: #{inspect(leaked)}
          """
      end
    end

    :ok
  end

  defp write!(path, value) do
    File.write!(path, Jason.encode!(value, pretty: true) <> "\n")
  end
end

IncidentCompiler.StressCorpus.run()
