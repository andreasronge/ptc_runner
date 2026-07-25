%{
  version: "0.1.0",
  tag_prefix: "ptc_runner_launcher-v",
  macos_deployment_target: "15.0",
  precompiled_targets: %{
    {:unix, :darwin} => %{
      "aarch64-apple-darwin" => {"gcc", "g++", "<%= cc %> -arch arm64", "<%= cxx %> -arch arm64"}
    },
    {:unix, :linux} => %{
      "x86_64-linux-gnu" => "x86_64-linux-gnu-"
    }
  }
}
