defmodule PtcRunnerMcp.Tools do
  @moduledoc """
  `tools/list` and `tools/call` handlers.

  Per `Plans/ptc-runner-mcp-server.md` § 8.1, the server advertises
  exactly one tool, `ptc_lisp_execute`. The advertised description is
  the canonical `:mcp_no_tools` profile string from
  `PtcRunner.PtcToolProtocol`, followed by exactly two newlines, then
  the package-owned authoring card (§ 8.4).

  Phase 2 wired real `Lisp.run/2` execution through
  `PtcRunnerMcp.Sandbox` and enforced `:max_program_bytes` and
  `:max_concurrent_calls` (§ 11). Phase 3 wires the remaining two
  arguments per § 9.3 / § 9.4:

    * `context` — JSON object whose keys land as `data/<key>` bindings
      inside the program. Validated for shape, key syntax, and
      encoded byte size before a concurrency permit is acquired.
    * `signature` — PTC signature string, parsed via
      `PtcToolProtocol.parse_signature/1` and used for return-value
      validation only. Parse failure is `args_error`; mismatch
      between the parsed signature and the program's return is
      `validation_error`.

  Both validations short-circuit before `ConcurrencyGate.try_acquire/1`
  so a malformed argument never consumes a permit.
  """

  alias PtcRunner.PtcToolProtocol
  alias PtcRunnerMcp.{ConcurrencyGate, Envelope, Limits, Sandbox}

  @tool_name "ptc_lisp_execute"

  # Compile-time read of the authoring card per § 8.4. The
  # `@external_resource` attribute tells BEAM to recompile this module
  # whenever the file changes. We resolve the path relative to this
  # source file rather than via `:code.priv_dir/1` because the app may
  # not yet be loaded at compile time.
  @priv_path Path.expand(Path.join([__DIR__, "..", "..", "priv", "mcp_authoring_card.md"]))
  @external_resource @priv_path
  @authoring_card File.read!(@priv_path)

  # Verbatim § 10.4 outputSchema. `oneOf` discriminated by `status`.
  # `result` is intentionally NOT in the success branch's `required`
  # list — `render_success/2` elides it for programs whose final
  # expression and `lisp_step.return` are both nil (§ 7.4 D2).
  @output_schema %{
    "type" => "object",
    "oneOf" => [
      %{
        "type" => "object",
        "required" => ["status", "prints", "feedback", "memory", "truncated"],
        "properties" => %{
          "status" => %{"const" => "ok"},
          "result" => %{"type" => "string"},
          "prints" => %{"type" => "array", "items" => %{"type" => "string"}},
          "feedback" => %{"type" => "string"},
          "memory" => %{
            "type" => "object",
            "required" => ["changed", "stored_keys", "truncated"],
            "properties" => %{
              "changed" => %{
                "type" => "object",
                "additionalProperties" => %{"type" => "string"}
              },
              "stored_keys" => %{"type" => "array", "items" => %{"type" => "string"}},
              "truncated" => %{"type" => "boolean"}
            }
          },
          "truncated" => %{"type" => "boolean"},
          "validated" => %{}
        }
      },
      %{
        "type" => "object",
        "required" => ["status", "reason", "message", "feedback"],
        "properties" => %{
          "status" => %{"const" => "error"},
          "reason" => %{
            "type" => "string",
            "enum" => [
              "parse_error",
              "runtime_error",
              "timeout",
              "memory_limit",
              "args_error",
              "fail",
              "validation_error",
              "busy",
              "unknown_tool"
            ]
          },
          "message" => %{"type" => "string"},
          "feedback" => %{"type" => "string"},
          "result" => %{"type" => "string"}
        }
      }
    ]
  }

  @doc """
  The verbatim authoring-card markdown shipped at
  `mcp_server/priv/mcp_authoring_card.md`.

  Read at compile time via `@external_resource`; edits to the source
  file trigger a recompile of this module.
  """
  @spec authoring_card() :: String.t()
  def authoring_card, do: @authoring_card

  @doc """
  The advertised `description` field for the `ptc_lisp_execute` tool.

  Composed per § 8.4 as
  `tool_description(:mcp_no_tools) <> "\\n\\n" <> authoring_card()`.
  """
  @spec advertised_description() :: String.t()
  def advertised_description do
    PtcToolProtocol.tool_description(:mcp_no_tools) <> "\n\n" <> authoring_card()
  end

  @doc """
  The verbatim § 10.4 `outputSchema` advertised in `tools/list`.

  Returned as a plain map (Jason-encodable). Tests assert byte-for-byte
  equality against the spec literal so any drift is caught at compile
  time of the test suite.
  """
  @spec output_schema() :: map()
  def output_schema, do: @output_schema

  @doc "The single tool entry returned in `tools/list`."
  @spec tool_entry() :: map()
  def tool_entry do
    %{
      "name" => @tool_name,
      "description" => advertised_description(),
      "inputSchema" => input_schema(),
      "outputSchema" => @output_schema,
      "annotations" => %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      }
    }
  end

  @doc "Handle a `tools/list` request. Always returns the single advertised tool."
  @spec list() :: map()
  def list, do: %{"tools" => [tool_entry()]}

  @doc """
  Handle a `tools/call` request.

  For `name: "ptc_lisp_execute"`, validates `program` (§ 9.2),
  `context` (§ 9.3), and `signature` (§ 9.4) before acquiring a
  concurrency permit. All argument-shape failures emit `args_error`
  without consuming a permit. The permit is held only while the
  underlying `Lisp.run/2` is in flight and is released even on
  validation error after execution.

  For any other name, returns an `unknown_tool` envelope per § 7.4
  D1 (NOT JSON-RPC `-32601`).

  ## Gate ownership

  Phase 4 moves `tools/call` execution into per-call worker processes
  spawned by `PtcRunnerMcp.Stdio` (§ 6.3, § 11). The serial-dispatch
  comment that lived here in Phase 2 is gone: the stdio reader now
  acquires the concurrency permit synchronously *before* spawning the
  worker, and releases it when the worker exits (normally or via
  `notifications/cancelled`). `Tools.call/1` keeps the legacy permit
  acquire/release for direct in-process callers (and tests); the
  worker path uses `call_validated/3` to skip the gate (the stdio
  reader owns it). See `Stdio.handle_async_call/3`.
  """
  @spec call(map()) :: map()
  def call(%{"name" => @tool_name, "arguments" => args}) when is_map(args) do
    handle_execute_with_gate(args)
  end

  def call(%{"name" => @tool_name}), do: handle_execute_with_gate(%{})

  def call(%{"name" => name}) when is_binary(name), do: Envelope.unknown_tool(name)
  def call(_), do: Envelope.unknown_tool("")

  @doc """
  Validate the inner `arguments` map for `tools/call name:
  "ptc_lisp_execute"`.

  Returns `{:ok, program, context, parsed_signature}` when all three
  argument-shape checks pass, or `{:error, envelope}` with the
  rendered `args_error` envelope when any fails. Used by
  `PtcRunnerMcp.Stdio` to short-circuit malformed requests *before*
  acquiring a concurrency permit (§ 9 / § 11).
  """
  @spec validate(map()) ::
          {:ok, String.t(), map(), Sandbox.parsed_signature()} | {:error, map()}
  def validate(args) when is_map(args) do
    with {:ok, program} <- validate_program(args),
         {:ok, context} <- validate_context(args),
         {:ok, parsed_signature} <- validate_signature(args) do
      {:ok, program, context, parsed_signature}
    else
      {:error, message} -> {:error, Envelope.render_error(:args_error, message)}
    end
  end

  @doc """
  Run an already-validated `tools/call` invocation WITHOUT acquiring a
  concurrency permit.

  Used by the per-call worker spawned in `PtcRunnerMcp.Stdio`: stdio
  acquires the permit before spawning, and releases it when the worker
  exits. `Sandbox.execute/3` is invoked with `link: true` so a worker
  killed by `notifications/cancelled` takes its sandbox child with it
  via the link signal (rather than letting the orphaned sandbox
  process run until its own heap/timeout limit).
  """
  @spec call_validated(String.t(), map(), Sandbox.parsed_signature()) :: map()
  def call_validated(program, context, parsed_signature)
      when is_binary(program) and is_map(context) do
    Sandbox.execute(program, context, parsed_signature, link: true)
  end

  @doc """
  Acquire-then-execute for in-process callers. Returns `:busy`
  envelope if `:max_concurrent_calls` is exceeded.

  Stdio does NOT use this — it owns the gate itself. This entry
  point exists for tests and any direct in-VM caller that wants
  end-to-end semantics in one shot.
  """
  @spec call_with_gate(map()) :: map()
  def call_with_gate(args) when is_map(args) do
    handle_execute_with_gate(args)
  end

  defp handle_execute_with_gate(args) do
    case validate(args) do
      {:ok, program, context, parsed_signature} ->
        run_with_gate(program, context, parsed_signature)

      {:error, envelope} ->
        envelope
    end
  end

  defp run_with_gate(program, context, parsed_signature) do
    cap = Limits.max_concurrent_calls()

    # Phase 4: this entry point is for direct in-process callers and
    # tests. The MCP stdio reader does NOT call this — it owns the
    # gate itself (acquire before spawn, release on worker DOWN) so a
    # worker killed by `notifications/cancelled` cannot leak permits
    # via a skipped `try/after` cleanup. See `Stdio.handle_async_call/3`.
    case ConcurrencyGate.try_acquire(cap) do
      :ok ->
        try do
          Sandbox.execute(program, context, parsed_signature)
        after
          ConcurrencyGate.release()
        end

      :full ->
        Envelope.busy(cap)
    end
  end

  # § 9.2: missing → not a string → empty after trim → too large.
  defp validate_program(args) do
    case Map.fetch(args, "program") do
      :error ->
        {:error, "argument `program` is required"}

      {:ok, value} when not is_binary(value) ->
        {:error, "argument `program` must be a string, got #{type_label(value)}"}

      {:ok, value} ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            {:error, "argument `program` must be a non-empty string"}

          byte_size(value) > Limits.max_program_bytes() ->
            {:error,
             "argument `program` exceeds max_program_bytes (" <>
               Integer.to_string(byte_size(value)) <>
               " > " <>
               Integer.to_string(Limits.max_program_bytes()) <> ")"}

          true ->
            {:ok, value}
        end
    end
  end

  # § 9.3: validate `context` shape, key syntax, and encoded byte size.
  # On success returns the same map (Jason already gave us binaries,
  # integers, floats, lists, maps — exactly what `Lisp.run/2`'s
  # `:context` opt expects).
  defp validate_context(args) do
    case Map.fetch(args, "context") do
      :error ->
        {:ok, %{}}

      {:ok, nil} ->
        {:ok, %{}}

      {:ok, value} when not is_map(value) or is_struct(value) ->
        {:error, "argument `context` must be a JSON object, got #{type_label(value)}"}

      {:ok, value} ->
        with :ok <- check_context_size(value),
             :ok <- check_context_keys(value) do
          {:ok, value}
        end
    end
  end

  defp check_context_size(map) do
    case Jason.encode(map) do
      {:ok, encoded} ->
        size = byte_size(encoded)
        cap = Limits.max_context_bytes()

        if size > cap do
          {:error,
           "argument `context` exceeds max_context_bytes (" <>
             Integer.to_string(size) <> " > " <> Integer.to_string(cap) <> ")"}
        else
          :ok
        end

      {:error, reason} ->
        {:error, "argument `context` is not JSON-encodable: #{inspect(reason)}"}
    end
  end

  defp check_context_keys(map) do
    Enum.reduce_while(map, :ok, fn {k, _v}, _acc ->
      cond do
        not is_binary(k) ->
          {:halt, {:error, "argument `context` keys must be strings (got: #{inspect(k)})"}}

        k == "" ->
          {:halt, {:error, "argument `context` keys must be non-empty"}}

        String.contains?(k, "/") ->
          {:halt,
           {:error,
            "argument `context` keys may not contain `/` (would shadow PTC-Lisp namespace): #{inspect(k)}"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # § 9.4: validate that `signature`, when present, is a string and
  # parses cleanly. Parse failure short-circuits BEFORE permit
  # acquisition.
  defp validate_signature(args) do
    case Map.fetch(args, "signature") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when not is_binary(value) ->
        {:error, "argument `signature` must be a string, got #{type_label(value)}"}

      {:ok, value} ->
        case PtcToolProtocol.parse_signature(value) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, reason} -> {:error, "argument `signature` is malformed: #{reason}"}
        end
    end
  end

  defp type_label(v) when is_struct(v), do: "struct"
  defp type_label(v) when is_map(v), do: "object"
  defp type_label(v) when is_list(v), do: "array"
  defp type_label(v) when is_integer(v), do: "integer"
  defp type_label(v) when is_float(v), do: "number"
  defp type_label(v) when is_boolean(v), do: "boolean"
  defp type_label(nil), do: "null"
  defp type_label(_), do: "unknown"

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "program" => %{
          "type" => "string",
          "description" => "PTC-Lisp source code. Must be non-empty after trimming whitespace."
        },
        "context" => %{
          "type" => "object",
          "description" =>
            "Optional map of named values bound under data/ in the program. " <>
              "Keys are strings; values are JSON-encodable.",
          "additionalProperties" => true
        },
        "signature" => %{
          "type" => "string",
          "description" =>
            "Optional PTC signature for return validation, e.g. '() -> {count :int}'."
        }
      },
      "required" => ["program"]
    }
  end
end
