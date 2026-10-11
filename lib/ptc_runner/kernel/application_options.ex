defmodule PtcRunner.Kernel.ApplicationOptions do
  @moduledoc false

  alias PtcRunner.Kernel.Limits

  @common_acquisition_options [:installed_limits, :input_authority, :input]
  @directory_shared_options @common_acquisition_options ++ [:component_override_descriptor]
  @directory_acquisition_options @directory_shared_options ++
                                   [:repl_interactive_loop, :omit_input]
  @memory_acquisition_options @common_acquisition_options ++ [:component_override]
  @directory_request_options @directory_shared_options ++
                               [:inspection_capture, :result_projection, :event_identity]
  @memory_request_options @memory_acquisition_options ++
                            [:inspection_capture, :result_projection, :event_identity]

  def validate(opts, kind) do
    allowed = allowed(kind)

    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        keys -- allowed != [] or length(keys) != MapSet.size(MapSet.new(keys)) ->
          {:error, :invalid_application_options}

        not valid_optional_installed_limits?(opts) ->
          {:error, :invalid_installed_limits}

        not valid_optional_boolean?(opts, :repl_interactive_loop) ->
          {:error, :invalid_application_options}

        not valid_optional_boolean?(opts, :omit_input) ->
          {:error, :invalid_application_options}

        true ->
          :ok
      end
    else
      {:error, :invalid_application_options}
    end
  end

  defp valid_optional_installed_limits?(opts) do
    case Keyword.fetch(opts, :installed_limits) do
      {:ok, limits} -> Limits.valid?(limits)
      :error -> true
    end
  end

  defp valid_optional_boolean?(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> true
      {:ok, value} when is_boolean(value) -> true
      _other -> false
    end
  end

  defp allowed(:directory_acquisition), do: @directory_acquisition_options
  defp allowed(:memory_acquisition), do: @memory_acquisition_options
  defp allowed(:directory_request), do: @directory_request_options
  defp allowed(:memory_request), do: @memory_request_options
end
