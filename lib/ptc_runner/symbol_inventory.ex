defmodule PtcRunner.SymbolInventory do
  @moduledoc """
  Sanitized model-visible symbol inventory projection.

  This module builds bounded facts for prompt rendering. It does not expose raw
  tool functions, host memory, prelude source, or private exports to renderers.
  """

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export
  alias PtcRunner.SubAgent.Namespace.SampleFormatter
  alias PtcRunner.SubAgent.Namespace.TypeVocabulary
  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.SubAgent.Signature.Renderer, as: SignatureRenderer
  alias PtcRunner.Tool

  @kernel_private_tools MapSet.new(["llm-complete", "eval-program", "log"])
  @secret_key_regex ~r/(^|[_-])(token|secret|password|api[_-]?key|access[_-]?key|credential|passwd)([_-]|$)/i
  @doc_limit 180

  @type kind :: :value | :function
  @type source :: :data | :tool | :prelude | :memory
  @type fact :: %{
          required(:ref) => String.t(),
          required(:kind) => kind(),
          required(:source) => source(),
          optional(:type) => String.t(),
          optional(:signature) => String.t(),
          optional(:params) => [String.t()],
          optional(:doc) => String.t(),
          optional(:sample) => String.t(),
          optional(:usage) => String.t(),
          optional(:effect) => atom()
        }

  @doc """
  Builds sanitized symbol facts from host-provided projections.

  Supported options:

    * `:data` - mission context map, rendered as `data/*` values.
    * `:tools` - mission/public tools, rendered as `tool/*` functions.
    * `:prelude` - compiled prelude; only `:prompt` exports are rendered.
    * `:memory_summary` - projected summary map with `entries`.
    * `:field_descriptions`, `:context_signature`, `:sample_limit`,
      `:sample_printable_limit` - formatting hints.
  """
  @spec project(keyword()) :: [fact()]
  def project(opts) when is_list(opts) do
    data = Keyword.get(opts, :data, %{}) || %{}
    tools = Keyword.get(opts, :tools, %{}) || %{}
    prelude = Keyword.get(opts, :prelude)
    memory_summary = Keyword.get(opts, :memory_summary)

    data_facts(data, opts) ++
      tool_facts(tools) ++
      prelude_facts(prelude, Keyword.get(opts, :export_mask)) ++
      memory_facts(memory_summary)
  end

  @doc """
  Renders projected facts with a validated renderer policy.

  Accepted renderer selectors are `:default`, `"default"`,
  `PtcRunner.SymbolInventory.DefaultRenderer`, `:reference`, `"reference"`, and
  `PtcRunner.SymbolInventory.ReferenceRenderer`.
  """
  @spec render([map()], term(), keyword()) :: {:ok, String.t() | nil, map()} | {:error, map()}
  def render(facts, renderer \\ :default, opts \\ []) when is_list(facts) do
    with {:ok, module} <- renderer_module(renderer) do
      {text, meta} = module.render(facts, opts)
      {:ok, text, meta}
    end
  end

  @doc "Resolves a renderer selector, failing closed for unknown policies."
  @spec renderer_module(term()) :: {:ok, module()} | {:error, map()}
  def renderer_module(renderer) when renderer in [nil, :default, "default", "default_v1"],
    do: {:ok, PtcRunner.SymbolInventory.DefaultRenderer}

  def renderer_module(renderer) when renderer in [:reference, "reference", "reference_v1"],
    do: {:ok, PtcRunner.SymbolInventory.ReferenceRenderer}

  def renderer_module(module)
      when module in [
             PtcRunner.SymbolInventory.DefaultRenderer,
             PtcRunner.SymbolInventory.ReferenceRenderer
           ],
      do: {:ok, module}

  def renderer_module(renderer) do
    {:error,
     %{
       reason: "invalid_symbol_inventory_renderer",
       message: "unknown symbol inventory renderer",
       renderer: inspect(renderer, limit: 5, printable_limit: 100)
     }}
  end

  @doc "Returns whether a data key is secret-like and should suppress samples."
  @spec secret_key?(term()) :: boolean()
  def secret_key?(key), do: Regex.match?(@secret_key_regex, to_string(key))

  defp data_facts(data, opts) when is_map(data) do
    field_descriptions = Keyword.get(opts, :field_descriptions, %{}) || %{}
    param_types = extract_param_types(Keyword.get(opts, :context_signature))
    sample_opts = sample_opts(opts)

    data
    |> Enum.sort_by(fn {name, _value} -> to_string(name) end)
    |> Enum.map(fn {name, value} ->
      name_str = to_string(name)
      ref = "data/#{name_str}"

      %{
        ref: ref,
        kind: :value,
        source: :data,
        type: data_type(name_str, value, param_types),
        usage: ref
      }
      |> maybe_put(:sample, data_sample(name, value, sample_opts))
      |> maybe_put(:doc, compact_doc(field_description(name, field_descriptions)))
    end)
  end

  defp data_facts(_data, _opts), do: []

  defp tool_facts(tools) when is_map(tools) do
    tools
    |> Enum.map(fn {name, format} ->
      {to_string(name), normalize_tool(to_string(name), format)}
    end)
    |> Enum.reject(fn {name, tool} ->
      is_nil(tool) or Tool.private?(tool) or MapSet.member?(@kernel_private_tools, name)
    end)
    |> Enum.sort_by(fn {name, _tool} -> name end)
    |> Enum.map(fn {name, tool} ->
      params = tool_params(tool.signature)
      ref = "tool/#{name}"

      %{
        ref: ref,
        kind: :function,
        source: :tool,
        params: params,
        doc: compact_doc(tool.description),
        usage: tool_usage(ref, params)
      }
      |> maybe_put(:type, tool_return_type(tool.signature))
    end)
  end

  defp tool_facts(_tools), do: []

  defp prelude_facts(nil, _export_mask), do: []

  defp prelude_facts(%Prelude{} = prelude, export_mask) do
    prelude
    |> Prelude.prompt_exports()
    |> visible_exports(export_mask)
    |> Enum.sort_by(& &1.ref)
    |> Enum.map(&prelude_fact/1)
  end

  defp prelude_fact(%Export{} = export) do
    kind = if export.kind == :constant, do: :value, else: :function
    usage = if kind == :function, do: function_usage(export.ref, export.params), else: export.ref

    %{
      ref: export.ref,
      kind: kind,
      source: :prelude,
      namespace: export.namespace,
      params: if(kind == :function, do: export.params, else: []),
      doc: compact_doc(export.doc),
      usage: usage
    }
    |> maybe_put(:signature, export.signature)
    |> maybe_put(:type, export.type)
    |> maybe_put(:effect, export_effect(export.effect))
  end

  defp memory_facts(nil), do: []

  defp memory_facts(%{} = summary) do
    summary
    |> Map.get("entries", Map.get(summary, :entries, []))
    |> case do
      entries when is_list(entries) -> entries
      _ -> []
    end
    |> Enum.sort_by(&memory_entry_name/1)
    |> Enum.map(&memory_fact/1)
    |> Enum.reject(&is_nil/1)
  end

  defp memory_facts(_summary), do: []

  defp memory_fact(%{} = entry) do
    name = memory_entry_name(entry)
    kind = normalize_kind(Map.get(entry, "kind", Map.get(entry, :kind)))

    if name == "" or is_nil(kind) do
      nil
    else
      %{
        ref: name,
        kind: kind,
        source: :memory,
        usage: if(kind == :function, do: function_usage(name, []), else: name)
      }
      |> maybe_put(:sample, memory_sample(kind, entry))
    end
  end

  defp memory_fact(_entry), do: nil

  defp normalize_tool(name, %Tool{} = tool), do: %{tool | name: tool.name || name}

  defp normalize_tool(name, format) do
    case Tool.new(name, format) do
      {:ok, tool} -> tool
      {:error, _reason} -> nil
    end
  end

  defp data_sample(name, value, opts) do
    if secret_key?(name), do: nil, else: SampleFormatter.format(value, opts)
  end

  defp data_type(name, value, param_types) do
    case Map.get(param_types, name) do
      nil ->
        TypeVocabulary.type_of(value)

      type ->
        SignatureRenderer.render_type(type, key_style: :lisp_prompt) |> String.replace(":", "")
    end
  end

  defp extract_param_types({:signature, params, _return_type}) do
    params
    |> Enum.map(fn {name, type} -> {to_string(name), type} end)
    |> Map.new()
  end

  defp extract_param_types(_), do: %{}

  defp field_description(_key, descriptions) when descriptions in [nil, %{}], do: nil

  defp field_description(key, descriptions) do
    key_str = to_string(key)
    key_atom = if is_atom(key), do: key, else: String.to_existing_atom(key_str)
    Map.get(descriptions, key_atom) || Map.get(descriptions, key_str)
  rescue
    ArgumentError -> Map.get(descriptions, to_string(key))
  end

  defp tool_params(signature),
    do: signature |> parse_signature() |> elem(0) |> Enum.map(&param_name/1)

  defp tool_return_type(signature) do
    {_params, return_type} = parse_signature(signature)
    SignatureRenderer.render_type(return_type, key_style: :lisp_prompt) |> String.replace(":", "")
  end

  defp parse_signature(nil), do: {[], :any}

  defp parse_signature(signature) when is_binary(signature) do
    normalized =
      signature
      |> String.trim()
      |> then(fn sig -> if String.starts_with?(sig, "->"), do: "()" <> sig, else: sig end)

    case Signature.parse(normalized) do
      {:ok, {:signature, params, return_type}} -> {params, return_type}
      {:error, _reason} -> {[], :any}
    end
  end

  defp parse_signature(_), do: {[], :any}

  defp param_name({name, _type}), do: SignatureRenderer.to_lisp_key(name)

  defp function_usage(ref, []), do: "(#{ref})"
  defp function_usage(ref, params), do: "(#{ref} #{Enum.join(params, " ")})"

  defp tool_usage(ref, []), do: "(#{ref} {})"

  defp tool_usage(ref, params) do
    args =
      params
      |> Enum.map_join(" ", fn param -> ":#{param} #{param}" end)

    "(#{ref} {#{args}})"
  end

  defp visible_exports(exports, nil), do: exports

  defp visible_exports(exports, export_mask) when is_map(export_mask) do
    Enum.filter(exports, fn %Export{} = export ->
      case Map.fetch(export_mask, export.namespace) do
        {:ok, refs} -> masked_ref_member?(refs, export.ref)
        :error -> true
      end
    end)
  end

  defp visible_exports(exports, _export_mask), do: exports

  defp masked_ref_member?(%MapSet{} = refs, ref), do: MapSet.member?(refs, ref)
  defp masked_ref_member?(refs, ref) when is_list(refs), do: ref in refs
  defp masked_ref_member?(_refs, _ref), do: true

  defp memory_entry_name(entry) do
    entry
    |> Map.get("name", Map.get(entry, :name, ""))
    |> to_string()
  end

  defp normalize_kind(:value), do: :value
  defp normalize_kind(:function), do: :function
  defp normalize_kind("value"), do: :value
  defp normalize_kind("function"), do: :function
  defp normalize_kind(_), do: nil

  defp memory_sample(:function, _entry), do: nil

  defp memory_sample(:value, entry) do
    Map.get(entry, "preview", Map.get(entry, :preview))
  end

  defp sample_opts(opts) do
    [
      sample_limit: Keyword.get(opts, :sample_limit, 3),
      sample_printable_limit: Keyword.get(opts, :sample_printable_limit, 80)
    ]
  end

  defp export_effect(:unknown), do: nil
  defp export_effect(effect), do: effect

  defp compact_doc(nil), do: nil

  defp compact_doc(text) when is_binary(text) do
    text
    |> String.split()
    |> Enum.join(" ")
    |> String.slice(0, @doc_limit)
  end

  defp compact_doc(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, :sample, :include), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
