defmodule PtcRunnerMcp.Credentials.Redactor do
  @moduledoc """
  Substring-replaces every plaintext value registered in the
  `PtcRunnerMcp.Credentials` redaction-set ETS table with the literal
  string `"[REDACTED]"`.

  This is the **defense-in-depth** filter wired into `Log`, `TraceFile`,
  `TracePayload`, and `UpstreamCalls` per
  `Plans/http-transport-credentials.md` §7.5.1. The primary safety
  guarantee is structural (resolved bindings live only in the
  Credentials state, the redaction set, and the in-flight `Req`
  request struct — see §7.5.3); this filter catches accidental leaks
  through code paths that violate that structure.

  ## Robustness

  `scrub/1` is a plain function call — it does **not** route through
  the `Credentials` GenServer. It reads ETS directly via the table
  name returned by `PtcRunnerMcp.Credentials.table_name/0`.

  Critically, `scrub/1` is **safe to call when `Credentials` has not
  been started**: many test contexts wire `Log` / `TraceFile` /
  `UpstreamCalls` without booting `Credentials`. When the named ETS
  table does not exist, `scrub/1` returns its input unchanged.

  ## Plaintext, not hashes

  The redaction-set holds **plaintext bytes** keyed by themselves
  (`{plaintext :: binary, true}`). A SHA-256 of the secret would not
  let us substring-match a log line containing the secret — we'd have
  to hash every candidate substring of every line, which is
  quadratic and absurd. See §7.5 of the spec.

  ## Longest-first replacement

  When two registered secrets are substrings of each other (e.g.
  `"foo"` and `"foobar"`), order matters: replacing `"foo"` first
  turns `"foobar"` into `"[REDACTED]bar"` and the longer secret never
  matches. We sort by `byte_size/1` descending before replacing so
  the longer (more specific) match wins.
  """

  alias PtcRunnerMcp.Credentials

  @placeholder "[REDACTED]"

  @doc """
  The literal substituted in place of every registered plaintext.
  """
  @spec placeholder() :: String.t()
  def placeholder, do: @placeholder

  @doc """
  Substring-replace every plaintext registered in the redaction set
  with `"[REDACTED]"`.

  Accepts a binary or iodata. iodata is converted to a binary first.

  Returns the input unchanged when the redaction-set ETS table does
  not exist (i.e. `PtcRunnerMcp.Credentials` has not booted yet, or
  has crashed). This makes the filter safe to wire into the four hot
  emission paths (Log/TraceFile/TracePayload/UpstreamCalls) without
  forcing every test that exercises those paths to also boot
  `Credentials`.
  """
  @spec scrub(String.t() | iodata()) :: String.t()
  def scrub(value) when is_binary(value) do
    case secrets() do
      [] -> value
      secrets -> Enum.reduce(secrets, value, &replace_one/2)
    end
  end

  def scrub(value) when is_list(value) do
    scrub(IO.iodata_to_binary(value))
  end

  # Read the redaction-set ETS table once. Returns a list of
  # plaintext binaries sorted longest-first (so a longer match wins
  # over a shorter substring of itself).
  #
  # `:ets.info/2` is the cheapest way to test for table existence
  # without raising; an absent named table returns `:undefined`.
  defp secrets do
    table = Credentials.table_name()

    case :ets.info(table, :size) do
      :undefined ->
        []

      0 ->
        []

      _size ->
        # `:ets.match/2` with `{:"$1", :_}` would also work, but
        # `tab2list/1` is simpler and the table is guaranteed small
        # (one row per binding × rotations). Wrap in try/rescue as
        # belt-and-suspenders for the race where the owning
        # GenServer dies between the `:ets.info/2` check and here.
        try do
          table
          |> :ets.tab2list()
          |> Enum.flat_map(fn
            {plaintext, true} when is_binary(plaintext) and plaintext != "" -> [plaintext]
            _ -> []
          end)
          |> Enum.sort_by(&byte_size/1, :desc)
        rescue
          ArgumentError -> []
        end
    end
  end

  defp replace_one(secret, acc) when is_binary(secret) and is_binary(acc) do
    String.replace(acc, secret, @placeholder)
  end
end
