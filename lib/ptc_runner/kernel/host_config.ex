defmodule PtcRunner.Kernel.HostConfig do
  @moduledoc """
  Strict loader for host-installed provider authority.

  The host document is operator-owned and separate from an application
  manifest. It fixes provider sources, credentials, data classes, and outer
  ceilings. MCP installations additionally fix transports, tool mappings, and
  effects; live LLM installations fix the model, cache policy, and optional
  sampling parameters. A manifest may later select an installed alias and
  narrow its authority; it cannot introduce or replace any field decoded here.

  An optional `limits` block replaces cataloged installed ceilings, so an
  operator can permit work measured in hours rather than in one bounded run.
  Omitted names keep their installed default. A manifest requests only
  manifest-narrowable values at or below whatever is installed here;
  installed-only operational limits remain host-owned. `install` is required
  and may be empty: a limits-only host document raises ceilings for a
  provider-free application without fabricating a provider.

  Loading is bounded, path-confined, duplicate-key rejecting, and side-effect
  free. In particular, credential declarations are validated but environment
  variables and files are not read. Executables are not resolved, processes
  are not started, and remote endpoints are not contacted. Those operations
  belong to the later preflight and acquisition phases.

  The closed V1 source identifiers are `mcp`, `llm`, `llm_replay`,
  `ptc_trace_snapshot`, `ptc_private_trace_snapshot`, and `ptc_inspection_snapshot`. LLM credentials are explicit bindings passed to
  the adapter per request rather than ambient provider-specific environment
  lookup. The native snapshot sources fix host-relative directories and
  expose only PtcRunner's canonical or private inspection query vocabularies.
  Every installation requires a public, non-secret `installation_revision`
  matching `\\A[a-z][a-z0-9._-]{0,127}\\z`; command decoding reports its
  absence before generic schema failure, including for unselected aliases.
  Stdio MCP transports always run with the runtime-owned `LC_ALL=C.UTF-8`;
  credential environment bindings cannot replace that protocol locale.

  A `streamable_http` endpoint is settled here rather than at acquisition, so a
  malformed or inadmissible URL is a host fault naming its installation instead
  of the connectivity failure of an unreachable server. It requires `https`.
  Plain `http` is admitted only against the literal loopback addresses
  `127.0.0.1` and `::1`, only with `allow_insecure_loopback`, and only when the
  transport declares neither `auth` nor `oauth`, so no configured credential
  crosses a plaintext socket. The allowance is refused against an `https`
  endpoint rather than ignored. Upstream MCP tool names are the installed
  server's, so they follow `PtcRunner.Kernel.MCPProtocol.valid_tool_name?/1`;
  only the public `as` name uses PtcRunner's own naming rule.

  `schema/0` is the canonical structural description shipped for editor and
  human feedback. Runtime decoding remains authoritative for semantic checks
  such as unique public tool names, credential references, reserved headers,
  portable environment names, and the requirement that `snapshot_identity`
  name a read mapping. MCP effects form the closed `read`/`write` operator
  classification; server-supplied annotations cannot widen or narrow it.
  """

  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPEndpoint
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Kernel.SchemaPath
  alias PtcRunner.Kernel.SchemaViolation
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.Lisp.RetainedSize

  @max_config_bytes 1_000_000
  @max_credentials 128
  @max_installations 128
  @max_tools 128
  @max_stdio_credential_environment 249
  @max_string_bytes 131_072
  @max_secret_bytes 65_536
  @max_result_bytes 1_048_576
  @max_trace_source_bytes 8_000_000
  @max_inspection_source_bytes 64_000_000
  @max_inspection_files 1_024
  @max_replay_entries 10_000
  # The accepted minimum must fit the complete smallest snapshot result under
  # both the encoded and retained-size measurements enforced at the boundary.
  @minimum_snapshot_result %{
    "items" => [],
    "next_cursor" => nil,
    "omitted_count" => 0,
    "snapshot_hash" => "sha256:" <> String.duplicate("0", 64),
    "truncated" => false
  }
  @minimum_snapshot_result_bytes max(
                                   byte_size(Jason.encode!(@minimum_snapshot_result)),
                                   RetainedSize.bytes(@minimum_snapshot_result)
                                 )
  @max_timeout_ms 300_000
  @max_llm_tokens 1_000_000
  @max_llm_seed 2_147_483_647
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @installation_revision @name
  @environment_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @header_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @reserved_environment ~w(HOME LC_ALL LOGNAME PATH SHELL TERM USER)
  @reserved_headers ~w(
    authorization
    connection
    content-length
    content-type
    host
    mcp-method
    mcp-name
    mcp-protocol-version
    proxy-authorization
    transfer-encoding
  )

  @enforce_keys [:path, :directory, :runtime, :limits, :credentials, :install]
  defstruct @enforce_keys

  @type credential ::
          %{source: :env, name: binary()}
          | %{source: :file, path: binary()}
          | %{source: :literal, value: binary()}

  @type tool :: %{
          as: binary(),
          effect: :read | :write,
          description: binary() | nil,
          error_feedback: :closed | :bounded,
          model_visible: boolean()
        }

  @type transport ::
          %{
            type: :stdio,
            command: binary(),
            cwd: binary(),
            args: [binary()],
            env: %{binary() => binary()},
            inherit_environment: boolean(),
            grace_ms: pos_integer(),
            stderr_bytes: non_neg_integer(),
            start_timeout_ms: pos_integer()
          }
          | %{
              type: :streamable_http,
              endpoint: binary(),
              allow_insecure_loopback: boolean(),
              auth: [map()],
              oauth: Authority.t() | nil
            }

  @type installation ::
          %{
            source: :mcp,
            transport: transport(),
            tools: %{binary() => tool()},
            snapshot_identity: %{tool: binary(), field: binary()} | nil,
            installation_revision: binary(),
            ceilings: %{
              timeout_ms: pos_integer(),
              max_catalog_tools: pos_integer(),
              max_result_bytes: pos_integer()
            },
            data_class: :normal | :private_inspection,
            accepts_data: [:normal | :private_inspection]
          }
          | %{
              source: :llm,
              model: binary(),
              credential: binary(),
              cache: boolean(),
              params: %{
                optional(:temperature) => float(),
                optional(:seed) => non_neg_integer(),
                optional(:max_tokens) => pos_integer()
              },
              installation_revision: binary(),
              ceilings: %{
                max_request_bytes: pos_integer(),
                max_response_bytes: pos_integer(),
                max_calls: pos_integer()
              },
              data_class: :normal | :private_inspection,
              accepts_data: [:normal | :private_inspection]
            }
          | %{
              source: :llm_replay,
              fixtures: binary(),
              installation_revision: binary(),
              ceilings: %{
                max_entries: pos_integer(),
                max_result_bytes: pos_integer(),
                max_calls: pos_integer()
              },
              data_class: :normal | :private_inspection,
              accepts_data: [:normal | :private_inspection]
            }
          | %{
              source: :ptc_trace_snapshot,
              directory: binary(),
              installation_revision: binary(),
              ceilings: %{
                max_source_bytes: pos_integer(),
                max_result_bytes: pos_integer()
              }
            }
          | %{
              source: :ptc_private_trace_snapshot,
              directory: binary(),
              installation_revision: binary(),
              ceilings: %{
                max_source_bytes: pos_integer(),
                max_result_bytes: pos_integer()
              }
            }
          | %{
              source: :ptc_inspection_snapshot,
              directory: binary(),
              installation_revision: binary(),
              ceilings: %{
                max_files: pos_integer(),
                max_source_bytes: pos_integer(),
                max_result_bytes: pos_integer()
              }
            }

  @type t :: %__MODULE__{
          path: binary(),
          directory: binary(),
          runtime: %{stdio_launcher: binary() | nil},
          credentials: %{binary() => credential()},
          install: %{binary() => installation()}
        }

  @doc false
  @spec minimum_snapshot_result_bytes() :: pos_integer()
  def minimum_snapshot_result_bytes, do: @minimum_snapshot_result_bytes

  @doc "Loads and semantically validates one host configuration."
  @spec load(binary()) :: {:ok, t()} | {:error, atom()}
  def load(path) when is_binary(path) do
    with {:ok, canonical} <- ConfinedFile.resolve_absolute(Path.expand(path)),
         directory = Path.dirname(canonical),
         {:ok, source} <-
           ConfinedFile.read(directory, Path.basename(canonical), @max_config_bytes),
         {:ok, decoded} <- StrictJSON.decode(source),
         {:ok, normalized} <- decode(decoded, directory) do
      {:ok,
       struct!(__MODULE__,
         path: canonical,
         directory: directory,
         runtime: normalized.runtime,
         limits: normalized.limits,
         credentials: normalized.credentials,
         install: normalized.install
       )}
    else
      {:error, :duplicate_json_key} -> {:error, :duplicate_host_config_key}
      {:error, :invalid_json} -> {:error, :invalid_host_config_json}
      {:error, _reason} = error -> error
    end
  end

  def load(_path), do: {:error, :invalid_host_config}

  @doc false
  @spec load_command(binary()) ::
          {:ok, t()}
          | {:error,
             :host_unavailable
             | :host_invalid
             | {:installation_revision_missing, binary()}
             | {:installation_endpoint_invalid, binary(), atom()}
             | {:host_schema_invalid, SchemaViolation.t()}
             | {:installed_limit_invalid, [PtcRunner.Kernel.CommandPath.segment()]}}
  def load_command(path) when is_binary(path) do
    with {:ok, canonical} <- ConfinedFile.resolve_absolute(Path.expand(path)),
         directory = Path.dirname(canonical),
         {:ok, source} <-
           ConfinedFile.read(directory, Path.basename(canonical), @max_config_bytes),
         {:ok, decoded} <- StrictJSON.decode_with_locations(source),
         {:ok, normalized} <- decode_command(decoded, directory) do
      {:ok,
       struct!(__MODULE__,
         path: canonical,
         directory: directory,
         runtime: normalized.runtime,
         limits: normalized.limits,
         credentials: normalized.credentials,
         install: normalized.install
       )}
    else
      {:error, {:duplicate_json_key, path}} ->
        {:error,
         {:host_schema_invalid, SchemaViolation.new(:duplicate_property, safe_host_path(path))}}

      {:error, reason}
      when reason in [
             :invalid_json,
             :invalid_utf8,
             :json_depth_exceeded,
             :json_node_limit_exceeded,
             :too_large
           ] ->
        {:error, :host_invalid}

      {:error, reason}
      when reason in [
             :host_unavailable,
             :host_invalid
           ] ->
        {:error, reason}

      {:error, {code, _detail}} = error
      when code in [
             :installation_revision_missing,
             :host_schema_invalid,
             :installed_limit_invalid
           ] ->
        error

      {:error, {:installation_endpoint_invalid, _name, _reason}} = error ->
        error

      {:error, _reason} ->
        {:error, :host_unavailable}
    end
  end

  def load_command(_path), do: {:error, :host_unavailable}

  @doc false
  @spec decode(term(), binary()) ::
          {:ok,
           %{
             runtime: %{stdio_launcher: binary() | nil},
             limits: Limits.t(),
             credentials: %{binary() => credential()},
             install: %{binary() => installation()}
           }}
          | {:error, :invalid_host_config}
  def decode(value, directory) when is_map(value) and is_binary(directory) do
    with true <- schema_valid?(value),
         :ok <-
           exact_keys(value, ~w($schema runtime limits credentials install), ~w(install)),
         :ok <- optional_schema(value["$schema"]),
         {:ok, runtime} <- runtime(Map.get(value, "runtime", %{})),
         {:ok, limits} <- limits(Map.get(value, "limits", %{})),
         {:ok, credentials} <- credentials(Map.get(value, "credentials", %{})),
         {:ok, install} <- installations(value["install"], credentials) do
      {:ok, %{runtime: runtime, limits: limits, credentials: credentials, install: install}}
    else
      _reason -> {:error, :invalid_host_config}
    end
  end

  def decode(_value, _directory), do: {:error, :invalid_host_config}

  @doc false
  def decode_command(value, directory) when is_map(value) and is_binary(directory) do
    with :ok <- require_installation_revisions(value),
         :ok <- require_admissible_endpoints(value),
         :ok <- validate_command_schema(value),
         :ok <-
           schema_result(
             exact_keys(value, ~w($schema runtime limits credentials install), ~w(install)),
             []
           ),
         :ok <- command_semantic_result(optional_schema(value["$schema"])),
         {:ok, runtime} <-
           command_semantic_result(runtime(Map.get(value, "runtime", %{}))),
         {:ok, limits} <- command_limits(Map.get(value, "limits", %{})),
         {:ok, credentials} <-
           command_semantic_result(credentials(Map.get(value, "credentials", %{}))),
         {:ok, install} <-
           command_semantic_result(installations(value["install"], credentials)) do
      {:ok, %{runtime: runtime, limits: limits, credentials: credentials, install: install}}
    end
  end

  def decode_command(_value, _directory),
    do: {:error, {:host_schema_invalid, SchemaViolation.new(:type, [])}}

  defp require_installation_revisions(%{"install" => installations})
       when is_map(installations) do
    installations
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find(fn name ->
      case Map.get(installations, name) do
        installation when is_map(installation) ->
          valid_name?(name) and not Map.has_key?(installation, "installation_revision")

        _invalid ->
          false
      end
    end)
    |> case do
      nil -> :ok
      name -> {:error, {:installation_revision_missing, name}}
    end
  end

  defp require_installation_revisions(_value), do: :ok

  # An inadmissible endpoint is a static fact about the document, so it is
  # reported here rather than as the connectivity failure it used to become at
  # acquisition. It names the installation through a subject, not through the
  # path: `SchemaPath` deliberately stops at `install` rather than echoing an
  # operator-chosen alias, and the alias is safe here only because it is
  # matched against `@name` first.
  #
  # This runs ahead of the generic schema pass so the refusal says which rule
  # was broken. Anything structurally unfit for the check is left to that pass.
  defp require_admissible_endpoints(%{"install" => installations})
       when is_map(installations) do
    installations
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find_value(fn name ->
      if valid_name?(name) do
        case endpoint_rejection(Map.get(installations, name)) do
          {:error, reason} -> {name, reason}
          :ok -> nil
        end
      end
    end)
    |> case do
      nil -> :ok
      {name, reason} -> {:error, {:installation_endpoint_invalid, name, reason}}
    end
  end

  defp require_admissible_endpoints(_value), do: :ok

  defp endpoint_rejection(%{
         "source" => "mcp",
         "transport" => %{"type" => "streamable_http"} = transport
       })
       when is_map(transport) do
    endpoint = Map.get(transport, "endpoint")
    insecure_loopback = Map.get(transport, "allow_insecure_loopback", false)
    auth = Map.get(transport, "auth", [])
    oauth = Map.get(transport, "oauth")

    if is_binary(endpoint) and is_boolean(insecure_loopback) and is_list(auth),
      do: installed_endpoint(endpoint, insecure_loopback, auth, oauth),
      else: :ok
  end

  defp endpoint_rejection(_installation), do: :ok

  defp schema_result(:ok, _segments), do: :ok

  defp schema_result({:error, _reason}, segments),
    do: {:error, {:host_schema_invalid, SchemaViolation.new(:schema, segments)}}

  # `validate_command_schema/1` has already proved the whole document under a
  # bounded worker. Failures after that boundary are semantic host failures;
  # do not repeat schema validation outside the worker to distinguish them.
  defp command_semantic_result(:ok), do: :ok
  defp command_semantic_result({:ok, decoded}), do: {:ok, decoded}
  defp command_semantic_result({:error, _reason}), do: {:error, :host_invalid}

  defp schema_valid?(value) do
    with {:ok, root} <- JSV.build(schema(), atoms: false, warnings: :silent),
         {:ok, _validated} <- JSV.validate(value, root, cast: false) do
      true
    else
      _invalid -> false
    end
  rescue
    _exception -> false
  end

  defp validate_command_schema(value) do
    schema = schema()

    case SchemaViolation.validate(command_schema_value(value), schema) do
      :ok -> :ok
      {:error, violation} -> {:error, {:host_schema_invalid, violation}}
    end
  end

  # Installed-limit values have their own closed diagnostic and exact path
  # below. Substitute valid values only for this structural pass so type/range
  # failures retain `installed_limit_invalid`; non-objects and unknown names
  # still fail the generated schema before any normalization.
  defp command_schema_value(%{"limits" => limits} = value) when is_map(limits) do
    if Map.keys(limits) -- Limits.names() == [] do
      installed = Map.from_struct(Limits.installed_defaults())

      schema_limits =
        Map.new(limits, fn {name, _value} ->
          {:ok, field} = Limits.name(name)
          {name, Map.fetch!(installed, field)}
        end)

      Map.put(value, "limits", schema_limits)
    else
      value
    end
  end

  defp command_schema_value(value), do: value

  defp safe_host_path(path), do: SchemaPath.explained_prefix(path, schema())

  defp command_limits(value) when is_map(value) do
    if Map.keys(value) -- Limits.names() == [] do
      case limits(value) do
        {:ok, limits} -> {:ok, limits}
        {:error, _reason} -> {:error, {:installed_limit_invalid, invalid_limit_path(value)}}
      end
    else
      {:error,
       {:host_schema_invalid, SchemaViolation.new(:unknown_property, [{:property, "limits"}])}}
    end
  end

  defp command_limits(_value),
    do: {:error, {:host_schema_invalid, SchemaViolation.new(:type, [{:property, "limits"}])}}

  defp invalid_limit_path(value) when is_map(value) do
    invalid_name =
      value
      |> Map.keys()
      |> Enum.sort()
      |> Enum.find(fn name ->
        case LimitCatalog.fetch(name) do
          {:ok, row} -> not LimitCatalog.valid_value?(row, value[name])
          :error -> false
        end
      end)

    if invalid_name,
      do: [{:property, "limits"}, {:property, invalid_name}],
      else: [{:property, "limits"}]
  end

  defp optional_schema(nil), do: :ok

  defp optional_schema(value) do
    if valid_string?(value, 2_048), do: :ok, else: {:error, :invalid_schema_annotation}
  end

  # The installed ceiling belongs to the operator, not the manifest. Pinning it
  # to one compiled-in table made every ceiling except three timeouts
  # unraisable, so a long-running agent could not be configured at all: a run
  # was capped at 16 model calls and 128 tool calls regardless of what its
  # manifest asked for. An omitted block keeps the previous compiled defaults,
  # and a manifest may still only narrow whatever ends up installed.
  defp limits(value) when is_map(value) do
    with :ok <- exact_keys(value, Limits.names(), []),
         {:ok, overrides} <- limit_overrides(Map.to_list(value), %{}),
         {:ok, limits} <- Limits.installed(overrides) do
      {:ok, limits}
    else
      _reason -> {:error, :invalid_limits}
    end
  end

  defp limits(_value), do: {:error, :invalid_limits}

  defp limit_overrides([], overrides), do: {:ok, overrides}

  defp limit_overrides([{key, number} | rest], overrides) do
    case LimitCatalog.fetch(key) do
      {:ok, row} ->
        if LimitCatalog.valid_value?(row, number),
          do: limit_overrides(rest, Map.put(overrides, row.field, number)),
          else: {:error, :invalid_limits}

      :error ->
        {:error, :invalid_limits}
    end
  end

  defp runtime(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(stdio_launcher), []),
         launcher <- Map.get(value, "stdio_launcher"),
         true <- is_nil(launcher) or valid_absolute_path?(launcher) do
      {:ok, %{stdio_launcher: launcher}}
    else
      _reason -> {:error, :invalid_runtime}
    end
  end

  defp runtime(_value), do: {:error, :invalid_runtime}

  defp credentials(value) when is_map(value) and map_size(value) <= @max_credentials do
    reduce_named_map(value, &credential/2)
  end

  defp credentials(_value), do: {:error, :invalid_credentials}

  defp credential(name, value) do
    with true <- valid_name?(name),
         true <- is_map(value) do
      case Map.to_list(value) do
        [{"env", env}] when is_binary(env) ->
          if env =~ @environment_name,
            do: {:ok, %{source: :env, name: env}},
            else: {:error, :invalid_credential}

        [{"file", path}] when is_binary(path) ->
          if valid_path_string?(path),
            do: {:ok, %{source: :file, path: path}},
            else: {:error, :invalid_credential}

        [{"literal", secret}] when is_binary(secret) ->
          if valid_string?(secret, @max_secret_bytes),
            do: {:ok, %{source: :literal, value: secret}},
            else: {:error, :invalid_credential}

        _other ->
          {:error, :invalid_credential}
      end
    else
      _reason -> {:error, :invalid_credential}
    end
  end

  defp installations(value, _credentials) when is_map(value) and map_size(value) == 0,
    do: {:ok, %{}}

  defp installations(value, credentials)
       when is_map(value) and map_size(value) in 1..@max_installations do
    with {:ok, installations} <-
           reduce_named_map(value, fn name, installation ->
             installation(name, installation, credentials)
           end),
         ids =
           for(
             {_name, %{source: :mcp, transport: %{oauth: %Authority{} = oauth}}} <-
               installations,
             do: oauth.installation_id
           ),
         true <- ids == Enum.uniq(ids) do
      {:ok, installations}
    else
      _invalid -> {:error, :invalid_installations}
    end
  end

  defp installations(_value, _credentials), do: {:error, :invalid_installations}

  defp installation(name, value, credentials) do
    with true <- valid_name?(name),
         true <- is_map(value) do
      case value["source"] do
        "mcp" ->
          mcp_installation(value, credentials)

        "llm" ->
          llm_installation(value, credentials)

        "ptc_trace_snapshot" ->
          trace_snapshot_installation(value, :ptc_trace_snapshot)

        "ptc_private_trace_snapshot" ->
          trace_snapshot_installation(value, :ptc_private_trace_snapshot)

        "ptc_inspection_snapshot" ->
          inspection_snapshot_installation(value)

        "llm_replay" ->
          llm_replay_installation(value)

        _unknown ->
          {:error, :invalid_installation}
      end
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp mcp_installation(value, credentials) do
    allowed =
      ~w(source transport tools snapshot_identity installation_revision ceilings data_class accepts_data)

    with :ok <-
           exact_keys(
             value,
             allowed,
             ~w(source transport tools installation_revision)
           ),
         {:ok, transport} <- transport(value["transport"], credentials),
         {:ok, tools} <- tools(value["tools"]),
         {:ok, snapshot_identity} <-
           snapshot_identity(Map.get(value, "snapshot_identity"), tools),
         {:ok, installation_revision} <-
           revision(value["installation_revision"]),
         {:ok, ceilings} <- ceilings(Map.get(value, "ceilings", %{})),
         {:ok, data_class} <- data_class(Map.get(value, "data_class", "normal")),
         {:ok, accepts_data} <-
           accepts_data(Map.get(value, "accepts_data", ["normal"])) do
      {:ok,
       %{
         source: :mcp,
         transport: transport,
         tools: tools,
         snapshot_identity: snapshot_identity,
         installation_revision: installation_revision,
         ceilings: ceilings,
         data_class: data_class,
         accepts_data: accepts_data
       }}
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp llm_installation(value, credentials) do
    allowed =
      ~w(source model credential cache params installation_revision ceilings data_class accepts_data)

    with :ok <-
           exact_keys(
             value,
             allowed,
             ~w(source model credential installation_revision)
           ),
         model when is_binary(model) <- value["model"],
         true <- valid_string?(model, 256),
         credential when is_binary(credential) <- value["credential"],
         true <- Map.has_key?(credentials, credential),
         cache when is_boolean(cache) <- Map.get(value, "cache", false),
         {:ok, params} <- llm_params(Map.get(value, "params", %{})),
         {:ok, installation_revision} <-
           revision(value["installation_revision"]),
         {:ok, ceilings} <- llm_ceilings(Map.get(value, "ceilings", %{})),
         {:ok, data_class} <- data_class(Map.get(value, "data_class", "normal")),
         {:ok, accepts_data} <-
           accepts_data(Map.get(value, "accepts_data", ["normal"])) do
      {:ok,
       %{
         source: :llm,
         model: model,
         credential: credential,
         cache: cache,
         params: params,
         installation_revision: installation_revision,
         ceilings: ceilings,
         data_class: data_class,
         accepts_data: accepts_data
       }}
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp llm_params(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(temperature seed max_tokens), []),
         temperature when is_number(temperature) and temperature >= 0 and temperature <= 2 <-
           Map.get(value, "temperature", 0.0),
         seed when is_integer(seed) and seed in 0..@max_llm_seed <-
           Map.get(value, "seed", 0),
         max_tokens when is_integer(max_tokens) and max_tokens in 1..@max_llm_tokens <-
           Map.get(value, "max_tokens", 1) do
      params =
        %{}
        |> maybe_put_param(:temperature, value, "temperature", temperature * 1.0)
        |> maybe_put_param(:seed, value, "seed", seed)
        |> maybe_put_param(:max_tokens, value, "max_tokens", max_tokens)

      {:ok, params}
    else
      _reason -> {:error, :invalid_llm_params}
    end
  end

  defp llm_params(_value), do: {:error, :invalid_llm_params}

  defp maybe_put_param(params, atom_key, value, string_key, normalized) do
    if Map.has_key?(value, string_key), do: Map.put(params, atom_key, normalized), else: params
  end

  defp trace_snapshot_installation(value, source)
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot] do
    with :ok <-
           exact_keys(
             value,
             ~w(source directory installation_revision ceilings),
             ~w(source directory installation_revision)
           ),
         directory when is_binary(directory) <- value["directory"],
         true <- valid_path_string?(directory),
         {:ok, installation_revision} <- revision(value["installation_revision"]),
         {:ok, ceilings} <- trace_snapshot_ceilings(Map.get(value, "ceilings", %{})) do
      {:ok,
       %{
         source: source,
         directory: directory,
         installation_revision: installation_revision,
         ceilings: ceilings
       }}
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp trace_snapshot_ceilings(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(max_source_bytes max_result_bytes), []),
         max_source_bytes when is_integer(max_source_bytes) and max_source_bytes > 0 <-
           Map.get(value, "max_source_bytes", @max_trace_source_bytes),
         true <- max_source_bytes <= @max_trace_source_bytes,
         max_result_bytes
         when is_integer(max_result_bytes) and
                max_result_bytes >= @minimum_snapshot_result_bytes <-
           Map.get(value, "max_result_bytes", @max_result_bytes),
         true <- max_result_bytes <= @max_result_bytes do
      {:ok,
       %{
         max_source_bytes: max_source_bytes,
         max_result_bytes: max_result_bytes
       }}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  defp trace_snapshot_ceilings(_value), do: {:error, :invalid_ceilings}

  defp llm_replay_installation(value) do
    allowed = ~w(source fixtures installation_revision ceilings data_class accepts_data)

    with :ok <-
           exact_keys(value, allowed, ~w(source fixtures installation_revision)),
         fixtures when is_binary(fixtures) <- value["fixtures"],
         true <- valid_path_string?(fixtures),
         {:ok, installation_revision} <-
           revision(value["installation_revision"]),
         {:ok, ceilings} <- llm_replay_ceilings(Map.get(value, "ceilings", %{})),
         {:ok, data_class} <- data_class(Map.get(value, "data_class", "normal")),
         {:ok, accepts_data} <- accepts_data(Map.get(value, "accepts_data", ["normal"])) do
      {:ok,
       %{
         source: :llm_replay,
         fixtures: fixtures,
         installation_revision: installation_revision,
         ceilings: ceilings,
         data_class: data_class,
         accepts_data: accepts_data
       }}
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp llm_replay_ceilings(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(max_entries max_result_bytes max_calls), []),
         max_entries when is_integer(max_entries) and max_entries > 0 <-
           Map.get(value, "max_entries", @max_replay_entries),
         true <- max_entries <= @max_replay_entries,
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
           Map.get(value, "max_result_bytes", @max_result_bytes),
         true <- max_result_bytes <= @max_result_bytes,
         {:ok, max_calls} <- optional_max_calls(value) do
      {:ok, %{max_entries: max_entries, max_result_bytes: max_result_bytes, max_calls: max_calls}}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  defp llm_replay_ceilings(_value), do: {:error, :invalid_ceilings}

  defp inspection_snapshot_installation(value) do
    with :ok <-
           exact_keys(
             value,
             ~w(source directory installation_revision ceilings),
             ~w(source directory installation_revision)
           ),
         directory when is_binary(directory) <- value["directory"],
         true <- valid_path_string?(directory),
         {:ok, installation_revision} <- revision(value["installation_revision"]),
         {:ok, ceilings} <- inspection_snapshot_ceilings(Map.get(value, "ceilings", %{})) do
      {:ok,
       %{
         source: :ptc_inspection_snapshot,
         directory: directory,
         installation_revision: installation_revision,
         ceilings: ceilings
       }}
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp inspection_snapshot_ceilings(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(max_files max_source_bytes max_result_bytes), []),
         max_files when is_integer(max_files) and max_files > 0 <-
           Map.get(value, "max_files", @max_inspection_files),
         true <- max_files <= @max_inspection_files,
         max_source_bytes when is_integer(max_source_bytes) and max_source_bytes > 0 <-
           Map.get(value, "max_source_bytes", @max_inspection_source_bytes),
         true <- max_source_bytes <= @max_inspection_source_bytes,
         max_result_bytes
         when is_integer(max_result_bytes) and
                max_result_bytes >= @minimum_snapshot_result_bytes <-
           Map.get(value, "max_result_bytes", @max_result_bytes),
         true <- max_result_bytes <= @max_result_bytes do
      {:ok,
       %{
         max_files: max_files,
         max_source_bytes: max_source_bytes,
         max_result_bytes: max_result_bytes
       }}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  defp inspection_snapshot_ceilings(_value), do: {:error, :invalid_ceilings}

  defp transport(%{"type" => "stdio"} = value, credentials),
    do: stdio_transport(value, credentials)

  defp transport(%{"type" => "streamable_http"} = value, credentials),
    do: http_transport(value, credentials)

  defp transport(_value, _credentials), do: {:error, :invalid_transport}

  defp stdio_transport(value, credentials) do
    allowed =
      ~w(type command cwd args env inherit_environment grace_ms stderr_bytes start_timeout_ms)

    with :ok <- exact_keys(value, allowed, ~w(type command)),
         command when is_binary(command) <- value["command"],
         true <- valid_string?(command, 4_096),
         cwd when is_binary(cwd) <- Map.get(value, "cwd", "."),
         true <- valid_path_string?(cwd),
         {:ok, args} <- string_list(Map.get(value, "args", []), 256),
         {:ok, env} <- environment_bindings(Map.get(value, "env", %{}), credentials),
         inherit when is_boolean(inherit) <-
           Map.get(value, "inherit_environment", true),
         grace_ms when is_integer(grace_ms) and grace_ms in 1..5_000 <-
           Map.get(value, "grace_ms", 250),
         stderr_bytes when is_integer(stderr_bytes) and stderr_bytes in 0..1_048_576 <-
           Map.get(value, "stderr_bytes", 65_536),
         start_timeout_ms
         when is_integer(start_timeout_ms) and start_timeout_ms in 1..60_000 <-
           Map.get(value, "start_timeout_ms", 5_000) do
      {:ok,
       %{
         type: :stdio,
         command: command,
         cwd: cwd,
         args: args,
         env: env,
         inherit_environment: inherit,
         grace_ms: grace_ms,
         stderr_bytes: stderr_bytes,
         start_timeout_ms: start_timeout_ms
       }}
    else
      _reason -> {:error, :invalid_transport}
    end
  end

  defp http_transport(value, credentials) do
    with :ok <-
           exact_keys(
             value,
             ~w(type endpoint allow_insecure_loopback auth oauth),
             ~w(type endpoint)
           ),
         endpoint when is_binary(endpoint) <- value["endpoint"],
         true <- valid_string?(endpoint, 4_096),
         insecure_loopback when is_boolean(insecure_loopback) <-
           Map.get(value, "allow_insecure_loopback", false),
         {:ok, auth} <- auth(Map.get(value, "auth", []), credentials),
         {:ok, oauth} <- optional_oauth(value, endpoint, credentials),
         true <- auth == [] or is_nil(oauth),
         :ok <- installed_endpoint(endpoint, insecure_loopback, auth, oauth) do
      {:ok,
       %{
         type: :streamable_http,
         endpoint: endpoint,
         allow_insecure_loopback: insecure_loopback,
         auth: auth,
         oauth: oauth
       }}
    else
      _reason -> {:error, :invalid_transport}
    end
  end

  # Runtime decoding owns this rule; `http_schema/0` mirrors it so an editor can
  # report the same refusal, and `admissible_endpoints/1` reports it as its own
  # diagnostic before the generic schema failure.
  #
  # The allowance is credential-free: an installed `auth` binding or an OAuth
  # authority must never cross a plaintext socket. That is a guarantee about
  # configured host credentials and nothing more — tool arguments and results
  # travelling over a loopback socket are still plaintext.
  defp installed_endpoint(endpoint, insecure_loopback, auth, oauth)
       when auth != [] or not is_nil(oauth) do
    if String.starts_with?(endpoint, "http://"),
      do: {:error, :credentials_require_https},
      else: MCPEndpoint.diagnose(endpoint, insecure_loopback)
  end

  defp installed_endpoint(endpoint, insecure_loopback, _auth, _oauth),
    do: MCPEndpoint.diagnose(endpoint, insecure_loopback)

  # An explicit `"oauth": null` is a key the schema counts as present and
  # refuses, so reading it as absent would accept a document the mirror rejects.
  # A transport declares an authority or omits the key.
  defp optional_oauth(value, endpoint, credentials) do
    case Map.fetch(value, "oauth") do
      :error -> {:ok, nil}
      {:ok, nil} -> {:error, :invalid_oauth}
      {:ok, oauth} -> Authority.from_host(oauth, endpoint, MapSet.new(Map.keys(credentials)))
    end
  end

  defp environment_bindings(value, credentials)
       when is_map(value) and map_size(value) <= @max_stdio_credential_environment do
    Enum.reduce_while(value, {:ok, %{}}, fn {name, binding}, {:ok, normalized} ->
      result =
        with true <- is_binary(name) and name =~ @environment_name,
             false <- name in @reserved_environment,
             true <- is_map(binding),
             :ok <- exact_keys(binding, ~w(binding), ~w(binding)),
             credential when is_binary(credential) <- binding["binding"],
             true <- Map.has_key?(credentials, credential) do
          {:ok, Map.put(normalized, name, credential)}
        else
          _reason -> {:error, :invalid_environment_binding}
        end

      case result do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp environment_bindings(_value, _credentials),
    do: {:error, :invalid_environment_binding}

  defp auth(value, credentials) when is_list(value) and length(value) <= 8 do
    Enum.reduce_while(value, {:ok, []}, fn entry, {:ok, normalized} ->
      case auth_entry(entry, credentials) do
        {:ok, auth} -> {:cont, {:ok, [auth | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp auth(_value, _credentials), do: {:error, :invalid_auth}

  defp auth_entry(%{"scheme" => scheme, "binding" => binding} = value, credentials)
       when scheme in ["bearer", "basic"] do
    with :ok <- exact_keys(value, ~w(scheme binding), ~w(scheme binding)),
         true <- is_binary(binding) and Map.has_key?(credentials, binding) do
      {:ok, %{scheme: auth_scheme(scheme), binding: binding}}
    else
      _reason -> {:error, :invalid_auth}
    end
  end

  defp auth_entry(
         %{"scheme" => "api_key", "binding" => binding, "header" => header} = value,
         credentials
       ) do
    with :ok <- exact_keys(value, ~w(scheme binding header), ~w(scheme binding header)),
         true <- is_binary(binding) and Map.has_key?(credentials, binding),
         true <- valid_header?(header) do
      {:ok, %{scheme: :api_key, binding: binding, header: header}}
    else
      _reason -> {:error, :invalid_auth}
    end
  end

  defp auth_entry(_value, _credentials), do: {:error, :invalid_auth}

  defp tools(value) when is_map(value) and map_size(value) in 1..@max_tools do
    with {:ok, tools} <- reduce_named_map(value, &tool/2),
         public_names = Enum.map(tools, fn {_upstream, tool} -> tool.as end),
         true <- public_names == Enum.uniq(public_names) do
      {:ok, tools}
    else
      _reason -> {:error, :invalid_tools}
    end
  end

  defp tools(_value), do: {:error, :invalid_tools}

  # The upstream key is the server's own tool name, so it is held to the MCP
  # protocol rule rather than to PtcRunner's naming rule. Only `as` crosses the
  # capability boundary, and that one stays lowercase-dotted.
  defp tool(upstream, value) do
    allowed = ~w(as effect description error_feedback model_visible)

    with true <- MCPProtocol.valid_tool_name?(upstream),
         true <- is_map(value),
         :ok <- exact_keys(value, allowed, ~w(as effect)),
         as when is_binary(as) <- value["as"],
         true <- valid_name?(as),
         effect when effect in ["read", "write"] <- value["effect"],
         {:ok, description} <- optional_description(Map.get(value, "description")),
         feedback when feedback in ["closed", "bounded"] <-
           Map.get(value, "error_feedback", "closed"),
         model_visible when is_boolean(model_visible) <-
           Map.get(value, "model_visible", false) do
      {:ok,
       %{
         as: as,
         effect: tool_effect(effect),
         description: description,
         error_feedback: error_feedback(feedback),
         model_visible: model_visible
       }}
    else
      _reason -> {:error, :invalid_tool}
    end
  end

  defp snapshot_identity(nil, _tools), do: {:ok, nil}

  defp snapshot_identity(value, tools) when is_map(value) do
    with :ok <- exact_keys(value, ~w(tool field), ~w(tool field)),
         tool when is_binary(tool) <- value["tool"],
         %{effect: :read} <- Map.get(tools, tool),
         field when is_binary(field) <- value["field"],
         true <- valid_name?(field) do
      {:ok, %{tool: tool, field: field}}
    else
      _reason -> {:error, :invalid_snapshot_identity}
    end
  end

  defp snapshot_identity(_value, _tools), do: {:error, :invalid_snapshot_identity}

  defp tool_effect("read"), do: :read
  defp tool_effect("write"), do: :write

  defp revision(value) do
    if is_binary(value) and value =~ @installation_revision,
      do: {:ok, value},
      else: {:error, :invalid_installation_revision}
  end

  defp ceilings(value) when is_map(value) do
    with :ok <-
           exact_keys(value, ~w(timeout_ms max_catalog_tools max_result_bytes), []),
         timeout_ms when is_integer(timeout_ms) and timeout_ms in 1..@max_timeout_ms <-
           Map.get(value, "timeout_ms", 5_000),
         max_catalog_tools when is_integer(max_catalog_tools) and max_catalog_tools in 1..128 <-
           Map.get(value, "max_catalog_tools", 128),
         max_result_bytes
         when is_integer(max_result_bytes) and max_result_bytes in 1..@max_result_bytes <-
           Map.get(value, "max_result_bytes", 1_000_000) do
      {:ok,
       %{
         timeout_ms: timeout_ms,
         max_catalog_tools: max_catalog_tools,
         max_result_bytes: max_result_bytes
       }}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  defp ceilings(_value), do: {:error, :invalid_ceilings}

  defp llm_ceilings(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(max_request_bytes max_response_bytes max_calls), []),
         max_request_bytes
         when is_integer(max_request_bytes) and max_request_bytes in 1..@max_result_bytes <-
           Map.get(value, "max_request_bytes", 1_000_000),
         max_response_bytes
         when is_integer(max_response_bytes) and max_response_bytes in 1..@max_result_bytes <-
           Map.get(value, "max_response_bytes", 1_000_000),
         {:ok, max_calls} <- optional_max_calls(value) do
      {:ok,
       %{
         max_request_bytes: max_request_bytes,
         max_response_bytes: max_response_bytes,
         max_calls: max_calls
       }}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  defp llm_ceilings(_value), do: {:error, :invalid_ceilings}

  # A ceiling above the per-name installed ceiling can never bind, because the
  # alias cap applies only when stricter than the run's per-name quota. Refuse
  # the unreachable value at load instead of installing a silent no-op.
  defp optional_max_calls(value) do
    {:ok, row} = LimitCatalog.fetch(:workflow_capability_calls_per_name)

    case Map.get(value, "max_calls", row.installed_default) do
      max_calls
      when is_integer(max_calls) and max_calls >= row.minimum and
             max_calls <= row.installed_default ->
        {:ok, max_calls}

      _invalid ->
        :error
    end
  end

  # Every enumerated string this decoder accepts maps to an atom through an
  # explicit clause, so the atom is a literal in this module and exists as soon
  # as it is loaded. `String.to_existing_atom/1` looked equivalent but borrowed
  # the atom from whichever module happened to intern it first, so decoding a
  # valid host document raised instead of returning a result whenever this
  # module ran before that one.
  defp data_class("normal"), do: {:ok, :normal}
  defp data_class("private_inspection"), do: {:ok, :private_inspection}
  defp data_class(_value), do: {:error, :invalid_data_class}

  defp auth_scheme("bearer"), do: :bearer
  defp auth_scheme("basic"), do: :basic

  defp error_feedback("closed"), do: :closed
  defp error_feedback("bounded"), do: :bounded

  defp accepts_data_class("normal"), do: :normal
  defp accepts_data_class("private_inspection"), do: :private_inspection

  defp accepts_data(value) when is_list(value) and length(value) in 1..2 do
    with true <- value == Enum.uniq(value),
         true <- Enum.all?(value, &(&1 in ["normal", "private_inspection"])) do
      {:ok, Enum.map(value, &accepts_data_class/1)}
    else
      _reason -> {:error, :invalid_accepts_data}
    end
  end

  defp accepts_data(_value), do: {:error, :invalid_accepts_data}

  defp string_list(value, max_items) when is_list(value) and length(value) <= max_items do
    if Enum.all?(value, &valid_string?(&1, @max_string_bytes)),
      do: {:ok, value},
      else: {:error, :invalid_string_list}
  end

  defp string_list(_value, _max_items), do: {:error, :invalid_string_list}

  defp optional_description(nil), do: {:ok, nil}

  defp optional_description(value) do
    if valid_string?(value, 4_096),
      do: {:ok, value},
      else: {:error, :invalid_description}
  end

  defp reduce_named_map(value, decoder) do
    Enum.reduce_while(value, {:ok, %{}}, fn {name, item}, {:ok, normalized} ->
      case decoder.(name, item) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(normalized, name, decoded)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_name?(name), do: is_binary(name) and name =~ @name

  defp valid_string?(value, max_bytes),
    do:
      is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp valid_path_string?(value), do: valid_string?(value, 4_096)

  defp valid_absolute_path?(value),
    do: valid_path_string?(value) and Path.type(value) == :absolute

  defp valid_header?(value) do
    is_binary(value) and value =~ @header_name and
      String.downcase(value) not in @reserved_headers and
      not String.starts_with?(String.downcase(value), "mcp-")
  end

  defp exact_keys(value, allowed, required) when is_map(value) do
    keys = Map.keys(value)
    if keys -- allowed == [] and required -- keys == [], do: :ok, else: {:error, :invalid_keys}
  end

  defp exact_keys(_value, _allowed, _required), do: {:error, :invalid_keys}

  @doc "Returns the generated JSON Schema 2020-12 contract for host configuration."
  @spec schema() :: map()
  def schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://ptc-runner.dev/schemas/ptc-host-config.schema.json",
      "title" => "PtcRunner host configuration",
      "description" =>
        "Operator-owned provider installation and installed ceilings. An empty install map is valid. Runtime loading remains authoritative.",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["install"],
      "properties" => %{
        "$schema" => %{"type" => "string", "minLength" => 1, "maxLength" => 2_048},
        "runtime" => runtime_schema(),
        "limits" => limits_schema(),
        "credentials" => credentials_schema(),
        "install" => installations_schema()
      }
    }
  end

  defp limits_schema do
    catalog_properties = LimitCatalog.schema_properties(:host)

    properties =
      Map.new(LimitCatalog.rows(), fn row ->
        description =
          case row.scope do
            :manifest_narrowable ->
              "Installed ceiling for #{row.name}; a manifest may only request less."

            :installed_only ->
              "Installed-only operational limit for #{row.name}; applications cannot declare it."
          end

        {row.name,
         catalog_properties |> Map.fetch!(row.name) |> Map.put("description", description)}
      end)

    properties
    |> closed_object()
    |> Map.put(
      "description",
      "Optional operator-owned installed ceilings. Omitted limits keep their cataloged installed defaults."
    )
  end

  defp runtime_schema do
    closed_object(%{
      "stdio_launcher" => %{
        "type" => "string",
        "minLength" => 1,
        "maxLength" => 4_096,
        "pattern" => "^/",
        "description" => "Optional absolute trusted launcher override."
      }
    })
  end

  defp credentials_schema do
    %{
      "type" => "object",
      "maxProperties" => @max_credentials,
      "propertyNames" => name_schema(),
      "additionalProperties" => %{
        "oneOf" => [
          required_object(%{"env" => environment_name_schema()}, ["env"]),
          required_object(%{"file" => path_schema()}, ["file"]),
          required_object(%{"literal" => bounded_string(@max_secret_bytes)}, ["literal"])
        ]
      }
    }
  end

  defp installations_schema do
    %{
      "type" => "object",
      "minProperties" => 0,
      "maxProperties" => @max_installations,
      "propertyNames" => name_schema(),
      "additionalProperties" => installation_schema()
    }
  end

  defp installation_schema do
    %{
      "oneOf" => [
        mcp_installation_schema(),
        llm_installation_schema(),
        trace_snapshot_installation_schema("ptc_trace_snapshot"),
        trace_snapshot_installation_schema("ptc_private_trace_snapshot"),
        inspection_snapshot_installation_schema(),
        llm_replay_installation_schema()
      ]
    }
  end

  defp mcp_installation_schema do
    required_object(
      %{
        "source" => %{"const" => "mcp"},
        "transport" => transport_schema(),
        "tools" => tools_schema(),
        "snapshot_identity" =>
          required_object(
            %{"tool" => name_schema(), "field" => name_schema()},
            ["tool", "field"]
          ),
        "installation_revision" => installation_revision_schema(),
        "ceilings" => ceilings_schema(),
        "data_class" => data_class_schema(),
        "accepts_data" => accepts_data_schema()
      },
      ["source", "transport", "tools", "installation_revision"]
    )
  end

  defp llm_installation_schema do
    required_object(
      %{
        "source" => %{"const" => "llm"},
        "model" => bounded_string(256),
        "credential" => name_schema(),
        "cache" => %{"type" => "boolean", "default" => false},
        "params" =>
          closed_object(%{
            "temperature" => %{
              "type" => "number",
              "minimum" => 0,
              "maximum" => 2
            },
            "seed" => %{
              "type" => "integer",
              "minimum" => 0,
              "maximum" => @max_llm_seed
            },
            "max_tokens" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => @max_llm_tokens
            }
          }),
        "installation_revision" => installation_revision_schema(),
        "ceilings" => llm_ceilings_schema(),
        "data_class" => data_class_schema(),
        "accepts_data" => accepts_data_schema()
      },
      ["source", "model", "credential", "installation_revision"]
    )
  end

  defp trace_snapshot_installation_schema(source) do
    required_object(
      %{
        "source" => %{"const" => source},
        "directory" => path_schema(),
        "installation_revision" => installation_revision_schema(),
        "ceilings" =>
          closed_object(%{
            "max_source_bytes" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => @max_trace_source_bytes,
              "default" => @max_trace_source_bytes
            },
            "max_result_bytes" => %{
              "type" => "integer",
              "minimum" => @minimum_snapshot_result_bytes,
              "maximum" => @max_result_bytes,
              "default" => @max_result_bytes
            }
          })
      },
      ["source", "directory", "installation_revision"]
    )
  end

  defp llm_replay_installation_schema do
    required_object(
      %{
        "source" => %{"const" => "llm_replay"},
        "fixtures" => path_schema(),
        "installation_revision" => installation_revision_schema(),
        "ceilings" =>
          closed_object(%{
            "max_entries" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => @max_replay_entries,
              "default" => @max_replay_entries
            },
            "max_result_bytes" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => @max_result_bytes,
              "default" => @max_result_bytes
            },
            "max_calls" => llm_max_calls_schema()
          }),
        "data_class" => data_class_schema(),
        "accepts_data" => accepts_data_schema()
      },
      ["source", "fixtures", "installation_revision"]
    )
  end

  defp inspection_snapshot_installation_schema do
    required_object(
      %{
        "source" => %{"const" => "ptc_inspection_snapshot"},
        "directory" => path_schema(),
        "installation_revision" => installation_revision_schema(),
        "ceilings" =>
          closed_object(%{
            "max_files" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => @max_inspection_files,
              "default" => @max_inspection_files
            },
            "max_source_bytes" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => @max_inspection_source_bytes,
              "default" => @max_inspection_source_bytes
            },
            "max_result_bytes" => %{
              "type" => "integer",
              "minimum" => @minimum_snapshot_result_bytes,
              "maximum" => @max_result_bytes,
              "default" => @max_result_bytes
            }
          })
      },
      ["source", "directory", "installation_revision"]
    )
  end

  defp data_class_schema do
    %{
      "type" => "string",
      "enum" => ["normal", "private_inspection"],
      "default" => "normal"
    }
  end

  defp accepts_data_schema do
    %{
      "type" => "array",
      "minItems" => 1,
      "maxItems" => 2,
      "uniqueItems" => true,
      "items" => %{"enum" => ["normal", "private_inspection"]},
      "default" => ["normal"]
    }
  end

  defp transport_schema do
    %{"oneOf" => [stdio_schema(), http_schema()]}
  end

  defp stdio_schema do
    required_object(
      %{
        "type" => %{"const" => "stdio"},
        "command" => bounded_string(4_096),
        "cwd" => Map.put(path_schema(), "default", "."),
        "args" => %{
          "type" => "array",
          "maxItems" => 256,
          "items" => bounded_string(@max_string_bytes),
          "default" => []
        },
        "env" => %{
          "type" => "object",
          "maxProperties" => @max_stdio_credential_environment,
          "propertyNames" => environment_name_schema(),
          "additionalProperties" => required_object(%{"binding" => name_schema()}, ["binding"]),
          "default" => %{}
        },
        "inherit_environment" => %{"type" => "boolean", "default" => true},
        "grace_ms" => integer_schema(1, 5_000, 250),
        "stderr_bytes" => integer_schema(0, 1_048_576, 65_536),
        "start_timeout_ms" => integer_schema(1, 60_000, 5_000)
      },
      ["type", "command"]
    )
  end

  defp http_schema do
    %{
      "type" => %{"const" => "streamable_http"},
      "endpoint" => bounded_string(4_096),
      "allow_insecure_loopback" => %{"type" => "boolean", "default" => false},
      "auth" => %{
        "type" => "array",
        "maxItems" => 8,
        "items" => auth_schema(),
        "default" => []
      },
      "oauth" => oauth_schema()
    }
    |> required_object(["type", "endpoint"])
    |> Map.put("not", %{
      "required" => ["auth", "oauth"],
      "properties" => %{"auth" => %{"minItems" => 1}}
    })
    |> Map.put("oneOf", [secure_endpoint_schema(), loopback_endpoint_schema()])
  end

  # Mirrors `installed_endpoint/4`, which stays authoritative. An HTTPS endpoint
  # carries no allowance; a plain-HTTP endpoint requires one, reaches a literal
  # loopback address only, and admits no configured host credential.
  #
  # The mirror is deliberately one-directional: it must never reject an endpoint
  # decoding accepts, or a valid document would fail as a generic schema fault.
  # The reverse is harmless, and does happen — a regex `$` also matches before a
  # trailing newline, which `MCPEndpoint.safe_characters?/1` refuses outright.
  defp secure_endpoint_schema do
    %{
      "properties" => %{
        "endpoint" => %{"pattern" => "^https://[^\\s\\x00-\\x1f\\x7f-\\x9f]*$"},
        "allow_insecure_loopback" => %{"const" => false}
      }
    }
  end

  defp loopback_endpoint_schema do
    %{
      "properties" => %{
        "endpoint" => %{
          "pattern" =>
            "^http://(127\\.0\\.0\\.1|\\[::1\\])(:[0-9]+)?([/?][^\\s\\x00-\\x1f\\x7f-\\x9f]*)?$"
        },
        "allow_insecure_loopback" => %{"const" => true},
        "auth" => %{"maxItems" => 0}
      },
      "required" => ["allow_insecure_loopback"],
      "not" => %{"required" => ["oauth"]}
    }
  end

  defp oauth_schema do
    required_object(
      %{
        "installation_id" => bounded_string(256),
        "issuer" => bounded_string(4_096),
        "resource" => bounded_string(4_096),
        "scope_ceiling" => scope_list_schema(true),
        "default_scopes" => Map.put(scope_list_schema(true), "default", []),
        "refresh_access" => %{
          "enum" => ["none", "when_supported"],
          "default" => "none"
        },
        "authorization_timeout_ms" => integer_schema(1, 900_000, 300_000),
        "unknown_expiry_ttl_ms" => integer_schema(1, 86_400_000, 300_000),
        "network" =>
          closed_object(%{
            "additional_origins" => origin_list_schema(),
            "private_network_origins" => origin_list_schema()
          }),
        "client" => oauth_client_schema()
      },
      ["installation_id", "issuer", "scope_ceiling", "client"]
    )
  end

  defp oauth_client_schema do
    %{
      "oneOf" => [
        pre_registered_client_schema("none", "loopback_redirect"),
        pre_registered_client_schema("none", "redirect_uris"),
        pre_registered_client_schema("client_secret_basic", "redirect_uris"),
        metadata_document_client_schema("loopback_redirect"),
        metadata_document_client_schema("redirect_uris")
      ]
    }
  end

  defp pre_registered_client_schema(method, redirect_field) do
    properties = %{
      "registration" => %{"const" => "pre_registered"},
      "client_id" => bounded_string(2_048),
      "token_endpoint_auth_method" => %{"const" => method},
      "grant_types" => %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => 2,
        "uniqueItems" => true,
        "contains" => %{"const" => "authorization_code"},
        "items" => %{"enum" => ["authorization_code", "refresh_token"]}
      },
      redirect_field => redirect_schema(redirect_field)
    }

    {properties, required} =
      if method == "client_secret_basic" do
        {
          Map.put(properties, "client_secret_binding", name_schema()),
          [
            "registration",
            "client_id",
            "token_endpoint_auth_method",
            "client_secret_binding",
            "grant_types",
            redirect_field
          ]
        }
      else
        {
          properties,
          [
            "registration",
            "client_id",
            "token_endpoint_auth_method",
            "grant_types",
            redirect_field
          ]
        }
      end

    required_object(properties, required)
  end

  defp metadata_document_client_schema(redirect_field) do
    required_object(
      %{
        "registration" => %{"const" => "client_id_metadata_document"},
        "client_id" => bounded_string(2_048),
        "token_endpoint_auth_method" => %{"const" => "none"},
        redirect_field => redirect_schema(redirect_field)
      },
      ["registration", "client_id", "token_endpoint_auth_method", redirect_field]
    )
  end

  defp redirect_schema("redirect_uris"), do: redirect_list_schema()
  defp redirect_schema("loopback_redirect"), do: loopback_redirect_schema()

  defp scope_list_schema(allow_empty?) do
    %{
      "type" => "array",
      "minItems" => if(allow_empty?, do: 0, else: 1),
      "maxItems" => 64,
      "uniqueItems" => true,
      "items" => bounded_string(256)
    }
  end

  defp origin_list_schema do
    %{
      "type" => "array",
      "maxItems" => 32,
      "uniqueItems" => true,
      "items" => bounded_string(4_096),
      "default" => []
    }
  end

  defp redirect_list_schema do
    %{
      "type" => "array",
      "minItems" => 1,
      "maxItems" => 16,
      "uniqueItems" => true,
      "items" => bounded_string(4_096)
    }
  end

  defp loopback_redirect_schema do
    required_object(
      %{
        "host" => %{"enum" => ["127.0.0.1", "::1"]},
        "path" => bounded_string(1_024)
      },
      ["host", "path"]
    )
  end

  defp auth_schema do
    %{
      "oneOf" => [
        required_object(
          %{"scheme" => %{"enum" => ["bearer", "basic"]}, "binding" => name_schema()},
          ["scheme", "binding"]
        ),
        required_object(
          %{
            "scheme" => %{"const" => "api_key"},
            "binding" => name_schema(),
            "header" => bounded_string(256)
          },
          ["scheme", "binding", "header"]
        )
      ]
    }
  end

  defp tools_schema do
    %{
      "type" => "object",
      "minProperties" => 1,
      "maxProperties" => @max_tools,
      "propertyNames" => upstream_tool_name_schema(),
      "additionalProperties" =>
        required_object(
          %{
            "as" => name_schema(),
            "effect" => %{"enum" => ["read", "write"]},
            "description" => bounded_string(4_096),
            "error_feedback" => %{
              "enum" => ["closed", "bounded"],
              "default" => "closed"
            },
            "model_visible" => %{"type" => "boolean", "default" => false}
          },
          ["as", "effect"]
        )
    }
  end

  defp ceilings_schema do
    closed_object(%{
      "timeout_ms" => integer_schema(1, @max_timeout_ms, 5_000),
      "max_catalog_tools" => integer_schema(1, 128, 128),
      "max_result_bytes" => integer_schema(1, @max_result_bytes, 1_000_000)
    })
  end

  defp llm_ceilings_schema do
    closed_object(%{
      "max_request_bytes" => integer_schema(1, @max_result_bytes, 1_000_000),
      "max_response_bytes" => integer_schema(1, @max_result_bytes, 1_000_000),
      "max_calls" => llm_max_calls_schema()
    })
  end

  defp llm_max_calls_schema do
    {:ok, row} = LimitCatalog.fetch(:workflow_capability_calls_per_name)
    integer_schema(row.minimum, row.installed_default, row.installed_default)
  end

  defp required_object(properties, required) do
    properties
    |> closed_object()
    |> Map.put("required", required)
  end

  defp closed_object(properties),
    do: %{"type" => "object", "additionalProperties" => false, "properties" => properties}

  defp bounded_string(max_length),
    do: %{"type" => "string", "minLength" => 1, "maxLength" => max_length}

  defp path_schema, do: bounded_string(4_096)

  defp name_schema,
    do: %{"type" => "string", "pattern" => "^[a-z][a-z0-9._-]{0,127}$"}

  # Mirrors `PtcRunner.Kernel.MCPProtocol.valid_tool_name?/1`: an upstream name
  # is whatever the installed server advertises.
  defp upstream_tool_name_schema,
    do: %{"type" => "string", "pattern" => "^[^\\s\\x00-\\x1f\\x7f]{1,128}$"}

  defp installation_revision_schema, do: name_schema()

  defp environment_name_schema,
    do: %{"type" => "string", "pattern" => "^[A-Za-z_][A-Za-z0-9_]*$"}

  defp integer_schema(minimum, maximum, default),
    do: %{"type" => "integer", "minimum" => minimum, "maximum" => maximum, "default" => default}
end
