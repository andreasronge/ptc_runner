# Trusted host join between one validated private trial result, that same run's
# canonical trace, and its exact private inspection artifact. RESULT_HASH is
# `sha256:` followed by the SHA-256 digest of RESULT.json's canonical bytes.
# Invoke with:
#
#   jq -n --arg result_hash "$RESULT_HASH" \
#     --slurpfile result RESULT.json --slurpfile trace TRACE.jsonl \
#     --slurpfile inspection INSPECTION.jsonl \
#     -f repo-analyst/join-trial.jq

def citation_is_backed_by_read($citation; $reads):
  ($citation.lines[0] <= $citation.lines[1])
  and any(
    $reads[];
    .arguments.path == $citation.path
    and .result.status == "ok"
    and .result.value.path == $citation.path
    and .result.value.snapshot_hash == $citation.snapshot_hash
    and (
      [range($citation.lines[0]; $citation.lines[1] + 1)]
      - [.result.value.lines[].line]
      | length == 0
    )
  );

(
  if ($result | length) != 1 then
    error("expected exactly one trial result")
  else
    $result[0]
  end
) as $trial
| [$trace[] | select(.type == "run-started")] as $starts
| (
    if ($starts | length) != 1 then
      error("expected exactly one run-started event")
    else
      $starts[0]
    end
  ) as $started
| [$trace[] | select(.type == "run-stopped")] as $stops
| (
    if ($stops | length) != 1 then
      error("expected exactly one run-stopped event")
    else
      $stops[0]
    end
  ) as $stopped
| [
    $inspection[]
    | select(
        .record_type == "capability-input"
        and .payload.environment == "mission"
        and .payload.name == "workspace.read"
      )
    | . as $input
    | first(
        $inspection[]
        | select(
            .record_type == "capability-output"
            and .correlation.capability_id == $input.correlation.capability_id
          )
      ) as $output
    | {
        "arguments": $input.payload.arguments,
        "result": $output.payload.result
      }
  ] as $reads
| ($started.data.connector_snapshots // []) as $providers
| [$providers[].snapshot_hash] as $provider_hashes
| [$providers[] | select(.content_snapshot_hash != null) | .content_snapshot_hash]
    as $content_hashes
| [$providers[] | select(.source == "llm_replay") | .fixture_set_hash]
    as $fixture_hashes
| ($started.data.component_overrides // []) as $overrides
| if ($started.run_id != $stopped.run_id)
    or ($started.trace_id != $stopped.trace_id) then
    error("run-started and run-stopped identities disagree")
  elif ($inspection | length) == 0
    or any(
      $inspection[];
      .run_id != $started.run_id or .trace_id != $started.trace_id
    ) then
    error("inspection artifact does not belong to the traced run")
  elif $result_hash != $stopped.data.result_hash then
    error("trial result digest does not match run-stopped")
  elif any(
    ($trial.citations // [])[];
    (citation_is_backed_by_read(.; $reads) | not)
  ) then
    error("trial citation is not backed by an exact workspace.read result")
  elif ($provider_hashes | length) == 0 then
    error("run recorded no provider identities")
  elif ($content_hashes | length) == 0 then
    error("run recorded no content snapshot identity")
  elif ($fixture_hashes | length) > 1 then
    error("run recorded more than one replay fixture set")
  else
    .
  end
| (
    if $trial.subject == "candidate" then
      if ($overrides | length) != 1 then
        error("candidate run must record exactly one component override")
      elif $overrides[0].component_id != $trial.candidate.component_id
        or $overrides[0].base_source_hash != $trial.candidate.base_source_hash
        or $overrides[0].source_hash != $trial.candidate.source_hash then
        error("candidate identity disagrees with the verified override")
      else
        {
          "override_component_id": $overrides[0].component_id,
          "override_base_source_hash": $overrides[0].base_source_hash,
          "override_source_hash": $overrides[0].source_hash
        }
      end
    elif $trial.subject == "baseline" then
      if ($overrides | length) == 0 then
        {}
      else
        error("baseline run unexpectedly recorded a component override")
      end
    else
      error("trial declares an unrecognised subject")
    end
  ) as $override_identity
| ($trial | del(.answer, .citations))
  + {
      "run_identity":
        ({
          "run_id": $started.run_id,
          "result_hash": $result_hash,
          "workflow_bundle_hash": $started.data.workflow_prelude.hash,
          "mission_bundle_hashes": ($started.data.missions | with_entries(.value = .value.prelude.hash)),
          "provider_snapshot_hashes": $provider_hashes,
          "content_snapshot_hashes": $content_hashes
        }
        + (if ($fixture_hashes | length) == 1 then
             {"fixture_set_hash": $fixture_hashes[0]}
           else
             {}
           end)
        + $override_identity)
    }
