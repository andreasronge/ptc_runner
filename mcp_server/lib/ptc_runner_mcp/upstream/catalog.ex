defmodule PtcRunnerMcp.Upstream.Catalog do
  @moduledoc """
  Renders the inline upstream catalog injected into the
  `ptc_lisp_execute` tool description in aggregator mode.

  Per `Plans/ptc-runner-mcp-aggregator.md` §12.5 the catalog is one
  block per configured upstream, listing each tool's name, args, and
  truncated description in the shape:

      <upstream-name>:
        <tool>(<arg>: <type>, <arg>: <type>?) - <description>

  Optional fields (those NOT in the JSON Schema's `required` array)
  are marked with a trailing `?`. Complex JSON Schema types (object,
  array) are rendered as their bare type name — the LLM sees
  `object` / `array` rather than the full schema. Descriptions are
  hard-truncated at 80 characters with an ellipsis suffix. The
  truncation rule is "ellipsis", not "ellipsis-on-word-boundary",
  because the catalog is read by an LLM, not a human, and a
  predictable cap matters more than aesthetics.

  An upstream whose Connection is not yet `:started` (the eager-fetch
  at boot in §12.5.1 failed for it) renders as a placeholder:

      <name>:
        (unavailable at startup)

  This is the catalog's view of "I have nothing useful to say about
  this upstream" — it's the same shape as a `tools/list` cache miss,
  not an attempt to encode the failure reason. The upstream will be
  re-attempted on first `(tool/mcp-call ...)` invocation per §4.3.

  Empty input — no upstreams configured at all — renders as the
  empty string. `Tools.advertised_description/2` already degrades
  to the no-catalog shape when given an empty string, so the
  description-builder seam stays simple.

  ## Freeze-at-boot (§12.5 explicit)

  > "The catalog is generated at startup from each upstream's
  > `tools/list` response (cached per §6.3) and **rebuilt only on
  > PtcRunner restart**."

  The string returned by `render/1` MUST NOT be recomputed on every
  `tools/list` request. Live recomputation produces non-deterministic
  catalog text:

    * an upstream that crashes post-boot would flip its block to
      `(unavailable at startup)` even though the LLM was previously
      told its tools exist,
    * an upstream that failed at boot but later succeeds would
      retroactively gain a catalog block.

  Both violate the spec's "rebuilt only on PtcRunner restart"
  contract. To satisfy it:

    * `Upstream.Supervisor.start_link/1` calls `render/1` once,
      after `eager_start_upstreams/1` returns, and stores the
      result via `freeze/1` into `:persistent_term`.
    * `Tools.tool_entry/0` reads the frozen string via `frozen/0`.
    * Restarts of the MCP server (a fresh BEAM VM) start with an
      empty `:persistent_term` and re-freeze; this is the only way
      to refresh the catalog.

  `:persistent_term` is the right primitive: writes are expensive
  but happen exactly once; reads are O(1) and lock-free, which
  matters because every `tools/list` request reads the catalog.
  """

  alias PtcRunnerMcp.Upstream
  alias PtcRunnerMcp.Upstream.Connection

  @description_limit 80
  @ellipsis "..."
  @persistent_term_key {__MODULE__, :frozen}
  @persistent_snapshot_key {__MODULE__, :frozen_snapshot}

  # §9.1 (http-transport-credentials.md): the per-server header gains
  # an optional `[transport: stdio|http]` tag so the LLM can see at a
  # glance whether an upstream is local-only or has a network
  # dependency. The tag is derived from the upstream's `:impl` module
  # (read off the routing entry — we deliberately do NOT add a new
  # `transport:` field to the upstream entry struct).
  #
  # Only the two real transports get an annotation. `Fake` (in-process,
  # used in tests) and any unknown impl render WITHOUT a tag — this is
  # the conservative choice that keeps existing Fake-driven catalog
  # tests byte-equal to their pre-§9.1 expectations, and avoids
  # advertising a "fake" transport to a real LLM if a misconfigured
  # production deploy somehow ended up wired to `Fake`.
  @transport_tags %{
    PtcRunnerMcp.Upstream.Stdio => "stdio",
    PtcRunnerMcp.Upstream.Http => "http"
  }

  @doc """
  Renders the catalog for the routing `Registry` named `registry`.

  Walks each configured upstream in the order the Registry
  enumerates them, fetches the per-Connection `cached_tools/1`
  snapshot, and produces the §12.5 block format. Returns an empty
  string when no upstreams are configured.

  This function is intentionally tolerant of partially-failed boot:
  upstreams whose eager-start failed (no cached tools yet) render
  as the "(unavailable at startup)" placeholder. The catalog is a
  description, not a health check.
  """
  @spec render(atom() | pid()) :: String.t()
  def render(registry) when is_atom(registry) or is_pid(registry) do
    case snapshot(registry) do
      [] -> ""
      entries -> Enum.map_join(entries, "\n\n", &render_upstream/1)
    end
  end

  @doc """
  Returns the structured catalog snapshot for a routing `Registry`.

  The shape is the same input accepted by `render_entries/1`:
  `%{name: String.t(), tools: list() | nil, impl: module() | nil}`.
  `ptc_task` capability summaries use this structured snapshot instead of
  parsing the human-oriented rendered catalog string.
  """
  @spec snapshot(atom() | pid()) :: [
          %{
            required(:name) => String.t(),
            required(:tools) => [Upstream.tool_schema()] | nil,
            optional(:impl) => module() | nil
          }
        ]
  def snapshot(registry) when is_atom(registry) or is_pid(registry) do
    configured_entries(registry)
  end

  @doc """
  Renders the catalog from an explicit list of upstream snapshots.

  Each entry is
  `%{name: String.t(), tools: [Upstream.tool_schema()] | nil, impl: module() | nil}`.
  The `:impl` key is optional — when absent or `nil` the per-server
  header has no `[transport: …]` annotation. When present and the
  module is one of the recognised transports (`Upstream.Stdio` /
  `Upstream.Http`), the header gains a `[transport: stdio|http]` tag
  per §9.1.

  Used directly by tests to exercise the rendering rules without
  spinning up a Registry. `nil` for `:tools` means "no cached tools
  yet" and emits the unavailable-at-startup placeholder.
  """
  @spec render_entries([
          %{
            required(:name) => String.t(),
            required(:tools) => [Upstream.tool_schema()] | nil,
            optional(:impl) => module() | nil
          }
        ]) :: String.t()
  def render_entries([]), do: ""

  def render_entries(entries) when is_list(entries) do
    Enum.map_join(entries, "\n\n", &render_upstream/1)
  end

  # ----------------------------------------------------------------
  # Freeze-at-boot persistent_term seam (§12.5 "rebuilt only on
  # PtcRunner restart")
  # ----------------------------------------------------------------

  @doc """
  Returns the frozen-at-boot catalog string, or `""` if no catalog
  has been frozen (non-aggregator mode, or a boot path that did
  not call `freeze/1`).

  This is the function `Tools.tool_entry/0` reads on every
  `tools/list` request — `:persistent_term.get/2` is O(1) and
  lock-free, so the request path stays cheap.
  """
  @spec frozen() :: String.t()
  def frozen do
    :persistent_term.get(@persistent_term_key, "")
  end

  @doc """
  Returns the frozen structured catalog snapshot, or `[]` if none is frozen.
  """
  @spec frozen_snapshot() :: [
          %{
            required(:name) => String.t(),
            required(:tools) => [Upstream.tool_schema()] | nil,
            optional(:impl) => module() | nil
          }
        ]
  def frozen_snapshot do
    :persistent_term.get(@persistent_snapshot_key, [])
  end

  @doc """
  Stores `catalog` (a pre-rendered string) into `:persistent_term`
  so subsequent `frozen/0` reads return it.

  Called exactly once by `Upstream.Supervisor.start_link/1` after
  `eager_start_upstreams/1` completes.
  """
  @spec freeze(String.t()) :: :ok
  def freeze(catalog) when is_binary(catalog) do
    :persistent_term.put(@persistent_term_key, catalog)
  end

  @doc """
  Stores the structured catalog snapshot into `:persistent_term`.

  This is a sibling contract to `freeze/1`; Phase 0 keeps it separate so
  existing boot paths that only freeze the rendered catalog remain unchanged.
  """
  @spec freeze_snapshot(list()) :: :ok
  def freeze_snapshot(entries) when is_list(entries) do
    :persistent_term.put(@persistent_snapshot_key, entries)
  end

  @doc """
  Removes any frozen catalog from `:persistent_term`. Test-only
  cleanup hook — production never needs this because the
  MCP-server lifetime is the BEAM VM lifetime, and a fresh VM
  starts with an empty `:persistent_term`.
  """
  @spec clear_frozen() :: :ok
  def clear_frozen do
    _ = :persistent_term.erase(@persistent_term_key)
    _ = :persistent_term.erase(@persistent_snapshot_key)
    :ok
  end

  # ----------------------------------------------------------------
  # Private helpers
  # ----------------------------------------------------------------

  defp configured_entries(registry) do
    routings =
      try do
        GenServer.call(registry, :all_routings)
      catch
        :exit, _ -> %{}
      end

    routings
    |> Enum.map(fn {name, %{routing_id: routing_id} = routing} ->
      tools =
        case Connection.whereis(routing_id, name) do
          nil -> nil
          pid -> safe_cached_tools(pid)
        end

      %{name: name, tools: tools, impl: Map.get(routing, :impl)}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp safe_cached_tools(pid) do
    Connection.cached_tools(pid)
  catch
    :exit, _ -> nil
  end

  defp render_upstream(%{name: name, tools: nil} = entry) do
    "#{header(name, entry)}\n  (unavailable at startup)"
  end

  defp render_upstream(%{name: name, tools: []} = entry) do
    "#{header(name, entry)}\n  (no tools advertised)"
  end

  defp render_upstream(%{name: name, tools: tools} = entry) when is_list(tools) do
    rendered_tools = Enum.map_join(tools, "\n", &render_tool/1)
    "#{header(name, entry)}\n#{rendered_tools}"
  end

  # Per-server header: `name:` for unknown / Fake / missing impl
  # (preserves byte-for-byte the pre-§9.1 catalog shape that existing
  # tests pin), and `name [transport: stdio|http]:` when the impl is
  # one of the two real transports.
  defp header(name, entry) do
    case transport_tag(Map.get(entry, :impl)) do
      nil -> "#{name}:"
      tag -> "#{name} [transport: #{tag}]:"
    end
  end

  defp transport_tag(nil), do: nil
  defp transport_tag(impl) when is_atom(impl), do: Map.get(@transport_tags, impl)
  defp transport_tag(_), do: nil

  defp render_tool(tool) do
    name = tool_field(tool, :name)
    schema = tool_field(tool, :input_schema, %{})
    output_schema = tool_field(tool, :output_schema, nil)
    description = tool_field(tool, :description, "")

    args = render_args(schema)
    output_part = render_output(output_schema)
    desc_part = render_description(description)

    "  #{name}(#{args})#{output_part}#{desc_part}"
  end

  defp render_output(schema) when is_map(schema) do
    case render_signature_type(schema) do
      "" -> ""
      type -> " -> #{type}"
    end
  end

  defp render_output(_), do: ""

  # Argument ordering rule: required args first in the order they
  # appear in the schema's `required` array, then optional args
  # alphabetically. This is deterministic across Jason-decoded maps
  # (which don't preserve `properties` insertion order beyond small
  # sizes), matches the §12.5 example for required-leading cases,
  # and keeps catalog output reproducible run-to-run.
  defp render_args(schema) when is_map(schema) do
    properties = Map.get(schema, "properties") || Map.get(schema, :properties) || %{}
    required = Map.get(schema, "required") || Map.get(schema, :required) || []

    properties_by_string =
      Map.new(properties, fn {k, v} -> {to_string(k), v} end)

    required_strs =
      Enum.map(required, &to_string/1)
      |> Enum.filter(&Map.has_key?(properties_by_string, &1))

    required_set = MapSet.new(required_strs)

    optional_strs =
      properties_by_string
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(required_set, &1))
      |> Enum.sort()

    ordered = required_strs ++ optional_strs

    Enum.map_join(ordered, ", ", fn name_str ->
      arg_schema = Map.fetch!(properties_by_string, name_str)
      type_str = render_type(arg_schema)
      optional? = not MapSet.member?(required_set, name_str)
      "#{name_str}: #{type_str}#{if optional?, do: "?", else: ""}"
    end)
  end

  defp render_args(_), do: ""

  # JSON Schema → terse type label. Complex types collapse to their
  # bare type name (the §12.5 example shows `object` / `array` rather
  # than the full schema body). Unknown / missing types fall back to
  # `any` so the catalog never crashes on a malformed upstream.
  #
  # `enum` / `const` constraints take priority over the raw `type`
  # field: a schema like `{"type": "string", "enum": ["open","closed"]}`
  # renders as `enum<string>` (or just `enum` for heterogeneous
  # values), not `string`. The constraint is exactly the hint the
  # calling LLM needs to write a correct argument value, and dropping
  # it for the primitive type label loses information the catalog
  # exists to surface.
  defp render_type(schema) when is_map(schema) do
    # `fetch_field` distinguishes "key absent" from "key present with
    # a falsy value" — `{"const": false}`, `{"const": null}`,
    # `{"const": 0}`, `{"const": ""}` are all valid JSON Schema
    # const constraints that must render `const<...>` rather than
    # falling through to the primitive type. A truthy-binding cond
    # (e.g. `Map.get/2 |> truthy?`) would skip them all because
    # `false`/`nil`/`0`/`""` are all falsy in Elixir's `cond`.
    case fetch_field(schema, "const", :const) do
      {:ok, const_value} ->
        render_const(const_value)

      :error ->
        case enum_value(schema) do
          values when is_list(values) -> render_enum(values)
          nil -> render_primitive_type(schema)
        end
    end
  end

  defp render_type(_), do: "any"

  defp render_signature_type(schema) when is_map(schema) do
    case schema_variant_type(schema) do
      {:ok, type} -> type
      :error -> render_signature_primitive(schema)
    end
  end

  defp render_signature_type(_), do: ":any"

  defp schema_variant_type(schema) do
    schemas = get_field(schema, "oneOf", :oneOf) || get_field(schema, "anyOf", :anyOf)

    case schemas do
      list when is_list(list) and list != [] ->
        types =
          list
          |> Enum.map(&render_signature_type/1)
          |> Enum.uniq()

        case types do
          [type] -> {:ok, type}
          _ -> {:ok, ":any"}
        end

      _ ->
        :error
    end
  end

  defp render_signature_primitive(schema) do
    case get_field(schema, "type", :type) do
      "string" -> ":string"
      "integer" -> ":int"
      "number" -> ":float"
      "boolean" -> ":bool"
      "array" -> render_signature_array(schema)
      "object" -> render_signature_object(schema)
      _ -> ":any"
    end
  end

  defp render_signature_array(schema) do
    items = get_field(schema, "items", :items)
    "[#{render_signature_type(items || %{})}]"
  end

  defp render_signature_object(schema) do
    properties = get_field(schema, "properties", :properties)

    case properties do
      props when is_map(props) and map_size(props) > 0 ->
        required = signature_required_names(schema)

        fields =
          props
          |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
          |> Enum.take(5)
          |> Enum.map_join(", ", fn {key, value} ->
            key = to_string(key)
            optional = if key in required, do: "", else: "?"
            "#{key} #{render_signature_type(value)}#{optional}"
          end)

        "{#{fields}}"

      _ ->
        ":map"
    end
  end

  defp signature_required_names(schema) do
    case get_field(schema, "required", :required) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp enum_value(schema) do
    case get_field(schema, "enum", :enum) do
      list when is_list(list) and list != [] -> list
      _ -> nil
    end
  end

  defp render_primitive_type(schema) do
    case get_field(schema, "type", :type) do
      "string" -> "string"
      "integer" -> "integer"
      "number" -> "number"
      "boolean" -> "boolean"
      "object" -> "object"
      "array" -> "array"
      "null" -> "null"
      list when is_list(list) -> Enum.map_join(list, "|", &to_string/1)
      nil -> infer_type(schema)
      other -> to_string(other)
    end
  end

  defp get_field(schema, string_key, atom_key) do
    case Map.fetch(schema, string_key) do
      {:ok, v} -> v
      :error -> Map.get(schema, atom_key)
    end
  end

  # Like `get_field/3` but returns `{:ok, value} | :error`, so callers
  # can distinguish "key absent" from "key present with a falsy value"
  # — the case that breaks `{"const": false}` / `{"const": null}` /
  # `{"const": 0}` / `{"const": ""}` if you only check truthiness.
  defp fetch_field(schema, string_key, atom_key) do
    case Map.fetch(schema, string_key) do
      {:ok, _} = ok -> ok
      :error -> Map.fetch(schema, atom_key)
    end
  end

  # `const` collapses to `const<json-value>`. We use `Jason.encode/1`
  # so strings get their quotes (`const<"fixed">`), numbers stay
  # bare (`const<42>`), booleans stay bare (`const<true>`), and any
  # value the upstream actually used (e.g. arrays / objects) renders
  # in canonical JSON form. Encode failures fall back to "const" —
  # we never crash the catalog on a weird value.
  defp render_const(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> "const<#{encoded}>"
      {:error, _} -> "const"
    end
  end

  # `enum` collapses to `enum<type>` when every listed value is the
  # same primitive type, and bare `enum` otherwise. The subscript
  # case is the most useful one for the LLM — `{type: "string", enum:
  # [...]}` is by far the dominant real-world shape, and the
  # subscript tells the LLM both "constrained" and "this is a string
  # constraint." Heterogeneous enums (e.g. `["a", 1, true]`) cannot
  # be summarized in one label without lying about the shape, so we
  # render the bare keyword.
  defp render_enum([]), do: "enum"

  defp render_enum(values) when is_list(values) do
    case enum_primitive(values) do
      nil -> "enum"
      primitive -> "enum<#{primitive}>"
    end
  end

  defp render_enum(_), do: "enum"

  defp enum_primitive(values) do
    types = values |> Enum.map(&value_primitive/1) |> Enum.uniq()

    case types do
      [single] when is_binary(single) -> single
      _ -> nil
    end
  end

  defp value_primitive(v) when is_binary(v), do: "string"
  defp value_primitive(v) when is_integer(v), do: "integer"
  defp value_primitive(v) when is_float(v), do: "number"
  defp value_primitive(v) when is_boolean(v), do: "boolean"
  defp value_primitive(nil), do: "null"
  defp value_primitive(v) when is_list(v), do: "array"
  defp value_primitive(v) when is_map(v), do: "object"
  defp value_primitive(_), do: nil

  # When a schema declares no `type` field AND no `enum`/`const`
  # constraints, fall back to inferring from structural keys so the
  # catalog stays useful for upstreams whose schemas underspecify.
  # The alternative — always rendering "any" — confuses the LLM
  # about whether anything goes or only the constrained shape.
  defp infer_type(schema) do
    cond do
      Map.has_key?(schema, "properties") -> "object"
      Map.has_key?(schema, :properties) -> "object"
      Map.has_key?(schema, "items") -> "array"
      Map.has_key?(schema, :items) -> "array"
      true -> "any"
    end
  end

  defp render_description(""), do: ""
  defp render_description(nil), do: ""

  defp render_description(text) when is_binary(text) do
    # Collapse internal whitespace (including newlines) into a single
    # space so descriptions whose source format is multi-line markdown
    # render as a single line in the catalog. Hard-cap at the
    # character (codepoint) limit, with an explicit ellipsis suffix
    # when truncated. We count by codepoints rather than bytes so a
    # description with multi-byte characters truncates predictably.
    collapsed =
      text
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    case collapsed do
      "" ->
        ""

      bin ->
        truncated =
          if String.length(bin) > @description_limit do
            String.slice(bin, 0, @description_limit - String.length(@ellipsis)) <> @ellipsis
          else
            bin
          end

        " - #{truncated}"
    end
  end

  defp tool_field(tool, key, default \\ nil) do
    case tool do
      %{^key => v} -> v
      _ -> Map.get(tool, to_string(key), default)
    end
  end
end
