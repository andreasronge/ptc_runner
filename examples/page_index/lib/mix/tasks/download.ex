defmodule Mix.Tasks.Download do
  @shortdoc "Download FinanceBench PDFs for PageIndex example"
  @moduledoc """
  Downloads the required PDF files from FinanceBench for testing the PageIndex example.

  ## Usage

      mix download           # Download all required PDFs
      mix download --force   # Re-download even if files exist
      mix download --list    # List files without downloading

  ## Files

  Downloads 3M financial documents from the FinanceBench dataset:
  - 3M_2022_10K.pdf (1.6 MB) - Annual report for FY2022 questions
  - 3M_2018_10K.pdf (1.2 MB) - Annual report for baseline questions
  - 3M_2023Q2_10Q.pdf (5.3 MB) - Quarterly report for Q2 2023 questions

  Files are saved to `data/` and are gitignored.

  ## Source

  PDFs are from the FinanceBench dataset (MIT license):
  https://github.com/patronus-ai/financebench
  """

  use Mix.Task

  @base_url "https://raw.githubusercontent.com/patronus-ai/financebench/main/pdfs"
  @data_dir "data"

  @pdfs [
    {"3M_2022_10K.pdf", 1_655_681},
    {"3M_2018_10K.pdf", 1_252_586},
    {"3M_2023Q2_10Q.pdf", 5_287_301}
  ]

  @impl Mix.Task
  def run(args) do
    force = "--force" in args
    list_only = "--list" in args

    if list_only do
      list_files()
    else
      download_files(force)
    end
  end

  defp list_files do
    Mix.shell().info("\nFinanceBench PDFs for PageIndex example:\n")

    total =
      Enum.reduce(@pdfs, 0, fn {name, size}, acc ->
        exists = File.exists?(Path.join(@data_dir, name))
        status = if exists, do: "[exists]", else: "[missing]"
        Mix.shell().info("  #{status} #{name} (#{format_size(size)})")
        acc + size
      end)

    Mix.shell().info("\nTotal: #{format_size(total)}")
    Mix.shell().info("Directory: #{@data_dir}/")
  end

  defp download_files(force) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    File.mkdir_p!(@data_dir)

    Mix.shell().info("\nDownloading FinanceBench PDFs...\n")

    results =
      Enum.map(@pdfs, fn {name, expected_size} ->
        download_file(name, expected_size, force)
      end)

    succeeded = Enum.count(results, &(&1 == :ok))
    failed = Enum.count(results, &(&1 == :error))
    skipped = Enum.count(results, &(&1 == :skipped))

    Mix.shell().info("")

    if failed > 0 do
      Mix.shell().error("Downloaded: #{succeeded}, Skipped: #{skipped}, Failed: #{failed}")
      System.halt(1)
    else
      Mix.shell().info("Done! Downloaded: #{succeeded}, Skipped: #{skipped}")
    end
  end

  defp download_file(name, expected_size, force) do
    dest = Path.join(@data_dir, name)

    cond do
      File.exists?(dest) and not force ->
        Mix.shell().info("  ✓ #{name} (exists)")
        :skipped

      true ->
        url = "#{@base_url}/#{name}"
        Mix.shell().info("  ↓ #{name} (#{format_size(expected_size)})...")

        case do_download(url, dest) do
          :ok ->
            actual_size = File.stat!(dest).size

            if actual_size == expected_size do
              Mix.shell().info("    ✓ Downloaded")
              :ok
            else
              Mix.shell().info("    ✓ Downloaded (#{format_size(actual_size)})")
              :ok
            end

          {:error, reason} ->
            Mix.shell().error("    ✗ Failed: #{reason}")
            :error
        end
    end
  end

  defp do_download(url, dest) do
    ssl_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    url_charlist = String.to_charlist(url)

    case :httpc.request(:get, {url_charlist, []}, ssl_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        File.write!(dest, body)
        :ok

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
