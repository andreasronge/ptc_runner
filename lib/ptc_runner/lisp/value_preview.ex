defmodule PtcRunner.Lisp.ValuePreview do
  @moduledoc """
  Heap-proportional structural previews for human and model observations.

  Unlike `PtcRunner.Lisp.Format`, this module is deliberately bounded. Its
  default pass samples collections and preserves sibling shape while enforcing
  depth, node, string, character, and UTF-8 byte ceilings. When the shape pass
  reports truncation from implicit ceilings, one bounded greedy pass may lift
  node and string ceilings to the output budget and item and depth ceilings to
  larger internal traversal bounds. It replaces the preview with an exact
  rendering only if every part fits those bounds. Otherwise the original
  shape-preserving preview wins.

  In the shape pass, map keys are exempt from the per-entry character share: a
  key renders against the whole key ceiling at every nesting depth, and only the
  remainder is charged to its value. That ceiling is 67 rendered characters,
  which holds 64 plain ones plus the delimiters and an elision mark, and fewer
  where escaping expands them. A truncated value stays identifiable from what
  survives while a truncated key does not, so a map that cannot fit shows fewer
  entries with intact names rather than every name abbreviated, and a key too
  long for the ceiling keeps an elided prefix rather than an opaque marker. The
  exact pass has no key ceiling, because it renders only when the complete value
  fits the output budget.

  Neither pass recursively sanitizes a complete value or materializes a
  complete collection before applying the traversal ceilings.

  Preview results are presentation metadata only. Callers must never turn a
  preview failure into an evaluation failure or use a preview as the retained
  continuation value.
  """

  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.ExternalizedCollision
  alias PtcRunner.Lisp.Format.Builtin, as: DisplayBuiltin
  alias PtcRunner.Lisp.Format.Fn, as: DisplayFn
  alias PtcRunner.Lisp.Format.JavaDisplay
  alias PtcRunner.Lisp.Format.RegexLiteral
  alias PtcRunner.Lisp.Format.SymbolRef
  alias PtcRunner.Lisp.Format.Var
  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Java.Primitive, as: JavaPrimitive
  alias PtcRunner.Lisp.Java.Surface, as: JavaSurface
  alias PtcRunner.Lisp.Java.Time.Duration, as: JavaDuration
  alias PtcRunner.Lisp.Java.Time.Instant, as: JavaInstant
  alias PtcRunner.Lisp.Java.Time.LocalDate, as: JavaLocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.RuntimeCallable
  alias PtcRunner.Lisp.TypeVocabulary
  alias PtcRunner.Lisp.ValuePreview.Result

  @default_max_chars 2_048
  @default_max_items 16
  @default_max_depth 4
  @default_max_nodes 256
  @default_max_string_chars 256
  @max_complete_items 256
  @max_complete_depth 256
  @sampled_key_limit 24
  @sort_key_chars 64
  # The sort-key ceiling plus the surrounding quotes and the truncation ellipsis,
  # which `render_string/5` reserves out of the budget it is handed.
  @key_chars @sort_key_chars + 3
  # Enough for a short scalar or an elision marker, so an entry with a long key
  # still renders a value instead of collapsing the map to its marker.
  @min_value_chars 8
  @large_integer Integer.pow(10, 100)

  @type option ::
          {:max_chars, pos_integer()}
          | {:max_bytes, pos_integer()}
          | {:max_items, pos_integer()}
          | {:max_depth, non_neg_integer()}
          | {:max_nodes, pos_integer()}
          | {:max_string_chars, pos_integer()}

  @spec render(term(), [option()]) :: Result.t()
  def render(value, opts \\ []) when is_list(opts) do
    shape_policy = policy(opts, :shape)
    sampled_keys = sampled_keys(value, shape_policy)

    value
    |> render_once(shape_policy, sampled_keys)
    |> maybe_render_complete(value, opts, shape_policy, sampled_keys)
  rescue
    _error ->
      unavailable()
  end

  @doc false
  @spec scalar_text(term()) :: {:ok, String.t()} | :error
  def scalar_text(nil), do: {:ok, "nil"}
  def scalar_text(true), do: {:ok, "true"}
  def scalar_text(false), do: {:ok, "false"}

  def scalar_text(value)
      when is_integer(value) and value <= @large_integer and value >= -@large_integer,
      do: {:ok, Integer.to_string(value)}

  def scalar_text(value) when is_integer(value), do: {:ok, "#<large-integer>"}
  def scalar_text(:infinity), do: {:ok, "##Inf"}
  def scalar_text(:negative_infinity), do: {:ok, "##-Inf"}
  def scalar_text(:nan), do: {:ok, "##NaN"}

  def scalar_text(value) when is_float(value),
    do: {:ok, :erlang.float_to_binary(value, [:compact, decimals: 10])}

  def scalar_text(value) when is_atom(value), do: {:ok, ":" <> Atom.to_string(value)}
  def scalar_text(_value), do: :error

  @doc "Renders a preview with a bounded visible truncation notice."
  @spec render_with_notice(term(), [option()]) :: Result.t()
  def render_with_notice(value, opts \\ []) when is_list(opts) do
    policy = policy(opts, :shape)
    initial = render(value, opts)

    if initial.truncated? do
      notice = notice(initial)
      separator = " "
      notice_chars = String.length(separator <> notice)
      notice_bytes = byte_size(separator <> notice)

      if notice_chars < policy.max_chars and notice_bytes < policy.max_bytes do
        bounded_policy =
          opts
          |> Keyword.put(:max_chars, policy.max_chars - notice_chars)
          |> Keyword.put(:max_bytes, policy.max_bytes - notice_bytes)
          |> policy(:shape)

        bounded = safe_render_once(value, bounded_policy, initial.sampled_keys)

        %{bounded | text: bounded.text <> separator <> notice, truncated?: true}
      else
        %{initial | text: bounded_notice(notice, policy.max_chars, policy.max_bytes)}
      end
    else
      initial
    end
  end

  @doc false
  @spec notice(Result.t()) :: String.t()
  def notice(%Result{} = result) do
    caps = result.caps_hit |> Enum.map_join(",", &Atom.to_string/1)

    sampled =
      case Enum.take(result.sampled_keys, 6) do
        [] -> ""
        keys -> "; sampled keys: " <> (keys |> Enum.join(",") |> escape_untrusted())
      end

    "#<preview truncated: #{caps}#{sampled}>"
  end

  @doc false
  @spec fallback(atom()) :: Result.t()
  def fallback(reason) when reason in [:heap_exceeded, :timeout, :worker_failed, :cancelled] do
    %Result{
      text: "#<preview unavailable: #{reason}>",
      truncated?: true,
      caps_hit: [:output],
      sampled_keys: []
    }
  end

  defp policy(opts, allocation_mode) when allocation_mode in [:shape, :complete] do
    max_chars = positive(opts[:max_chars], @default_max_chars)

    %{
      allocation_mode: allocation_mode,
      max_chars: max_chars,
      max_bytes: positive(opts[:max_bytes], max(max_chars * 4, max_chars)),
      max_items: positive(opts[:max_items], @default_max_items),
      max_depth: non_negative(opts[:max_depth], @default_max_depth),
      max_nodes: positive(opts[:max_nodes], @default_max_nodes),
      max_string_chars: positive(opts[:max_string_chars], @default_max_string_chars)
    }
  end

  defp render_once(value, policy, sampled_keys) do
    {text, truncated?, caps, _nodes_left} =
      render_value(value, 0, policy.max_chars, policy.max_bytes, policy.max_nodes, policy)

    caps_hit = caps |> MapSet.to_list() |> Enum.sort()

    %Result{
      text: text,
      truncated?: truncated? or caps_hit != [],
      caps_hit: caps_hit,
      sampled_keys: sampled_keys
    }
  end

  defp safe_render_once(value, policy, sampled_keys) do
    render_once(value, policy, sampled_keys)
  rescue
    _error -> unavailable()
  end

  defp maybe_render_complete(shape, value, opts, shape_policy, sampled_keys) do
    if shape.truncated? and retryable_caps?(shape.caps_hit, opts) do
      complete_policy =
        shape_policy
        |> Map.put(:allocation_mode, :complete)
        |> lift_implicit_cap(opts, :max_items)
        |> lift_implicit_cap(opts, :max_depth)
        |> lift_implicit_cap(opts, :max_nodes)
        |> lift_implicit_cap(opts, :max_string_chars)

      case render_once(value, complete_policy, sampled_keys) do
        %Result{truncated?: false, caps_hit: []} = complete -> complete
        _incomplete -> shape
      end
    else
      shape
    end
  rescue
    _error -> shape
  end

  defp lift_implicit_cap(policy, opts, cap) do
    if Keyword.has_key?(opts, cap),
      do: policy,
      else: Map.put(policy, cap, implicit_complete_cap(cap, policy.max_chars))
  end

  defp retryable_caps?(caps, opts) do
    Enum.all?(caps, fn
      :items -> not Keyword.has_key?(opts, :max_items)
      :depth -> not Keyword.has_key?(opts, :max_depth)
      :nodes -> not Keyword.has_key?(opts, :max_nodes)
      :string -> not Keyword.has_key?(opts, :max_string_chars)
      :output -> true
    end)
  end

  defp implicit_complete_cap(:max_items, max_chars), do: min(max_chars, @max_complete_items)
  defp implicit_complete_cap(:max_depth, max_chars), do: min(max_chars, @max_complete_depth)
  defp implicit_complete_cap(_cap, max_chars), do: max_chars

  defp unavailable do
    %Result{
      text: "#<preview unavailable>",
      truncated?: true,
      caps_hit: [:output],
      sampled_keys: []
    }
  end

  defp bounded_notice(notice, max_chars, max_bytes) do
    {graphemes, _more?} = take_grapheme_list(notice, max_chars)

    graphemes
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, bytes} ->
      next = bytes + byte_size(grapheme)
      if next <= max_bytes, do: {:cont, {[grapheme | acc], next}}, else: {:halt, {acc, bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value, default), do: default

  defp render_value(_value, _depth, chars, bytes, nodes, _policy)
       when chars <= 0 or bytes <= 0 or nodes <= 0,
       do: {"", true, MapSet.new([if(nodes <= 0, do: :nodes, else: :output)]), max(nodes, 0)}

  # This is intentionally one ordered type dispatcher: clause priority is part
  # of the preview contract (for example booleans before atoms and Java values
  # before generic structs), so splitting it would obscure that precedence.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp render_value(value, depth, chars, bytes, nodes, policy) do
    nodes = nodes - 1

    cond do
      is_nil(value) ->
        leaf("nil", chars, bytes, nodes)

      value === true ->
        leaf("true", chars, bytes, nodes)

      value === false ->
        leaf("false", chars, bytes, nodes)

      is_integer(value) ->
        render_integer(value, chars, bytes, nodes)

      value === :infinity ->
        leaf("##Inf", chars, bytes, nodes)

      value === :negative_infinity ->
        leaf("##-Inf", chars, bytes, nodes)

      value === :nan ->
        leaf("##NaN", chars, bytes, nodes)

      is_float(value) ->
        leaf(:erlang.float_to_binary(value, [:compact, decimals: 10]), chars, bytes, nodes)

      is_binary(value) ->
        render_string(value, chars, bytes, nodes, policy)

      match?(%LispKeyword{}, value) ->
        render_keyword(value, chars, bytes, nodes, policy)

      match?(%ExternalizedCollision{}, value) ->
        render_value(value.value, depth, chars, bytes, nodes + 1, policy)

      match?(%DisplayFn{}, value) ->
        render_bounded_label("#fn[", value.params, "]", chars, bytes, nodes, policy)

      match?(%DisplayBuiltin{}, value) ->
        leaf("#<builtin>", chars, bytes, nodes)

      match?(%Var{}, value) ->
        render_bounded_label("#'", value.name, "", chars, bytes, nodes, policy)

      match?(%SymbolRef{}, value) ->
        render_bounded_label("'", value.name, "", chars, bytes, nodes, policy)

      match?(%RegexLiteral{}, value) ->
        render_regex(value.source, chars, bytes, nodes, policy)

      match?(%JavaDisplay{}, value) ->
        render_bounded_label("", value.label, "", chars, bytes, nodes, policy)

      match?(%JavaCallable{}, value) ->
        render_java_callable(value, chars, bytes, nodes, policy)

      match?(%JavaPrimitive{}, value) ->
        render_java_primitive(value, chars, bytes, nodes, policy)

      match?(%JavaLocalDate{}, value) ->
        render_java_object(
          value,
          JavaLocalDate,
          "java.time.LocalDate",
          chars,
          bytes,
          nodes,
          policy
        )

      match?(%JavaInstant{}, value) ->
        render_java_object(
          value,
          JavaInstant,
          "java.time.Instant",
          chars,
          bytes,
          nodes,
          policy
        )

      match?(%JavaDuration{}, value) ->
        render_java_object(
          value,
          JavaDuration,
          "java.time.Duration",
          chars,
          bytes,
          nodes,
          policy
        )

      match?(%JavaDate{}, value) ->
        render_java_object(
          value,
          JavaDate,
          "java.util.Date",
          chars,
          bytes,
          nodes,
          policy
        )

      match?(%Date{}, value) ->
        render_iso8601(Date.to_iso8601(value), chars, bytes, nodes, policy)

      match?(%DateTime{}, value) ->
        render_iso8601(DateTime.to_iso8601(value), chars, bytes, nodes, policy)

      match?(%NaiveDateTime{}, value) ->
        render_iso8601(NaiveDateTime.to_iso8601(value), chars, bytes, nodes, policy)

      match?(%Time{}, value) ->
        render_iso8601(Time.to_iso8601(value), chars, bytes, nodes, policy)

      is_atom(value) ->
        leaf(":" <> Atom.to_string(value), chars, bytes, nodes)

      is_function(value) ->
        leaf("#<fn>", chars, bytes, nodes)

      match?(%Builtin{}, value) ->
        leaf("#<builtin>", chars, bytes, nodes)

      match?(%RuntimeCallable{}, value) ->
        leaf("#fn[...]", chars, bytes, nodes)

      builtin_binding?(value) ->
        leaf("#<builtin>", chars, bytes, nodes)

      opaque_callable?(value) ->
        leaf("#fn[...]", chars, bytes, nodes)

      match?({:var, _name}, value) ->
        render_var_tuple(value, chars, bytes, nodes, policy)

      match?({:symbol_ref, _name}, value) ->
        render_symbol_tuple(value, chars, bytes, nodes, policy)

      match?({:re_mp, _compiled, _anchored, _source}, value) ->
        render_regex_tuple(value, chars, bytes, nodes, policy)

      closure?(value) ->
        leaf(closure_label(value), chars, bytes, nodes)

      depth >= policy.max_depth and container?(value) ->
        depth_marker(value, chars, bytes, nodes)

      is_list(value) ->
        render_list(value, depth, chars, bytes, nodes, policy)

      match?(%MapSet{}, value) ->
        render_set(value, depth, chars, bytes, nodes, policy)

      is_map(value) and not is_struct(value) ->
        render_map(value, depth, chars, bytes, nodes, policy)

      is_tuple(value) ->
        render_tuple(value, depth, chars, bytes, nodes, policy)

      is_struct(value) ->
        render_struct(value, chars, bytes, nodes)

      true ->
        leaf("#<unrenderable>", chars, bytes, nodes)
    end
  end

  defp render_integer(value, chars, bytes, nodes)
       when value > @large_integer or value < -@large_integer,
       do: leaf("#<large-integer>", chars, bytes, nodes, :string)

  defp render_integer(value, chars, bytes, nodes),
    do: leaf(Integer.to_string(value), chars, bytes, nodes)

  defp render_keyword(%LispKeyword{name: name}, chars, bytes, nodes, policy) do
    render_bounded_label(":", name, "", chars, bytes, nodes, policy)
  end

  defp render_string(value, chars, bytes, nodes, policy) do
    limit =
      case policy.allocation_mode do
        :shape -> min(policy.max_string_chars, max(chars - 3, 0))
        :complete -> min(policy.max_string_chars, max(chars, 0))
      end

    {graphemes, more?} = take_grapheme_list(value, limit)
    fit_quoted(graphemes, more?, chars, bytes, nodes)
  end

  defp render_iso8601(value, chars, bytes, nodes, policy),
    do: render_string(value, chars, bytes, nodes, policy)

  defp render_regex(source, chars, bytes, nodes, policy) do
    {graphemes, more?} = take_grapheme_list(source, policy.max_string_chars)
    fit_regex(graphemes, more?, chars, bytes, nodes)
  end

  defp fit_regex(graphemes, more?, chars, bytes, nodes) do
    chunks = graphemes |> IO.iodata_to_binary() |> escape_untrusted() |> grapheme_chunks()

    case fit_delimited_chunks(chunks, more?, "#\"", "\"", chars, bytes) do
      {:ok, text, truncated?} ->
        caps = if(truncated?, do: MapSet.new([:string]), else: MapSet.new())
        {text, truncated?, caps, nodes}

      :error ->
        leaf("#<…>", chars, bytes, nodes, :string)
    end
  end

  defp fit_quoted(graphemes, more?, chars, bytes, nodes) do
    content =
      graphemes
      |> IO.iodata_to_binary()
      |> String.replace("</untrusted_ptc_output>", "</untrusted_ptc_output (escaped)>")

    exact = inspect(content <> if(more?, do: "…", else: ""), printable_limit: :infinity)

    if fits?(exact, chars, bytes) do
      caps = if(more?, do: MapSet.new([:string]), else: MapSet.new())
      {exact, more?, caps, nodes}
    else
      case content |> quoted_chunks() |> fit_truncated_chunks(~S|"|, ~S|"|, chars, bytes) do
        {:ok, text, true} ->
          {text, true, MapSet.new([:string]), nodes}

        :error when chars >= 2 and bytes >= 2 ->
          {~S|""|, true, MapSet.new([:output, :string]), nodes}

        :error ->
          {"", true, MapSet.new([:output, :string]), nodes}
      end
    end
  end

  defp fit_delimited_chunks(chunks, more?, open, close, chars, bytes) do
    marker = if(more?, do: "…", else: "")
    exact = IO.iodata_to_binary([open, chunks, marker, close])

    if fits?(exact, chars, bytes) do
      {:ok, exact, more?}
    else
      fit_truncated_chunks(chunks, open, close, chars, bytes)
    end
  end

  defp fit_truncated_chunks(chunks, open, close, chars, bytes) do
    marker = "…"
    fixed_chars = String.length(open <> marker <> close)
    fixed_bytes = byte_size(open <> marker <> close)

    if fixed_chars <= chars and fixed_bytes <= bytes do
      kept =
        take_fitting_chunks(
          chunks,
          max(chars - fixed_chars, 0),
          max(bytes - fixed_bytes, 0),
          [],
          0,
          0
        )

      {:ok, IO.iodata_to_binary([open, kept, marker, close]), true}
    else
      :error
    end
  end

  defp take_fitting_chunks([], _chars, _bytes, acc, _used_chars, _used_bytes),
    do: Enum.reverse(acc)

  defp take_fitting_chunks([chunk | rest], chars, bytes, acc, used_chars, used_bytes) do
    next_chars = used_chars + String.length(chunk)
    next_bytes = used_bytes + byte_size(chunk)

    if next_chars <= chars and next_bytes <= bytes do
      take_fitting_chunks(rest, chars, bytes, [chunk | acc], next_chars, next_bytes)
    else
      Enum.reverse(acc)
    end
  end

  defp grapheme_chunks(value), do: grapheme_chunks(value, [])

  defp grapheme_chunks("", acc), do: Enum.reverse(acc)

  defp grapheme_chunks(value, acc) do
    case String.next_grapheme(value) do
      {grapheme, rest} -> grapheme_chunks(rest, [grapheme | acc])
      nil -> Enum.reverse(acc)
    end
  end

  defp quoted_chunks(value), do: quoted_chunks(value, [])

  defp quoted_chunks("", acc), do: Enum.reverse(acc)

  defp quoted_chunks(<<"#", "{", rest::binary>>, acc),
    do: quoted_chunks(rest, [<<"\\", "#", "{">> | acc])

  defp quoted_chunks(value, acc) do
    case String.next_grapheme(value) do
      {grapheme, rest} -> quoted_chunks(rest, [quoted_chunk(grapheme) | acc])
      nil -> Enum.reverse(acc)
    end
  end

  defp quoted_chunk("\""), do: "\\\""
  defp quoted_chunk("\\"), do: "\\\\"
  defp quoted_chunk(<<0>>), do: "\\0"
  defp quoted_chunk(<<7>>), do: "\\a"
  defp quoted_chunk(<<8>>), do: "\\b"
  defp quoted_chunk("\t"), do: "\\t"
  defp quoted_chunk("\n"), do: "\\n"
  defp quoted_chunk(<<11>>), do: "\\v"
  defp quoted_chunk(<<12>>), do: "\\f"
  defp quoted_chunk("\r"), do: "\\r"
  defp quoted_chunk(<<27>>), do: "\\e"

  defp quoted_chunk(grapheme) do
    if String.printable?(grapheme) do
      grapheme
    else
      grapheme
      |> inspect(binaries: :as_strings, printable_limit: :infinity)
      |> String.trim_leading(~S|"|)
      |> String.trim_trailing(~S|"|)
    end
  end

  defp render_list(list, depth, chars, bytes, nodes, policy) do
    {items, more?} = take_list(list, policy.max_items)

    render_sequence("[", "]", items, more?, :items, %{
      depth: depth,
      chars: chars,
      bytes: bytes,
      nodes: nodes,
      policy: policy
    })
  end

  defp render_set(%MapSet{} = set, depth, chars, bytes, nodes, policy) do
    items = Enum.take(set, policy.max_items + 1)
    more? = MapSet.size(set) > policy.max_items

    render_sequence(
      "\#{",
      "}",
      Enum.take(items, policy.max_items),
      more?,
      :items,
      %{depth: depth, chars: chars, bytes: bytes, nodes: nodes, policy: policy}
    )
  end

  defp render_tuple(tuple, depth, chars, bytes, nodes, policy) do
    size = tuple_size(tuple)
    count = min(size, policy.max_items)
    items = if(count == 0, do: [], else: Enum.map(0..(count - 1), &elem(tuple, &1)))

    render_sequence(
      "[",
      "]",
      items,
      size > count,
      :items,
      %{depth: depth, chars: chars, bytes: bytes, nodes: nodes, policy: policy}
    )
  end

  defp render_bounded_label(prefix, value, suffix, chars, bytes, nodes, policy)
       when is_binary(value) do
    {graphemes, more?} = take_grapheme_list(value, policy.max_string_chars)
    chunks = graphemes |> IO.iodata_to_binary() |> escape_untrusted() |> grapheme_chunks()

    case fit_delimited_chunks(chunks, more?, prefix, suffix, chars, bytes) do
      {:ok, text, truncated?} ->
        caps = if(truncated?, do: MapSet.new([:string]), else: MapSet.new())
        {text, truncated?, caps, nodes}

      :error ->
        leaf("#<…>", chars, bytes, nodes, :string)
    end
  end

  defp render_bounded_label(_prefix, _value, _suffix, chars, bytes, nodes, _policy),
    do: leaf("#<unrenderable>", chars, bytes, nodes, :output)

  defp render_var_tuple({:var, name}, chars, bytes, nodes, policy)
       when is_atom(name) or is_binary(name),
       do: render_bounded_label("#'", Kernel.to_string(name), "", chars, bytes, nodes, policy)

  defp render_var_tuple(_value, chars, bytes, nodes, _policy),
    do: leaf("#<unrenderable>", chars, bytes, nodes, :output)

  defp render_symbol_tuple({:symbol_ref, name}, chars, bytes, nodes, policy)
       when is_binary(name),
       do: render_bounded_label("'", name, "", chars, bytes, nodes, policy)

  defp render_symbol_tuple(_value, chars, bytes, nodes, _policy),
    do: leaf("#<unrenderable>", chars, bytes, nodes, :output)

  defp render_regex_tuple({:re_mp, _compiled, _anchored, source}, chars, bytes, nodes, policy)
       when is_binary(source),
       do: render_regex(source, chars, bytes, nodes, policy)

  defp render_regex_tuple(_value, chars, bytes, nodes, _policy),
    do: leaf("#<unrenderable>", chars, bytes, nodes, :output)

  defp render_java_callable(callable, chars, bytes, nodes, policy) do
    with true <- JavaCallable.valid?(callable),
         {:ok, label} <- JavaSurface.reference_label(callable.reference_id) do
      render_bounded_label("", label, "", chars, bytes, nodes, policy)
    else
      _invalid -> render_invalid_java(chars, bytes, nodes, policy)
    end
  end

  defp render_java_primitive(primitive, chars, bytes, nodes, policy) do
    case JavaPrimitive.unwrap(primitive) do
      {:ok, value} ->
        label = "#java[#{primitive.kind} #{format_java_value(value)}]"
        render_bounded_label("", label, "", chars, bytes, nodes, policy)

      {:error, :invalid_java_value} ->
        render_invalid_java(chars, bytes, nodes, policy)
    end
  end

  defp render_java_object(value, module, class_name, chars, bytes, nodes, policy) do
    if module.valid?(value) do
      label = "#java[#{class_name} #{module.canonical(value)}]"
      render_bounded_label("", label, "", chars, bytes, nodes, policy)
    else
      render_invalid_java(chars, bytes, nodes, policy)
    end
  end

  defp render_invalid_java(chars, bytes, nodes, policy),
    do: render_string("#<invalid-java-value>", chars, bytes, nodes, policy)

  defp format_java_value(:infinity), do: "##Inf"
  defp format_java_value(:negative_infinity), do: "##-Inf"
  defp format_java_value(:nan), do: "##NaN"
  defp format_java_value(value), do: Kernel.to_string(value)

  defp render_map(map, depth, chars, bytes, nodes, policy) do
    entries =
      map
      |> take_enumerable(policy.max_items)
      |> Enum.sort_by(fn {key, _value} -> key_sort_label(key) end)

    more? = map_size(map) > length(entries)

    render_entries(entries, more?, depth, chars, bytes, nodes, policy)
  end

  defp render_entries(entries, more?, depth, chars, bytes, nodes, policy) do
    entry_fun = fn {key, value}, child_chars, child_bytes, child_nodes ->
      render_map_entry(key, value, depth, child_chars, child_bytes, child_nodes, policy)
    end

    render_sequence_with(
      %{
        open: "{",
        close: "}",
        items: entries,
        more?: more?,
        cap: :items,
        chars: chars,
        bytes: bytes,
        nodes: nodes,
        allocation_mode: policy.allocation_mode,
        # Only a map entry may outgrow its share, because its key is rendered
        # against the key ceiling rather than that share. One wide entry must not
        # hide every narrower sibling, so a map skips what does not fit and keeps
        # going; a list still stops, where position carries meaning.
        skip_oversized: true
      },
      entry_fun
    )
  end

  # A truncated value stays identifiable from what survives; a truncated key is
  # unrecoverable, so the key never takes a share of the entry's budget. It gets
  # the whole key ceiling regardless of how deeply the entry nests, and the value
  # keeps a small floor beneath the remainder. Nothing here widens the render:
  # an entry may outgrow its share, but the sequence renderer still drops one
  # that does not fit the parent budget and marks the map truncated, so a map
  # whose keys alone exceed the ceiling shows fewer entries with intact names
  # instead of every name stubbed.
  defp render_map_entry(key, value, depth, chars, bytes, nodes, policy) do
    {key_budget_chars, key_budget_bytes} =
      case policy.allocation_mode do
        :shape -> {@key_chars, @key_chars * 4}
        :complete -> {chars, bytes}
      end

    {key_text, key_truncated?, key_caps, nodes} =
      render_key(key, depth + 1, key_budget_chars, key_budget_bytes, nodes, policy)

    separator = " "
    value_floor_chars = if(policy.allocation_mode == :shape, do: @min_value_chars, else: 0)

    remaining_chars =
      max(chars - String.length(key_text) - 1, value_floor_chars)

    remaining_bytes =
      max(bytes - byte_size(key_text) - 1, value_floor_chars * 4)

    {value_text, value_truncated?, value_caps, nodes} =
      render_value(value, depth + 1, remaining_chars, remaining_bytes, nodes, policy)

    # A key with nothing after it reads as a pair whose value is the next key, so
    # an entry whose value did not fit is dropped whole. The sequence renderer
    # turns the empty text into the map's truncation marker.
    text = if value_text == "", do: "", else: key_text <> separator <> value_text

    {
      text,
      key_truncated? or value_truncated?,
      MapSet.union(key_caps, value_caps),
      nodes
    }
  end

  defp render_key(key, _depth, chars, bytes, nodes, policy) when is_binary(key),
    do: render_string(key, chars, bytes, nodes, policy)

  defp render_key(%LispKeyword{} = key, _depth, chars, bytes, nodes, policy),
    do: render_keyword(key, chars, bytes, nodes, policy)

  # Through the same bounded label renderer keywords use, so a long atom key
  # elides to an identifiable prefix instead of collapsing to an opaque marker.
  defp render_key(key, _depth, chars, bytes, nodes, policy) when is_atom(key),
    do: render_bounded_label(":", Atom.to_string(key), "", chars, bytes, nodes, policy)

  defp render_key(key, depth, chars, bytes, nodes, policy),
    do: render_value(key, depth, chars, bytes, nodes, policy)

  defp render_sequence(open, close, items, more?, cap, render_context) do
    %{depth: depth, chars: chars, bytes: bytes, nodes: nodes, policy: policy} = render_context

    item_fun = fn item, child_chars, child_bytes, child_nodes ->
      render_value(item, depth + 1, child_chars, child_bytes, child_nodes, policy)
    end

    render_sequence_with(
      %{
        open: open,
        close: close,
        items: items,
        more?: more?,
        cap: cap,
        chars: chars,
        bytes: bytes,
        nodes: nodes,
        allocation_mode: policy.allocation_mode
      },
      item_fun
    )
  end

  defp render_sequence_with(sequence, item_fun) do
    %{
      open: open,
      close: close,
      items: items,
      chars: chars,
      bytes: bytes,
      nodes: nodes,
      allocation_mode: allocation_mode
    } = sequence

    case fits?(open <> close, chars, bytes) do
      false ->
        leaf("#<…>", chars, bytes, nodes, :output)

      true ->
        base_chars = String.length(open) + String.length(close)
        base_bytes = byte_size(open) + byte_size(close)

        {parts, used_chars, used_bytes, nodes, truncated?, caps, stopped?} =
          render_sequence_items(items, item_fun, %{
            chars: chars - base_chars,
            bytes: bytes - base_bytes,
            nodes: nodes,
            remaining_count: length(items),
            allocation_mode: allocation_mode,
            skip_oversized: Map.get(sequence, :skip_oversized, false),
            parts: [],
            used_chars: 0,
            used_bytes: 0,
            truncated?: false,
            skipped?: false,
            caps: []
          })

        parts = Enum.reverse(parts)
        needs_marker? = sequence.more? or stopped?
        marker = if(parts == [], do: "...", else: " ...")

        {parts, truncated?, caps} =
          if needs_marker? and
               fits?(marker, chars - base_chars - used_chars, bytes - base_bytes - used_bytes) do
            {parts ++ [marker], true,
             MapSet.put(caps, if(sequence.more?, do: sequence.cap, else: :output))}
          else
            {parts, truncated? or needs_marker?,
             if(needs_marker?, do: MapSet.put(caps, :output), else: caps)}
          end

        {open <> Enum.join(parts) <> close, truncated?, caps, nodes}
    end
  end

  defp render_sequence_items([], _item_fun, state) do
    %{parts: parts, used_chars: used_chars, used_bytes: used_bytes} = state

    {parts, used_chars, used_bytes, state.nodes, state.truncated?, MapSet.new(state.caps),
     state.skipped?}
  end

  defp render_sequence_items([item | rest], item_fun, state) do
    separator = if(state.parts == [], do: "", else: " ")
    marker_reserve_chars = if(state.allocation_mode == :shape, do: 4, else: 0)
    marker_reserve_bytes = if(state.allocation_mode == :shape, do: 4, else: 0)

    remaining_chars =
      state.chars - state.used_chars - String.length(separator) - marker_reserve_chars

    remaining_bytes = state.bytes - state.used_bytes - byte_size(separator) - marker_reserve_bytes

    divisor = if(state.allocation_mode == :shape, do: max(state.remaining_count, 1), else: 1)
    child_chars = max(div(max(remaining_chars, 0), divisor), 0)
    child_bytes = max(div(max(remaining_bytes, 0), divisor), 0)

    {text, child_truncated?, child_caps, next_nodes} =
      item_fun.(item, child_chars, child_bytes, state.nodes)

    next = separator <> text

    if text == "" or
         not fits?(
           next,
           state.chars - state.used_chars - marker_reserve_chars,
           state.bytes - state.used_bytes - marker_reserve_bytes
         ) do
      # The dropped text still tells us which ceiling ended it, so the caps the
      # child reported survive alongside the output cap this drop adds.
      caps = [:output | MapSet.to_list(child_caps)] ++ state.caps

      if state.skip_oversized and rest != [] do
        render_sequence_items(rest, item_fun, %{
          state
          | nodes: next_nodes,
            remaining_count: state.remaining_count - 1,
            truncated?: true,
            skipped?: true,
            caps: caps
        })
      else
        # The dropped render still consumed nodes; an enclosing sequence must not
        # spend them again.
        {state.parts, state.used_chars, state.used_bytes, next_nodes, true, MapSet.new(caps),
         true}
      end
    else
      render_sequence_items(rest, item_fun, %{
        state
        | nodes: next_nodes,
          remaining_count: state.remaining_count - 1,
          parts: [next | state.parts],
          used_chars: state.used_chars + String.length(next),
          used_bytes: state.used_bytes + byte_size(next),
          truncated?: state.truncated? or child_truncated?,
          caps: MapSet.to_list(child_caps) ++ state.caps
      })
    end
  end

  defp render_struct(struct, chars, bytes, nodes) do
    module = struct.__struct__ |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
    leaf("#<#{module}>", chars, bytes, nodes)
  rescue
    _error -> leaf("#<struct>", chars, bytes, nodes, :output)
  end

  defp depth_marker(value, chars, bytes, nodes) do
    marker =
      cond do
        is_list(value) -> "[...]"
        match?(%MapSet{}, value) -> "\#{...}"
        is_map(value) -> "{...}"
        is_tuple(value) -> "[...]"
      end

    leaf(marker, chars, bytes, nodes, :depth)
  end

  defp leaf(text, chars, bytes, nodes, cap \\ nil) do
    text = escape_untrusted(text)

    if fits?(text, chars, bytes) do
      caps = if(cap, do: MapSet.new([cap]), else: MapSet.new())
      {text, not is_nil(cap), caps, nodes}
    else
      fallback = if(fits?("#<…>", chars, bytes), do: "#<…>", else: "")
      {fallback, true, MapSet.new([:output]), nodes}
    end
  end

  defp fits?(text, chars, bytes),
    do: String.length(text) <= chars and byte_size(text) <= bytes

  defp take_list(list, limit), do: take_list(list, limit, [])

  defp take_list([], _limit, acc), do: {Enum.reverse(acc), false}
  defp take_list(_rest, 0, acc), do: {Enum.reverse(acc), true}
  defp take_list([item | rest], limit, acc), do: take_list(rest, limit - 1, [item | acc])

  defp take_enumerable(value, limit) do
    value
    |> Enum.reduce_while({[], 0}, fn item, {acc, count} ->
      if count < limit,
        do: {:cont, {[item | acc], count + 1}},
        else: {:halt, {acc, count}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp take_graphemes(value, limit) do
    {graphemes, more?} = take_grapheme_list(value, limit)
    {IO.iodata_to_binary(graphemes), more?}
  end

  defp take_grapheme_list(value, limit), do: take_grapheme_list(value, limit, [])

  defp take_grapheme_list("", _limit, acc), do: {Enum.reverse(acc), false}
  defp take_grapheme_list(value, 0, acc), do: {Enum.reverse(acc), value != ""}

  defp take_grapheme_list(value, limit, acc) do
    case String.next_grapheme(value) do
      {grapheme, rest} -> take_grapheme_list(rest, limit - 1, [grapheme | acc])
      nil -> {Enum.reverse(acc), false}
    end
  end

  defp sampled_keys(value, policy) do
    {keys, _keys_left, _nodes_left} =
      collect_sampled_keys(
        value,
        policy.max_depth,
        @sampled_key_limit,
        min(policy.max_nodes, @sampled_key_limit * 4),
        policy,
        []
      )

    keys |> Enum.uniq() |> Enum.sort()
  end

  defp collect_sampled_keys(_value, _depth, keys_left, nodes_left, _policy, acc)
       when keys_left <= 0 or nodes_left <= 0,
       do: {acc, max(keys_left, 0), max(nodes_left, 0)}

  defp collect_sampled_keys(_value, depth, keys_left, nodes_left, _policy, acc)
       when depth < 0,
       do: {acc, keys_left, nodes_left}

  defp collect_sampled_keys(value, depth, keys_left, nodes_left, policy, acc)
       when is_map(value) and not is_struct(value) do
    entries = take_enumerable(value, min(policy.max_items, keys_left))

    labels =
      entries
      |> Enum.map(fn {key, _value} -> sampled_key_label(key) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(keys_left)

    keys_left = keys_left - length(labels)
    acc = acc ++ labels

    Enum.reduce_while(entries, {acc, keys_left, nodes_left - 1}, fn {_key, child}, state ->
      {keys, remaining_keys, remaining_nodes} = state

      if remaining_keys <= 0 or remaining_nodes <= 0 do
        {:halt, state}
      else
        {:cont,
         collect_sampled_keys(
           child,
           depth - 1,
           remaining_keys,
           remaining_nodes,
           policy,
           keys
         )}
      end
    end)
  end

  defp collect_sampled_keys(value, depth, keys_left, nodes_left, policy, acc)
       when is_list(value) do
    value
    |> take_list(policy.max_items)
    |> elem(0)
    |> collect_sampled_keys_from_children(depth, keys_left, nodes_left, policy, acc)
  end

  defp collect_sampled_keys(%MapSet{} = value, depth, keys_left, nodes_left, policy, acc) do
    value
    |> Enum.take(policy.max_items)
    |> collect_sampled_keys_from_children(depth, keys_left, nodes_left, policy, acc)
  end

  defp collect_sampled_keys(value, depth, keys_left, nodes_left, policy, acc)
       when is_tuple(value) do
    if callable_representation?(value) do
      {acc, keys_left, nodes_left - 1}
    else
      size = tuple_size(value)
      count = min(size, policy.max_items)

      if(count == 0, do: [], else: Enum.map(0..(count - 1), &elem(value, &1)))
      |> collect_sampled_keys_from_children(depth, keys_left, nodes_left, policy, acc)
    end
  end

  defp collect_sampled_keys(
         %ExternalizedCollision{value: value},
         depth,
         keys_left,
         nodes_left,
         policy,
         acc
       ),
       do: collect_sampled_keys(value, depth, keys_left, nodes_left, policy, acc)

  defp collect_sampled_keys(_value, _depth, keys_left, nodes_left, _policy, acc),
    do: {acc, keys_left, nodes_left - 1}

  defp collect_sampled_keys_from_children(
         children,
         depth,
         keys_left,
         nodes_left,
         policy,
         acc
       ) do
    Enum.reduce_while(children, {acc, keys_left, nodes_left - 1}, fn child, state ->
      {keys, remaining_keys, remaining_nodes} = state

      if remaining_keys <= 0 or remaining_nodes <= 0 do
        {:halt, state}
      else
        {:cont,
         collect_sampled_keys(
           child,
           depth - 1,
           remaining_keys,
           remaining_nodes,
           policy,
           keys
         )}
      end
    end)
  end

  defp sampled_key_label(key) when is_binary(key),
    do: elem(take_graphemes(key, @sort_key_chars), 0)

  defp sampled_key_label(%LispKeyword{name: name}),
    do: ":" <> elem(take_graphemes(name, @sort_key_chars), 0)

  defp sampled_key_label(key) when is_atom(key), do: ":" <> Atom.to_string(key)

  defp sampled_key_label(key) when is_integer(key) do
    {:ok, label} = scalar_text(key)
    label
  end

  defp sampled_key_label(_key), do: nil

  defp key_sort_label(key), do: sampled_key_label(key) || type_label(key)

  defp type_label(value) when is_list(value), do: "vector"
  defp type_label(value) when is_tuple(value), do: "tuple"
  defp type_label(value) when is_map(value), do: "map"
  defp type_label(_value), do: "other"

  defp closure?({:closure, _, _, _, _, _}), do: true
  defp closure?(_value), do: false

  defp builtin_binding?({:normal, function}), do: is_function(function)
  defp builtin_binding?({:variadic, function, _identity}), do: is_function(function)

  defp builtin_binding?({:variadic_nonempty, name, function}),
    do: is_atom(name) and is_function(function)

  defp builtin_binding?({:multi_arity, name, functions}),
    do: is_atom(name) and is_tuple(functions)

  defp builtin_binding?({:special, name}), do: is_atom(name)
  defp builtin_binding?(_value), do: false

  defp opaque_callable?({:collect, function}), do: is_function(function)
  defp opaque_callable?({:juxt_fn, functions}), do: is_list(functions)

  defp opaque_callable?({tag, _value}) when tag in [:complement_fn, :constantly_fn],
    do: true

  defp opaque_callable?({tag, functions})
       when tag in [:comp_fn, :every_pred_fn, :some_fn],
       do: is_list(functions)

  defp opaque_callable?({:partial_fn, _function, fixed}), do: is_list(fixed)
  defp opaque_callable?({:fnil_fn, _function, _default}), do: true
  defp opaque_callable?(_value), do: false

  defp callable_representation?(value),
    do: TypeVocabulary.callable?(value)

  defp closure_label({:closure, params, _, _, _, _}) when is_list(params) do
    names =
      params
      |> Enum.take(@default_max_items)
      |> Enum.map_join(" ", fn
        {:var, name} when is_atom(name) or is_binary(name) -> Kernel.to_string(name)
        {:symbol, name} when is_atom(name) or is_binary(name) -> Kernel.to_string(name)
        {:destructure, _pattern} -> "_"
        _other -> "?"
      end)

    "#fn[#{names}]"
  end

  defp closure_label(_value), do: "#fn[...]"

  defp escape_untrusted(text),
    do: String.replace(text, "</untrusted_ptc_output>", "</untrusted_ptc_output (escaped)>")

  defp container?(value),
    do: is_list(value) or is_tuple(value) or match?(%MapSet{}, value) or is_map(value)
end
