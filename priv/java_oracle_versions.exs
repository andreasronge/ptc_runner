%{
  java: %{
    distribution: "temurin",
    vendor: "Eclipse Adoptium",
    feature: 21,
    runtime: "21.0.11+10",
    setup_java: "21.0.11+10.0.LTS",
    mise: "temurin-21.0.11+10.0.LTS"
  },
  clojure: "1.12.5",
  babashka: "1.4.192",
  # Release archive SHA-256 pins; update together with the Babashka version.
  babashka_sha256: %{
    {:linux, :aarch64} => "da4a7660ba5449922db46bc74966f2bb1041340edaf1b107fd6af66464764e97",
    {:linux, :amd64} => "d8371697a727495749f9481414a2fdba5fe702dfc1b74a8ec58195f0a646abd5",
    {:macos, :aarch64} => "9ed01a7f36e26274d1ba5c5881c04c2866caa5c4b4ed9b447cb47978f44846a6",
    {:macos, :amd64} => "8aaba607989944cdcef53964d7322abad7ec46db1fdf5bcc94b3bf02cdc7b4b2"
  }
}
