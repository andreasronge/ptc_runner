defmodule PtcRunner.Lisp.Prelude.FormScanner do
  @moduledoc ~S"""
  Byte-exact top-level form span scanner for raw PTC-Lisp prelude source TEXT.

  This is the missing piece `prelude/edit` and `prelude/form` need (plan
  `docs/plans/prelude-form-edit-and-introspection.md`, Phase 3): the parser
  (`PtcRunner.Lisp.Parser` / `PtcRunner.Lisp.FastParser`) tracks no source
  positions, and parse -> swap-form -> re-render via `Formatter` would
  reformat every untouched form, destroying byte-identity. `scan/1` instead
  walks the RAW TEXT directly, tracking bracket/string/comment depth well
  enough to compute the byte span of every top-level form plus the
  whitespace/comment "gap" that precedes it, without ever building an AST.

  ## Result shape

  `scan/1` returns `{:ok, result}` where `result` is:

      %{
        forms: [
          %{
            head: "defn",           # see "head/name" below
            name: "get-user",       # nil if the form has no name (see below)
            gap: {0, 12},           # {offset, length} gap BEFORE this form
            span: {12, 84}          # {offset, length} of the form itself
          },
          ...
        ],
        trailing_gap: {96, 4}       # {offset, length} of content after the
                                    # LAST form (whitespace/comments/EOF slack)
      }

  Every offset/length pair is in BYTES, not characters. Reconcatenating
  `gap ++ span ++ gap ++ span ++ ... ++ trailing_gap` in order reproduces the
  original source byte-for-byte — `scan/1` checks this itself (see
  "Self-checks" below), so callers never have to.

  ## head / name

  A prelude is not the only source this scanner has to survive: the corpus
  gate (below) includes `test/smoke/*.clj` files, which are plain PTC-Lisp
  scripts, not preludes — their final top-level "form" is often a bare
  return value (a map literal, a vector, ...), not a `(head ...)` list. So
  `head`/`name` are defined for ANY top-level value, not only lists:

    * If the form is a list whose first element is a symbol (`(defn ...)`,
      `(let ...)`, `(anything-callable ...)`), `head` is that symbol's
      literal source text.
    * `name` is populated only when `head` is one of the four
      prelude-recognized heads — `ns`, `defn`, `defn-`, `def` — and the
      list's SECOND element is itself a plain symbol (the namespace name for
      `ns`, the def/defn name otherwise). This mirrors
      `PtcRunner.Lisp.Prelude.Compiler`'s `handle_ns_directive/2`,
      `handle_defn/3`, and `handle_def/2`, which all take the name from that
      same position — but this module does NOT call into `Compiler`; the two
      are independent by construction (see "Self-checks").
    * Every other shape — a list with a non-symbol head (or an empty list),
      or any non-list top-level value (a vector, map, set, string, number,
      keyword, ...) — gets a generic `head` describing its syntactic kind
      (`"list"`, `"vector"`, `"map"`, `"set"`, `"short_fn"`, `"string"`,
      `"regex_literal"`, `"var"`, `"quoted_symbol"`, `"keyword"`, `"number"`,
      `"nil"`, `"true"`, `"false"`) and `name: nil`. A bare top-level SYMBOL
      (unusual, but legal) gets its own literal text as `head`.

  `head`/`name` are metadata for humans and for `prelude/edit` to key off of
  — never re-parsed by this module, and never assumed to be unique.

  ## Design decisions (fail-closed, on purpose)

  1. **Diverges from `FastParser`'s top-level `skip_extra_closers/1`
     leniency.** The real reader silently discards a stray closing
     delimiter found BETWEEN top-level forms (`skip_inter_expr/1` in
     `lib/ptc_runner/lisp/fast_parser.ex`) — error-recovery behavior, not a
     lexical construct. This scanner does not replicate it: a stray `)`/`]`/
     `}` between forms is an unclassifiable byte and fails closed
     (`%{reason: :unexpected_byte}`) rather than being silently skipped. No
     prelude/example/test source in this repo relies on that leniency.
  2. **Character literals classify as `"string"`, not `"char_literal"`.**
     The reader itself has no separate character-literal AST node — `\a`
     and `"a"` both parse to `{:string, "a"}` (see `FastParser.parse_char/1`
     and the language spec §3.5: "Character literals are represented as
     single-character strings internally"). Giving them a distinct `head`
     label here would make this scanner's classification strictly finer
     than the reader's own value model, which the cross-check (below) would
     then have no way to agree with. So both scan to `"string"`.
  3. **No semantic validation.** Map literals aren't checked for even arity,
     number/keyword literals aren't validated beyond their character class,
     and namespaced/qualified symbols aren't specially parsed — this module
     only needs byte-accurate token BOUNDARIES, never the parsed VALUE. Full
     semantic validation still happens at the existing compile gate
     (`PtcRunner.Lisp.Prelude.Compiler.compile/1`).

  ## Self-checks (both run INSIDE `scan/1`, never left to the caller)

  1. **Round-trip.** Reconcatenating every gap + form span + the trailing
     gap must reproduce the input byte-for-byte, or scanning fails with
     `%{reason: :scan_roundtrip_mismatch}`.
  2. **Cross-check against the real parser.** `scan/1` also derives the
     ordered `{head, name}` list by calling `PtcRunner.Lisp.Parser.parse/1`
     on the SAME source and walking the returned AST (a second,
     independent code path — see `derive_head_name/1` below, which
     classifies parsed AST shapes the same way `tag_label/1` classifies raw
     scan tags, without either function calling the other). Any
     disagreement (including the real parser rejecting source this scanner
     accepted) fails with `%{reason: :scan_cross_check_mismatch}` or
     `%{reason: :scan_cross_check_parse_failed}`. This is also the backstop
     for lexical-grammar drift: if `FastParser`'s reader grammar ever
     changes and this hand-written mirror doesn't get updated to match, the
     cross-check starts failing loudly instead of silently drifting.

  With both checks in place, the worst failure mode is a loud refusal —
  never a silently wrong span.

  ## Locating the `(ns ...)` docstring

  `locate_ns_doc/2` is a narrowly-scoped helper for source-authoring tools:
  given the byte span of a `(ns ...)`
  form (as produced by `scan/1` — a `%{head: "ns", ...}` entry), it locates
  the docstring token, if any, WITHOUT re-deriving or duplicating any of
  `PtcRunner.Lisp.Prelude.Compiler`'s `ns_metadata/1` semantics — it reuses
  this module's own `scan_symbol/1`/`scan_value/1`/`skip_ws/1` machinery
  against the same span. Span in, span(s) out: callers splice bytes
  themselves; this module never rewrites source text.

  ## Reader-macro coverage

  Mirrors every construct `PtcRunner.Lisp.FastParser.parse/1` accepts:
  lists `(...)`, vectors `[...]`, maps `{...}`, sets `#{...}`, short-fn
  `#(...)`, strings `"..."` and regex literals `#"..."` (identical escape
  rules — `\\`, `\"`, `\n`, `\t`, `\r`, any other `\<char>` passed through,
  and literal embedded newlines allowed; unterminated is the one string-side
  error), character literals (`\newline`, `\space`, `\tab`, `\return`,
  `\backspace`, `\formfeed`, or any other single UTF-8 codepoint), var refs
  `#'name`, quoted symbols `'name` (quoted COLLECTIONS stay unsupported, same
  as the reader), keywords `:name`, numbers (int/float/exponent), the
  `##Inf`/`##-Inf`/`##NaN` literals, `nil`/`true`/`false`, comma-as-whitespace,
  `;` line comments, and symbols (including the embedded-`'` prime-notation
  rest-char, e.g. `inc'`).
  """

  alias PtcRunner.Lisp.Parser

  @type byte_span :: {non_neg_integer(), non_neg_integer()}

  @type form :: %{
          head: String.t(),
          name: String.t() | nil,
          gap: byte_span(),
          span: byte_span()
        }

  @type t :: %{forms: [form()], trailing_gap: byte_span()}

  @type scan_error :: %{required(:reason) => atom(), optional(atom()) => term()}

  @type ns_doc_location :: %{doc_span: byte_span() | nil, insert_at: non_neg_integer()}

  @naming_heads ["ns", "defn", "defn-", "def"]

  # Must be defined (as a guard-usable macro) before any function clause
  # below uses it in a `when` guard.
  defguardp is_symbol_first(c)
            when c in ?a..?z or c in ?A..?Z or
                   c in [?+, ?-, ?*, ?/, ?<, ?>, ?=, ??, ?!, ?_, ?%, ?., ?&]

  @doc """
  Scans `source` and returns the byte-exact top-level form spans, or a
  fail-closed `{:error, %{reason: ...}}` — never a guess.
  """
  @spec scan(binary()) :: {:ok, t()} | {:error, scan_error()}
  def scan(source) when is_binary(source) do
    with {:ok, forms, trailing_gap} <- scan_program({source, 0}, []) do
      result = %{forms: forms, trailing_gap: trailing_gap}

      with :ok <- verify_roundtrip(source, result),
           :ok <- verify_cross_check(source, result) do
        {:ok, result}
      end
    end
  rescue
    e ->
      {:error, %{reason: :scan_internal_error, message: Exception.message(e)}}
  end

  @doc """
  Locates the `(ns ...)` docstring token within `ns_span` — the `{offset,
  length}` byte span of a form `scan/1` reported with `head: "ns"`.

  Returns `doc_span`, the exact byte span of the quoted string literal
  (INCLUDING its surrounding quotes) when the ns form already has a
  docstring — e.g. `(ns name "doc" ...)` — or `nil` when it does not (`(ns
  name)` / `(ns name {meta})`). `insert_at` is always the byte offset
  immediately after the namespace name symbol (before any following
  whitespace, docstring, metadata map, or closing paren): a caller replaces
  exactly `doc_span` in place when it is present, or splices new bytes at
  `insert_at` when it is `nil` — either way, no other byte of the ns form is
  ever touched.

  Fails closed (`{:error, %{reason: :unexpected_ns_form}}`) on any shape
  other than `(ns <symbol> ...)`. Callers are only expected to pass spans
  `scan/1` itself already tagged `head: "ns"` for the SAME source, so this
  should never trigger for a real caller — it exists so a shape this module
  doesn't recognize is refused rather than mis-splice.
  """
  @spec locate_ns_doc(binary(), byte_span()) :: {:ok, ns_doc_location()} | {:error, scan_error()}
  def locate_ns_doc(source, {offset, length}) when is_binary(source) do
    cursor = {binary_part(source, offset, length), offset}

    with {"(" <> rest, offset1} <- cursor,
         cursor2 = skip_ws({rest, offset1 + 1}),
         {:ok, cursor3, {:symbol, "ns"}} <- scan_symbol(cursor2),
         cursor4 = skip_ws(cursor3),
         {:ok, cursor5, {:symbol, _name}} <- scan_symbol(cursor4) do
      locate_after_ns_name(skip_ws(cursor5))
    else
      _ -> {:error, %{reason: :unexpected_ns_form}}
    end
  rescue
    e -> {:error, %{reason: :scan_internal_error, message: Exception.message(e)}}
  end

  defp locate_after_ns_name({"\"" <> _, doc_offset} = cursor) do
    case scan_value(cursor) do
      {:ok, {_rest, doc_end}, :string} ->
        {:ok, %{doc_span: {doc_offset, doc_end - doc_offset}, insert_at: doc_offset}}

      {:error, _} = err ->
        err
    end
  end

  defp locate_after_ns_name({_rest, insert_at}), do: {:ok, %{doc_span: nil, insert_at: insert_at}}

  # ============================================================
  # Top-level program loop
  # ============================================================

  defp scan_program({_bin, gap_start} = cursor, acc) do
    cursor2 = skip_ws(cursor)

    case cursor2 do
      {"", gap_end} ->
        {:ok, Enum.reverse(acc), {gap_start, gap_end - gap_start}}

      {_rest, gap_end} ->
        case scan_top_level_form(cursor2) do
          {:ok, {_rest3, form_end} = cursor3, head, name} ->
            form = %{
              head: head,
              name: name,
              gap: {gap_start, gap_end - gap_start},
              span: {gap_end, form_end - gap_end}
            }

            scan_program(cursor3, [form | acc])

          {:error, _} = err ->
            err
        end
    end
  end

  # A top-level form is any single scanned VALUE — usually a `(head ...)`
  # list, but `test/smoke/*.clj` scripts prove real corpus source can end in
  # a bare return value too. See "head / name" in the moduledoc.
  defp scan_top_level_form(cursor) do
    case scan_value(cursor) do
      {:ok, cursor2, {:list, [{:symbol, head} | rest_children]}} ->
        {:ok, cursor2, head, maybe_name(head, rest_children)}

      {:ok, cursor2, tag} ->
        {:ok, cursor2, tag_label(tag), nil}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_name(head, [{:symbol, name} | _]) when head in @naming_heads, do: name
  defp maybe_name(_head, _rest_children), do: nil

  # Generic head label for anything that isn't a symbol-headed list — kept
  # in lockstep with derive_head_name/1's AST-side classification below.
  defp tag_label({:symbol, text}), do: text
  defp tag_label({:list, _children}), do: "list"
  defp tag_label({:vector, _children}), do: "vector"
  defp tag_label({:map, _children}), do: "map"
  defp tag_label({:set, _children}), do: "set"
  defp tag_label({:short_fn, _children}), do: "short_fn"
  defp tag_label(:string), do: "string"
  defp tag_label(:regex_literal), do: "regex_literal"
  defp tag_label(:var), do: "var"
  defp tag_label(:quoted_symbol), do: "quoted_symbol"
  defp tag_label(:keyword), do: "keyword"
  defp tag_label(:number), do: "number"
  defp tag_label(:nil_literal), do: "nil"
  defp tag_label(:true_literal), do: "true"
  defp tag_label(:false_literal), do: "false"

  # ============================================================
  # Value dispatch — mirrors FastParser.do_parse_expr/2 clause-for-clause
  # ============================================================

  defp scan_value({"", offset}), do: {:error, %{reason: :unexpected_eof, offset: offset}}

  defp scan_value({"(" <> rest, offset}), do: scan_seq({rest, offset + 1}, ?), :list)
  defp scan_value({"[" <> rest, offset}), do: scan_seq({rest, offset + 1}, ?], :vector)
  defp scan_value({"{" <> rest, offset}), do: scan_seq({rest, offset + 1}, ?}, :map)

  defp scan_value({<<?#, ?{, rest::binary>>, offset}),
    do: scan_seq({rest, offset + 2}, ?}, :set)

  defp scan_value({"#(" <> rest, offset}), do: scan_seq({rest, offset + 2}, ?), :short_fn)

  defp scan_value({"#\"" <> rest, offset}),
    do: {rest, offset + 2} |> scan_string_body() |> tagged(:regex_literal)

  defp scan_value({"#'" <> rest, offset}), do: {rest, offset + 2} |> scan_var() |> tagged(:var)

  defp scan_value({"'" <> rest, offset}),
    do: {rest, offset + 1} |> scan_quoted_symbol() |> tagged(:quoted_symbol)

  defp scan_value({"##-Inf" <> rest, offset} = cursor) do
    if symbol_boundary?(rest), do: {:ok, {rest, offset + 6}, :number}, else: scan_symbol(cursor)
  end

  defp scan_value({"##Inf" <> rest, offset} = cursor) do
    if symbol_boundary?(rest), do: {:ok, {rest, offset + 5}, :number}, else: scan_symbol(cursor)
  end

  defp scan_value({"##NaN" <> rest, offset} = cursor) do
    if symbol_boundary?(rest), do: {:ok, {rest, offset + 5}, :number}, else: scan_symbol(cursor)
  end

  defp scan_value({"\"" <> rest, offset}),
    do: {rest, offset + 1} |> scan_string_body() |> tagged(:string)

  defp scan_value({":" <> _rest, _offset} = cursor),
    do: cursor |> scan_keyword() |> tagged(:keyword)

  # Character literals collapse to the same `:string` tag as regular
  # strings — see moduledoc design decision #2.
  defp scan_value({"\\" <> rest, offset}),
    do: {rest, offset + 1} |> scan_char_literal() |> tagged(:string)

  defp scan_value({"nil" <> rest, offset} = cursor) do
    if symbol_boundary?(rest),
      do: {:ok, {rest, offset + 3}, :nil_literal},
      else: scan_symbol(cursor)
  end

  defp scan_value({"true" <> rest, offset} = cursor) do
    if symbol_boundary?(rest),
      do: {:ok, {rest, offset + 4}, :true_literal},
      else: scan_symbol(cursor)
  end

  defp scan_value({"false" <> rest, offset} = cursor) do
    if symbol_boundary?(rest),
      do: {:ok, {rest, offset + 5}, :false_literal},
      else: scan_symbol(cursor)
  end

  defp scan_value({<<c, _rest::binary>>, _offset} = cursor) when c in ?0..?9 do
    cursor |> scan_number() |> tagged(:number)
  end

  defp scan_value({"-" <> <<c, _rest::binary>>, _offset} = cursor) when c in ?0..?9 do
    cursor |> scan_number() |> tagged(:number)
  end

  defp scan_value(cursor), do: scan_symbol(cursor)

  defp tagged({:ok, cursor2}, tag), do: {:ok, cursor2, tag}
  defp tagged({:error, _} = err, _tag), do: err

  # ============================================================
  # Sequences: list / vector / map / set / short-fn
  # ============================================================

  defp scan_seq(cursor, closer, kind) do
    case scan_children(cursor, closer, kind, []) do
      {:ok, cursor2, children} -> {:ok, cursor2, {kind, children}}
      {:error, _} = err -> err
    end
  end

  defp scan_children(cursor, closer, kind, acc) do
    cursor2 = skip_ws(cursor)

    case cursor2 do
      {<<^closer, rest::binary>>, offset} ->
        {:ok, {rest, offset + 1}, Enum.reverse(acc)}

      {"", offset} ->
        {:error, %{reason: :unclosed_form, kind: kind, offset: offset}}

      _ ->
        case scan_value(cursor2) do
          {:ok, cursor3, tag} -> scan_children(cursor3, closer, kind, [tag | acc])
          {:error, _} = err -> err
        end
    end
  end

  # ============================================================
  # Strings and regex literals — identical escape rules
  # ============================================================

  defp scan_string_body({"\"" <> rest, offset}), do: {:ok, {rest, offset + 1}}

  defp scan_string_body({"\\" <> rest, offset}) do
    case rest do
      <<c, _rest::binary>> when c in [?\n, ?\r] ->
        {:error, %{reason: :unterminated_string, offset: offset}}

      <<c::utf8, rest2::binary>> ->
        scan_string_body({rest2, offset + 1 + byte_size(<<c::utf8>>)})

      "" ->
        {:error, %{reason: :unterminated_string, offset: offset}}
    end
  end

  defp scan_string_body({"\n" <> rest, offset}), do: scan_string_body({rest, offset + 1})

  defp scan_string_body({<<c::utf8, rest::binary>>, offset}),
    do: scan_string_body({rest, offset + byte_size(<<c::utf8>>)})

  defp scan_string_body({"", offset}),
    do: {:error, %{reason: :unterminated_string, offset: offset}}

  # ============================================================
  # Character literals (cursor starts right AFTER the backslash)
  # ============================================================

  @named_char_literals ["newline", "space", "tab", "return", "backspace", "formfeed"]

  defp scan_char_literal({rest, offset}) do
    case Enum.find(@named_char_literals, &String.starts_with?(rest, &1)) do
      nil ->
        case rest do
          <<c::utf8, rest2::binary>> -> {:ok, {rest2, offset + byte_size(<<c::utf8>>)}}
          "" -> {:error, %{reason: :invalid_char_literal, offset: offset}}
        end

      name ->
        {:ok,
         {binary_part(rest, byte_size(name), byte_size(rest) - byte_size(name)),
          offset + byte_size(name)}}
    end
  end

  # ============================================================
  # Vars (#'name) and quoted symbols ('name)
  # ============================================================

  defp scan_var({<<c, _rest::binary>>, _offset} = cursor) when is_symbol_first(c) do
    {_name, cursor2} = take_while(cursor, &symbol_rest_char?/1)
    {:ok, cursor2}
  end

  defp scan_var({_rest, offset}), do: {:error, %{reason: :invalid_var, offset: offset}}

  defp scan_quoted_symbol({<<c, _rest::binary>>, _offset} = cursor) when is_symbol_first(c) do
    {_name, cursor2} = take_while(cursor, &symbol_rest_char?/1)
    {:ok, cursor2}
  end

  defp scan_quoted_symbol({<<c, _rest::binary>>, offset}) when c in [?(, ?[, ?{] do
    {:error, %{reason: :quoted_collection_not_supported, offset: offset}}
  end

  defp scan_quoted_symbol({_rest, offset}) do
    {:error, %{reason: :invalid_quoted_symbol, offset: offset}}
  end

  # ============================================================
  # Keywords
  # ============================================================

  defp scan_keyword({":" <> rest, offset}) do
    {name, cursor2} = take_while({rest, offset + 1}, &keyword_char?/1)

    if name == "" do
      {:error, %{reason: :invalid_keyword, offset: offset}}
    else
      {:ok, cursor2}
    end
  end

  # ============================================================
  # Numbers
  # ============================================================

  defp scan_number({"-" <> rest, offset}), do: scan_number_digits({rest, offset + 1})
  defp scan_number(cursor), do: scan_number_digits(cursor)

  defp scan_number_digits(cursor) do
    {_int, cursor2} = take_while(cursor, &digit?/1)

    cursor3 =
      cond do
        match_fraction?(cursor2) -> cursor2 |> take_fraction() |> take_valid_exponent()
        match_exponent?(cursor2) -> take_valid_exponent(cursor2)
        true -> cursor2
      end

    {:ok, cursor3}
  end

  defp match_fraction?({"." <> <<c, _rest::binary>>, _offset}), do: digit?(c)
  defp match_fraction?(_cursor), do: false

  defp match_exponent?({<<e, rest::binary>>, _offset}) when e in [?e, ?E] do
    case rest do
      <<c, _rest::binary>> when c in ?0..?9 -> true
      <<s, c, _rest::binary>> when s in [?+, ?-] and c in ?0..?9 -> true
      _ -> false
    end
  end

  defp match_exponent?(_cursor), do: false

  defp take_fraction({"." <> rest, offset}) do
    {_digits, cursor2} = take_while({rest, offset + 1}, &digit?/1)
    cursor2
  end

  defp take_valid_exponent(cursor) do
    if match_exponent?(cursor), do: take_exponent(cursor), else: cursor
  end

  defp take_exponent({<<e, rest::binary>>, offset}) when e in [?e, ?E] do
    cursor = {rest, offset + 1}

    cursor2 =
      case cursor do
        {<<s, rest2::binary>>, offset2} when s in [?+, ?-] -> {rest2, offset2 + 1}
        _ -> cursor
      end

    {_digits, cursor3} = take_while(cursor2, &digit?/1)
    cursor3
  end

  # ============================================================
  # Symbols
  # ============================================================

  defp scan_symbol({<<c, _rest::binary>>, _offset} = cursor) when is_symbol_first(c) do
    {name, cursor2} = take_while(cursor, &symbol_rest_char?/1)
    {:ok, cursor2, {:symbol, name}}
  end

  defp scan_symbol({_rest, offset}), do: {:error, %{reason: :unexpected_byte, offset: offset}}

  # ============================================================
  # Whitespace, commas, and `;` line comments
  # ============================================================

  defp skip_ws({<<c, rest::binary>>, offset}) when c in [?\s, ?\t, ?\r, ?,],
    do: skip_ws({rest, offset + 1})

  defp skip_ws({"\n" <> rest, offset}), do: skip_ws({rest, offset + 1})
  defp skip_ws({";" <> rest, offset}), do: skip_comment({rest, offset + 1})
  defp skip_ws(cursor), do: cursor

  defp skip_comment({"\n" <> rest, offset}), do: skip_ws({rest, offset + 1})
  defp skip_comment({"", offset}), do: {"", offset}

  defp skip_comment({<<c::utf8, rest::binary>>, offset}),
    do: skip_comment({rest, offset + byte_size(<<c::utf8>>)})

  # ============================================================
  # Byte-run helpers (ASCII-gated, matching FastParser's take_while_length)
  # ============================================================

  defp take_while({bin, offset}, predicate) do
    len = take_while_length(bin, predicate, 0)
    value = binary_part(bin, 0, len)
    rest = binary_part(bin, len, byte_size(bin) - len)
    {value, {rest, offset + len}}
  end

  defp take_while_length(<<c, rest::binary>>, predicate, len) when c < 128 do
    if predicate.(c), do: take_while_length(rest, predicate, len + 1), else: len
  end

  defp take_while_length(_bin, _predicate, len), do: len

  # ============================================================
  # Character classes — duplicated from FastParser (private there) on
  # purpose; the cross-check in verify_cross_check/2 is what keeps this
  # copy honest if the reader grammar ever moves.
  # ============================================================

  defp symbol_rest_char?(c),
    do:
      c in ?a..?z or c in ?A..?Z or c in ?0..?9 or
        c in [?+, ?-, ?*, ?/, ?<, ?>, ?=, ??, ?!, ?_, ?%, ?., ?&, ?']

  defp keyword_char?(c),
    do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?+, ?-, ?*, ?<, ?>, ?=, ??, ?!, ?_]

  defp digit?(c), do: c in ?0..?9

  defp symbol_boundary?(""), do: true
  defp symbol_boundary?(<<c, _rest::binary>>) when c < 128, do: not symbol_rest_char?(c)
  defp symbol_boundary?(_rest), do: true

  # ============================================================
  # Self-check 1: round-trip byte identity
  # ============================================================

  defp verify_roundtrip(source, %{forms: forms, trailing_gap: trailing_gap}) do
    rebuilt =
      forms
      |> Enum.flat_map(fn f -> [slice(source, f.gap), slice(source, f.span)] end)
      |> Kernel.++([slice(source, trailing_gap)])
      |> IO.iodata_to_binary()

    if rebuilt == source do
      :ok
    else
      {:error, %{reason: :scan_roundtrip_mismatch}}
    end
  end

  defp slice(source, {offset, length}), do: binary_part(source, offset, length)

  # ============================================================
  # Self-check 2: cross-check against PtcRunner.Lisp.Parser
  #
  # Independent derivation: this walks the PARSED AST (never touching raw
  # byte offsets, never calling tag_label/1 above), while scan_program/2
  # walks raw TEXT (never building an AST). Agreement between the two,
  # form by form, is the safety net.
  # ============================================================

  defp verify_cross_check(source, %{forms: forms}) do
    scanned = Enum.map(forms, &{&1.head, &1.name})

    case parser_derived_names(source) do
      {:ok, ^scanned} ->
        :ok

      {:ok, parsed} ->
        {:error, %{reason: :scan_cross_check_mismatch, scanned: scanned, parsed: parsed}}

      {:error, reason} ->
        {:error, %{reason: :scan_cross_check_parse_failed, detail: reason}}
    end
  end

  defp parser_derived_names(source) do
    case Parser.parse(source) do
      {:ok, nil} -> {:ok, []}
      {:ok, {:program, forms}} -> {:ok, Enum.map(forms, &derive_head_name/1)}
      {:ok, single_form} -> {:ok, [derive_head_name(single_form)]}
      {:error, reason} -> {:error, reason}
    end
  end

  # AST-side mirror of tag_label/1 — classifies the SAME way, from parsed
  # AST shapes instead of raw scan tags. Every clause here corresponds to
  # exactly one scan_value/1 tag above.
  defp derive_head_name({:list, [head_ast | rest]}) do
    case symbol_text(head_ast) do
      nil ->
        {"list", nil}

      head ->
        name = if head in @naming_heads, do: rest |> List.first() |> symbol_text(), else: nil
        {head, name}
    end
  end

  defp derive_head_name({:list, []}), do: {"list", nil}
  defp derive_head_name({:vector, _children}), do: {"vector", nil}
  defp derive_head_name({:map, _pairs}), do: {"map", nil}
  defp derive_head_name({:set, _children}), do: {"set", nil}
  defp derive_head_name({:short_fn, _children}), do: {"short_fn", nil}
  defp derive_head_name({:string, _value}), do: {"string", nil}
  defp derive_head_name({:regex_literal, _value}), do: {"regex_literal", nil}
  defp derive_head_name({:var, _name}), do: {"var", nil}
  defp derive_head_name({:quoted_symbol, _name}), do: {"quoted_symbol", nil}
  defp derive_head_name({:keyword, _name}), do: {"keyword", nil}
  defp derive_head_name(nil), do: {"nil", nil}
  defp derive_head_name(true), do: {"true", nil}
  defp derive_head_name(false), do: {"false", nil}
  defp derive_head_name(:infinity), do: {"number", nil}
  defp derive_head_name(:negative_infinity), do: {"number", nil}
  defp derive_head_name(:nan), do: {"number", nil}
  defp derive_head_name(n) when is_number(n), do: {"number", nil}
  defp derive_head_name({:symbol, _} = node), do: {symbol_text(node), nil}
  defp derive_head_name({:ns_symbol, _ns, _key} = node), do: {symbol_text(node), nil}
  defp derive_head_name({:turn_history, _n} = node), do: {symbol_text(node), nil}
  defp derive_head_name(_other), do: {nil, nil}

  defp symbol_text({:symbol, name}) when is_binary(name), do: name
  defp symbol_text({:symbol, name}) when is_atom(name), do: Atom.to_string(name)
  defp symbol_text({:ns_symbol, ns, key}), do: "#{atom_or_string(ns)}/#{atom_or_string(key)}"
  defp symbol_text({:turn_history, n}), do: "*#{n}"
  defp symbol_text(_other), do: nil

  defp atom_or_string(v) when is_binary(v), do: v
  defp atom_or_string(v) when is_atom(v), do: Atom.to_string(v)
end
