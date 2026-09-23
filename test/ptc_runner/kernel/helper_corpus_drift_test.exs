defmodule PtcRunner.Kernel.HelperCorpusDriftTest do
  use ExUnit.Case, async: true

  @corpus Path.expand("../../../scripts/labs/helper-corpus/corpus", __DIR__)
  @preludes Path.expand("../../../priv/preludes/kernel", __DIR__)

  test "each frozen helper bundle is the shipped prelude plus only its corpus entry" do
    subjects = @corpus |> Path.join("index.json") |> File.read!() |> Jason.decode!()

    for subject <- subjects["subjects"] do
      bundle = Path.join([@corpus, subject, "oracle-bundle"])
      manifest = bundle |> Path.join("ptc.json") |> File.read!() |> Jason.decode!()
      [%{"id" => id, "path" => path}] = manifest["workflow"]["components"]
      shipped = File.read!(Path.join(@preludes, id <> ".clj"))
      frozen = File.read!(Path.join(bundle, path))

      assert String.starts_with?(frozen, shipped),
             "#{subject}: frozen #{id} no longer matches priv/preludes/kernel/#{id}.clj; " <>
               "regenerate with `mix run scripts/labs/helper-corpus/run.exs`"

      entry = binary_part(frozen, byte_size(shipped), byte_size(frozen) - byte_size(shipped))

      assert entry =~ ~r/\A\n\(defn corpus \[input\]\s+\(return\s.*\)\n\z/s and
               length(String.split(entry, "(def")) == 2,
             "#{subject}: frozen bundle adds more than its corpus entry"
    end
  end
end
