defmodule PtcRunnerMcp.AggregatorIsErrorTest do
  @moduledoc """
  Phase 4 hardening (Plans/ptc-runner-mcp-aggregator.md §16 entry 2):
  upstream `tools/call` results with `isError: true` MUST be
  normalized to tagged failure data and recorded as
  `status: "error", reason: "tool_error"` in `upstream_calls`.

  Pre-fix the JSON-RPC call itself succeeded, so the aggregator
  recorded `status: "ok"` and the program received the upstream's
  error envelope as a non-`nil` value — silently breaking the §7.1
  *world-fault → nil* contract for tool-level errors.

  These tests pin the post-fix semantics:

    1. `isError: true` with the standard MCP `content[0].text` shape
       → program sees `:ok false`, entry has `reason: "tool_error"`,
       `error` carries the extracted text.
    2. `isError: false` is unchanged — program sees the value,
       entry has `status: "ok"`.
    3. An upstream that omits `isError` entirely (the common
       success case for many MCP servers) is treated as success.
    4. Top-level JSON `null` returns `:ok true, :value nil`.
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

    on_exit(fn ->
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

  describe "isError: true normalization (§16 entry 2)" do
    test "upstream isError: true with content[0].text → program sees tagged tool_error" do
      # Mirrors filesystem-MCP's ENOENT shape exactly:
      #     %{"content" => [%{"text" => "ENOENT: ...", "type" => "text"}],
      #       "isError" => true}
      put_fake("alpha", %{
        "fail" => fn _, _ ->
          {:ok,
           %{
             "content" => [%{"text" => "test failure msg", "type" => "text"}],
             "isError" => true
           }}
        end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "fail" :args {}})]
              (and (not (:ok r))
                   (= (:reason r) :tool_error)
                   (= (:message r) "test failure msg")))
          |,
          %{"output_schema" => %{"type" => "boolean"}}
        )

      assert env["isError"] == false, "envelope was: #{inspect(env, limit: :infinity)}"
      assert structured(env)["validated"] == true,
             "expected program to see tagged tool_error, got: #{inspect(env, limit: :infinity)}"

      [entry] = upstream_calls(env)
      assert entry["server"] == "alpha"
      assert entry["tool"] == "fail"
      assert entry["status"] == "error"
      assert entry["reason"] == "tool_error"
      assert entry["error"] == "test failure msg"

      assert is_integer(entry["duration_ms"]) and entry["duration_ms"] >= 0
    end

    test "upstream isError: true without content list falls back to inspect/2 detail" do
      # An upstream that doesn't follow the `content[0].text`
      # convention still surfaces as a world-fault; the error
      # detail uses `inspect/2` so the LLM has *something*
      # diagnostic.
      put_fake("alpha", %{
        "weird" => fn _, _ ->
          {:ok, %{"isError" => true, "details" => %{"code" => 42}}}
        end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "weird" :args {}})]
              (and (not (:ok r))
                   (= (:reason r) :tool_error)
                   (includes? (:message r) "details")))
          |,
          %{"output_schema" => %{"type" => "boolean"}}
        )

      assert env["isError"] == false
      assert structured(env)["validated"] == true

      [entry] = upstream_calls(env)
      assert entry["status"] == "error"
      assert entry["reason"] == "tool_error"
      assert entry["error"] =~ "details"
    end

    test "upstream isError: false leaves the value unchanged + status: ok" do
      put_fake("alpha", %{
        "ok" => fn _, _ ->
          {:ok,
           %{
             "content" => [%{"text" => "everything is fine", "type" => "text"}],
             "isError" => false
           }}
        end
      })

      env =
        call(~S|
          (let [r (tool/mcp-call {:server "alpha" :tool "ok" :args {}})]
            (:value r))
        |)

      assert env["isError"] == false
      assert structured(env)["status"] == "ok"
      # The program drilled into the upstream's content[0].text —
      # which means the upstream's value was passed through
      # unchanged (NOT normalized to nil).
      assert structured(env)["result"] =~ "everything is fine"

      [entry] = upstream_calls(env)
      assert entry["status"] == "ok"
      refute Map.has_key?(entry, "reason")
      refute Map.has_key?(entry, "error")
    end

    test "upstream that omits isError entirely is treated as success" do
      # Many MCP upstreams (memory-MCP, github-MCP for read calls,
      # etc.) don't emit `isError` when there's no error. The
      # absence of the key MUST NOT trip the new normalization
      # path.
      put_fake("alpha", %{
        "no_iserr" => fn _, _ ->
          {:ok, %{"content" => [%{"text" => "hello", "type" => "text"}]}}
        end
      })

      env =
        call(~S|
          (let [r (tool/mcp-call {:server "alpha" :tool "no_iserr" :args {}})]
            (:value r))
        |)

      assert env["isError"] == false
      assert structured(env)["result"] =~ "hello"

      [entry] = upstream_calls(env)
      assert entry["status"] == "ok"
    end

    test "top-level JSON null becomes tagged JSON nil" do
      put_fake("alpha", %{"null" => fn _, _ -> {:ok, nil} end})

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "null" :args {}})]
              (and (:ok r) (nil? (:value r)) (= (:value_kind r) :json)))
          |,
          %{"output_schema" => %{"type" => "boolean"}}
        )

      assert env["isError"] == false

      assert structured(env)["validated"] == true,
             "the program saw something other than tagged JSON nil: " <>
               inspect(env, limit: :infinity)

      [entry] = upstream_calls(env)
      assert entry["status"] == "ok"
    end

    test "isError: true with long ASCII content caps the recorded error string" do
      # Defensive: an upstream that emits a multi-megabyte error
      # message (e.g., a stack trace) must not bloat
      # `upstream_calls[].error`. The post-fix cap is 500
      # codepoints + a single ellipsis. For ASCII (1 byte per
      # codepoint) the codepoint cap and byte cap coincide.
      huge = String.duplicate("a", 10_000)

      put_fake("alpha", %{
        "fail" => fn _, _ ->
          {:ok, %{"content" => [%{"text" => huge, "type" => "text"}], "isError" => true}}
        end
      })

      env =
        call(~S|(tool/mcp-call {:server "alpha" :tool "fail" :args {}})|)

      assert env["isError"] == false
      [entry] = upstream_calls(env)
      assert entry["status"] == "error"
      assert entry["reason"] == "tool_error"

      assert String.length(entry["error"]) < String.length(huge),
             "error string was not truncated"

      # 500 codepoints of payload + 1 codepoint ellipsis = 501
      # codepoints in the worst case. Pin that exact upper bound
      # so future regressions to a larger cap are caught.
      assert String.length(entry["error"]) <= 501,
             "error string was not capped near 500 codepoints: #{String.length(entry["error"])}"
    end

    test "isError: true with multi-byte UTF-8 content slices on codepoint boundaries" do
      # Codex review of `923d2c8` flagged that the byte-aligned
      # truncation (`<<head::binary-size(500), _::binary>> = text`)
      # could slice a multi-byte UTF-8 codepoint mid-encoding,
      # producing an invalid binary that then crashed
      # `Jason.encode!/1` when the response envelope was built —
      # i.e. an MCP server crash on an isError envelope from an
      # upstream emitting non-ASCII text (Chinese stack traces,
      # error messages with `€`, em-dashes, etc.). The post-fix
      # cap is in codepoints, not bytes.
      #
      # We use `€` (U+20AC, **3** UTF-8 bytes — `0xE2 0x82 0xAC`)
      # rather than `é` (U+00E9, 2 bytes) because the byte cap of
      # 500 happens to fall on a clean boundary for 2-byte
      # codepoints (500 is even). For 3-byte codepoints, byte
      # offset 500 lands at codepoint index 166⅔ — i.e., on the
      # second byte of the 167th `€` — which leaves a half-encoded
      # trailing byte that breaks `String.valid?/1` and crashes
      # `Jason.encode!/1` with `invalid byte 0xE2`. This reproduces
      # the full-server crash that codex caught.
      #
      # 600 × `€` = 1800 bytes, well over a byte-based 500 cap.
      multibyte = String.duplicate("€", 600)
      assert byte_size(multibyte) == 1_800
      assert String.length(multibyte) == 600

      put_fake("alpha", %{
        "fail" => fn _, _ ->
          {:ok, %{"content" => [%{"text" => multibyte, "type" => "text"}], "isError" => true}}
        end
      })

      env =
        call(
          ~S|
            (let [r (tool/mcp-call {:server "alpha" :tool "fail" :args {}})]
              (and (not (:ok r)) (= (:reason r) :tool_error)))
          |,
          %{"output_schema" => %{"type" => "boolean"}}
        )

      # Phase 4 contract: still normalized to a tagged world-fault.
      assert env["isError"] == false,
             "envelope should not be an error: #{inspect(env, limit: :infinity)}"

      assert structured(env)["validated"] == true,
             "program did not see tagged tool_error: #{inspect(env, limit: :infinity)}"

      [entry] = upstream_calls(env)
      assert entry["status"] == "error"
      assert entry["reason"] == "tool_error"

      # Discriminating assertions for the codex finding:
      #
      # 1. The recorded `error` is **valid UTF-8**. Pre-fix this
      #    was `false` because the byte-aligned truncation cut
      #    the second-to-last `é` mid-encoding.
      assert String.valid?(entry["error"]),
             "error string is invalid UTF-8: #{inspect(entry["error"], limit: 50)}"

      # 2. Length is bounded by the codepoint cap.
      assert String.length(entry["error"]) <= 501,
             "error string exceeds codepoint cap: " <>
               "#{String.length(entry["error"])} codepoints"

      # 3. The envelope round-trips through `Jason.encode!/1`
      #    without raising. This is THE discriminating assertion:
      #    pre-fix, building the structured response would have
      #    raised `Jason.EncodeError` because the truncated
      #    `error` field carried an invalid UTF-8 binary, and the
      #    MCP server would have crashed instead of replying.
      assert is_binary(Jason.encode!(env)),
             "Jason.encode!/1 of the envelope did not produce a binary"
    end
  end
end
