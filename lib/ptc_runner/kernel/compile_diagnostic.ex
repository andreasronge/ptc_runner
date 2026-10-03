defmodule PtcRunner.Kernel.CompileDiagnostic do
  @moduledoc """
  Closed projection policy for structured bundle-derived diagnostic messages.

  Compiler-rendered messages never cross the command boundary. This module
  admits only exact, bounded detail shapes whose names use the PTC-Lisp symbol
  grammar, and rebuilds messages from literals after every submitted name is
  found verbatim in the component source. An unknown-namespace message also
  requires the compiler's available-namespace list to equal the runtime's
  canonical public list. It bounds capability names already attested by a
  frozen bundle before they enter a missing-requirement message. Anything else
  retains the fixed catalog message.
  """

  alias PtcRunner.Kernel.CapabilityRequirementDiagnostic
  alias PtcRunner.Kernel.DiagnosticPattern
  alias PtcRunner.Lisp.CoreAST
  alias PtcRunner.Lisp.Format.SymbolRef
  alias PtcRunner.Lisp.NamespaceDiagnostic

  @max_names 8
  @max_name_bytes 128
  @max_message_bytes 1_100
  @symbol_first "[A-Za-z+*\\/<>=?!_%.&-]"
  @symbol_rest "[A-Za-z0-9+*\\/<>=?!_%.&'-]"
  @symbol_pattern @symbol_first <> @symbol_rest <> "{0,127}"
  @unqualified_symbol_first "[A-Za-z+*<>=?!_%.&-]"
  @unqualified_symbol_rest "[A-Za-z0-9+*<>=?!_%.&'-]"
  @unqualified_symbol_pattern @unqualified_symbol_first <> @unqualified_symbol_rest <> "{0,127}"

  @unbound_templates [
    [{:literal, "Undefined variable: "}, {:slot, :names, :text, @symbol_pattern}],
    [
      {:literal, "Undefined variables: "},
      {:slot, :names, :text, @symbol_pattern <> "(, #{@symbol_pattern}){1,7}"}
    ]
  ]
  @duplicate_template [
    {:literal, "Duplicate definition: "},
    {:slot, :namespace, :text, @unqualified_symbol_pattern},
    {:literal, "/"},
    {:slot, :name, :text, @unqualified_symbol_pattern}
  ]
  @requirement_singular "Missing capability requirement: "
  @requirement_plural "Missing capability requirements: "

  @doc false
  @spec bounded_details(term(), term()) :: {:ok, map()} | :error
  def bounded_details(:unbound_var, %{unbound_names: names} = details)
      when map_size(details) == 1 do
    case bounded_names(names, @max_names, []) do
      {:ok, bounded} -> {:ok, %{unbound_names: bounded}}
      :error -> :error
    end
  end

  def bounded_details(
        :duplicate_ref,
        %{duplicate_namespace: namespace, duplicate_name: name} = details
      )
      when map_size(details) == 2 do
    if valid_unqualified_name?(namespace) and valid_unqualified_name?(name),
      do: {:ok, %{duplicate_namespace: namespace, duplicate_name: name}},
      else: :error
  end

  def bounded_details(
        :unknown_namespace,
        %{
          rejected_namespace: namespace,
          available_namespaces: available_namespaces
        } = details
      )
      when map_size(details) == 2 do
    if valid_unqualified_name?(namespace) and
         available_namespaces == NamespaceDiagnostic.available_namespaces() do
      {:ok,
       %{
         rejected_namespace: namespace,
         available_namespaces: available_namespaces
       }}
    else
      :error
    end
  end

  def bounded_details(_reason, _details), do: :error

  @doc "Rebuilds one public compiler message from admitted submitted-source names."
  @spec rebuild(term(), term(), term()) :: {:ok, binary()} | :error
  def rebuild(:unbound_var, details, source) when is_binary(source) do
    with {:ok, %{unbound_names: names}} <- bounded_details(:unbound_var, details),
         true <- Enum.all?(names, &String.contains?(source, &1)) do
      {:ok, unbound_message(names)}
    else
      _invalid -> :error
    end
  end

  def rebuild(:duplicate_ref, details, source) when is_binary(source) do
    with {:ok, %{duplicate_namespace: namespace, duplicate_name: name}} <-
           bounded_details(:duplicate_ref, details),
         true <- String.contains?(source, namespace),
         true <- String.contains?(source, name) do
      {:ok, DiagnosticPattern.render(@duplicate_template, %{namespace: namespace, name: name})}
    else
      _invalid -> :error
    end
  end

  def rebuild(:unknown_namespace, details, source) when is_binary(source) do
    with {:ok,
          %{
            rejected_namespace: namespace,
            available_namespaces: available_namespaces
          }} <- bounded_details(:unknown_namespace, details),
         true <- String.contains?(source, namespace <> "/"),
         message = NamespaceDiagnostic.message(namespace, available_namespaces),
         true <- valid_message?(:unknown_namespace, message) do
      {:ok, message}
    else
      _invalid -> :error
    end
  end

  def rebuild(_reason, _details, _source), do: :error

  @doc false
  @spec capability_requirement_message(term()) :: {:ok, binary()} | :error
  def capability_requirement_message(names) do
    CapabilityRequirementDiagnostic.message(
      names,
      @requirement_singular,
      @requirement_plural
    )
  end

  @doc false
  @spec valid_message?(atom(), term()) :: boolean()
  def valid_message?(:undefined_variable, message) when is_binary(message) do
    byte_size(message) <= @max_message_bytes and valid_unbound_message?(message)
  end

  def valid_message?(:duplicate_definition, message) do
    case DiagnosticPattern.parse(@duplicate_template, message) do
      {:ok, %{namespace: namespace, name: name}} ->
        valid_unqualified_name?(namespace) and valid_unqualified_name?(name) and
          CoreAST.valid_prelude_ref?(namespace <> "/" <> name)

      :error ->
        false
    end
  end

  def valid_message?(:unknown_namespace, message) when is_binary(message) do
    with true <- byte_size(message) <= @max_message_bytes,
         {:ok, namespace} <- NamespaceDiagnostic.rejected_namespace(message) do
      valid_unqualified_name?(namespace)
    else
      _invalid -> false
    end
  end

  def valid_message?(:capability_requirement_missing, message) when is_binary(message) do
    CapabilityRequirementDiagnostic.valid_message?(
      message,
      @requirement_singular,
      @requirement_plural
    )
  end

  def valid_message?(_code, _message), do: false

  @doc false
  @spec message_schema(atom(), binary()) :: map()
  def message_schema(:undefined_variable, fallback),
    do: %{
      "oneOf" => [
        %{"const" => fallback} | Enum.map(@unbound_templates, &dynamic_message_schema/1)
      ]
    }

  def message_schema(:duplicate_definition, fallback),
    do: %{"oneOf" => [%{"const" => fallback}, dynamic_message_schema(@duplicate_template)]}

  def message_schema(:unknown_namespace, fallback),
    do: %{
      "oneOf" => [
        %{"const" => fallback},
        dynamic_message_schema(NamespaceDiagnostic.template(@unqualified_symbol_pattern))
      ]
    }

  def message_schema(:capability_requirement_missing, fallback) do
    CapabilityRequirementDiagnostic.message_schema(
      fallback,
      @requirement_singular,
      @requirement_plural
    )
  end

  def message_schema(_code, fallback), do: %{"const" => fallback}

  defp bounded_names([], _remaining, []), do: :error
  defp bounded_names([], _remaining, names), do: {:ok, Enum.reverse(names)}
  defp bounded_names([_name | _rest], 0, _names), do: :error

  defp bounded_names([name | rest], remaining, names) do
    if valid_name?(name),
      do: bounded_names(rest, remaining - 1, [name | names]),
      else: :error
  end

  defp bounded_names(_names, _remaining, _bounded), do: :error

  defp valid_name?(name),
    do: SymbolRef.valid_name?(name) and byte_size(name) <= @max_name_bytes

  defp valid_unqualified_name?(name),
    do: valid_name?(name) and not String.contains?(name, "/")

  defp unbound_message(names) do
    template =
      if length(names) == 1, do: hd(@unbound_templates), else: List.last(@unbound_templates)

    DiagnosticPattern.render(template, %{names: Enum.join(names, ", ")})
  end

  defp valid_unbound_message?(message) do
    Enum.any?(@unbound_templates, fn template ->
      with {:ok, %{names: joined}} <- DiagnosticPattern.parse(template, message),
           {:ok, names} <- bounded_names(String.split(joined, ", "), @max_names, []) do
        unbound_message(names) == message
      else
        :error -> false
      end
    end)
  end

  defp dynamic_message_schema(template),
    do: DiagnosticPattern.exact_message_schema(@max_message_bytes, template)
end
