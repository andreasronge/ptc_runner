defmodule PtcRunner.PreludeStore.FormEdit do
  @moduledoc ~S"""
  Applies a validated, form-keyed edit BATCH to prelude source text, using
  `PtcRunner.Lisp.Prelude.FormScanner` byte spans (plan
  `docs/plans/prelude-form-edit-and-introspection.md`, Phase 3). This is the
  splice layer `PtcRunner.PreludeStore.edit/3,4` sits on: it never touches
  the store, never compiles anything — `apply/2` is a pure text transform,
  and the store's existing `compile_bounded` write-time gate is what
  actually rejects a bad result (a nonsensical splice fails to COMPILE, it
  is never silently stored).

  ## Op set

  Each edit is a map (string OR atom keys; `"op"`/`:op` value a string OR
  atom — `field/3` and `op_value/1` below accept either, matching the
  dual-key style already used throughout `PreludeStore`). Op names use
  underscores (`"replace_form"`, not `"replace-form"`): the tool-boundary key
  normalizer rewrites hyphens in ARG KEYS but not in keyword-derived VALUES
  (`PtcRunner.SubAgent.KeyNormalizer`), so a canonical underscore spelling
  keeps the wire value unambiguous regardless of path.

    * `%{"op" => "replace_form", "name" => n, "source" => s}` — `s` must
      scan to EXACTLY one top-level form whose derived name equals `n`
      (`:invalid_form_source` / `:form_name_mismatch` otherwise). The head
      may change freely (`defn` <-> `defn-` <-> `def`) — a visibility flip
      is an ordinary replace, surfaced in the write result's
      `public_surface` diff, not rejected here.
    * `%{"op" => "add_form", "source" => s, "placement" => "end" | "before"
      | "after", "anchor" => name}` — `placement` defaults to `"end"`;
      `"before"`/`"after"` require `anchor`. `s` must scan to exactly one
      NAMED top-level form whose name does not already exist and is not
      added twice in the same batch.
    * `%{"op" => "remove_form", "name" => n}` — `n` must exist.
    * `%{"op" => "set_ns_doc", "doc" => d}` — replaces (or inserts, if
      absent) the docstring in the `(ns ...)` form ONLY, via
      `FormScanner.locate_ns_doc/2`; every other byte of that form is
      untouched.

  **The `(ns ...)` form is deliberately excluded from the name-keyed op
  space** (`replace_form`/`remove_form`/`add_form`'s `anchor`, and the
  existing-name check) — it is reachable only through `set_ns_doc`. This
  mirrors the plan's own framing ("the `(ns ...)` form is not symbol-keyed
  like definitions") and sidesteps a real ambiguity: `FormScanner` derives a
  `name` for an `ns` form too (its namespace symbol), and nothing stops a
  prelude author from also naming a `defn`/`def` the same as its own
  namespace (the compiler only rejects duplicate refs among `defn`/`def`
  specs, never against the ns name). Every name-keyed lookup in this module
  therefore only ever considers forms whose scanned `head` is
  `"defn"`/`"defn-"`/`"def"`; the `ns` form is matched separately, by
  `head == "ns"`, so a same-named `defn` can never be confused with it.

  ## Batch semantics

  All ops resolve their target/anchor spans against the BASE source's scan —
  never against each other or against a partially-spliced intermediate
  result — then the whole batch is spliced in one pass. Batches are
  rejected outright (before any splicing) when:

    * two ops target the same existing form name (two `replace_form`s, a
      `replace_form` and a `remove_form`, two `remove_form`s, ...) —
      `:conflicting_edit_batch`;
    * an `add_form` is anchored `:before`/`:after` a name this SAME batch
      removes — `:conflicting_edit_batch`;
    * more than one `set_ns_doc` op appears — `:conflicting_edit_batch`;
    * an `add_form`'s name already exists in the base, or is added twice in
      this batch — `:form_already_exists`;
    * a `replace_form`/`remove_form` target, or an `add_form` anchor, is not
      an existing (keyable) form name — `:form_not_found`.

  An empty `edits` list, a non-list `edits`, a non-map edit, an unknown
  `"op"`, or a missing/mistyped required field all fail `:invalid_argument`.

  ## Splice text rules

    * `replace_form` swaps ONLY the target's `span`; its preceding `gap`
      (header comments, blank lines) is untouched.
    * `remove_form` removes the target's `span` AND its preceding `gap` —
      header comments travel with the form they document.
    * `add_form :before X` inserts `"\n\n" <> new-form-text` immediately
      before X's ORIGINAL preceding gap begins (i.e. right after whatever
      precedes X, separated from it by a blank line), so X's own header
      comments stay attached to X, not to the newly inserted form. The
      separator sits on the new form's LEFT edge — on its right, X's own
      untouched gap provides the separation.
    * `add_form :after X` inserts `"\n\n" <> new-form-text` immediately
      after X's span ends (before whatever follows X, gap and all).
    * `add_form :end` (the default) appends `"\n\n" <> new-form-text` after
      the LAST form's span, before the source's trailing gap.
    * Untouched forms are byte-identical by construction: their gap and span
      are copied verbatim from the base source.

  Only the single top-level FORM text from a `replace_form`/`add_form`
  `source` is spliced in — that source's OWN leading gap (e.g. a comment the
  caller put before the form) and trailing gap are discarded; only its
  `span` (per `FormScanner`) is used. Callers who want a header comment on a
  new/replacement form must have it land in the base's own gap handling
  (the target's untouched preceding gap for `replace_form`; not currently
  reachable for `add_form` — a documented limitation, not a bug: `add_form`
  has no op for authoring a NEW leading gap).

  ## Result

  `{:ok, new_source, summary}` where `summary` is `%{replaced: [names],
  added: [names], removed: [names], ns_doc_set: boolean}` (all three name
  lists sorted). Errors are `{:error, %{reason: atom(), message: String.t(),
  optional(:name) => String.t()}}`.
  """

  alias PtcRunner.Lisp.Prelude.FormScanner

  @type edit :: map()
  @type summary :: %{
          replaced: [String.t()],
          added: [String.t()],
          removed: [String.t()],
          ns_doc_set: boolean()
        }

  @keyable_heads ~w(defn defn- def)

  @doc """
  Applies `edits` to `base_source`, returning `{:ok, new_source, summary}` or
  a fail-closed `{:error, %{reason: ..., message: ...}}`.

  `opts` supports `:max_source_bytes` — when set, every caller-supplied
  `source`/`doc` string is bounded BEFORE any scanning or parsing work
  happens on it (`:source_too_large`). The base source is trusted (it comes
  from the store, which already enforces its own bound); only edit payloads
  need this pre-scan gate — without it, an oversized `replace_form` source
  would burn scanner/parser CPU only to be rejected later by the write-time
  size check.
  """
  @spec apply(binary(), [edit()], keyword()) :: {:ok, binary(), summary()} | {:error, map()}
  def apply(base_source, edits, opts \\ [])

  def apply(base_source, edits, opts)
      when is_binary(base_source) and is_list(edits) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_source_bytes)

    with :ok <- validate_edits_shape(edits),
         :ok <- validate_edit_bounds(edits, max_bytes),
         {:ok, scan} <- scan_base(base_source),
         {:ok, ops} <- normalize_all(edits),
         :ok <- validate_batch(ops, scan) do
      splice(base_source, scan, ops)
    end
  end

  def apply(_base_source, _edits, _opts) do
    {:error, invalid_argument("FormEdit.apply/3 requires a binary base_source and a list edits")}
  end

  # ============================================================
  # Shape / base scan
  # ============================================================

  defp validate_edits_shape([]), do: {:error, invalid_argument("edits must be a non-empty list")}

  defp validate_edits_shape(edits) do
    if Enum.all?(edits, &(is_map(&1) and not is_struct(&1))) do
      :ok
    else
      {:error, invalid_argument("each edit must be a map")}
    end
  end

  # Bounds every string an edit can carry (`source`, `doc`) before ANY
  # scanner/parser work touches it. Field presence/typing is NOT validated
  # here — `normalize_all/1` owns that; this pass only guards resource use.
  defp validate_edit_bounds(_edits, nil), do: :ok

  defp validate_edit_bounds(edits, max_bytes) do
    edits
    |> Enum.find_value(fn edit ->
      ["source", :source, "doc", :doc]
      |> Enum.map(&Map.get(edit, &1))
      |> Enum.find(&(is_binary(&1) and byte_size(&1) > max_bytes))
    end)
    |> case do
      nil ->
        :ok

      oversized ->
        {:error,
         %{
           reason: :source_too_large,
           message: "edit source is #{byte_size(oversized)} bytes; limit is #{max_bytes}",
           limit_bytes: max_bytes
         }}
    end
  end

  defp scan_base(base_source) do
    case FormScanner.scan(base_source) do
      {:ok, scan} -> {:ok, scan}
      {:error, reason} -> {:error, base_scan_failed(reason)}
    end
  end

  # ============================================================
  # Per-op normalization (validated independently of the batch/base)
  # ============================================================

  defp normalize_all(edits) do
    Enum.reduce_while(edits, {:ok, []}, fn edit, {:ok, acc} ->
      case normalize_edit(edit) do
        {:ok, op} -> {:cont, {:ok, [op | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      {:error, _} = err -> err
    end
  end

  defp normalize_edit(edit) when is_map(edit) do
    case field(edit, "op", :op) |> op_value() do
      {:ok, "replace_form"} -> normalize_replace(edit)
      {:ok, "add_form"} -> normalize_add(edit)
      {:ok, "remove_form"} -> normalize_remove(edit)
      {:ok, "set_ns_doc"} -> normalize_set_ns_doc(edit)
      {:ok, other} -> {:error, invalid_argument("unknown edit op #{inspect(other)}")}
      :error -> {:error, invalid_argument("edit is missing a required \"op\" field")}
    end
  end

  defp normalize_replace(edit) do
    with {:ok, name} <- require_string(edit, "name", :name),
         {:ok, source} <- require_string(edit, "source", :source),
         {:ok, form} <- scan_single_form(source) do
      if form.name == name do
        {:ok, %{type: :replace, name: name, text: slice(source, form.span)}}
      else
        {:error, form_name_mismatch(name, form.name)}
      end
    end
  end

  defp normalize_add(edit) do
    with {:ok, source} <- require_string(edit, "source", :source),
         {:ok, placement, anchor} <- normalize_placement(edit),
         {:ok, form} <- scan_single_form(source),
         {:ok, name} <- require_form_name(form) do
      {:ok,
       %{
         type: :add,
         name: name,
         text: slice(source, form.span),
         placement: placement,
         anchor: anchor
       }}
    end
  end

  defp normalize_remove(edit) do
    with {:ok, name} <- require_string(edit, "name", :name) do
      {:ok, %{type: :remove, name: name}}
    end
  end

  defp normalize_set_ns_doc(edit) do
    with {:ok, doc} <- require_string(edit, "doc", :doc) do
      {:ok, %{type: :set_ns_doc, doc: doc}}
    end
  end

  defp normalize_placement(edit) do
    case field(edit, "placement", :placement) |> op_value() do
      :error ->
        {:ok, :end, nil}

      {:ok, "end"} ->
        {:ok, :end, nil}

      {:ok, "before"} ->
        with {:ok, anchor} <- require_string(edit, "anchor", :anchor), do: {:ok, :before, anchor}

      {:ok, "after"} ->
        with {:ok, anchor} <- require_string(edit, "anchor", :anchor), do: {:ok, :after, anchor}

      {:ok, other} ->
        {:error,
         invalid_argument(
           ~s(add_form placement must be "before", "after", or "end", got #{inspect(other)})
         )}
    end
  end

  # Only ever called with a value `require_string/3` already proved binary.
  defp scan_single_form(source) do
    case FormScanner.scan(source) do
      {:ok, %{forms: [form]}} ->
        {:ok, form}

      {:ok, %{forms: forms}} ->
        {:error,
         invalid_form_source(
           "source must scan to exactly one top-level form, got #{length(forms)}"
         )}

      {:error, reason} ->
        {:error, invalid_form_source("source failed to scan: #{inspect(reason, limit: 5)}")}
    end
  end

  defp require_form_name(%{name: nil}),
    do: {:error, invalid_form_source("source must scan to exactly one NAMED top-level form")}

  defp require_form_name(%{name: name}), do: {:ok, name}

  # ============================================================
  # Batch-level validation (needs the base scan's keyable names)
  # ============================================================

  defp validate_batch(ops, scan) do
    keyable_names = keyable_forms(scan) |> Enum.map(& &1.name)

    with :ok <- validate_targets_exist(ops, keyable_names),
         :ok <- validate_add_names(ops, keyable_names),
         :ok <- validate_no_duplicate_targets(ops),
         :ok <- validate_anchors_not_removed(ops) do
      validate_single_ns_doc(ops)
    end
  end

  defp keyable_forms(%{forms: forms}), do: Enum.filter(forms, &(&1.head in @keyable_heads))

  defp validate_targets_exist(ops, keyable_names) do
    ops
    |> Enum.find_value(fn
      %{type: t, name: name} when t in [:replace, :remove] ->
        if name in keyable_names, do: nil, else: form_not_found(name)

      %{type: :add, placement: p, anchor: anchor} when p in [:before, :after] ->
        if anchor in keyable_names, do: nil, else: form_not_found(anchor)

      _ ->
        nil
    end)
    |> wrap_error()
  end

  defp validate_add_names(ops, keyable_names) do
    add_names = for %{type: :add, name: name} <- ops, do: name

    cond do
      dup = Enum.find(add_names, &(&1 in keyable_names)) ->
        {:error, form_already_exists(dup)}

      dup = (add_names -- Enum.uniq(add_names)) |> List.first() ->
        {:error, form_already_exists(dup)}

      true ->
        :ok
    end
  end

  defp validate_no_duplicate_targets(ops) do
    targets = for %{type: t, name: name} <- ops, t in [:replace, :remove], do: name

    case (targets -- Enum.uniq(targets)) |> List.first() do
      nil -> :ok
      dup -> {:error, conflicting_batch("multiple edits target form `#{dup}`")}
    end
  end

  defp validate_anchors_not_removed(ops) do
    removed_names = for %{type: :remove, name: name} <- ops, do: name

    ops
    |> Enum.find_value(fn
      %{type: :add, anchor: anchor} when not is_nil(anchor) ->
        if anchor in removed_names do
          conflicting_batch("add_form is anchored to `#{anchor}`, which this batch removes")
        end

      _ ->
        nil
    end)
    |> wrap_error()
  end

  defp validate_single_ns_doc(ops) do
    if Enum.count(ops, &(&1.type == :set_ns_doc)) > 1 do
      {:error, conflicting_batch("only one set_ns_doc edit is allowed per batch")}
    else
      :ok
    end
  end

  defp wrap_error(nil), do: :ok
  defp wrap_error(error), do: {:error, error}

  # ============================================================
  # Splice
  # ============================================================

  defp splice(base_source, scan, ops) do
    replace_by_name = for %{type: :replace, name: n, text: t} <- ops, into: %{}, do: {n, t}
    remove_names = for %{type: :remove, name: n} <- ops, do: n
    add_names = for %{type: :add, name: n} <- ops, do: n
    adds_before = group_adds(ops, :before)
    adds_after = group_adds(ops, :after)
    adds_end = for %{type: :add, placement: :end, text: t} <- ops, do: t

    ns_doc =
      Enum.find_value(ops, fn
        %{type: :set_ns_doc, doc: doc} -> doc
        _ -> nil
      end)

    state = %{
      replace_by_name: replace_by_name,
      remove_names: remove_names,
      adds_before: adds_before,
      adds_after: adds_after
    }

    with {:ok, ns_replacement} <- ns_replacement_text(base_source, scan, ns_doc) do
      fragments =
        Enum.flat_map(scan.forms, &form_fragments(&1, base_source, state, ns_replacement))

      end_fragments = Enum.map(adds_end, &("\n\n" <> &1))

      new_source =
        (fragments ++ end_fragments ++ [slice(base_source, scan.trailing_gap)])
        |> IO.iodata_to_binary()

      summary = %{
        replaced: replace_by_name |> Map.keys() |> Enum.sort(),
        added: Enum.sort(add_names),
        removed: Enum.sort(remove_names),
        ns_doc_set: not is_nil(ns_doc)
      }

      {:ok, new_source, summary}
    end
  end

  # One form's contribution to the spliced source: `[]` when it is removed,
  # else its (possibly add_form-flanked) gap + span, with the span text
  # itself swapped for a replacement/ns-doc splice when applicable.
  # Extracted from `splice/3` to keep nesting shallow there.
  defp form_fragments(form, base_source, state, ns_replacement) do
    keyable? = form.head in @keyable_heads

    if keyable? and form.name in state.remove_names do
      []
    else
      before_texts = if keyable?, do: Map.get(state.adds_before, form.name, []), else: []
      after_texts = if keyable?, do: Map.get(state.adds_after, form.name, []), else: []
      text = form_text(form, base_source, state.replace_by_name, ns_replacement, keyable?)

      Enum.map(before_texts, &("\n\n" <> &1)) ++
        [slice(base_source, form.gap), text] ++
        Enum.map(after_texts, &("\n\n" <> &1))
    end
  end

  defp form_text(form, base_source, replace_by_name, ns_replacement, keyable?) do
    cond do
      form.head == "ns" and not is_nil(ns_replacement) ->
        ns_replacement

      keyable? and Map.has_key?(replace_by_name, form.name) ->
        Map.fetch!(replace_by_name, form.name)

      true ->
        slice(base_source, form.span)
    end
  end

  defp group_adds(ops, placement) do
    ops
    |> Enum.filter(&(&1.type == :add and &1.placement == placement))
    |> Enum.group_by(& &1.anchor, & &1.text)
  end

  defp ns_replacement_text(_base_source, _scan, nil), do: {:ok, nil}

  defp ns_replacement_text(base_source, scan, doc) do
    case Enum.find(scan.forms, &(&1.head == "ns")) do
      nil ->
        {:error,
         %{reason: :ns_form_not_found, message: "no (ns ...) form found in prelude source"}}

      ns_form ->
        case FormScanner.locate_ns_doc(base_source, ns_form.span) do
          {:ok, %{doc_span: nil, insert_at: at}} ->
            {:ok, splice_span(base_source, ns_form.span, at, 0, " " <> quote_doc(doc) <> " ")}

          {:ok, %{doc_span: {doc_off, doc_len}}} ->
            {:ok, splice_span(base_source, ns_form.span, doc_off, doc_len, quote_doc(doc))}

          {:error, reason} ->
            {:error, base_scan_failed(reason)}
        end
    end
  end

  # Rebuilds the WHOLE `form_span` text with a local replacement/insertion at
  # `at` (absolute offset) spanning `replace_len` bytes (0 for a pure
  # insert) — every other byte of the form comes from `base_source`
  # unchanged.
  defp splice_span(base_source, {form_off, form_len}, at, replace_len, insertion) do
    before_len = at - form_off
    before = binary_part(base_source, form_off, before_len)
    after_start = form_off + before_len + replace_len
    after_len = form_off + form_len - after_start
    after_ = binary_part(base_source, after_start, after_len)
    before <> insertion <> after_
  end

  defp quote_doc(doc) do
    escaped =
      doc
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp slice(source, {offset, length}), do: binary_part(source, offset, length)

  # ============================================================
  # Field access (dual atom/string keys, never `String.to_atom/1` on
  # untrusted input) and error helpers
  # ============================================================

  defp field(edit, string_key, atom_key) do
    case Map.get(edit, string_key) do
      nil -> Map.get(edit, atom_key)
      value -> value
    end
  end

  defp require_string(edit, string_key, atom_key) do
    case field(edit, string_key, atom_key) do
      v when is_binary(v) -> {:ok, v}
      _ -> {:error, invalid_argument("edit is missing required string field \"#{string_key}\"")}
    end
  end

  # Converts a known atom/keyword-style op or placement VALUE to its string
  # form. Safe: `Atom.to_string/1` never creates an atom, unlike
  # `String.to_atom/1` — this module never converts untrusted strings into
  # atoms.
  defp op_value(nil), do: :error
  defp op_value(v) when is_binary(v), do: {:ok, v}
  defp op_value(v) when is_atom(v), do: {:ok, Atom.to_string(v)}
  defp op_value(_), do: :error

  defp invalid_argument(message), do: %{reason: :invalid_argument, message: message}

  defp invalid_form_source(message), do: %{reason: :invalid_form_source, message: message}

  defp form_name_mismatch(declared, derived) do
    %{
      reason: :form_name_mismatch,
      message:
        "replace_form declared name `#{declared}` but source scans to name #{inspect(derived)}",
      name: declared
    }
  end

  defp form_not_found(name),
    do: %{reason: :form_not_found, message: "prelude form `#{name}` not found", name: name}

  defp form_already_exists(name),
    do: %{
      reason: :form_already_exists,
      message: "prelude form `#{name}` already exists",
      name: name
    }

  defp conflicting_batch(message), do: %{reason: :conflicting_edit_batch, message: message}

  defp base_scan_failed(reason) do
    %{
      reason: :base_scan_failed,
      message: "prelude source failed to scan: #{inspect(reason, limit: 5)}"
    }
  end
end
