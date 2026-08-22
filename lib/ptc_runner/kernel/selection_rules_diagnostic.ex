defmodule PtcRunner.Kernel.SelectionRulesDiagnostic do
  @moduledoc """
  Closed messages for provider-selection rule failures.

  Messages name only sealed selection-rule fields, sealed named sets, and a
  closed rule vocabulary. Rejected values, caller-authored keys, and
  installation aliases never cross this boundary.
  """

  alias PtcRunner.Kernel.DiagnosticPattern

  @field "[a-z][a-z0-9._-]{0,127}"
  @field_name ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @unknown_property "the provider selection contains an unknown property"
  @prefix "the provider selection field "
  @field_invalid_suffix " is invalid"
  @members_suffix " contains a name outside its allowed set"
  @subset_middle " must be a subset of "
  @write_required_suffix " is required because the installation maps a write"
  @required_when_middle " is required when the "
  @required_when_suffix " set is nonempty"
  @required_suffix " is required"
  @ceiling_suffix " exceeds an installed or context ceiling"
  @max_field_bytes 128
  @max_message_bytes byte_size(@prefix) + @max_field_bytes +
                       byte_size(@required_when_middle) + @max_field_bytes +
                       byte_size(@required_when_suffix)

  @type rejection ::
          :unknown_property
          | {:field, binary()}
          | {:members, binary()}
          | {:required, binary()}
          | {:subset_of, binary(), binary()}
          | {:required_when_set_nonempty, binary(), binary()}
          | {:ceiling, binary()}

  @doc "Renders one closed selection-rule rejection."
  @spec message(term()) :: {:ok, binary()} | :error
  def message(:unknown_property), do: {:ok, @unknown_property}

  def message({:field, field}), do: field_message(field, @field_invalid_suffix)
  def message({:members, field}), do: field_message(field, @members_suffix)
  def message({:required, field}), do: field_message(field, @required_suffix)
  def message({:ceiling, field}), do: field_message(field, @ceiling_suffix)

  def message({:subset_of, child, parent})
      when is_binary(child) and is_binary(parent) do
    if valid_name?(child) and valid_name?(parent) do
      {:ok, @prefix <> child <> @subset_middle <> parent}
    else
      :error
    end
  end

  def message({:required_when_set_nonempty, field, "write"}) when is_binary(field) do
    field_message(field, @write_required_suffix)
  end

  def message({:required_when_set_nonempty, field, set})
      when is_binary(field) and is_binary(set) do
    if valid_name?(field) and valid_name?(set) do
      {:ok, @prefix <> field <> @required_when_middle <> set <> @required_when_suffix}
    else
      :error
    end
  end

  def message(_rejection), do: :error

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    case parse(message) do
      {:ok, rejection} -> message(rejection) == {:ok, message}
      :error -> false
    end
  end

  def valid_message?(_message), do: false

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    %{
      "oneOf" => [
        %{"const" => fallback},
        %{"const" => @unknown_property},
        field_pattern(@field_invalid_suffix),
        field_pattern(@members_suffix),
        pattern(
          DiagnosticPattern.exact(
            DiagnosticPattern.escape(@prefix) <>
              @field <>
              DiagnosticPattern.escape(@subset_middle) <> @field
          )
        ),
        field_pattern(@write_required_suffix),
        pattern(
          DiagnosticPattern.exact(
            DiagnosticPattern.escape(@prefix) <>
              @field <>
              DiagnosticPattern.escape(@required_when_middle) <>
              @field <> DiagnosticPattern.escape(@required_when_suffix)
          )
        ),
        field_pattern(@required_suffix),
        field_pattern(@ceiling_suffix)
      ]
    }
  end

  defp field_message(field, suffix) when is_binary(field) and is_binary(suffix) do
    if valid_name?(field), do: {:ok, @prefix <> field <> suffix}, else: :error
  end

  defp field_message(_field, _suffix), do: :error

  defp parse(@unknown_property), do: {:ok, :unknown_property}

  defp parse(@prefix <> rest) do
    cond do
      String.ends_with?(rest, @write_required_suffix) ->
        parse_field(rest, @write_required_suffix, :required_when_write)

      String.ends_with?(rest, @members_suffix) ->
        parse_field(rest, @members_suffix, :members)

      String.ends_with?(rest, @field_invalid_suffix) ->
        parse_field(rest, @field_invalid_suffix, :field)

      String.ends_with?(rest, @ceiling_suffix) ->
        parse_field(rest, @ceiling_suffix, :ceiling)

      String.ends_with?(rest, @required_when_suffix) ->
        parse_required_when(rest)

      String.ends_with?(rest, @required_suffix) ->
        parse_field(rest, @required_suffix, :required)

      String.contains?(rest, @subset_middle) ->
        parse_subset(rest)

      true ->
        :error
    end
  end

  defp parse(_message), do: :error

  defp parse_field(rest, suffix, kind) do
    field = String.replace_suffix(rest, suffix, "")

    if valid_name?(field) and field <> suffix == rest do
      case kind do
        :required_when_write -> {:ok, {:required_when_set_nonempty, field, "write"}}
        other -> {:ok, {other, field}}
      end
    else
      :error
    end
  end

  defp parse_subset(rest) do
    case String.split(rest, @subset_middle, parts: 2) do
      [child, parent] ->
        if valid_name?(child) and valid_name?(parent) and
             child <> @subset_middle <> parent == rest,
           do: {:ok, {:subset_of, child, parent}},
           else: :error

      _other ->
        :error
    end
  end

  defp parse_required_when(rest) do
    inner = String.replace_suffix(rest, @required_when_suffix, "")

    case String.split(inner, @required_when_middle, parts: 2) do
      [field, set] ->
        if valid_name?(field) and valid_name?(set) and set != "write" and
             field <> @required_when_middle <> set <> @required_when_suffix == rest,
           do: {:ok, {:required_when_set_nonempty, field, set}},
           else: :error

      _other ->
        :error
    end
  end

  defp pattern(body) when is_binary(body) do
    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => @max_message_bytes,
      "pattern" => body
    }
  end

  defp field_pattern(suffix) when is_binary(suffix) do
    pattern(
      DiagnosticPattern.exact(
        DiagnosticPattern.escape(@prefix) <> @field <> DiagnosticPattern.escape(suffix)
      )
    )
  end

  defp valid_name?(name), do: name =~ @field_name
end
