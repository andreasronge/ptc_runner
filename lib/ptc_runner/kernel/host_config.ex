defmodule PtcRunner.Kernel.HostConfig do
  @moduledoc """
  Strict loader for host-installed provider authority.

  The host document is operator-owned and separate from an application
  manifest. It fixes provider sources, credentials, data classes, and outer
  ceilings. MCP installations additionally fix transports, tool mappings, and
  effects; live LLM installations fix the model, cache policy, and optional
  sampling parameters. A manifest may later select an installed alias and
  narrow its authority; it cannot introduce or replace any field decoded here.

  Loading is bounded, path-confined, duplicate-key rejecting, and side-effect
  free. In particular, credential declarations are validated but environment
  variables and files are not read. Executables are not resolved, processes
  are not started, and remote endpoints are not contacted. Those operations
  belong to the later preflight and acquisition phases.

  The closed V1 source identifiers are `mcp`, `llm`, `llm_replay`,
  `ptc_trace_snapshot`, and `ptc_inspection_snapshot`. LLM credentials are explicit bindings passed to
  the adapter per request rather than ambient provider-specific environment
  lookup. The native snapshot sources fix host-relative directories and
  expose only PtcRunner's canonical or private inspection query vocabularies.

  `schema/0` is the canonical structural description shipped for editor and
  human feedback. Runtime decoding remains authoritative for semantic checks
  such as unique public tool names, credential references, reserved headers,
  and portable environment names.
  """

  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.StrictJSON

  @max_config_bytes 1_000_000
  @max_credentials 128
  @max_installations 128
  @max_tools 128
  @max_string_bytes 131_072
  @max_secret_bytes 65_536
  @max_result_bytes 1_048_576
  @max_trace_source_bytes 8_000_000
  @max_inspection_source_bytes 64_000_000
  @max_inspection_files 1_024
  @max_replay_entries 10_000
  @max_timeout_ms 300_000
  @max_llm_tokens 1_000_000
  @max_llm_seed 2_147_483_647
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @environment_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @header_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @reserved_environment ~w(HOME LOGNAME PATH SHELL TERM USER)
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

  @enforce_keys [:path, :directory, :runtime, :credentials, :install]
  defstruct @enforce_keys

  @type credential ::
          %{source: :env, name: binary()}
          | %{source: :file, path: binary()}
          | %{source: :literal, value: binary()}

  @type tool :: %{
          as: binary(),
          effect: :read,
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
              auth: [map()]
            }

  @type installation ::
          %{
            source: :mcp,
            transport: transport(),
            tools: %{binary() => tool()},
            snapshot_identity: %{tool: binary(), field: binary()} | nil,
            installation_revision: binary() | nil,
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
              installation_revision: binary() | nil,
              ceilings: %{
                max_request_bytes: pos_integer(),
                max_response_bytes: pos_integer()
              },
              data_class: :normal | :private_inspection,
              accepts_data: [:normal | :private_inspection]
            }
          | %{
              source: :llm_replay,
              fixtures: binary(),
              installation_revision: binary() | nil,
              ceilings: %{max_entries: pos_integer(), max_result_bytes: pos_integer()},
              data_class: :normal | :private_inspection,
              accepts_data: [:normal | :private_inspection]
            }
          | %{
              source: :ptc_trace_snapshot,
              directory: binary(),
              ceilings: %{
                max_source_bytes: pos_integer(),
                max_result_bytes: pos_integer()
              }
            }
          | %{
              source: :ptc_inspection_snapshot,
              directory: binary(),
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
  @spec decode(term(), binary()) ::
          {:ok,
           %{
             runtime: %{stdio_launcher: binary() | nil},
             credentials: %{binary() => credential()},
             install: %{binary() => installation()}
           }}
          | {:error, :invalid_host_config}
  def decode(value, directory) when is_map(value) and is_binary(directory) do
    with :ok <-
           exact_keys(value, ~w($schema runtime credentials install), ~w(install)),
         :ok <- optional_schema(value["$schema"]),
         {:ok, runtime} <- runtime(Map.get(value, "runtime", %{})),
         {:ok, credentials} <- credentials(Map.get(value, "credentials", %{})),
         {:ok, install} <- installations(value["install"], credentials) do
      {:ok, %{runtime: runtime, credentials: credentials, install: install}}
    else
      _reason -> {:error, :invalid_host_config}
    end
  end

  def decode(_value, _directory), do: {:error, :invalid_host_config}

  defp optional_schema(nil), do: :ok

  defp optional_schema(value) do
    if valid_string?(value, 2_048), do: :ok, else: {:error, :invalid_schema_annotation}
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

  defp installations(value, credentials)
       when is_map(value) and map_size(value) in 1..@max_installations do
    reduce_named_map(value, fn name, installation ->
      installation(name, installation, credentials)
    end)
  end

  defp installations(_value, _credentials), do: {:error, :invalid_installations}

  defp installation(name, value, credentials) do
    with true <- valid_name?(name),
         true <- is_map(value) do
      case value["source"] do
        "mcp" -> mcp_installation(value, credentials)
        "llm" -> llm_installation(value, credentials)
        "ptc_trace_snapshot" -> trace_snapshot_installation(value)
        "ptc_inspection_snapshot" -> inspection_snapshot_installation(value)
        "llm_replay" -> llm_replay_installation(value)
        _unknown -> {:error, :invalid_installation}
      end
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp mcp_installation(value, credentials) do
    allowed =
      ~w(source transport tools snapshot_identity installation_revision ceilings data_class accepts_data)

    with :ok <- exact_keys(value, allowed, ~w(source transport tools)),
         {:ok, transport} <- transport(value["transport"], credentials),
         {:ok, tools} <- tools(value["tools"]),
         {:ok, snapshot_identity} <-
           snapshot_identity(Map.get(value, "snapshot_identity"), tools),
         {:ok, installation_revision} <-
           optional_revision(Map.get(value, "installation_revision")),
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

    with :ok <- exact_keys(value, allowed, ~w(source model credential)),
         model when is_binary(model) <- value["model"],
         true <- valid_string?(model, 256),
         credential when is_binary(credential) <- value["credential"],
         true <- Map.has_key?(credentials, credential),
         cache when is_boolean(cache) <- Map.get(value, "cache", false),
         {:ok, params} <- llm_params(Map.get(value, "params", %{})),
         {:ok, installation_revision} <-
           optional_revision(Map.get(value, "installation_revision")),
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

  defp trace_snapshot_installation(value) do
    with :ok <- exact_keys(value, ~w(source directory ceilings), ~w(source directory)),
         directory when is_binary(directory) <- value["directory"],
         true <- valid_path_string?(directory),
         {:ok, ceilings} <- trace_snapshot_ceilings(Map.get(value, "ceilings", %{})) do
      {:ok,
       %{
         source: :ptc_trace_snapshot,
         directory: directory,
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
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
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

    with :ok <- exact_keys(value, allowed, ~w(source fixtures)),
         fixtures when is_binary(fixtures) <- value["fixtures"],
         true <- valid_path_string?(fixtures),
         {:ok, installation_revision} <-
           optional_revision(Map.get(value, "installation_revision")),
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
    with :ok <- exact_keys(value, ~w(max_entries max_result_bytes), []),
         max_entries when is_integer(max_entries) and max_entries > 0 <-
           Map.get(value, "max_entries", @max_replay_entries),
         true <- max_entries <= @max_replay_entries,
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
           Map.get(value, "max_result_bytes", @max_result_bytes),
         true <- max_result_bytes <= @max_result_bytes do
      {:ok, %{max_entries: max_entries, max_result_bytes: max_result_bytes}}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  defp llm_replay_ceilings(_value), do: {:error, :invalid_ceilings}

  defp inspection_snapshot_installation(value) do
    with :ok <- exact_keys(value, ~w(source directory ceilings), ~w(source directory)),
         directory when is_binary(directory) <- value["directory"],
         true <- valid_path_string?(directory),
         {:ok, ceilings} <- inspection_snapshot_ceilings(Map.get(value, "ceilings", %{})) do
      {:ok,
       %{
         source: :ptc_inspection_snapshot,
         directory: directory,
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
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
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
    with :ok <- exact_keys(value, ~w(type endpoint auth), ~w(type endpoint)),
         endpoint when is_binary(endpoint) <- value["endpoint"],
         true <- valid_string?(endpoint, 4_096),
         {:ok, auth} <- auth(Map.get(value, "auth", []), credentials) do
      {:ok, %{type: :streamable_http, endpoint: endpoint, auth: auth}}
    else
      _reason -> {:error, :invalid_transport}
    end
  end

  defp environment_bindings(value, credentials)
       when is_map(value) and map_size(value) <= 256 do
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

  defp tool(upstream, value) do
    allowed = ~w(as effect description error_feedback model_visible)

    with true <- valid_name?(upstream),
         true <- is_map(value),
         :ok <- exact_keys(value, allowed, ~w(as effect)),
         as when is_binary(as) <- value["as"],
         true <- valid_name?(as),
         "read" <- value["effect"],
         {:ok, description} <- optional_description(Map.get(value, "description")),
         feedback when feedback in ["closed", "bounded"] <-
           Map.get(value, "error_feedback", "closed"),
         model_visible when is_boolean(model_visible) <-
           Map.get(value, "model_visible", false) do
      {:ok,
       %{
         as: as,
         effect: :read,
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
         true <- Map.has_key?(tools, tool),
         field when is_binary(field) <- value["field"],
         true <- valid_name?(field) do
      {:ok, %{tool: tool, field: field}}
    else
      _reason -> {:error, :invalid_snapshot_identity}
    end
  end

  defp snapshot_identity(_value, _tools), do: {:error, :invalid_snapshot_identity}

  defp optional_revision(nil), do: {:ok, nil}

  defp optional_revision(value) do
    if valid_string?(value, 256),
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
    with :ok <- exact_keys(value, ~w(max_request_bytes max_response_bytes), []),
         max_request_bytes
         when is_integer(max_request_bytes) and max_request_bytes in 1..@max_result_bytes <-
           Map.get(value, "max_request_bytes", 1_000_000),
         max_response_bytes
         when is_integer(max_response_bytes) and max_response_bytes in 1..@max_result_bytes <-
           Map.get(value, "max_response_bytes", 1_000_000) do
      {:ok,
       %{
         max_request_bytes: max_request_bytes,
         max_response_bytes: max_response_bytes
       }}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  defp llm_ceilings(_value), do: {:error, :invalid_ceilings}

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
        "Operator-owned provider installation. Runtime loading remains authoritative.",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["install"],
      "properties" => %{
        "$schema" => %{"type" => "string", "minLength" => 1, "maxLength" => 2_048},
        "runtime" => runtime_schema(),
        "credentials" => credentials_schema(),
        "install" => installations_schema()
      }
    }
  end

  defp runtime_schema do
    closed_object(%{
      "stdio_launcher" => %{
        "type" => "string",
        "minLength" => 1,
        "maxLength" => 4_096,
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
      "minProperties" => 1,
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
        trace_snapshot_installation_schema(),
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
        "installation_revision" => bounded_string(256),
        "ceilings" => ceilings_schema(),
        "data_class" => data_class_schema(),
        "accepts_data" => accepts_data_schema()
      },
      ["source", "transport", "tools"]
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
        "installation_revision" => bounded_string(256),
        "ceilings" => llm_ceilings_schema(),
        "data_class" => data_class_schema(),
        "accepts_data" => accepts_data_schema()
      },
      ["source", "model", "credential"]
    )
  end

  defp trace_snapshot_installation_schema do
    required_object(
      %{
        "source" => %{"const" => "ptc_trace_snapshot"},
        "directory" => path_schema(),
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
              "minimum" => 1,
              "maximum" => @max_result_bytes,
              "default" => @max_result_bytes
            }
          })
      },
      ["source", "directory"]
    )
  end

  defp llm_replay_installation_schema do
    required_object(
      %{
        "source" => %{"const" => "llm_replay"},
        "fixtures" => path_schema(),
        "installation_revision" => bounded_string(256),
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
            }
          }),
        "data_class" => data_class_schema(),
        "accepts_data" => accepts_data_schema()
      },
      ["source", "fixtures"]
    )
  end

  defp inspection_snapshot_installation_schema do
    required_object(
      %{
        "source" => %{"const" => "ptc_inspection_snapshot"},
        "directory" => path_schema(),
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
              "minimum" => 1,
              "maximum" => @max_result_bytes,
              "default" => @max_result_bytes
            }
          })
      },
      ["source", "directory"]
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
          "maxProperties" => 256,
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
    required_object(
      %{
        "type" => %{"const" => "streamable_http"},
        "endpoint" => bounded_string(4_096),
        "auth" => %{
          "type" => "array",
          "maxItems" => 8,
          "items" => auth_schema(),
          "default" => []
        }
      },
      ["type", "endpoint"]
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
      "propertyNames" => name_schema(),
      "additionalProperties" =>
        required_object(
          %{
            "as" => name_schema(),
            "effect" => %{"const" => "read"},
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
      "max_response_bytes" => integer_schema(1, @max_result_bytes, 1_000_000)
    })
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

  defp environment_name_schema,
    do: %{"type" => "string", "pattern" => "^[A-Za-z_][A-Za-z0-9_]*$"}

  defp integer_schema(minimum, maximum, default),
    do: %{"type" => "integer", "minimum" => minimum, "maximum" => maximum, "default" => default}
end
