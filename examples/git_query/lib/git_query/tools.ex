defmodule GitQuery.Tools do
  @moduledoc """
  Safe git command wrappers for repository queries.

  All tools are read-only operations that return structured data.
  Each tool accepts a map with string keys.
  """

  # PTC-Lisp signatures for each tool (used by SubAgents)
  @signatures %{
    get_commits:
      {"(since :string?, until :string?, author :string?, path :string?, grep :string?, limit :int?) -> [{hash :string, author :string, date :string, subject :string}]",
       "Get commit history with optional filters. Date filters: '1 month ago', '2024-01-01'. Returns list of commits."},
    get_author_stats:
      {"(since :string?, until :string?, path :string?) -> [{author :string, email :string, count :int}]",
       "Get commit counts by author, sorted by count descending."},
    get_file_stats:
      {"(since :string?, until :string?, author :string?, limit :int?) -> [{file :string, change_count :int}]",
       "Get most frequently changed files, optionally filtered by author."},
    get_file_history:
      {"(file_path :string, limit :int?) -> [{hash :string, author :string, date :string, subject :string}]",
       "Get commit history for a specific file. Follows renames."},
    get_diff_stats:
      {"(from_ref :string?, to_ref :string?, since :string?, path :string?) -> {files_changed :int, insertions :int, deletions :int, files [{file :string, insertions :int, deletions :int}]}",
       "Get line change statistics between refs or for a time period."}
  }

  @doc "Get PTC-Lisp signatures for all tools"
  def signatures, do: @signatures

  def get_commits(params) do
    repo_path = Map.fetch!(params, "repo_path")
    since = Map.get(params, "since")
    until_date = Map.get(params, "until")
    author = Map.get(params, "author")
    path = Map.get(params, "path")
    grep = Map.get(params, "grep")
    limit = Map.get(params, "limit", 50)

    args =
      ["log", "--format=%H|%an|%ai|%s", "-n", to_string(limit)]
      |> maybe_add_arg("--since", since)
      |> maybe_add_arg("--until", until_date)
      |> maybe_add_arg("--author", author)
      |> maybe_add_arg("--grep", grep)
      |> maybe_add_path_arg(path)

    case run_git(repo_path, args) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_commit_line/1)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        %{error: reason}
    end
  end

  def get_author_stats(params) do
    repo_path = Map.fetch!(params, "repo_path")
    since = Map.get(params, "since")
    until_date = Map.get(params, "until")
    path = Map.get(params, "path")

    args =
      ["shortlog", "-sne", "HEAD"]
      |> maybe_add_arg("--since", since)
      |> maybe_add_arg("--until", until_date)
      |> maybe_add_path_arg(path)

    case run_git(repo_path, args) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_shortlog_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.count, :desc)

      {:error, reason} ->
        %{error: reason}
    end
  end

  def get_file_stats(params) do
    repo_path = Map.fetch!(params, "repo_path")
    since = Map.get(params, "since")
    until_date = Map.get(params, "until")
    author = Map.get(params, "author")
    limit = Map.get(params, "limit", 20)

    args =
      ["log", "--name-only", "--format="]
      |> maybe_add_arg("--since", since)
      |> maybe_add_arg("--until", until_date)
      |> maybe_add_arg("--author", author)

    case run_git(repo_path, args) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_file, count} -> count end, :desc)
        |> Enum.take(limit)
        |> Enum.map(fn {file, count} -> %{file: file, change_count: count} end)

      {:error, reason} ->
        %{error: reason}
    end
  end

  def get_file_history(params) do
    repo_path = Map.fetch!(params, "repo_path")
    file_path = Map.fetch!(params, "file_path")
    limit = Map.get(params, "limit", 20)

    args = ["log", "--format=%H|%an|%ai|%s", "-n", to_string(limit), "--follow", "--", file_path]

    case run_git(repo_path, args) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_commit_line/1)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        %{error: reason}
    end
  end

  def get_diff_stats(params) do
    repo_path = Map.fetch!(params, "repo_path")
    from_ref = Map.get(params, "from_ref")
    to_ref = Map.get(params, "to_ref", "HEAD")
    since = Map.get(params, "since")
    path = Map.get(params, "path")

    # If since is provided, find the first commit after that date
    from_ref =
      if since && !from_ref do
        case get_first_commit_since(repo_path, since) do
          {:ok, hash} -> "#{hash}^"
          _ -> nil
        end
      else
        from_ref
      end

    args =
      if from_ref do
        ["diff", "--stat", "--stat-width=200", "#{from_ref}..#{to_ref}"]
      else
        ["diff", "--stat", "--stat-width=200", to_ref]
      end

    args = maybe_add_path_arg(args, path)

    case run_git(repo_path, args) do
      {:ok, output} ->
        parse_diff_stat(output)

      {:error, reason} ->
        %{error: reason}
    end
  end

  # --- Private functions ---

  defp run_git(repo_path, args) do
    case System.cmd("git", args, cd: repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {error, _code} ->
        {:error, String.trim(error)}
    end
  end

  defp maybe_add_arg(args, _flag, nil), do: args
  defp maybe_add_arg(args, _flag, ""), do: args
  defp maybe_add_arg(args, flag, value), do: args ++ [flag, value]

  defp maybe_add_path_arg(args, nil), do: args
  defp maybe_add_path_arg(args, ""), do: args
  defp maybe_add_path_arg(args, path), do: args ++ ["--", path]

  defp parse_commit_line(line) do
    case String.split(line, "|", parts: 4) do
      [hash, author, date, subject] ->
        %{
          hash: String.slice(hash, 0, 8),
          author: author,
          date: date,
          subject: subject
        }

      _ ->
        nil
    end
  end

  defp parse_shortlog_line(line) do
    # Format: "  123\tAuthor Name <email@example.com>"
    case Regex.run(~r/^\s*(\d+)\s+(.+?)\s*<(.+?)>/, line) do
      [_, count, author, email] ->
        %{
          count: String.to_integer(count),
          author: String.trim(author),
          email: email
        }

      _ ->
        nil
    end
  end

  defp parse_diff_stat(output) do
    lines = String.split(output, "\n", trim: true)

    # The last line contains the summary: "X files changed, Y insertions(+), Z deletions(-)"
    {file_lines, summary_lines} = Enum.split(lines, -1)

    files =
      file_lines
      |> Enum.map(&parse_diff_file_line/1)
      |> Enum.reject(&is_nil/1)

    {files_changed, insertions, deletions} =
      case summary_lines do
        [summary] -> parse_diff_summary(summary)
        _ -> {length(files), 0, 0}
      end

    %{
      files_changed: files_changed,
      insertions: insertions,
      deletions: deletions,
      files: files
    }
  end

  defp parse_diff_file_line(line) do
    # Format: " path/to/file | 10 ++++----"
    case Regex.run(~r/^\s*(.+?)\s*\|\s*(\d+)\s*([+-]*)/, line) do
      [_, file, _changes, plusminus] ->
        insertions = String.graphemes(plusminus) |> Enum.count(&(&1 == "+"))
        deletions = String.graphemes(plusminus) |> Enum.count(&(&1 == "-"))

        %{
          file: String.trim(file),
          insertions: insertions,
          deletions: deletions
        }

      _ ->
        nil
    end
  end

  defp parse_diff_summary(summary) do
    files =
      case Regex.run(~r/(\d+)\s+files?\s+changed/, summary) do
        [_, n] -> String.to_integer(n)
        _ -> 0
      end

    insertions =
      case Regex.run(~r/(\d+)\s+insertions?/, summary) do
        [_, n] -> String.to_integer(n)
        _ -> 0
      end

    deletions =
      case Regex.run(~r/(\d+)\s+deletions?/, summary) do
        [_, n] -> String.to_integer(n)
        _ -> 0
      end

    {files, insertions, deletions}
  end

  defp get_first_commit_since(repo_path, since) do
    args = ["log", "--reverse", "--format=%H", "--since", since, "-n", "1"]

    case run_git(repo_path, args) do
      {:ok, ""} -> {:error, "No commits found since #{since}"}
      {:ok, hash} -> {:ok, String.trim(hash)}
      error -> error
    end
  end
end
