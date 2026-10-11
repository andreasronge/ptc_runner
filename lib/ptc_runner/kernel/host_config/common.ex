defmodule PtcRunner.Kernel.HostConfig.Common do
  @moduledoc false

  alias PtcRunner.Lisp.RetainedSize

  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPEndpoint
  alias PtcRunner.Kernel.MCPProtocol

  @max_result_bytes 1_048_576
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @installation_revision @name

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

  def minimum_snapshot_result_bytes, do: @minimum_snapshot_result_bytes

  def usage_guarantees(%{"tokens" => tokens, "cost_currency" => currency} = guarantees)
      when map_size(guarantees) == 2 and is_boolean(tokens) and currency in ["USD", nil],
      do: {:ok, %{tokens: tokens, cost_currency: currency}}

  def usage_guarantees(_value), do: {:error, :invalid_usage_guarantees}

  def usage_guarantee_requirements(guarantees, %Limits{} = limits) do
    with :ok <-
           optional_budget_requirement(
             limits.llm_cost_microusd,
             guarantees.tokens,
             :llm_cost_microusd,
             :usage_tokens
           ),
         :ok <-
           optional_budget_requirement(
             limits.llm_cost_microusd,
             guarantees.cost_currency == "USD",
             :llm_cost_microusd,
             :usage_cost_currency
           ) do
      optional_budget_requirement(
        limits.llm_total_tokens,
        guarantees.tokens,
        :llm_total_tokens,
        :usage_tokens
      )
    end
  end

  def reservation_tariff(nil), do: {:ok, nil}

  def reservation_tariff(%{"currency" => "USD", "id" => id} = tariff)
      when map_size(tariff) == 2 and is_binary(id) and byte_size(id) in 1..128 do
    if String.valid?(id),
      do: {:ok, %{currency: "USD", id: id}},
      else: {:error, :invalid_reservation_tariff}
  end

  def reservation_tariff(_value), do: {:error, :invalid_reservation_tariff}

  def optional_budget_requirement(nil, _satisfied?, _limit, _prerequisite), do: :ok
  def optional_budget_requirement(_enabled, true, _limit, _prerequisite), do: :ok

  def optional_budget_requirement(_enabled, false, limit, prerequisite),
    do: {:error, {:optional_budget_prerequisite, limit, prerequisite}}

  # Runtime decoding owns this rule; `http_schema/0` mirrors it so an editor can
  # report the same refusal, and `admissible_endpoints/1` reports it as its own
  # diagnostic before the generic schema failure.
  #
  # The allowance is credential-free: an installed `auth` binding or an OAuth
  # authority must never cross a plaintext socket. That is a guarantee about
  # configured host credentials and nothing more — tool arguments and results
  # travelling over a loopback socket are still plaintext.

  def installed_endpoint(endpoint, insecure_loopback, auth, oauth)
      when auth != [] or not is_nil(oauth) do
    if is_binary(endpoint) and String.starts_with?(endpoint, "http://"),
      do: {:error, :credentials_require_https},
      else: MCPEndpoint.diagnose(endpoint, insecure_loopback)
  end

  def installed_endpoint(endpoint, insecure_loopback, _auth, _oauth),
    do: MCPEndpoint.diagnose(endpoint, insecure_loopback)

  # The upstream key is the server's own tool name, so it is held to the MCP
  # protocol rule rather than to PtcRunner's naming rule. Only `as` crosses the
  # capability boundary, and that one stays lowercase-dotted.
  def tool(upstream, value) do
    allowed = ~w(as effect description error_feedback inspection_capture model_visible)

    with true <- MCPProtocol.valid_tool_name?(upstream),
         true <- is_map(value),
         :ok <- exact_keys(value, allowed, ~w(as effect)),
         as when is_binary(as) <- value["as"],
         true <- valid_name?(as),
         effect when effect in ["read", "write"] <- value["effect"],
         capture when capture in ["full", "digest_results"] <-
           Map.get(value, "inspection_capture", "full"),
         true <- capture == "full" or effect == "read",
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
         model_visible: model_visible,
         inspection_capture: inspection_capture(capture)
       }}
    else
      _reason -> {:error, :invalid_tool}
    end
  end

  def tool_effect("read"), do: :read
  def tool_effect("write"), do: :write

  def revision(value) do
    if is_binary(value) and value =~ @installation_revision,
      do: {:ok, value},
      else: {:error, :invalid_installation_revision}
  end

  def llm_ceilings(value, %Limits{} = limits) when is_map(value) do
    {:ok, row} = LimitCatalog.fetch(:llm_request_timeout_ms)
    host_ceiling = limits.llm_request_timeout_ms
    default_timeout_ms = min(row.compiled_default, host_ceiling)

    with :ok <-
           exact_keys(
             value,
             ~w(max_request_bytes max_response_bytes max_calls request_timeout_ms),
             []
           ),
         max_request_bytes
         when is_integer(max_request_bytes) and max_request_bytes in 1..@max_result_bytes <-
           Map.get(value, "max_request_bytes", 1_000_000),
         max_response_bytes
         when is_integer(max_response_bytes) and max_response_bytes in 1..@max_result_bytes <-
           Map.get(value, "max_response_bytes", 1_000_000),
         {:ok, max_calls} <- optional_max_calls(value),
         {:ok, request_timeout_ms} <-
           optional_request_timeout_ms(value, default_timeout_ms, host_ceiling, row) do
      {:ok,
       %{
         max_request_bytes: max_request_bytes,
         max_response_bytes: max_response_bytes,
         max_calls: max_calls,
         request_timeout_ms: request_timeout_ms
       }}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  def llm_ceilings(_value, _limits), do: {:error, :invalid_ceilings}

  def optional_request_timeout_ms(value, default_timeout_ms, host_ceiling, row) do
    case Map.get(value, "request_timeout_ms", default_timeout_ms) do
      request_timeout_ms
      when is_integer(request_timeout_ms) and request_timeout_ms >= row.minimum and
             request_timeout_ms <= host_ceiling ->
        {:ok, request_timeout_ms}

      _invalid ->
        :error
    end
  end

  # A ceiling above the per-name installed ceiling can never bind, because the
  # alias cap applies only when stricter than the run's per-name quota. Refuse
  # the unreachable value at load instead of installing a silent no-op.
  def optional_max_calls(value) do
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
  def data_class("normal"), do: {:ok, :normal}
  def data_class("private_inspection"), do: {:ok, :private_inspection}
  def data_class(_value), do: {:error, :invalid_data_class}

  def error_feedback("closed"), do: :closed
  def error_feedback("bounded"), do: :bounded

  def inspection_capture("full"), do: :full
  def inspection_capture("digest_results"), do: :digest_results

  def accepts_data_class("normal"), do: :normal
  def accepts_data_class("private_inspection"), do: :private_inspection

  def accepts_data(value) when is_list(value) and length(value) in 1..2 do
    with true <- value == Enum.uniq(value),
         true <- Enum.all?(value, &(&1 in ["normal", "private_inspection"])) do
      {:ok, Enum.map(value, &accepts_data_class/1)}
    else
      _reason -> {:error, :invalid_accepts_data}
    end
  end

  def accepts_data(_value), do: {:error, :invalid_accepts_data}

  def optional_description(nil), do: {:ok, nil}

  def optional_description(value) do
    if valid_string?(value, 4_096),
      do: {:ok, value},
      else: {:error, :invalid_description}
  end

  def reduce_named_map(value, decoder), do: reduce_named_entries(value, decoder)

  def reduce_sorted_named_map(value, decoder) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> reduce_named_entries(decoder)
  end

  def reduce_named_entries(entries, decoder) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {name, item}, {:ok, normalized} ->
      case decoder.(name, item) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(normalized, name, decoded)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def valid_name?(name), do: is_binary(name) and name =~ @name

  def valid_string?(value, max_bytes),
    do:
      is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
        not String.contains?(value, <<0>>)

  def valid_path_string?(value), do: valid_string?(value, 4_096)

  def valid_absolute_path?(value),
    do: valid_path_string?(value) and Path.type(value) == :absolute

  def exact_keys(value, allowed, required) when is_map(value) do
    keys = Map.keys(value)
    if keys -- allowed == [] and required -- keys == [], do: :ok, else: {:error, :invalid_keys}
  end

  def exact_keys(_value, _allowed, _required), do: {:error, :invalid_keys}

  def endpoint_rejection(%{
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

  def endpoint_rejection(%{"source" => "decision", "backend" => "http"} = value) do
    auth = if Map.has_key?(value, "credential"), do: [value["credential"]], else: []

    installed_endpoint(
      value["endpoint"],
      Map.get(value, "allow_insecure_loopback", false),
      auth,
      nil
    )
  end

  def endpoint_rejection(_installation), do: :ok
end
