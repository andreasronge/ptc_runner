defmodule PtcRunner.Kernel.HostConfig do
  @moduledoc """
  Strict loader for host-installed provider authority.

  The host document is operator-owned and separate from an application
  manifest. It fixes provider sources, credentials, data classes, and outer
  ceilings. MCP installations additionally fix transports, tool mappings, and
  effects; live LLM installations fix the model, structured-output mode, usage
  guarantees, cache policy, and optional inference controls. A manifest may
  later select an installed alias and narrow its authority; it cannot introduce
  or replace any field decoded here. Changing `structured_output_mode`, a usage
  guarantee, an inference control, or an installation
  `ceilings.request_timeout_ms` requires a new `installation_revision`.

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

  The closed V1 source identifiers are `mcp`, `llm`, `llm_replay`, `decision`, `decision_replay`,
  `ptc_trace_snapshot`, `ptc_private_trace_snapshot`, and `ptc_inspection_snapshot`. LLM credentials are explicit bindings passed to
  the adapter per request rather than ambient provider-specific environment
  lookup. Only `openai-compat:` LLM installations may omit the credential;
  acquisition then resolves no credential and sends no Authorization header.
  Chat decision installations resolve an installed `llm` alias in
  `json_schema` mode during decode and retain its declaration in their
  configuration identity. The native snapshot sources fix host-relative directories and
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

  alias PtcRunner.Kernel.HostConfig.Common

  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.InstallationConfigDigest
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.OptionalBudgetDiagnostic
  alias PtcRunner.Kernel.SchemaPath
  alias PtcRunner.Kernel.SchemaViolation
  alias PtcRunner.Kernel.StrictJSON

  alias PtcRunner.Kernel.HostConfig.{Decision, LLM, MCP, Replay, Snapshot}
  import PtcRunner.Kernel.HostConfig.Common, except: [minimum_snapshot_result_bytes: 0]

  @max_config_bytes 1_000_000
  @max_credentials 128
  @max_installations 128
  @max_tools 128
  @max_stdio_credential_environment 249
  @max_string_bytes 131_072
  @max_secret_bytes 65_536
  @max_result_bytes 1_048_576
  @max_trace_source_bytes 8_000_000
  @max_inspection_source_bytes 536_871_120
  @max_inspection_files 1_024
  @max_replay_entries 10_000
  # The accepted minimum must fit the complete smallest snapshot result under
  # both the encoded and retained-size measurements enforced at the boundary.
  @minimum_snapshot_result_bytes Common.minimum_snapshot_result_bytes()
  @max_timeout_ms 300_000
  @max_llm_tokens 1_000_000
  @max_llm_seed 2_147_483_647
  @environment_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
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
            installation_config_digest: binary(),
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
              credential: binary() | nil,
              cache: boolean(),
              params: %{
                optional(:temperature) => float(),
                optional(:seed) => non_neg_integer(),
                optional(:max_tokens) => pos_integer(),
                optional(:top_p) => float(),
                optional(:presence_penalty) => float(),
                optional(:frequency_penalty) => float(),
                optional(:reasoning_effort) => :none | :minimal | :low | :medium | :high
              },
              structured_output_mode: :json_schema | :json_object | :unsupported,
              usage_guarantees: %{tokens: boolean(), cost_currency: String.t() | nil},
              reservation_tariff: %{currency: String.t(), id: binary()} | nil,
              installation_revision: binary(),
              installation_config_digest: binary(),
              ceilings: %{
                max_request_bytes: pos_integer(),
                max_response_bytes: pos_integer(),
                max_calls: pos_integer(),
                request_timeout_ms: pos_integer()
              },
              data_class: :normal | :private_inspection,
              accepts_data: [:normal | :private_inspection]
            }
          | %{
              source: :llm_replay,
              fixtures: binary(),
              installation_revision: binary(),
              installation_config_digest: binary(),
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
              installation_config_digest: binary(),
              ceilings: %{
                max_source_bytes: pos_integer(),
                max_result_bytes: pos_integer()
              }
            }
          | %{
              source: :ptc_private_trace_snapshot,
              directory: binary(),
              installation_revision: binary(),
              installation_config_digest: binary(),
              ceilings: %{
                max_source_bytes: pos_integer(),
                max_result_bytes: pos_integer()
              }
            }
          | %{
              source: :ptc_inspection_snapshot,
              directory: binary(),
              installation_revision: binary(),
              installation_config_digest: binary(),
              ceilings: %{
                max_files: pos_integer(),
                max_source_bytes: pos_integer(),
                max_result_bytes: pos_integer()
              }
            }

  @type decision_installation :: %{
          required(:source) => :decision | :decision_replay,
          required(:installation_revision) => binary(),
          required(:installation_config_digest) => binary(),
          required(:max_total_tokens_per_call) => pos_integer(),
          required(:max_cost_microusd_per_call) => non_neg_integer(),
          optional(:backend) => :chat | :http,
          optional(:endpoint) => binary(),
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{
          path: binary(),
          directory: binary(),
          runtime: %{stdio_launcher: binary() | nil},
          credentials: %{binary() => credential()},
          install: %{binary() => installation() | decision_installation()}
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
             | {:schema_validation_unavailable, SchemaViolation.unavailable_reason()}
             | {:host_schema_invalid, SchemaViolation.t()}
             | {:installed_limit_invalid, [PtcRunner.Kernel.CommandPath.segment()]}
             | {:optional_budget_prerequisite, binary(), atom(), atom()}}
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
             :schema_validation_unavailable,
             :host_schema_invalid,
             :installed_limit_invalid
           ] ->
        error

      {:error, {:installation_endpoint_invalid, _name, _reason}} = error ->
        error

      {:error, {:optional_budget_prerequisite, _name, _limit, _prerequisite}} = error ->
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
             install: %{binary() => installation() | decision_installation()}
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
         {:ok, install} <- installations(value["install"], credentials, limits) do
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
           command_semantic_result(installations(value["install"], credentials, limits)) do
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
  # validated as an installation name first.
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

  defp schema_result(:ok, _segments), do: :ok

  defp schema_result({:error, _reason}, segments),
    do: {:error, {:host_schema_invalid, SchemaViolation.new(:schema, segments)}}

  # `validate_command_schema/1` has already proved the whole document under a
  # bounded worker. Failures after that boundary are semantic host failures;
  # do not repeat schema validation outside the worker to distinguish them.
  defp command_semantic_result(:ok), do: :ok
  defp command_semantic_result({:ok, decoded}), do: {:ok, decoded}

  defp command_semantic_result(
         {:error, {:optional_budget_prerequisite, name, limit, prerequisite}} = error
       ) do
    if valid_name?(name) and OptionalBudgetDiagnostic.valid_prerequisite?(limit, prerequisite),
      do: error,
      else: {:error, :host_invalid}
  end

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
      {:unavailable, reason} -> {:error, {:schema_validation_unavailable, reason}}
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
        Map.new(limits, fn {name, value} ->
          if schema_minimum_violation?(name, value) do
            {name, value}
          else
            {:ok, field} = Limits.name(name)
            {:ok, row} = LimitCatalog.fetch(field)
            {name, Map.fetch!(installed, field) || row.minimum}
          end
        end)

      Map.put(value, "limits", schema_limits)
    else
      value
    end
  end

  defp command_schema_value(value), do: value

  # The two normal-trace floors exist because a trace that cannot record its own
  # terminal events is not a trace, and both are published as schema minimums.
  # A host value below one of them is pointed at the rule that states it; every
  # other range failure keeps the closed installed-limit diagnostic.
  defp schema_minimum_violation?(name, value)
       when name in ["event_payload_bytes", "normal_event_count"] and is_integer(value) do
    {:ok, field} = Limits.name(name)
    {:ok, row} = LimitCatalog.fetch(field)
    value < row.minimum
  end

  defp schema_minimum_violation?(_name, _value), do: false

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

  defp installations(value, _credentials, _limits) when is_map(value) and map_size(value) == 0,
    do: {:ok, %{}}

  defp installations(value, credentials, limits)
       when is_map(value) and map_size(value) in 1..@max_installations do
    with {:ok, installations} <-
           reduce_sorted_named_map(value, fn name, installation ->
             installation(name, installation, credentials, limits)
           end),
         ids =
           for(
             {_name, %{source: :mcp, transport: %{oauth: %Authority{} = oauth}}} <-
               installations,
             do: oauth.installation_id
           ),
         true <- ids == Enum.uniq(ids),
         {:ok, installations} <- resolve_decision_chats(installations),
         {:ok, installations} <- InstallationConfigDigest.attach_all(installations) do
      {:ok, installations}
    else
      {:error, {:optional_budget_prerequisite, _name, _limit, _prerequisite}} = error ->
        error

      _invalid ->
        {:error, :invalid_installations}
    end
  end

  defp installations(_value, _credentials, _limits), do: {:error, :invalid_installations}

  defp installation(name, value, credentials, limits) do
    with true <- valid_name?(name),
         true <- is_map(value) do
      case value["source"] do
        "mcp" ->
          MCP.mcp_installation(value, credentials)

        "llm" ->
          case LLM.llm_installation(value, credentials, limits) do
            {:error, {:optional_budget_prerequisite, limit, prerequisite}} ->
              {:error, {:optional_budget_prerequisite, name, limit, prerequisite}}

            result ->
              result
          end

        "ptc_trace_snapshot" ->
          Snapshot.trace_snapshot_installation(value, :ptc_trace_snapshot)

        "ptc_private_trace_snapshot" ->
          Snapshot.trace_snapshot_installation(value, :ptc_private_trace_snapshot)

        "ptc_inspection_snapshot" ->
          Snapshot.inspection_snapshot_installation(value)

        "decision" ->
          Decision.decision_installation(value, credentials, limits)

        "decision_replay" ->
          Decision.decision_replay_installation(value, limits)

        "llm_replay" ->
          Replay.llm_replay_installation(value)

        _unknown ->
          {:error, :invalid_installation}
      end
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp resolve_decision_chats(installations) do
    Enum.reduce_while(installations, {:ok, %{}}, fn {name, installation}, {:ok, acc} ->
      case resolve_decision_chat(installation, installations) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, name, resolved)}}
        error -> {:halt, error}
      end
    end)
  end

  defp resolve_decision_chat(
         %{source: :decision, backend: :chat, llm: alias_name} = decision,
         installations
       ) do
    with %{source: :llm, structured_output_mode: :json_schema} = llm <-
           Map.get(installations, alias_name),
         true <- decision.data_class == llm.data_class,
         true <- MapSet.subset?(MapSet.new(decision.accepts_data), MapSet.new(llm.accepts_data)) do
      {:ok,
       decision
       |> Map.put(:chat_installation, llm)
       |> Map.put(:credential, llm.credential)
       |> Map.put(:usage_guarantees, llm.usage_guarantees)}
    else
      _ -> {:error, :invalid_installation}
    end
  end

  defp resolve_decision_chat(installation, _installations), do: {:ok, installation}

  @doc "Returns the generated JSON Schema 2020-12 contract for host configuration."
  @spec schema() :: map()
  def schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://ptc-runner.dev/schemas/ptc-host-config.schema.json",
      "title" => "PtcRunner host configuration",
      "description" =>
        "Installed provider configuration and ceilings. An empty install map is valid. Runtime loading remains authoritative.",
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

            :optional_manifest_narrowable ->
              optional_limit_schema_description(row)

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
      "Optional installed ceilings. Omitted limits keep their cataloged installed defaults."
    )
  end

  defp optional_limit_schema_description(%{name: name, prerequisite_description: description})
       when is_binary(description) and description != "" do
    "Optional limit for #{name}; omission disables it. " <> description
  end

  defp optional_limit_schema_description(%{name: name}) do
    "Optional limit for #{name}; omission disables it. A positive value enables it and becomes the inherited manifest default and installed ceiling."
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
        decision_installation_schema(),
        chat_decision_installation_schema(),
        http_decision_installation_schema(),
        decision_replay_installation_schema(),
        trace_snapshot_installation_schema("ptc_trace_snapshot"),
        trace_snapshot_installation_schema("ptc_private_trace_snapshot"),
        inspection_snapshot_installation_schema(),
        llm_replay_installation_schema()
      ]
    }
  end

  defp decision_installation_schema do
    chat = llm_installation_schema()

    properties =
      chat["properties"]
      |> Map.drop(~w(cache params structured_output_mode))
      |> Map.put("credential", name_schema())
      |> Map.put("source", %{"const" => "decision"})
      |> Map.put(
        "routing",
        closed_object(%{
          "zdr" => %{"type" => "boolean"},
          "data_collection" => %{"enum" => ["allow", "deny"]},
          "allow_fallbacks" => %{"type" => "boolean"}
        })
      )
      |> Map.merge(decision_bounds_schema())

    required_object(
      properties,
      ~w(source model credential usage_guarantees installation_revision max_cost_per_call max_total_tokens_per_call)
    )
  end

  defp http_decision_installation_schema do
    properties =
      decision_installation_schema()["properties"]
      |> Map.drop(~w(routing reservation_tariff))
      |> Map.put("backend", %{"const" => "http"})
      |> Map.put("endpoint", bounded_string(4_096))
      |> Map.put("allow_insecure_loopback", %{"type" => "boolean", "default" => false})

    loopback =
      loopback_endpoint_schema()
      |> Map.put("not", %{"required" => ["credential"]})
      |> update_in(["properties"], &Map.delete(&1, "auth"))

    required_object(
      properties,
      ~w(source backend endpoint model usage_guarantees installation_revision max_cost_per_call max_total_tokens_per_call)
    )
    |> Map.put("oneOf", [secure_endpoint_schema(), loopback])
  end

  defp chat_decision_installation_schema do
    properties =
      decision_installation_schema()["properties"]
      |> Map.drop(~w(model credential routing usage_guarantees reservation_tariff))
      |> Map.put("backend", %{"const" => "chat"})
      |> Map.put("llm", bounded_string(128))

    required_object(
      properties,
      ~w(source backend llm installation_revision max_cost_per_call max_total_tokens_per_call)
    )
  end

  defp decision_replay_installation_schema do
    replay = llm_replay_installation_schema()

    properties =
      replay["properties"]
      |> Map.put("source", %{"const" => "decision_replay"})
      |> Map.put("usage_guarantees", llm_installation_schema()["properties"]["usage_guarantees"])
      |> Map.merge(decision_bounds_schema())

    required_object(
      properties,
      ~w(source fixtures installation_revision max_cost_per_call max_total_tokens_per_call)
    )
  end

  defp decision_bounds_schema do
    %{
      "max_cost_per_call" =>
        required_object(
          %{
            "currency" => %{"const" => "USD"},
            "amount" => %{
              "type" => "string",
              "pattern" => "^(0|[1-9][0-9]*)(\\.[0-9]+)?$",
              "maxLength" => 64
            }
          },
          ~w(currency amount)
        ),
      "max_total_tokens_per_call" => %{
        "type" => "integer",
        "minimum" => 1,
        "maximum" => LLMUsage.maximum_integer()
      }
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
        "credential" =>
          Map.put(
            name_schema(),
            "description",
            "Optional only for openai-compat: models. When omitted, no credential is resolved and no Authorization header is sent; configured credentials must resolve."
          ),
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
            },
            "top_p" => %{
              "type" => "number",
              "exclusiveMinimum" => 0,
              "maximum" => 1
            },
            "presence_penalty" => %{
              "type" => "number",
              "minimum" => -2,
              "maximum" => 2
            },
            "frequency_penalty" => %{
              "type" => "number",
              "minimum" => -2,
              "maximum" => 2
            },
            "reasoning_effort" => %{
              "type" => "string",
              "enum" => ["none", "minimal", "low", "medium", "high"]
            }
          }),
        "structured_output_mode" => %{
          "description" =>
            "Direct openai-compat: supports json_schema as your declaration of strict server schema support (which the adapter cannot verify); configured credentials are sent as Authorization: Bearer; schemas are sent unchanged and returned objects are validated. Direct ollama: refuses structured modes. Direct routes refuse reservation tariffs and cost budgets; token budgets require usage_guarantees.tokens: true.",
          "type" => "string",
          "enum" => ["json_schema", "json_object", "unsupported"]
        },
        "usage_guarantees" =>
          required_object(
            %{
              "tokens" => %{"type" => "boolean"},
              "cost_currency" => %{"type" => ["string", "null"], "enum" => ["USD", nil]}
            },
            ["tokens", "cost_currency"]
          ),
        "reservation_tariff" =>
          required_object(
            %{
              "currency" => %{"const" => "USD"},
              "id" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}
            },
            ["currency", "id"]
          ),
        "installation_revision" => installation_revision_schema(),
        "ceilings" => llm_ceilings_schema(),
        "data_class" => data_class_schema(),
        "accepts_data" => accepts_data_schema()
      },
      [
        "source",
        "model",
        "structured_output_mode",
        "usage_guarantees",
        "installation_revision"
      ]
    )
    |> Map.put("allOf", [
      %{
        "if" => %{"properties" => %{"model" => %{"pattern" => "^openai-compat:"}}},
        "else" => %{"required" => ["credential"]}
      }
    ])
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
        %{
          "as" => name_schema(),
          "effect" => %{"enum" => ["read", "write"]},
          "description" => bounded_string(4_096),
          "error_feedback" => %{
            "enum" => ["closed", "bounded"],
            "default" => "closed"
          },
          "inspection_capture" => %{
            "enum" => ["full", "digest_results"],
            "default" => "full"
          },
          "model_visible" => %{"type" => "boolean", "default" => false}
        }
        |> required_object(["as", "effect"])
        |> Map.merge(%{
          "if" => %{
            "properties" => %{"inspection_capture" => %{"const" => "digest_results"}},
            "required" => ["inspection_capture"]
          },
          "then" => %{"properties" => %{"effect" => %{"const" => "read"}}}
        })
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
    {:ok, row} = LimitCatalog.fetch(:llm_request_timeout_ms)

    closed_object(%{
      "max_request_bytes" => integer_schema(1, @max_result_bytes, 1_000_000),
      "max_response_bytes" => integer_schema(1, @max_result_bytes, 1_000_000),
      "max_calls" => llm_max_calls_schema(),
      "request_timeout_ms" => integer_schema(row.minimum, row.maximum, row.compiled_default)
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
