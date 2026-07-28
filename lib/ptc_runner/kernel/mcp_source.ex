defmodule PtcRunner.Kernel.MCPSource do
  @moduledoc """
  Builds one host-installed, read-only MCP capability source.

  The host freezes one typed `:streamable_http` or `:stdio` transport,
  upstream-to-public tool mappings, and installed ceilings in `builder/1`. A
  manifest can only select mapped public names and lower the request timeout
  or result ceiling. Each run build discovers one stateless MCP 2026-07-28
  server and its tools, compiles their bounded schemas, and returns ordinary
  frozen Kernel capabilities plus a safe deterministic snapshot. Input and
  output schemas are compiled once during assembly and the compiled validators
  are reused for every invocation.

  Runtime calls propagate a W3C `traceparent` derived from the private Kernel
  trace and capability-attempt identities. When private inspection is
  explicitly enabled, version 2 inspection records retain paired exact decoded
  JSON-RPC request and response bodies correlated to that attempt. Transport
  credentials and environment values are never part of those bodies or
  records.

  Streamable HTTP supports JSON and SSE responses to POST requests and rejects
  redirects and remote endpoint changes. Both transports support schema-valid
  structured object results with exact text or embedded text-resource
  companions. Unstructured results expose ordered text plus bounded embedded
  text resources; binary resources and other content block types remain
  unsupported. The source rejects writes and manifest-supplied connection or
  credential configuration.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.MCPLauncherStaging
  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Kernel.MCPRequestContext
  alias PtcRunner.Kernel.MCPStdioTransport
  alias PtcRunner.Kernel.ProviderError

  @protocol "2026-07-28"
  @client_info %{"name" => "ptc_runner", "version" => "0.x"}
  @client_capabilities %{}
  @max_result_bytes 1_048_576
  # The wire response also contains its JSON-RPC envelope and may contain
  # transport-level formatting. Keep this hard safety bound independent from
  # the canonical decoded-result ceiling exposed to operators.
  @max_transport_response_bytes 2_097_152
  @max_discovery_bytes 1_048_576
  @max_headers 32
  @max_header_bytes 16_384
  @max_outbound_headers 64
  @max_outbound_header_bytes 32_768
  @max_launcher_bytes 16_777_216
  @max_launcher_symlinks 40
  @launcher_protocol_version 1
  @header_token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @sha256 ~r/\Asha256:[0-9a-f]{64}\z/
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @sse_event_separator ~r/(?:\r\n|\r|\n)(?:\r\n|\r|\n)/

  @type builder :: PtcRunner.Kernel.ProviderRegistry.builder()

  @spec builder(keyword()) :: builder()
  @doc """
  Returns an installed provider builder for one fixed MCP source.

  ## Options

    * `:transport` - required `{type, options}` tuple. The type is
      `:streamable_http` or `:stdio`. Streamable HTTP requires a fixed HTTPS
      `:endpoint`; loopback HTTP is accepted only when
      `:allow_insecure_loopback` is `true` (default `false`), and userinfo and
      fragments are rejected. Its zero-argument `:headers` callback defaults
      to `fn -> [] end`, is evaluated once inside the provider-acquisition
      deadline, and is reused for the built provider. At most 32 valid headers
      totaling 16,384 bytes are accepted; client-owned `mcp-*` names are
      rejected. Header values never enter capabilities, snapshots, errors,
      Logger, Telemetry, or canonical events. Stdio requires absolute `:executable` and
      `:cwd` paths plus the executable's raw 32-byte `:executable_sha256`.
      Optional stdio fields are `:args` (default `[]`), `:env` (default `%{}`),
      `:grace_ms` (default `250`, maximum `5_000`), `:stderr_bytes` (default
      `65_536`, maximum `1_048_576`), and `:start_timeout_ms` (default `5_000`,
      maximum `60_000`). At most 256 arguments and 256 environment bindings
      are accepted; every configuration string is at most 131,072 bytes.
      Strings are UTF-8 and NUL-free; environment names use the portable
      `[A-Za-z_][A-Za-z0-9_]*` form. The launcher is limited to 16 MiB. The
      optional absolute `:launcher` path is a trusted custom override.
      Otherwise stdio requires
      the optional `ptc_runner_launcher ~> 0.1.0` companion dependency. The
      core owns launcher protocol version 1, copies the canonical launcher into
      a private mode-0700 staging directory, hashes and executes those same
      staged bytes, and removes the staged path after the startup handshake.
      The configured server executable and working-directory hierarchies must
      remain trusted and immutable through launcher preflight and spawn.
    * `:tools` - required map from fixed upstream names to
      `%{as: public_name, effect: :read}`. A mapping may also carry a bounded
      host-owned `:description`, `:model_visible` (default `true` for direct
      embedding), and `:error_feedback` (`:closed`, the default, or
      `:bounded`). Bounded feedback exposes at most 1,024 bytes of exact,
      validated text from an MCP `isError` result as untrusted recoverable
      capability-error details. Enabling it trusts the installed server not
      to place secrets, paths, or stack traces in that text. Public canonical
      events remain closed. Both names are unique and bounded; only the public
      name crosses the capability boundary. The host JSON decoder supplies its
      stricter model-invisible default explicitly.
    * `:timeout_ms` - installed end-to-end ceiling for discovery, calls, and
      requests (default `5_000`; stdio maximum `300_000`). A manifest may only
      lower it.
    * `:max_result_bytes` - installed decoded MCP result ceiling (default
      `1_000_000`; maximum `1_048_576`). The same canonical JSON measurement
      applies to both transports independently of JSON-RPC and framing
      overhead.
    * `:max_catalog_tools` - discovery catalog ceiling from 1 through 128
      (default `128`).
    * `:max_pages` - discovery pagination ceiling from 1 through 64
      (default `16`).
    * `:snapshot_identity` - optional `%{tool: upstream_name, field: name}`.
      After discovery, the source invokes that mapped read-only tool once with
      an empty argument object, requires the named field to contain a lowercase
      `sha256:` digest, and folds it into the frozen provider snapshot.
    * `:installation_revision` - optional bounded non-secret behavior revision
      included in the safe provider snapshot.

  Unknown or invalid installation options raise `ArgumentError` without
  including option values. The returned registry builder accepts an `"allow"`
  list of installed public names (defaulting to every mapped public name), an
  optional `"model_visible"` subset (defaulting to the selected names whose
  host mapping is model-visible), and optional lower `"timeout_ms"` and
  `"max_result_bytes"` values; invalid selections return
  `{:error, :invalid_mcp_selection}`. Assembly returns
  `{:ok, %{capabilities: list, snapshot: map, close: zero_arity_function}}` or a
  stable atom error: `:mcp_authentication_failed`, `:mcp_timeout`,
  `:mcp_transport_error`, `:mcp_protocol_error`, `:mcp_remote_error`,
  `:mcp_response_exceeded`, `:mcp_catalog_exceeded`, `:mcp_invalid_catalog`,
  `:mcp_invalid_tool_schema`, `:mcp_unsupported_result`,
  `:mcp_mapped_tool_missing`, or `:mcp_invalid_snapshot_identity`.

  ## Frozen result and snapshot contracts

  Discovery produces ordinary read-only `PtcRunner.Kernel.Capability` values.
  An advertised object output schema accepts only schema-valid
  `structuredContent` accompanied by exact text blocks (which are validated
  and discarded). A tool without an output schema accepts only exact text
  blocks and returns `%{"text" => [string()]}`.
  MCP `isError`, malformed/mixed content, invalid JSON-RPC envelopes, and
  schema failures become bounded `PtcRunner.Kernel.ProviderError` values with
  closed reasons. Authentication, timeout, unsupported-result, invalid-result,
  and transport failures never include remote messages or payloads.

  The safe connector snapshot has top-level fields `provider`, `protocol`,
  `transport`, `server_info_hash`, `snapshot_hash`, and `tools`. When the host
  installs `snapshot_identity`, it also carries the validated
  `content_snapshot_hash`; changing that identity changes the overall
  `snapshot_hash`. Stdio
  snapshots additionally contain the launcher protocol, launcher digest, and
  server-executable digest. The nullable server hash fingerprints bounded self-reported
  implementation identity without exposing its untrusted text. Successful
  tools without an output schema return `%{"text" => [string()]}` and add a
  `"resources"` list only when the result contains exact embedded text
  resources. Each resource retains only `uri`, `text`, and optional
  `mimeType`; response ceilings bound the complete decoded result before
  normalization. Each sorted tool entry contains only its public `name`, fixed
  `"read"` effect,
  model-visibility flag, one-way upstream-name and nullable prompt-visible
  description hashes, `input_schema_hash`, nullable `output_schema_hash`, and
  nullable `http_headers_hash`. Hashes are lowercase SHA-256; endpoints, raw
  upstream names and descriptions, headers, credentials, paths, arguments,
  and results are excluded.
  """
  def builder(opts) when is_list(opts) do
    case installed_config(opts) do
      {:ok, installed} -> fn selection, context -> build(installed, selection, context) end
      {:error, reason} -> raise ArgumentError, "invalid MCP source: #{reason}"
    end
  end

  def builder(_opts), do: raise(ArgumentError, "invalid MCP source")

  defp installed_config(opts) do
    allowed = [
      :transport,
      :tools,
      :timeout_ms,
      :max_result_bytes,
      :max_catalog_tools,
      :max_pages,
      :snapshot_identity,
      :installation_revision
    ]

    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys -- allowed == [] and Enum.uniq(keys) == keys,
         {:ok, transport} <- installed_transport(Keyword.get(opts, :transport)),
         {:ok, tools} <- installed_tools(Keyword.get(opts, :tools)),
         timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 <-
           Keyword.get(opts, :timeout_ms, 5_000),
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
           Keyword.get(opts, :max_result_bytes, 1_000_000),
         :ok <- transport_ceilings(transport, timeout_ms, max_result_bytes),
         max_catalog_tools when max_catalog_tools in 1..128 <-
           Keyword.get(opts, :max_catalog_tools, 128),
         max_pages when max_pages in 1..64 <- Keyword.get(opts, :max_pages, 16),
         {:ok, snapshot_identity} <-
           installed_snapshot_identity(Keyword.get(opts, :snapshot_identity), tools),
         {:ok, installation_revision} <-
           optional_installation_revision(Keyword.get(opts, :installation_revision)) do
      {:ok,
       %{
         transport: transport,
         tools: tools,
         timeout_ms: timeout_ms,
         max_result_bytes: max_result_bytes,
         max_catalog_tools: max_catalog_tools,
         max_pages: max_pages,
         snapshot_identity: snapshot_identity,
         installation_revision: installation_revision
       }}
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp installed_transport({:streamable_http, opts}) when is_list(opts) do
    allowed = [:endpoint, :headers, :allow_insecure_loopback]

    with true <- Keyword.keyword?(opts),
         true <- Keyword.keys(opts) -- allowed == [],
         true <- Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts),
         endpoint when is_binary(endpoint) <- Keyword.get(opts, :endpoint),
         allow_insecure_loopback when is_boolean(allow_insecure_loopback) <-
           Keyword.get(opts, :allow_insecure_loopback, false),
         :ok <- endpoint(endpoint, allow_insecure_loopback),
         headers when is_function(headers, 0) <- Keyword.get(opts, :headers, fn -> [] end) do
      {:ok, %{type: :streamable_http, endpoint: endpoint, headers: headers}}
    else
      _reason -> {:error, :invalid_transport}
    end
  end

  defp installed_transport({:stdio, opts}) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts),
         true <- :launcher_protocol_version not in Keyword.keys(opts),
         {:ok, opts} <- freeze_launcher_override(opts),
         validation_options =
           opts
           |> Keyword.put_new(:launcher, "/ptc-runner-launcher")
           |> Keyword.put(:launcher_protocol_version, @launcher_protocol_version),
         {:ok, _config} <- MCPStdioTransport.validate_options(validation_options) do
      {:ok, %{type: :stdio, options: opts}}
    else
      _reason -> {:error, :invalid_transport}
    end
  end

  defp installed_transport(_transport), do: {:error, :invalid_transport}

  defp freeze_launcher_override(opts) do
    case Keyword.fetch(opts, :launcher) do
      {:ok, launcher} ->
        with {:ok, canonical} <- canonical_executable_path(launcher),
             do: {:ok, Keyword.put(opts, :launcher, canonical)}

      :error ->
        {:ok, opts}
    end
  end

  defp transport_ceilings(%{type: :streamable_http}, _timeout_ms, max_result_bytes) do
    if max_result_bytes <= @max_result_bytes,
      do: :ok,
      else: {:error, :invalid_transport}
  end

  defp transport_ceilings(%{type: :stdio}, timeout_ms, max_result_bytes) do
    ceilings = MCPStdioTransport.request_ceilings()

    if timeout_ms <= ceilings.timeout_ms and max_result_bytes <= @max_result_bytes and
         @max_transport_response_bytes <= ceilings.result_bytes,
       do: :ok,
       else: {:error, :invalid_transport}
  end

  defp endpoint(endpoint, allow_loopback?) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil} when is_binary(host) ->
        :ok

      %URI{scheme: "http", host: host, userinfo: nil, fragment: nil}
      when allow_loopback? and host in ["127.0.0.1", "localhost", "::1"] ->
        :ok

      _uri ->
        {:error, :invalid_endpoint}
    end
  end

  defp installed_tools(tools) when is_map(tools) and map_size(tools) in 1..128 do
    Enum.reduce_while(tools, {:ok, %{}, MapSet.new()}, fn
      {upstream, %{as: public, effect: :read} = mapping}, {:ok, normalized, public_names}
      when is_binary(upstream) and is_binary(public) ->
        description = Map.get(mapping, :description)
        model_visible = Map.get(mapping, :model_visible, true)
        error_feedback = Map.get(mapping, :error_feedback, :closed)

        if Map.keys(mapping) --
             [:as, :effect, :description, :model_visible, :error_feedback] == [] and
             MCPProtocol.valid_tool_name?(upstream) and public =~ @name and
             not MapSet.member?(public_names, public) and
             (is_nil(description) or valid_string?(description, 4_096)) and
             is_boolean(model_visible) and error_feedback in [:closed, :bounded] do
          {:cont,
           {:ok,
            Map.put(normalized, upstream, %{
              as: public,
              effect: :read,
              description: description,
              model_visible: model_visible,
              error_feedback: error_feedback
            }), MapSet.put(public_names, public)}}
        else
          {:halt, {:error, :invalid_tools}}
        end

      _mapping, _acc ->
        {:halt, {:error, :invalid_tools}}
    end)
    |> case do
      {:ok, normalized, _names} -> {:ok, normalized}
      error -> error
    end
  end

  defp installed_tools(_tools), do: {:error, :invalid_tools}

  defp installed_snapshot_identity(nil, _tools), do: {:ok, nil}

  defp installed_snapshot_identity(%{tool: tool, field: field} = identity, tools)
       when map_size(identity) == 2 and is_binary(tool) and is_binary(field) do
    if Map.has_key?(tools, tool) and field =~ @name,
      do: {:ok, identity},
      else: {:error, :invalid_snapshot_identity}
  end

  defp installed_snapshot_identity(_identity, _tools),
    do: {:error, :invalid_snapshot_identity}

  defp optional_installation_revision(nil), do: {:ok, nil}

  defp optional_installation_revision(value) do
    if valid_string?(value, 256),
      do: {:ok, value},
      else: {:error, :invalid_installation_revision}
  end

  defp valid_string?(value, max_bytes),
    do:
      is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp build(installed, selection, context) do
    with {:ok, selected} <- selection(installed, selection, context),
         {:ok, transport} <- acquire_transport(installed.transport, context, selected) do
      case discover(transport, installed, selected, context.provider) do
        {:ok, capabilities, snapshot} ->
          {:ok,
           %{
             capabilities: capabilities,
             snapshot: snapshot,
             close: fn -> close_transport(transport) end
           }}

        {:error, reason} ->
          case close_transport(transport) do
            :ok -> {:error, reason}
            {:error, :mcp_transport_error} -> {:error, :mcp_transport_error}
          end
      end
    end
  end

  defp acquire_transport(%{type: :streamable_http} = installed, context, selected) do
    with {:ok, headers} <- resolve_headers(installed.headers, selected.timeout_ms),
         {:ok, request_context} <-
           MCPRequestContext.start(
             owner: context.owner,
             endpoint: installed.endpoint,
             headers: headers,
             timeout_ms: selected.timeout_ms
           ) do
      {:ok, %{type: :streamable_http, handle: request_context}}
    end
  end

  defp acquire_transport(%{type: :stdio, options: options}, context, selected) do
    deadline_ms = System.monotonic_time(:millisecond) + selected.timeout_ms

    result =
      case within_deadline(selected.timeout_ms, fn ->
             prepare_staged_launcher(options, context.owner, selected.timeout_ms)
           end) do
        {:ok, staged} ->
          staged
          |> start_stdio_transport(options, context, selected, deadline_ms)
          |> finalize_launcher_staging(staged, deadline_ms)

        error ->
          error
      end

    normalize_stdio_acquisition(result)
  end

  defp prepare_staged_launcher(options, owner, lease_ms) do
    with {:ok, staging} <- MCPLauncherStaging.start(owner, lease_ms) do
      case with {:ok, launcher} <- resolve_stdio_launcher(options),
                do: stage_launcher(launcher, staging) do
        {:ok, _staged} = success ->
          success

        error ->
          _ = MCPLauncherStaging.close(staging, lease_ms)
          error
      end
    end
  end

  defp start_stdio_transport(staged, options, context, selected, deadline_ms) do
    with remaining_ms when remaining_ms > 0 <-
           deadline_ms - System.monotonic_time(:millisecond),
         options =
           options
           |> Keyword.put(:launcher, staged.path)
           |> Keyword.put(:launcher_protocol_version, @launcher_protocol_version)
           |> Keyword.update(
             :start_timeout_ms,
             min(5_000, remaining_ms),
             &min(&1, remaining_ms)
           ),
         {:ok, handle} <- MCPStdioTransport.start(options, context.owner) do
      {:ok,
       %{
         type: :stdio,
         handle: handle,
         timeout_ms: selected.timeout_ms,
         launcher_protocol_version: @launcher_protocol_version,
         launcher_sha256: Base.encode16(staged.digest, case: :lower),
         server_executable_sha256:
           options
           |> Keyword.fetch!(:executable_sha256)
           |> Base.encode16(case: :lower)
       }}
    end
  end

  defp normalize_stdio_acquisition(result) do
    case result do
      {:ok, _transport} = success ->
        success

      remaining_ms when is_integer(remaining_ms) and remaining_ms <= 0 ->
        {:error, :mcp_timeout}

      {:error, :mcp_timeout} ->
        {:error, :mcp_timeout}

      {:error, :mcp_stdio_spawn_timeout} ->
        {:error, :mcp_timeout}

      {:error, _reason} ->
        {:error, :mcp_transport_error}
    end
  end

  defp resolve_stdio_launcher(options) do
    with {:ok, launcher} <- configured_stdio_launcher(options),
         do: canonical_executable_path(launcher)
  end

  defp configured_stdio_launcher(options) do
    case Keyword.fetch(options, :launcher) do
      {:ok, launcher} -> {:ok, launcher}
      :error -> companion_launcher()
    end
  end

  defp companion_launcher do
    launcher_module = Module.concat(["PtcRunnerLauncher"])

    if Code.ensure_loaded?(launcher_module) and
         function_exported?(launcher_module, :protocol_version, 0) and
         function_exported?(launcher_module, :executable_path, 0) and
         launcher_module.protocol_version() == @launcher_protocol_version do
      case launcher_module.executable_path() do
        {:ok, launcher} -> {:ok, launcher}
        {:error, :unsupported_platform} -> {:error, :unsupported_mcp_stdio_platform}
        {:error, _reason} -> {:error, :mcp_stdio_launcher_unavailable}
      end
    else
      {:error, :mcp_stdio_launcher_unavailable}
    end
  end

  defp close_transport(%{
         type: :streamable_http,
         handle: %MCPRequestContext{} = request_context
       }),
       do: MCPRequestContext.close(request_context)

  defp close_transport(%{type: :stdio, handle: %MCPStdioTransport{} = handle}),
    do: MCPStdioTransport.close(handle)

  defp stage_launcher(source, staging) do
    with {:ok, stat} <- File.stat(source),
         true <-
           stat.type == :regular and stat.size in 1..@max_launcher_bytes and
             Bitwise.band(stat.mode, 0o111) != 0,
         {:ok, digest} <- copy_launcher(source, staging.path),
         :ok <- File.chmod(staging.path, 0o500) do
      {:ok, Map.put(staging, :digest, digest)}
    else
      _invalid -> {:error, :mcp_stdio_launcher_unavailable}
    end
  rescue
    _exception -> {:error, :mcp_stdio_launcher_unavailable}
  end

  defp copy_launcher(source, target) do
    with {:ok, input} <- File.open(source, [:read, :binary]) do
      try do
        case File.open(target, [:write, :binary, :exclusive], fn output ->
               copy_launcher_chunks(input, output, :crypto.hash_init(:sha256), 0)
             end) do
          {:ok, {:ok, digest}} -> {:ok, digest}
          _error -> {:error, :mcp_stdio_launcher_unavailable}
        end
      after
        File.close(input)
      end
    end
  end

  defp copy_launcher_chunks(input, output, hash, bytes) do
    case IO.binread(input, 65_536) do
      :eof when bytes > 0 ->
        {:ok, :crypto.hash_final(hash)}

      chunk when is_binary(chunk) and bytes + byte_size(chunk) <= @max_launcher_bytes ->
        with :ok <- IO.binwrite(output, chunk) do
          copy_launcher_chunks(
            input,
            output,
            :crypto.hash_update(hash, chunk),
            bytes + byte_size(chunk)
          )
        end

      _empty_exceeded_or_error ->
        {:error, :mcp_stdio_launcher_unavailable}
    end
  end

  defp finalize_launcher_staging(result, staging, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)
    cleanup = MCPLauncherStaging.close(staging, remaining_ms)
    deadline_expired? = System.monotonic_time(:millisecond) >= deadline_ms

    cond do
      cleanup == :ok and not deadline_expired? ->
        result

      deadline_expired? ->
        rollback_acquisition(result, :mcp_timeout, &close_transport/1)

      true ->
        rollback_acquisition(
          result,
          :mcp_stdio_launcher_unavailable,
          &close_transport/1
        )
    end
  end

  @doc false
  def rollback_acquisition({:ok, transport}, reason, close)
      when is_atom(reason) and is_function(close, 1) do
    case close.(transport) do
      :ok -> {:error, reason}
      _cleanup_failed -> {:error, :mcp_transport_error}
    end
  rescue
    _exception -> {:error, :mcp_transport_error}
  catch
    _kind, _reason -> {:error, :mcp_transport_error}
  end

  def rollback_acquisition(_result, reason, close)
      when is_atom(reason) and is_function(close, 1),
      do: {:error, reason}

  defp canonical_executable_path(path) when is_binary(path) do
    case Path.split(path) do
      ["/" | components] -> resolve_path_components("/", components, 0)
      _relative_or_invalid -> {:error, :mcp_stdio_launcher_unavailable}
    end
  end

  defp canonical_executable_path(_path), do: {:error, :mcp_stdio_launcher_unavailable}

  defp resolve_path_components(_current, [], _symlinks),
    do: {:error, :mcp_stdio_launcher_unavailable}

  defp resolve_path_components(current, ["." | remaining], symlinks),
    do: resolve_path_components(current, remaining, symlinks)

  defp resolve_path_components(current, [".." | remaining], symlinks),
    do: resolve_path_components(Path.dirname(current), remaining, symlinks)

  defp resolve_path_components(current, [component | remaining], symlinks) do
    candidate = Path.join(current, component)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :directory}} when remaining != [] ->
        resolve_path_components(candidate, remaining, symlinks)

      {:ok, %File.Stat{type: :regular}} when remaining == [] ->
        {:ok, candidate}

      {:ok, %File.Stat{type: :symlink}} ->
        resolve_symlink(current, candidate, remaining, symlinks)

      _missing_or_invalid ->
        {:error, :mcp_stdio_launcher_unavailable}
    end
  end

  defp resolve_symlink(current, candidate, remaining, symlinks) do
    with true <- symlinks < @max_launcher_symlinks,
         {:ok, target} <- File.read_link(candidate) do
      case Path.split(target) do
        ["/" | target_components] ->
          resolve_path_components("/", target_components ++ remaining, symlinks + 1)

        target_components ->
          resolve_path_components(current, target_components ++ remaining, symlinks + 1)
      end
    else
      _missing_or_exceeded -> {:error, :mcp_stdio_launcher_unavailable}
    end
  end

  defp selection(installed, selection, context) do
    with true <- is_map(selection) and not is_struct(selection),
         true <-
           Map.keys(selection) -- ~w(allow model_visible timeout_ms max_result_bytes) == [],
         public_names =
           Map.new(installed.tools, fn {_upstream, mapping} -> {mapping.as, mapping} end),
         allow when is_list(allow) and length(allow) in 1..128 <-
           Map.get(selection, "allow", public_names |> Map.keys() |> Enum.sort()),
         true <- Enum.all?(allow, &is_binary/1) and Enum.uniq(allow) == allow,
         true <- Enum.all?(allow, &Map.has_key?(public_names, &1)),
         installed_visible =
           Enum.filter(allow, fn name -> Map.fetch!(public_names, name).model_visible end),
         model_visible when is_list(model_visible) and length(model_visible) <= 128 <-
           Map.get(selection, "model_visible", installed_visible),
         true <-
           Enum.all?(model_visible, &is_binary/1) and
             Enum.uniq(model_visible) == model_visible,
         true <- Enum.all?(model_visible, &(&1 in installed_visible)),
         timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 <-
           Map.get(
             selection,
             "timeout_ms",
             min(installed.timeout_ms, destination_timeout(context))
           ),
         true <- timeout_ms <= installed.timeout_ms,
         true <- timeout_ms <= destination_timeout(context),
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
           Map.get(
             selection,
             "max_result_bytes",
             min(installed.max_result_bytes, context.limits.capability_result_bytes)
           ),
         true <- max_result_bytes <= installed.max_result_bytes,
         true <- max_result_bytes <= context.limits.capability_result_bytes do
      {:ok,
       %{
         allow: MapSet.new(allow),
         model_visible: MapSet.new(model_visible),
         timeout_ms: timeout_ms,
         max_result_bytes: max_result_bytes
       }}
    else
      _reason -> {:error, :invalid_mcp_selection}
    end
  end

  defp destination_timeout(%{destination: :workflow, limits: limits}),
    do: limits.workflow_timeout_ms

  defp destination_timeout(%{destination: :mission, limits: limits}),
    do: limits.evaluation_timeout_ms

  defp discover(transport, installed, selected, provider) do
    with {:ok, discovery} <-
           rpc(
             transport,
             "server/discover",
             %{},
             @max_discovery_bytes
           ),
         {:ok, server} <- MCPProtocol.discover_result(discovery, @protocol),
         true <- Map.has_key?(server.capabilities, "tools"),
         {:ok, discovered} <- list_tools(transport, installed),
         {:ok, capabilities, tools} <-
           capabilities(transport, installed, selected, discovered),
         {:ok, content_snapshot_hash} <-
           content_snapshot_hash(transport, installed, selected, discovered),
         {:ok, snapshot} <-
           snapshot(
             provider,
             transport,
             tools,
             server.server_info,
             content_snapshot_hash,
             installed
           ) do
      {:ok, capabilities, snapshot}
    else
      {:error, _reason} = error -> error
      _reason -> {:error, :mcp_protocol_error}
    end
  end

  defp list_tools(transport, installed) do
    state = %{
      tools: %{},
      names: %{},
      seen: %{},
      received_tools: 0,
      received_bytes: 0,
      cache_scope: nil
    }

    list_tools(transport, installed, nil, state, 0)
  end

  defp list_tools(_request, installed, _cursor, state, pages)
       when pages >= installed.max_pages or state.received_tools > installed.max_catalog_tools,
       do: {:error, :mcp_catalog_exceeded}

  defp list_tools(transport, installed, cursor, state, pages) do
    params = if is_nil(cursor), do: %{}, else: %{"cursor" => cursor}

    with {:ok, result} <- rpc(transport, "tools/list", params, @max_discovery_bytes) do
      case MCPProtocol.catalog_page(
             result,
             state,
             installed.max_catalog_tools,
             @max_discovery_bytes
           ) do
        {:done, tools} ->
          {:ok, tools}

        {:continue, next, state} ->
          list_tools(transport, installed, next, state, pages + 1)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp capabilities(transport, installed, selected, discovered) do
    installed.tools
    |> Enum.filter(fn {_upstream, mapping} -> MapSet.member?(selected.allow, mapping.as) end)
    |> Enum.sort_by(fn {_upstream, mapping} -> mapping.as end)
    |> Enum.reduce_while({:ok, [], []}, fn {upstream, mapping}, {:ok, capabilities, tools} ->
      case capability(transport, upstream, mapping, discovered[upstream], selected) do
        {:ok, capability, snapshot_tool} ->
          {:cont, {:ok, [capability | capabilities], [snapshot_tool | tools]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, capabilities, tools} -> {:ok, Enum.reverse(capabilities), Enum.reverse(tools)}
      error -> error
    end
  end

  defp capability(_request, _upstream, _mapping, nil, _selected),
    do: {:error, :mcp_mapped_tool_missing}

  defp capability(transport, upstream, mapping, tool, selected) do
    case MCPProtocol.selected_tool(tool) do
      {:ok, contract} ->
        assemble_capability(transport, upstream, mapping, contract, selected)

      {:error, _reason} = error ->
        error
    end
  end

  defp assemble_capability(transport, upstream, mapping, contract, selected) do
    with {:ok, capability} <-
           Capability.new(
             name: mapping.as,
             description: mapping.description || contract.description,
             model_visible: MapSet.member?(selected.model_visible, mapping.as),
             input_schema: contract.input_schema,
             output_schema: contract.output_schema,
             effect: :read,
             callback: fn _arguments, _context -> {:error, :uninstalled_mcp_callback} end
           ),
         capability = %{
           capability
           | callback:
               callback(
                 transport,
                 upstream,
                 contract.header_parameters,
                 capability.output_validator,
                 mapping.error_feedback,
                 selected
               )
         },
         {:ok, input_hash} <- schema_hash(capability.input_schema),
         {:ok, output_hash} <- optional_schema_hash(capability.output_schema),
         {:ok, headers_hash} <-
           transport_header_parameters_hash(transport.type, contract.header_parameters) do
      upstream_name_hash = sha256(upstream)

      description_hash =
        if capability.model_visible, do: optional_text_hash(capability.description), else: nil

      {:ok, capability,
       %{
         "name" => mapping.as,
         "effect" => "read",
         "error_feedback" => Atom.to_string(mapping.error_feedback),
         "model_visible" => capability.model_visible,
         "upstream_name_hash" => upstream_name_hash,
         "description_hash" => description_hash,
         "input_schema_hash" => input_hash,
         "output_schema_hash" => output_hash,
         "http_headers_hash" => headers_hash
       }}
    else
      _reason -> {:error, :mcp_invalid_tool_schema}
    end
  end

  defp callback(
         transport,
         upstream,
         header_parameters,
         output_validator,
         error_feedback,
         selected
       ) do
    fn arguments, context ->
      case rpc(
             transport,
             "tools/call",
             %{"name" => upstream, "arguments" => arguments},
             selected.max_result_bytes,
             header_parameters,
             context
           ) do
        {:ok, result} -> normalize_result(result, output_validator, error_feedback)
        {:error, reason} -> {:error, provider_error(reason)}
      end
    end
  end

  defp normalize_result(result, output_validator, error_feedback) do
    case MCPProtocol.normalize_tool_result(result, output_validator, error_feedback) do
      {:ok, value} ->
        {:ok, value}

      {:error, :mcp_domain_error} ->
        {:error, ProviderError.new(:domain_error, "mcp_domain_error")}

      {:error, {:mcp_domain_error, feedback}} ->
        {:error, ProviderError.new(:domain_error, feedback)}

      {:error, :mcp_invalid_result} ->
        {:error, ProviderError.new(:invalid_result, "mcp_invalid_result")}
    end
  end

  defp content_snapshot_hash(_transport, %{snapshot_identity: nil}, _selected, _discovered),
    do: {:ok, nil}

  defp content_snapshot_hash(
         transport,
         %{snapshot_identity: %{tool: upstream, field: field}} = installed,
         selected,
         discovered
       ) do
    mapping = Map.fetch!(installed.tools, upstream)

    with tool when is_map(tool) <- discovered[upstream],
         {:ok, contract} <- MCPProtocol.selected_tool(tool),
         {:ok, capability, _snapshot_tool} <-
           assemble_capability(transport, upstream, mapping, contract, selected),
         true <- JSONSchema.valid?(capability.input_validator, %{}),
         {:ok, value} <- capability.callback.(%{}, nil),
         hash when is_binary(hash) <- value[field],
         true <- hash =~ @sha256 do
      {:ok, hash}
    else
      _reason -> {:error, :mcp_invalid_snapshot_identity}
    end
  end

  defp snapshot(
         provider,
         %{type: type} = transport,
         tools,
         server_info,
         content_snapshot_hash,
         installed
       )
       when is_binary(provider) and type in [:streamable_http, :stdio] do
    transport_name = Atom.to_string(type)
    identity_projection = transport_identity_projection(transport)
    identity_fields = transport_identity_fields(transport)

    with {:ok, server_info_hash} <- optional_server_info_hash(server_info),
         projection =
           {:object,
            [
              {"protocol", "mcp-#{@protocol}"},
              {"transport", transport_name}
            ] ++
              identity_projection ++
              optional_projection(
                "installation_revision",
                installed.installation_revision
              ) ++
              optional_projection("content_snapshot_hash", content_snapshot_hash) ++
              [
                {"server_info_hash", server_info_hash},
                {"tools",
                 Enum.map(tools, fn tool ->
                   {:object,
                    [
                      {"name", tool["name"]},
                      {"effect", tool["effect"]},
                      {"error_feedback", tool["error_feedback"]},
                      {"model_visible", tool["model_visible"]},
                      {"upstream_name_hash", tool["upstream_name_hash"]},
                      {"description_hash", tool["description_hash"]},
                      {"input_schema_hash", tool["input_schema_hash"]},
                      {"output_schema_hash", tool["output_schema_hash"]},
                      {"http_headers_hash", tool["http_headers_hash"]}
                    ]}
                 end)}
              ]},
         {:ok, encoded} <- DeterministicJSON.encode(projection) do
      snapshot =
        Map.merge(
          %{
            "provider" => provider,
            "protocol" => "mcp-#{@protocol}",
            "transport" => transport_name,
            "server_info_hash" => server_info_hash,
            "snapshot_hash" => sha256(encoded),
            "tools" => tools
          },
          identity_fields
        )
        |> maybe_put_snapshot(
          "installation_revision",
          installed.installation_revision
        )
        |> maybe_put_snapshot("content_snapshot_hash", content_snapshot_hash)

      {:ok, snapshot}
    end
  end

  defp optional_projection(_key, nil), do: []
  defp optional_projection(key, value), do: [{key, value}]

  defp maybe_put_snapshot(snapshot, _key, nil), do: snapshot
  defp maybe_put_snapshot(snapshot, key, value), do: Map.put(snapshot, key, value)

  defp transport_identity_projection(%{type: :streamable_http}), do: []

  defp transport_identity_projection(%{type: :stdio} = transport) do
    [
      {"launcher_protocol_version", transport.launcher_protocol_version},
      {"launcher_sha256", transport.launcher_sha256},
      {"server_executable_sha256", transport.server_executable_sha256}
    ]
  end

  defp transport_identity_fields(%{type: :streamable_http}), do: %{}

  defp transport_identity_fields(%{type: :stdio} = transport) do
    %{
      "launcher_protocol_version" => transport.launcher_protocol_version,
      "launcher_sha256" => transport.launcher_sha256,
      "server_executable_sha256" => transport.server_executable_sha256
    }
  end

  defp schema_hash(schema) do
    with {:ok, encoded} <- DeterministicJSON.encode(schema), do: {:ok, sha256(encoded)}
  end

  defp optional_schema_hash(nil), do: {:ok, nil}
  defp optional_schema_hash(schema), do: schema_hash(schema)

  defp optional_server_info_hash(nil), do: {:ok, nil}
  defp optional_server_info_hash(server_info), do: schema_hash(server_info)
  defp optional_text_hash(nil), do: nil
  defp optional_text_hash(value), do: sha256(value)

  defp header_parameters_hash([]), do: {:ok, nil}

  defp header_parameters_hash(parameters) do
    parameters
    |> Enum.map(fn parameter ->
      %{
        "name" => String.downcase(parameter.name),
        "path" => parameter.path,
        "type" => parameter.type
      }
    end)
    |> schema_hash()
  end

  defp transport_header_parameters_hash(:streamable_http, parameters),
    do: header_parameters_hash(parameters)

  defp transport_header_parameters_hash(:stdio, _parameters), do: {:ok, nil}

  defp rpc(transport, method, params, max_bytes),
    do: rpc(transport, method, params, max_bytes, [], nil)

  defp rpc(
         %{type: :streamable_http, handle: request_context},
         method,
         params,
         max_bytes,
         header_parameters,
         context
       ) do
    with_request(request_context, fn request ->
      with {:ok, parameter_headers} <-
             MCPProtocol.header_values(header_parameters, Map.get(params, "arguments", %{})),
           {:ok, headers} <- request_headers(request, method, params, parameter_headers),
           payload = MCPProtocol.request(request.id, method, params, request_metadata(context)),
           {:ok, response} <-
             http(request, headers, payload, @max_transport_response_bytes),
           {:ok, body} <- response_body(response, request.id),
           :ok <- capture_exchange(context, :streamable_http, payload, body) do
        bounded_outcome(body, method, max_bytes)
      end
    end)
  end

  defp rpc(
         %{type: :stdio, handle: handle, timeout_ms: timeout_ms},
         method,
         params,
         max_bytes,
         _header_parameters,
         context
       ) do
    request =
      if match?(%{inspection_sink: %InspectionSink{}}, context) do
        MCPStdioTransport.request_exchange(
          handle,
          method,
          params,
          request_metadata(context),
          @max_transport_response_bytes,
          timeout_ms
        )
      else
        MCPStdioTransport.request(
          handle,
          method,
          params,
          request_metadata(nil),
          @max_transport_response_bytes,
          timeout_ms
        )
      end

    case request do
      {:ok, %{request: payload, response: body}} ->
        with :ok <- capture_exchange(context, :stdio, payload, body),
             do: bounded_outcome(body, method, max_bytes)

      {:ok, body} ->
        bounded_outcome(body, method, max_bytes)

      {:error, :closed} ->
        {:error, :mcp_transport_error}

      {:error, _reason} = error ->
        error
    end
  end

  defp capture_exchange(nil, _transport, _request, _response), do: :ok

  defp capture_exchange(
         %{inspection_sink: nil},
         _transport,
         _request,
         _response
       ),
       do: :ok

  defp capture_exchange(
         %{capability_id: capability_id, inspection_sink: sink},
         transport,
         %{"id" => request_id} = request,
         %{"id" => request_id} = response
       ) do
    correlation = %{capability_id: capability_id, request_id: request_id}
    payload = fn body -> %{transport: transport, body: body} end

    case InspectionSink.emit(sink, "mcp-request", correlation, payload.(request)) do
      :ok -> InspectionSink.emit(sink, "mcp-response", correlation, payload.(response))
      {:error, :inspection_sink_error} = error -> error
    end
  end

  defp capture_exchange(
         %{inspection_sink: sink},
         _transport,
         _request,
         _response
       ),
       do: InspectionSink.emit(sink, "mcp-request", %{}, %{})

  defp bounded_outcome(body, method, max_result_bytes) do
    with {:ok, result} <- MCPProtocol.outcome(body, method),
         {:ok, encoded} <- DeterministicJSON.encode(result),
         true <- byte_size(encoded) <= max_result_bytes do
      {:ok, result}
    else
      false -> {:error, :mcp_response_exceeded}
      {:error, :invalid_json} -> {:error, :mcp_protocol_error}
      {:error, :duplicate_key} -> {:error, :mcp_protocol_error}
      {:error, _reason} = error -> error
    end
  end

  defp with_request(request_context, callback) do
    case MCPRequestContext.begin_request(request_context) do
      {:ok, request} ->
        try do
          within_deadline(request.timeout_ms, fn -> callback.(request) end)
        after
          MCPRequestContext.finish_request(request_context)
        end

      {:error, :closed} ->
        {:error, :mcp_transport_error}
    end
  end

  defp resolve_headers(callback, timeout_ms) do
    within_deadline(timeout_ms, fn ->
      with {:ok, headers} <- safe_headers(callback),
           :ok <- validate_headers(headers) do
        {:ok, headers}
      end
    end)
  end

  defp within_deadline(timeout_ms, callback) do
    task =
      Task.async(fn ->
        try do
          callback.()
        rescue
          _exception -> {:error, :mcp_transport_error}
        catch
          _kind, _reason -> {:error, :mcp_transport_error}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :mcp_transport_error}
      nil -> {:error, :mcp_timeout}
    end
  end

  defp request_headers(request, method, params, parameter_headers) do
    protocol_headers =
      [
        {"accept", "application/json, text/event-stream"},
        {"content-type", "application/json"},
        {"mcp-protocol-version", @protocol},
        {"mcp-method", method}
      ] ++ applicable_name_header(method, params) ++ parameter_headers

    headers = request.headers ++ protocol_headers

    with :ok <- validate_outbound_headers(headers), do: {:ok, headers}
  end

  defp safe_headers(callback) do
    case callback.() do
      headers when is_list(headers) -> {:ok, headers}
      _headers -> {:error, :mcp_authentication_failed}
    end
  rescue
    _exception -> {:error, :mcp_authentication_failed}
  catch
    _kind, _reason -> {:error, :mcp_authentication_failed}
  end

  defp validate_headers(headers) do
    reserved = ~w(accept content-type)

    valid? =
      length(headers) <= @max_headers and
        Enum.all?(headers, fn
          {name, value} when is_binary(name) and is_binary(value) ->
            name =~ ~r/\A[a-z0-9-]+\z/ and name not in reserved and
              not String.starts_with?(name, "mcp-") and
              not String.contains?(value, ["\r", "\n"])

          _header ->
            false
        end) and header_wire_bytes(headers) <= @max_header_bytes

    if valid?, do: :ok, else: {:error, :mcp_authentication_failed}
  end

  defp validate_outbound_headers(headers) do
    valid? =
      length(headers) <= @max_outbound_headers and
        Enum.all?(headers, fn
          {name, value} when is_binary(name) and is_binary(value) ->
            name =~ @header_token and not String.contains?(value, ["\r", "\n"])

          _header ->
            false
        end) and header_wire_bytes(headers) <= @max_outbound_header_bytes

    if valid?, do: :ok, else: {:error, :mcp_protocol_error}
  end

  defp header_wire_bytes(headers) do
    Enum.reduce(headers, 0, fn {name, value}, total ->
      total + byte_size(name) + byte_size(value) + 4
    end)
  end

  defp http(request, headers, payload, max_bytes) do
    into = fn {:data, data}, {req, response} ->
      case accumulate_response(response, data, payload["id"], max_bytes) do
        {:cont, response} -> {:cont, {req, response}}
        {:halt, response} -> {:halt, {req, response}}
      end
    end

    case Req.request(
           method: :post,
           url: request.endpoint,
           headers: headers,
           json: payload,
           connect_options: [timeout: request.timeout_ms],
           pool_timeout: request.timeout_ms,
           receive_timeout: request.timeout_ms,
           retry: false,
           redirect: false,
           decode_body: false,
           into: into
         ) do
      {:ok, %{status: 404}} ->
        {:error, :mcp_protocol_error}

      {:ok, %{status: 400} = response} ->
        http_protocol_error(response, payload)

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :mcp_authentication_failed}

      {:ok, %{status: status, body: :body_exceeded}} when status in 200..299 ->
        {:error, :mcp_response_exceeded}

      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, _response} ->
        {:error, :mcp_transport_error}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :mcp_timeout}

      {:error, _reason} ->
        {:error, :mcp_transport_error}
    end
  end

  defp accumulate_response(response, data, id, max_bytes) do
    if response_content_type(response) == "text/event-stream" do
      accumulate_sse(response, data, id, max_bytes)
    else
      accumulate_body(response, data, max_bytes)
    end
  end

  defp accumulate_body(response, data, max_bytes) do
    body = if is_binary(response.body), do: response.body, else: ""

    if byte_size(body) + byte_size(data) <= max_bytes,
      do: {:cont, %{response | body: body <> data}},
      else: {:halt, %{response | body: :body_exceeded}}
  end

  defp accumulate_sse(response, data, id, max_bytes) do
    state =
      case response.body do
        {:mcp_sse, state} -> state
        _empty -> %{buffer: "", response: nil, bytes: 0, at_start?: true}
      end

    combined = state.buffer <> data
    processed_bytes = state.bytes - byte_size(state.buffer)
    remaining_bytes = max(max_bytes - processed_bytes, 0)
    candidate_bytes = min(byte_size(combined), remaining_bytes)
    candidate = binary_part(combined, 0, candidate_bytes)

    case consume_sse_events(candidate, state.response, id, state.at_start?) do
      {:ok, buffer, decoded, at_start?} ->
        if is_map(decoded) do
          {:halt, %{response | body: {:mcp_sse_response, decoded}}}
        else
          if byte_size(combined) <= remaining_bytes do
            state = %{
              buffer: buffer,
              response: nil,
              bytes: state.bytes + byte_size(data),
              at_start?: at_start?
            }

            {:cont, %{response | body: {:mcp_sse, state}}}
          else
            {:halt, %{response | body: :body_exceeded}}
          end
        end

      {:error, :mcp_protocol_error} ->
        {:halt, %{response | body: :mcp_protocol_error}}
    end
  end

  defp consume_sse_events(buffer, response, id, at_start?) do
    case Regex.run(@sse_event_separator, buffer, return: :index) do
      [{index, separator_bytes}] ->
        event = binary_part(buffer, 0, index)
        offset = index + separator_bytes
        rest = binary_part(buffer, offset, byte_size(buffer) - offset)
        event = strip_sse_bom(event, at_start?)

        with {:ok, response} <- decode_sse_event(event, response, id) do
          if is_map(response),
            do: {:ok, rest, response, false},
            else: consume_sse_events(rest, response, id, false)
        end

      nil ->
        {:ok, buffer, response, at_start?}
    end
  end

  defp response_body(%{body: {:mcp_sse_response, response}}, _id), do: {:ok, response}
  defp response_body(%{body: :mcp_protocol_error}, _id), do: {:error, :mcp_protocol_error}
  defp response_body(%{body: {:mcp_sse, _state}}, _id), do: {:error, :mcp_protocol_error}

  defp response_body(%{body: body} = response, id) when is_binary(body) do
    case response_content_type(response) do
      "application/json" ->
        MCPProtocol.decode_response(body, id)

      "text/event-stream" ->
        decode_sse(body, id)

      _unsupported ->
        {:error, :mcp_protocol_error}
    end
  end

  defp response_body(_response, _id), do: {:error, :mcp_response_exceeded}

  defp http_protocol_error(response, %{"id" => id, "method" => method}) do
    with {:ok, body} <- response_body(response, id),
         {:error, :mcp_remote_error} <- MCPProtocol.outcome(body, method) do
      {:error, :mcp_protocol_error}
    else
      _invalid -> {:error, :mcp_protocol_error}
    end
  end

  defp response_content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value] when is_binary(value) ->
        value
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase()

      _headers ->
        nil
    end
  end

  defp decode_sse(body, id) do
    case consume_sse_events(body, nil, id, true) do
      {:ok, _rest, response, _at_start?} when is_map(response) -> {:ok, response}
      _result -> {:error, :mcp_protocol_error}
    end
  end

  defp decode_sse_event(event, response, id) when is_binary(event) do
    if String.valid?(event) do
      data_lines =
        event
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> :binary.split("\n", [:global])
        |> Enum.reduce([], fn
          "data", lines -> ["" | lines]
          "data:" <> value, lines -> [strip_sse_space(value) | lines]
          _other, lines -> lines
        end)
        |> Enum.reverse()

      case data_lines do
        [] -> {:ok, response}
        lines -> lines |> Enum.join("\n") |> decode_sse_data(response, id)
      end
    else
      {:error, :mcp_protocol_error}
    end
  end

  defp decode_sse_data(data, response, id) do
    case MCPProtocol.decode_message(data) do
      {:ok, {:notification, _notification}} when is_nil(response) ->
        {:ok, nil}

      {:ok, {:response, ^id, decoded}} when is_nil(response) ->
        {:ok, decoded}

      _invalid ->
        {:error, :mcp_protocol_error}
    end
  end

  defp strip_sse_space(" " <> value), do: value
  defp strip_sse_space(value), do: value
  defp strip_sse_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>, true), do: rest
  defp strip_sse_bom(event, _at_start?), do: event

  defp provider_error(:mcp_authentication_failed),
    do: ProviderError.new(:authentication_failed, "mcp_authentication_failed")

  defp provider_error(:mcp_timeout),
    do: ProviderError.new(:timeout, "mcp_timeout", retryable?: true)

  defp provider_error(:mcp_response_exceeded),
    do: ProviderError.new(:invalid_result, "mcp_response_exceeded")

  defp provider_error(:mcp_protocol_error),
    do: ProviderError.new(:invalid_result, "mcp_protocol_error")

  defp provider_error(:mcp_remote_error),
    do: ProviderError.new(:domain_error, "mcp_remote_error")

  defp provider_error(:mcp_unsupported_result),
    do: ProviderError.new(:invalid_result, "mcp_unsupported_result")

  defp provider_error(_reason),
    do: ProviderError.new(:transport_error, "mcp_transport_error", retryable?: true)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp request_metadata(context) do
    metadata = %{
      "io.modelcontextprotocol/protocolVersion" => @protocol,
      "io.modelcontextprotocol/clientInfo" => @client_info,
      "io.modelcontextprotocol/clientCapabilities" => @client_capabilities
    }

    case context do
      %{traceparent: traceparent} when is_binary(traceparent) ->
        Map.put(metadata, "traceparent", traceparent)

      _context ->
        metadata
    end
  end

  defp applicable_name_header("tools/call", %{"name" => name}) when is_binary(name),
    do: [{"mcp-name", MCPProtocol.encode_header(name)}]

  defp applicable_name_header(_method, _params), do: []
end
