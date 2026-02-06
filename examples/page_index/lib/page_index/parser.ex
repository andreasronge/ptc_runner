defmodule PageIndex.Parser do
  @moduledoc """
  PDF text extraction using pdfplumber via PdfExtractor.

  Provides `extract_pages/1` which returns page text with 1-based page numbers.
  """

  @doc """
  Extracts text from each page of the PDF.
  Returns a list of {page_number, text} tuples with 1-based page numbers
  (matching printed PDF page numbers).
  """
  def extract_pages(pdf_path) do
    # Use longer timeout for large PDFs (5 minutes)
    case GenServer.call(PdfExtractor, {:extract_text, [pdf_path, []]}, 300_000) do
      {:ok, pages_map} ->
        # pdf_extractor returns 0-based page numbers; normalize to 1-based
        pages =
          pages_map
          |> Enum.sort_by(fn {page_num, _} -> page_num end)
          |> Enum.map(fn {page_num, text} -> {page_num + 1, text} end)

        {:ok, pages}

      {:error, reason} ->
        {:error, "Failed to extract PDF: #{inspect(reason)}"}
    end
  end
end
