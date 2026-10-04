defmodule Mix.Tasks.Ptc.InstallBabashkaTest do
  # async: false — reenables a Mix task, mutating the global Mix.TasksServer run-state (class D).
  use ExUnit.Case, async: false
  @moduletag :operator

  alias Mix.Tasks.Ptc.InstallBabashka

  test "rejects versions without a pinned digest before downloading" do
    assert_raise Mix.Error, ~r/No pinned Babashka checksum/, fn ->
      InstallBabashka.run(["--version", "9.9.999", "--force"])
    end
  end

  @tag :tmp_dir
  test "rejects a release-supplied digest and restricts curl to HTTPS", %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    payload = "compromised archive"
    digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    log = Path.join(dir, "curl-args")
    curl = Path.join(bin, "curl")

    File.write!(curl, """
    #!/bin/sh
    printf '%s\n' "$*" >> '#{log}'
    destination=''
    head=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --head) head=true ;;
        -o|--output) shift; destination="$1" ;;
      esac
      url="$1"
      shift
    done
    if [ "$head" = true ]; then
      printf '%s' "$url"
    else
      case "$url" in
        *.sha256) printf '%s' '#{digest}' > "$destination" ;;
        *) printf '%s' '#{payload}' > "$destination" ;;
      esac
    fi
    """)

    File.chmod!(curl, 0o700)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)
    on_exit(fn -> System.put_env("PATH", previous_path) end)

    File.cd!(dir, fn ->
      assert_raise Mix.Error, ~r/SHA-256 mismatch/, fn ->
        InstallBabashka.run(["--force"])
      end
    end)

    requests = File.read!(log) |> String.split("\n", trim: true)
    refute Enum.any?(requests, &String.contains?(&1, ".sha256"))
    assert Enum.all?(requests, &String.contains?(&1, "--proto =https"))
    refute File.exists?(Path.join(dir, "_build/tools/bb"))
  end

  test "rejects unsafe version strings before downloading" do
    for version <- ["../1.4.192", "1.4.192/asset", "v1.4.192", "1.4"] do
      Mix.Task.reenable("ptc.install_babashka")

      assert_raise Mix.Error, ~r/Invalid Babashka version/, fn ->
        InstallBabashka.run(["--version", version, "--force"])
      end
    end
  end
end
