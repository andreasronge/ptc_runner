defmodule PtcRunnerMcp.AggregatorAutoDecodeTest do
  @moduledoc """
  Phase C of `Plans/json-support.md` (§6 Aggregator Auto-Decode).

  When an upstream `tools/call` returns a result envelope where:

    1. `result["structuredContent"]` is absent or `nil`,
    2. `result["content"]` is a list whose first item is a text item
       (`"type" == "text"`),
    3. The first item's `"mimeType"` is `"application/json"` (exact)
       or any string ending in `"+json"` (RFC 6839 structured suffix),
    4. `Jason.decode/1` on `"text"` returns `{:ok, value}`,

  the aggregator promotes the decoded value into
  `result["structuredContent"]` (additive — `content[]` is preserved)
  and emits a `[:ptc_runner_mcp, :upstream, :auto_decode, :stop]`
  telemetry event with measurements/metadata per §7.

  Decoded bare `nil` (the JSON literal `"null"`) is substituted with
  the `:"json-null"` keyword sentinel before assignment so the field
  is distinguishable from "absent" (§6.4 sub-field rule). The
  substitution applies ONLY to bare `nil` — `false` / `0` / `""` /
  `[]` are legitimate JSON payloads and must promote verbatim
  (post-§5.2 carve-out from `6852ca4`).

  Failure modes:

    * Malformed JSON with matching mimeType → result passes through
      unchanged, telemetry `:decode_failed`, **no**
      `upstream_calls` entry (§6.4 / §8 side-channel invariant —
      the side-channel is reserved for world-faults).
    * `structuredContent` already present → result passes through
      unchanged, telemetry `:already_structured`.
    * No matching mimeType / no text content → no telemetry event.

  Pipeline ordering (§6.4): classify_value → auto-decode → §7.3
  top-level :json-null rewrite. `isError: true` envelopes therefore
  never reach auto-decode.
  """

  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunnerMcp.{Limits, Tools}
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    stop_existing_registry(@registry_name)

    {:ok, _pid} = Registry.start_link(name: @registry_name)
    Limits.set(Limits.defaults())

    handler_id = "auto-decode-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:ptc_runner_mcp, :upstream, :auto_decode, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      stop_existing_registry(@registry_name)
      Limits.set(Limits.defaults())
    end)

    :ok
  end

  defp tools_config(tools) do
    %{
      tools:
        Map.new(tools, fn {n, fun} ->
          {n, {%{name: n, input_schema: %{}}, fun}}
        end)
    }
  end

  defp put_fake(name, tools) when is_map(tools) do
    :ok = Registry.put_fake(name, tools_config(tools), @registry_name)
  end

  defp call(program, extra \\ %{}) do
    args = Map.merge(%{"program" => program}, extra)
    Tools.call_with_gate(args)
  end

  defp structured(env), do: env["structuredContent"]
  defp upstream_calls(env), do: structured(env)["upstream_calls"] || []

  defp text_envelope(text, mime_type) do
    item = %{"type" => "text", "text" => text}

    item =
      case mime_type do
        nil -> item
        m when is_binary(m) -> Map.put(item, "mimeType", m)
      end

    %{"content" => [item]}
  end

  # ----------------------------------------------------------------
  # mimeType match → promotion
  # ----------------------------------------------------------------

  describe "auto-decode: mimeType triggers promotion (§6.1 / §6.4)" do
    test "exact application/json promotes structuredContent + preserves content[]" do
      put_fake("alpha", %{
        "j" => fn _, _ ->
          {:ok, text_envelope(~S|{"x":1,"y":[2,3]}|, "application/json")}
        end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (and (contains? r "structuredContent")
                   (= (get-in r ["structuredContent" "x"]) 1)
                   (= (get-in r ["structuredContent" "y"]) [2 3])
                   (= (get-in r ["content" 0 "text"]) "{\"x\":1,\"y\":[2,3]}")
                   (= (get-in r ["content" 0 "type"]) "text")
                   (= (get-in r ["content" 0 "mimeType"]) "application/json")))
          |,
          %{"signature" => ":bool"}
        )

      assert env["isError"] == false, "envelope: #{inspect(env, limit: :infinity)}"

      assert structured(env)["validated"] == true,
             "promotion+content-preservation contract failed: #{inspect(env, limit: :infinity)}"

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], meas, meta}
      assert meta.outcome == :promoted
      assert meta.server == "alpha"
      assert meta.tool == "j"
      assert meta.mime_type == "application/json"
      assert is_integer(meas.decoded_bytes)
      assert meas.decoded_bytes > 0
    end

    test "+json suffix: application/ld+json promotes" do
      put_fake("alpha", %{
        "j" => fn _, _ ->
          {:ok, text_envelope(~S|{"@id":"x"}|, "application/ld+json")}
        end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (= (get-in r ["structuredContent" "@id"]) "x"))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], _meas, meta}
      assert meta.outcome == :promoted
      assert meta.mime_type == "application/ld+json"
    end

    test "+json suffix: application/vnd.foo+json promotes" do
      put_fake("alpha", %{
        "j" => fn _, _ ->
          {:ok, text_envelope(~S|{"k":"v"}|, "application/vnd.foo+json")}
        end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (= (get-in r ["structuredContent" "k"]) "v"))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], _meas, meta}
      assert meta.outcome == :promoted
      assert meta.mime_type == "application/vnd.foo+json"
    end
  end

  # ----------------------------------------------------------------
  # No-match → pass-through, no event
  # ----------------------------------------------------------------

  describe "auto-decode: non-matching mimeType is silent (§6.1)" do
    test "mimeType absent → unchanged, no telemetry event" do
      put_fake("alpha", %{
        "j" => fn _, _ -> {:ok, text_envelope(~S|{"x":1}|, nil)} end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (not (contains? r "structuredContent")))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true
      refute_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], _, _}, 100
    end

    test "mimeType text/plain → unchanged, no telemetry event" do
      put_fake("alpha", %{
        "j" => fn _, _ -> {:ok, text_envelope(~S|{"x":1}|, "text/plain")} end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (not (contains? r "structuredContent")))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true
      refute_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], _, _}, 100
    end

    test "mimeType application/xml → unchanged, no telemetry event" do
      put_fake("alpha", %{
        "j" => fn _, _ -> {:ok, text_envelope("<x/>", "application/xml")} end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (not (contains? r "structuredContent")))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true
      refute_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], _, _}, 100
    end

    test "non-text first content item → no event even with matching mimeType-like field" do
      put_fake("alpha", %{
        "j" => fn _, _ ->
          {:ok,
           %{
             "content" => [
               %{"type" => "image", "mimeType" => "application/json", "data" => "..."}
             ]
           }}
        end
      })

      _env =
        call(~S|
          (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
            (contains? r "structuredContent"))
        |)

      refute_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], _, _}, 100
    end
  end

  # ----------------------------------------------------------------
  # Decode failure: side-channel invariant test (§6.4 / §8)
  # ----------------------------------------------------------------

  describe "auto-decode: malformed JSON pass-through (§6.4 lock-in)" do
    test "matching mimeType + malformed JSON → unchanged + :decode_failed event + NO upstream_calls entry" do
      bad_text = "{not json"

      put_fake("alpha", %{
        "j" => fn _, _ -> {:ok, text_envelope(bad_text, "application/json")} end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (and (not (contains? r "structuredContent"))
                   (= (get-in r ["content" 0 "text"]) "{not json")
                   (= (get-in r ["content" 0 "mimeType"]) "application/json")))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true,
             "decode failure must pass through unchanged: #{inspect(env, limit: :infinity)}"

      # Side-channel invariant: ONE upstream_calls entry, status: ok
      # — the call itself succeeded, only the decode failed and that
      # is reserved-silent in `upstream_calls` per §6.4 / §8.
      [entry] = upstream_calls(env)
      assert entry["status"] == "ok"

      refute Map.has_key?(entry, "reason"),
             "decode failure must NOT add a reason — that side-channel is reserved for world-faults"

      refute Map.has_key?(entry, "error"),
             "decode failure must NOT add an error — that side-channel is reserved for world-faults"

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], meas, meta}
      assert meta.outcome == :decode_failed
      assert meta.server == "alpha"
      assert meta.tool == "j"
      assert meta.mime_type == "application/json"
      assert meas.decoded_bytes == 0
      assert meas.text_bytes == byte_size(bad_text)
    end
  end

  # ----------------------------------------------------------------
  # Already structured: precedence (§6.1 #1)
  # ----------------------------------------------------------------

  describe "auto-decode: structuredContent already present (§6.1 #1)" do
    test "upstream's structuredContent wins — never overridden" do
      put_fake("alpha", %{
        "j" => fn _, _ ->
          {:ok,
           %{
             "content" => [
               %{"type" => "text", "text" => ~S|{"x":1}|, "mimeType" => "application/json"}
             ],
             "structuredContent" => %{"upstream-says" => "this"}
           }}
        end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (= (get-in r ["structuredContent" "upstream-says"]) "this"))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], meas, meta}
      assert meta.outcome == :already_structured
      assert meas.decoded_bytes == 0
    end

    test "upstream structuredContent set to nil is treated as absent → promoted" do
      # §6.1 #1: "absent or nil" — explicit nil should not block
      # promotion. Tests the precise wording.
      put_fake("alpha", %{
        "j" => fn _, _ ->
          {:ok,
           %{
             "content" => [
               %{"type" => "text", "text" => ~S|{"x":1}|, "mimeType" => "application/json"}
             ],
             "structuredContent" => nil
           }}
        end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (= (get-in r ["structuredContent" "x"]) 1))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], _meas, meta}
      assert meta.outcome == :promoted
    end
  end

  # ----------------------------------------------------------------
  # Sub-field :json-null rule (§6.4) and falsy-payload carve-out (§5.2)
  # ----------------------------------------------------------------

  describe "auto-decode: nil substitution + falsy carve-out (§5.2 / §6.4)" do
    test ~S|decoded bare nil ("null" text) → structuredContent == :"json-null"| do
      put_fake("alpha", %{
        "j" => fn _, _ -> {:ok, text_envelope("null", "application/json")} end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (= (get r "structuredContent") :json-null))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true,
             "structuredContent must be :json-null sentinel: #{inspect(env, limit: :infinity)}"

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], _meas, meta}
      assert meta.outcome == :promoted
    end

    test "decoded false → structuredContent == false (NOT :json-null)" do
      put_fake("alpha", %{
        "j" => fn _, _ -> {:ok, text_envelope("false", "application/json")} end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (and (= (get r "structuredContent") false)
                   (not= (get r "structuredContent") :json-null)))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true,
             "false must promote verbatim (not :json-null): #{inspect(env, limit: :infinity)}"
    end

    test "decoded 0 → structuredContent == 0 (NOT :json-null)" do
      put_fake("alpha", %{
        "j" => fn _, _ -> {:ok, text_envelope("0", "application/json")} end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (= (get r "structuredContent") 0))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true
    end

    test ~S|decoded "" → structuredContent == "" (NOT :json-null)| do
      put_fake("alpha", %{
        "j" => fn _, _ -> {:ok, text_envelope(~S|""|, "application/json")} end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (= (get r "structuredContent") ""))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true
    end

    test "decoded [] → structuredContent == [] (NOT :json-null)" do
      put_fake("alpha", %{
        "j" => fn _, _ -> {:ok, text_envelope("[]", "application/json")} end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "j" :args {}})]
              (and (vector? (get r "structuredContent"))
                   (empty? (get r "structuredContent"))))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true
    end
  end

  # ----------------------------------------------------------------
  # Pipeline ordering: isError + auto-decode interaction (§6.4)
  # ----------------------------------------------------------------

  describe "auto-decode: isError envelopes never reach auto-decode (§6.1 / §6.4)" do
    test "isError: true with matching mimeType → no :auto_decode telemetry event fires" do
      # Locks in pipeline ordering: classify_value runs first and
      # short-circuits to :upstream_error before auto-decode can
      # observe the value. Without this ordering, an isError: true
      # envelope with matching mimeType would leak a promoted value
      # through telemetry even if the program-visible result is nil.
      put_fake("alpha", %{
        "fail" => fn _, _ ->
          {:ok,
           %{
             "content" => [
               %{"type" => "text", "text" => ~S|{"err":"boom"}|, "mimeType" => "application/json"}
             ],
             "isError" => true
           }}
        end
      })

      env =
        call(
          ~S|(nil? (tool/mcp-call {:server "alpha" :tool "fail" :args {}}))|,
          %{"signature" => ":bool"}
        )

      assert structured(env)["validated"] == true,
             "Phase 4 isError contract regressed: program did not see nil"

      [entry] = upstream_calls(env)
      assert entry["status"] == "error"
      assert entry["reason"] == "upstream_error"

      # The discriminating assertion: NO :auto_decode telemetry
      # fires on isError envelopes. Pipeline ordering lock-in.
      refute_receive {:telemetry, [:ptc_runner_mcp, :upstream, :auto_decode, :stop], _, _}, 100
    end
  end

  # ----------------------------------------------------------------
  # Wire-amplification spot check (§8)
  # ----------------------------------------------------------------

  describe "auto-decode: wire amplification (§8 spot check)" do
    test "promoted upstream envelope is >= 1.5x the byte size of an unpromoted one" do
      # Sanity check that BOTH content[] AND structuredContent ride
      # back on the wire. If the implementation accidentally drops
      # one, the byte ratio collapses below 1.5x.
      #
      # The spec's "wire" framing (§6.4 / §8) is the aggregator's
      # outbound MCP response — but the program-level result rendering
      # truncates `inspect/1` output past a soft limit, which would
      # mask the doubling on small payloads. Test the doubling at the
      # discriminating layer: compare what `content[0].text` carries
      # (just `content[...]`) against what the promoted envelope
      # contains (`content[...]` + `structuredContent`). Both fields
      # ship in the actual MCP response per §6.4.
      json_text =
        ~S|{"key1":"value1","key2":"value2","key3":[1,2,3,4,5],"key4":{"nested":true}}|

      put_fake("alpha", %{
        "promoted" => fn _, _ -> {:ok, text_envelope(json_text, "application/json")} end,
        "plain" => fn _, _ -> {:ok, text_envelope(json_text, "text/plain")} end
      })

      # Reach the upstream envelope as the program sees it (and as
      # the aggregator places it on the wire). Use a `:bool` shape
      # to assert structurally first.
      promoted_env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "promoted" :args {}})]
              (and (contains? r "content")
                   (contains? r "structuredContent")))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(promoted_env)["validated"] == true,
             "auto-decode promotion did not occur: #{inspect(promoted_env, limit: :infinity)}"

      plain_env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "plain" :args {}})]
              (and (contains? r "content")
                   (not (contains? r "structuredContent"))))
          |,
          %{"signature" => ":bool"}
        )

      assert structured(plain_env)["validated"] == true,
             "non-matching mimeType should leave structuredContent absent: " <>
               inspect(plain_env, limit: :infinity)

      # Now measure the doubling on the upstream-shaped maps that the
      # aggregator placed on the wire. We reconstruct the post-
      # promotion shape (content[] + structuredContent) and the pre-
      # promotion shape (content[] only) directly from the upstream
      # fixture data, since that's what the aggregator literally
      # ships in `result["structuredContent"]` for downstream.
      decoded = Jason.decode!(json_text)

      promoted_upstream = %{
        "content" => [
          %{"type" => "text", "text" => json_text, "mimeType" => "application/json"}
        ],
        "structuredContent" => decoded
      }

      plain_upstream = %{
        "content" => [
          %{"type" => "text", "text" => json_text, "mimeType" => "application/json"}
        ]
      }

      promoted_bytes = byte_size(Jason.encode!(promoted_upstream))
      plain_bytes = byte_size(Jason.encode!(plain_upstream))
      ratio = promoted_bytes / plain_bytes

      assert ratio >= 1.5,
             "wire-amplification spot check failed: ratio #{ratio} " <>
               "(promoted=#{promoted_bytes} plain=#{plain_bytes}). " <>
               "If <1.5, the implementation is silently dropping one of " <>
               "content[] / structuredContent."
    end
  end
end
