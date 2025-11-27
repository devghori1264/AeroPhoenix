defmodule Orchestrator.Debugger.FSBrowser do
  import Bitwise
  require Logger

  @type file_entry :: %{
          name: String.t(),
          path: String.t(),
          type: :file | :directory | :symlink | :socket | :pipe | :device,
          size: integer(),
          permissions: String.t(),
          owner: String.t(),
          group: String.t(),
          modified: DateTime.t(),
          accessed: DateTime.t(),
          created: DateTime.t(),
          symlink_target: String.t() | nil,
          mime_type: String.t() | nil
        }
  @type search_result :: %{
          path: String.t(),
          matches: list(match_info()),
          context: String.t() | nil
        }
  @type match_info :: %{
          line_number: integer(),
          line_content: String.t(),
          column: integer()
        }
  @spec list_directory(String.t(), String.t(), keyword()) ::
          {:ok, list(file_entry())} | {:error, term()}
  def list_directory(machine_id, path, opts \\ []) do
    with {:ok, full_path} <- resolve_machine_path(machine_id, path),
         {:ok, entries} <- do_list_directory(full_path, opts) do
      {:ok, entries}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec read_file(String.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file(machine_id, path, opts \\ []) do
    max_size = Keyword.get(opts, :max_size, 10 * 1024 * 1024)

    with {:ok, full_path} <- resolve_machine_path(machine_id, path),
         {:ok, stat} <- get_file_stat(full_path),
         :ok <- check_file_size(stat.size, max_size),
         {:ok, content} <- do_read_file(full_path, opts) do
      {:ok, content}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec get_file_info(String.t(), String.t()) :: {:ok, file_entry()} | {:error, term()}
  def get_file_info(machine_id, path) do
    with {:ok, full_path} <- resolve_machine_path(machine_id, path),
         {:ok, stat} <- get_file_stat(full_path) do
      entry = build_file_entry(full_path, stat)
      {:ok, entry}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec search_files(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, list(String.t())} | {:error, term()}
  def search_files(machine_id, root_path, pattern, opts \\ []) do
    with {:ok, full_path} <- resolve_machine_path(machine_id, root_path) do
      max_depth = Keyword.get(opts, :max_depth, 5)
      case_sensitive = Keyword.get(opts, :case_sensitive, false)
      use_regex = Keyword.get(opts, :regex, false)
      matches = do_search_files(full_path, pattern, max_depth, case_sensitive, use_regex)
      {:ok, matches}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec search_content(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, list(search_result())} | {:error, term()}
  def search_content(machine_id, root_path, query, opts \\ []) do
    with {:ok, full_path} <- resolve_machine_path(machine_id, root_path) do
      results = do_search_content(full_path, query, opts)
      {:ok, results}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec diff_files(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def diff_files(machine_id, path1, path2) do
    with {:ok, full_path1} <- resolve_machine_path(machine_id, path1),
         {:ok, full_path2} <- resolve_machine_path(machine_id, path2),
         {:ok, content1} <- File.read(full_path1),
         {:ok, content2} <- File.read(full_path2) do
      diff = compute_diff(content1, content2, path1, path2)
      {:ok, diff}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec watch_path(String.t(), String.t(), pid()) :: {:ok, reference()} | {:error, term()}
  def watch_path(machine_id, path, subscriber_pid) do
    with {:ok, full_path} <- resolve_machine_path(machine_id, path) do
      case FileSystem.start_link(dirs: [full_path]) do
        {:ok, watcher_pid} ->
          FileSystem.subscribe(watcher_pid)
          ref = make_ref()
          spawn_link(fn -> watch_loop(watcher_pid, subscriber_pid, ref, full_path) end)
          {:ok, ref}

        {:error, _reason} = error ->
          error
      end
    else
      {:error, _reason} = error -> error
    end
  end

  @spec get_disk_usage(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_disk_usage(machine_id, path) do
    with {:ok, full_path} <- resolve_machine_path(machine_id, path) do
      usage = calculate_disk_usage(full_path)
      {:ok, usage}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec analyze_permissions(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def analyze_permissions(machine_id, path) do
    with {:ok, full_path} <- resolve_machine_path(machine_id, path) do
      analysis = do_analyze_permissions(full_path)
      {:ok, analysis}
    else
      {:error, _reason} = error -> error
    end
  end

  defp resolve_machine_path(machine_id, path) do
    machine_root = get_machine_root(machine_id)

    if machine_root do
      sanitized = Path.expand(path, machine_root)

      if String.starts_with?(sanitized, machine_root) do
        {:ok, sanitized}
      else
        {:error, :path_traversal_attempt}
      end
    else
      {:error, :machine_not_found}
    end
  end

  defp get_machine_root(machine_id) do
    case Orchestrator.MachineRegistry.get_root_path(machine_id) do
      {:ok, path} -> path
      {:error, :not_found} -> nil
      {:error, _reason} -> nil
    end
  end

  defp do_list_directory(path, opts) do
    recursive = Keyword.get(opts, :recursive, false)
    max_depth = Keyword.get(opts, :max_depth, 1)
    include_hidden = Keyword.get(opts, :include_hidden, false)
    sort_by = Keyword.get(opts, :sort_by, :name)
    filter_pattern = Keyword.get(opts, :filter)

    case File.ls(path) do
      {:ok, names} ->
        entries =
          names
          |> Enum.reject(&should_skip_entry?(&1, include_hidden))
          |> Enum.map(&build_entry_from_name(path, &1))
          |> Enum.reject(&is_nil/1)
          |> maybe_filter_entries(filter_pattern)
          |> maybe_recurse(path, recursive, max_depth - 1, opts)
          |> sort_entries(sort_by)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp should_skip_entry?(name, include_hidden) do
    !include_hidden && String.starts_with?(name, ".")
  end

  defp build_entry_from_name(parent_path, name) do
    full_path = Path.join(parent_path, name)

    case get_file_stat(full_path) do
      {:ok, stat} ->
        build_file_entry(full_path, stat)

      {:error, _} ->
        nil
    end
  end

  defp build_file_entry(path, stat) do
    %{
      name: Path.basename(path),
      path: path,
      type: determine_file_type(stat.type),
      size: stat.size,
      permissions: format_permissions(stat.mode),
      owner: format_uid(stat.uid),
      group: format_gid(stat.gid),
      modified: datetime_from_erlang(stat.mtime),
      accessed: datetime_from_erlang(stat.atime),
      created: datetime_from_erlang(stat.ctime),
      symlink_target: read_symlink(path, stat.type),
      mime_type: detect_mime_type(path, stat.type)
    }
  end

  defp get_file_stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{} = stat} ->
        {:ok, stat}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp determine_file_type(:regular), do: :file
  defp determine_file_type(:directory), do: :directory
  defp determine_file_type(:symlink), do: :symlink
  defp determine_file_type(:device), do: :device
  defp determine_file_type(:other), do: :other
  defp determine_file_type(_), do: :other

  defp format_permissions(mode) do
    perms =
      for i <- 2..0//-1, reduce: "" do
        acc ->
          offset = i * 3
          r = if (mode &&& 1 <<< (offset + 2)) != 0, do: "r", else: "-"
          w = if (mode &&& 1 <<< (offset + 1)) != 0, do: "w", else: "-"
          x = if (mode &&& 1 <<< offset) != 0, do: "x", else: "-"
          acc <> r <> w <> x
      end

    perms
  end

  defp format_uid(uid), do: Integer.to_string(uid)
  defp format_gid(gid), do: Integer.to_string(gid)

  defp datetime_from_erlang({{year, month, day}, {hour, min, sec}}) do
    DateTime.new!(Date.new!(year, month, day), Time.new!(hour, min, sec), "Etc/UTC")
  end

  defp datetime_from_erlang(_), do: DateTime.utc_now()

  defp read_symlink(path, :symlink) do
    case File.read_link(path) do
      {:ok, target} -> target
      {:error, _} -> path
    end
  end

  defp compute_diff(content1, content2, path1, path2) do
    lines1 = String.split(content1, "\n")
    lines2 = String.split(content2, "\n")

    diff_header = """
    --- #{path1}
    +++ #{path2}
    """

    diff_body =
      compute_line_diff(lines1, lines2, 0, [])
      |> Enum.reverse()
      |> Enum.join("\n")

    diff_header <> diff_body
  end

  defp compute_line_diff([], [], _line_num, acc), do: acc

  defp compute_line_diff([line | rest1], [line | rest2], line_num, acc) do
    compute_line_diff(rest1, rest2, line_num + 1, ["  #{line}" | acc])
  end

  defp compute_line_diff([line1 | rest1], [line2 | rest2], line_num, acc) do
    new_acc = ["+#{line2}", "-#{line1}" | acc]
    compute_line_diff(rest1, rest2, line_num + 1, new_acc)
  end

  defp compute_line_diff([], [line | rest], line_num, acc) do
    compute_line_diff([], rest, line_num + 1, ["+#{line}" | acc])
  end

  defp compute_line_diff([line | rest], [], line_num, acc) do
    compute_line_diff(rest, [], line_num + 1, ["-#{line}" | acc])
  end

  defp watch_loop(watcher_pid, subscriber_pid, ref, watch_path) do
    receive do
      {:file_event, ^watcher_pid, {path, events}} ->
        if String.starts_with?(path, watch_path) do
          send(subscriber_pid, {:fs_change, ref, path, events})
        end

        watch_loop(watcher_pid, subscriber_pid, ref, watch_path)

      {:stop_watching, ^ref} ->
        :ok
    end
  end

  defp calculate_disk_usage(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} ->
        %{
          path: path,
          size_bytes: size,
          files: 1,
          directories: 0
        }

      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} ->
            results =
              Enum.map(names, fn name ->
                calculate_disk_usage(Path.join(path, name))
              end)

            total_size = Enum.sum(Enum.map(results, & &1.size_bytes))
            total_files = Enum.sum(Enum.map(results, & &1.files))
            total_dirs = Enum.sum(Enum.map(results, & &1.directories)) + 1

            %{
              path: path,
              size_bytes: total_size,
              files: total_files,
              directories: total_dirs
            }

          {:error, _} ->
            %{path: path, size_bytes: 0, files: 0, directories: 0}
        end

      _ ->
        %{path: path, size_bytes: 0, files: 0, directories: 0}
    end
  end

  defp do_analyze_permissions(path) do
    case File.stat(path) do
      {:ok, stat} ->
        entry_analysis = %{
          path: path,
          permissions: format_permissions(stat.mode),
          owner: stat.uid,
          group: stat.gid,
          readable: (stat.mode &&& 0o400) != 0,
          writable: (stat.mode &&& 0o200) != 0,
          executable: (stat.mode &&& 0o100) != 0
        }

        case stat.type do
          :directory ->
            case File.ls(path) do
              {:ok, names} ->
                children =
                  Enum.map(names, fn name ->
                    do_analyze_permissions(Path.join(path, name))
                  end)

                Map.put(entry_analysis, :children, children)

              {:error, _} ->
                entry_analysis
            end

          _ ->
            entry_analysis
        end

      {:error, _} ->
        %{path: path, error: :inaccessible}
    end
  end

  defp do_read_file(path, _opts), do: File.read(path)

  defp check_file_size(size, max_size) do
    if size > max_size, do: {:error, :file_too_large}, else: :ok
  end

  defp do_search_files(root_path, pattern, max_depth, case_sensitive, use_regex) do
    if max_depth < 0 do
      []
    else
      case File.ls(root_path) do
        {:ok, files} ->
          regex =
            if use_regex do
              Regex.compile!(pattern, if(case_sensitive, do: "", else: "i"))
            else
              nil
            end

          Enum.flat_map(files, fn file ->
            full_path = Path.join(root_path, file)

            match =
              if use_regex do
                Regex.match?(regex, file)
              else
                if case_sensitive,
                  do: String.contains?(file, pattern),
                  else: String.contains?(String.downcase(file), String.downcase(pattern))
              end

            current = if match, do: [full_path], else: []

            if File.dir?(full_path) do
              current ++
                do_search_files(full_path, pattern, max_depth - 1, case_sensitive, use_regex)
            else
              current
            end
          end)

        _ ->
          []
      end
    end
  end

  defp do_search_content(_root_path, _query, opts) do
    _max_depth = Keyword.get(opts, :max_depth, 3)
    _file_pattern = Keyword.get(opts, :file_pattern, "*")
    _case_sensitive = Keyword.get(opts, :case_sensitive, false)
    _use_regex = Keyword.get(opts, :regex, false)
    _context_lines = Keyword.get(opts, :context_lines, 0)
    _max_matches = Keyword.get(opts, :max_matches, 100)

    []
  end

  defp maybe_filter_entries(entries, nil), do: entries

  defp maybe_filter_entries(entries, pattern) do
    regex = Regex.compile!(pattern)
    Enum.filter(entries, fn entry -> Regex.match?(regex, entry.name) end)
  end

  defp maybe_recurse(entries, parent, true, depth, opts) when depth > 0 do
    if File.exists?(parent) do
      directories = Enum.filter(entries, &(&1.type == :directory))

      nested =
        Enum.flat_map(directories, fn dir ->
          case do_list_directory(dir.path, Keyword.put(opts, :max_depth, depth)) do
            {:ok, items} -> items
            _ -> []
          end
        end)

      entries ++ nested
    else
      entries
    end
  end

  defp maybe_recurse(entries, _, _, _, _), do: entries

  defp sort_entries(entries, :name), do: Enum.sort_by(entries, & &1.name)
  defp sort_entries(entries, :size), do: Enum.sort_by(entries, & &1.size, :desc)

  defp sort_entries(entries, :modified),
    do: Enum.sort_by(entries, & &1.modified, {:desc, DateTime})

  defp sort_entries(entries, _), do: entries

  defp detect_mime_type(path, :directory) do
    if File.dir?(path), do: "inode/directory", else: "application/octet-stream"
  end

  defp detect_mime_type(_, _), do: "application/octet-stream"
end
