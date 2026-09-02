defmodule PtcRunner.LiveStatus.Target do
  @moduledoc """
  An explicit destination for one run's live-status frames.

  Hosts use a target when status should stay inside the current BEAM instead
  of being posted to the external Viewer URL configured by
  `PTC_VIEWER_URL`. Reporting remains best-effort: callback failures are
  contained and never affect the run.
  """

  @enforce_keys [:report]
  defstruct [:report, :label, append_external?: false]

  @opaque t :: %__MODULE__{
            report: (binary(), map() -> term()),
            label: binary() | nil,
            append_external?: boolean()
          }

  @spec new((binary(), map() -> term()), keyword()) ::
          {:ok, t()} | {:error, :invalid_live_status_target}
  def new(report, opts \\ [])

  def new(report, opts) when is_function(report, 2) and is_list(opts) do
    keys = Keyword.keys(opts)

    target = %__MODULE__{
      report: report,
      label: Keyword.get(opts, :label),
      append_external?: Keyword.get(opts, :append_external?, false)
    }

    if Keyword.keyword?(opts) and keys -- [:label, :append_external?] == [] and
         length(keys) == MapSet.size(MapSet.new(keys)) and valid?(target),
       do: {:ok, target},
       else: {:error, :invalid_live_status_target}
  end

  def new(_report, _opts), do: {:error, :invalid_live_status_target}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{report: report, label: label} = target) do
    Enum.sort(Map.keys(target)) == [:__struct__, :append_external?, :label, :report] and
      is_function(report, 2) and valid_label?(label) and is_boolean(target.append_external?)
  end

  def valid?(_target), do: false

  @spec label(term()) :: binary() | nil
  def label(%__MODULE__{label: label}), do: label
  def label(_target), do: nil

  @doc false
  def append_external?(%__MODULE__{append_external?: value}), do: value
  def append_external?(_target), do: false

  @spec report(term(), binary(), map()) :: :ok | :error
  def report(%__MODULE__{} = target, run_id, frame)
      when is_binary(run_id) and is_map(frame) do
    case target.report.(run_id, frame) do
      :error -> :error
      _result -> :ok
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  def report(_target, _run_id, _frame), do: :error

  @doc false
  @spec compose([t()]) :: {:ok, t()} | {:error, :invalid_live_status_target}
  def compose(targets) when is_list(targets) and targets != [] do
    if Enum.all?(targets, &valid?/1) do
      new(
        fn run_id, frame ->
          results = Enum.map(targets, &report(&1, run_id, frame))
          if Enum.all?(results, &(&1 == :ok)), do: :ok, else: :error
        end,
        label: Enum.find_value(targets, &label/1),
        append_external?: Enum.all?(targets, &append_external?/1)
      )
    else
      {:error, :invalid_live_status_target}
    end
  end

  def compose(_targets), do: {:error, :invalid_live_status_target}

  defp valid_label?(nil), do: true

  defp valid_label?(label),
    do: is_binary(label) and byte_size(label) in 1..256 and String.valid?(label)
end
