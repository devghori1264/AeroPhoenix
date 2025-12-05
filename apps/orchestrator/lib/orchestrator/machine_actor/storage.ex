defmodule Orchestrator.MachineActor.Storage do
  require Logger

  @type conn :: Exqlite.Conn.t()
  @schema_version 1

  def db_path do
    Application.get_env(:orchestrator, :db_path, "orchestrator.db")
  end

  def db_path(machine_id) do
    data_dir = Application.get_env(:orchestrator, :machine_actor_data_dir, "data/machines")
    Path.join(data_dir, "#{machine_id}.db")
  end

  @spec init(String.t()) :: {:ok, conn()} | {:error, term()}
  def init(db_path) do
    db_path
    |> Path.dirname()
    |> File.mkdir_p()

    do_init_with_retry(db_path, 5)
  end

  defp do_init_with_retry(db_path, retries_left) do
    Logger.debug("Opening SQLite DB at #{db_path} (retries left: #{retries_left})")

    case Exqlite.Sqlite3.open(db_path) do
      {:ok, conn} ->
        Logger.debug("SQLite DB opened successfully")

        _ = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=MEMORY")
        _ = Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous=OFF")
        _ = Exqlite.Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")
        _ = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")

        check_sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'"
        case Exqlite.Sqlite3.prepare(conn, check_sql) do
          {:ok, stmt} ->
            Logger.debug("Prepare check_sql succeeded")
            Exqlite.Sqlite3.close(stmt)
          {:error, reason} ->
            Logger.error("Prepare check_sql failed: #{inspect(reason)}")
        end

        case ensure_schema(conn) do
          :ok ->
            Logger.debug("SQLite storage initialized for #{db_path}")
            {:ok, conn}

          {:error, reason} ->
            Logger.error("Schema initialization failed: #{inspect(reason)}")
            Exqlite.Sqlite3.close(conn)
            if retries_left > 0 do
              Process.sleep(100 * (6 - retries_left))
              do_init_with_retry(db_path, retries_left - 1)
            else
              {:error, reason}
            end
        end

      {:error, reason} ->
        Logger.error("Failed to open SQLite database: #{inspect(reason)}")
        if retries_left > 0 do
          Process.sleep(200 * (6 - retries_left))
          do_init_with_retry(db_path, retries_left - 1)
        else
          {:error, reason}
        end
    end
  end

  @spec load_metadata(conn()) :: {:ok, map()} | {:error, :not_found}
  def load_metadata(conn) do
    sql = """
    SELECT id, region, state, image, size_json, capabilities_json,
            created_at, updated_at, version
    FROM machines
    LIMIT 1
    """

    case query_rows(conn, sql) do
      {:ok, [row]} ->
        [id, region, state, image, size_json, cap_json, created_at, updated_at, version] = row

        state_atom =
          try do
            String.to_existing_atom(state)
          rescue
            ArgumentError -> String.to_atom(state)
          end

        capabilities =
          cap_json
          |> Jason.decode!()
          |> Enum.map(fn cap ->
            try do
              String.to_existing_atom(cap)
            rescue
              ArgumentError -> String.to_atom(cap)
            end
          end)

        metadata = %{
          id: id,
          region: region,
          state: state_atom,
          image: image,
          size: Jason.decode!(size_json, keys: :atoms),
          capabilities: capabilities,
          created_at: parse_datetime(created_at),
          updated_at: parse_datetime(updated_at),
          version: version
        }

        {:ok, metadata}

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Failed to load metadata", reason: inspect(reason))
        {:error, reason}
    end
  end

  @spec save_metadata(conn(), map()) :: :ok | {:error, term()}
  def save_metadata(conn, metadata) do
    sql = """
    REPLACE INTO machines (
      id, region, state, image, size_json, capabilities_json,
      created_at, updated_at, version
    ) VALUES (
      '#{metadata.id}',
      '#{metadata.region}',
      '#{Atom.to_string(metadata.state)}',
      #{if metadata.image, do: "'#{metadata.image}'", else: "NULL"},
      '#{Jason.encode!(metadata.size) |> String.replace("'", "''")}',
      '#{Jason.encode!(metadata.capabilities) |> String.replace("'", "''")}',
      '#{DateTime.to_iso8601(metadata.created_at)}',
      '#{DateTime.to_iso8601(metadata.updated_at)}',
      #{metadata.version}
    )
    """

    case exec_sql(conn, sql) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec close(conn()) :: :ok
  def close(conn) do
    Exqlite.Sqlite3.close(conn)
  end

  defp ensure_schema(conn) do
    check_sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'"

    case query_rows(conn, check_sql) do
      {:ok, []} ->
        Logger.info("Schema not found, creating...")
        create_schema(conn)

      {:ok, _} ->
        Logger.debug("Schema found, validating...")
        validate_schema_version(conn)

      {:error, reason} ->
        Logger.error("Failed to check schema: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_schema(conn) do
    version_table = """
    CREATE TABLE IF NOT EXISTS schema_version (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    )
    """

    machines_table = """
    CREATE TABLE IF NOT EXISTS machines (
      id TEXT PRIMARY KEY,
      region TEXT NOT NULL,
      state TEXT NOT NULL,
      image TEXT,
      size_json TEXT NOT NULL,
      capabilities_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      version INTEGER NOT NULL DEFAULT 1
    )
    """

    wal_table = """
    CREATE TABLE IF NOT EXISTS wal_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      operation_id TEXT NOT NULL UNIQUE,
      from_state TEXT NOT NULL,
      to_state TEXT NOT NULL,
      transition_type TEXT NOT NULL,
      opts_json TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('pending', 'completed', 'failed')),
      completed_at TEXT,
      error_reason TEXT
    )
    """

    wal_archive_table = """
    CREATE TABLE IF NOT EXISTS wal_entries_archive (
      id INTEGER PRIMARY KEY,
      operation_id TEXT NOT NULL,
      from_state TEXT NOT NULL,
      to_state TEXT NOT NULL,
      transition_type TEXT NOT NULL,
      opts_json TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      status TEXT NOT NULL,
      completed_at TEXT,
      error_reason TEXT
    )
    """

    idx_wal_status = """
    CREATE INDEX IF NOT EXISTS idx_wal_status_timestamp
    ON wal_entries(status, timestamp)
    WHERE status = 'pending'
    """

    idx_wal_op_id = """
    CREATE INDEX IF NOT EXISTS idx_wal_operation_id
    ON wal_entries(operation_id)
    """

    with :ok <- Exqlite.Sqlite3.execute(conn, version_table),
         :ok <- Exqlite.Sqlite3.execute(conn, machines_table),
         :ok <- Exqlite.Sqlite3.execute(conn, wal_table),
         :ok <- Exqlite.Sqlite3.execute(conn, wal_archive_table),
         :ok <- Exqlite.Sqlite3.execute(conn, idx_wal_status),
         :ok <- Exqlite.Sqlite3.execute(conn, idx_wal_op_id) do
      insert_version = """
      REPLACE INTO schema_version (version, applied_at)
      VALUES (?, ?)
      """

      case exec_sql(conn, insert_version, [
             @schema_version,
             DateTime.to_iso8601(DateTime.utc_now())
           ]) do
        {:ok, _} ->
          Logger.info("SQLite schema created", version: @schema_version)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_schema_version(conn) do
    sql = "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1"

    case query_rows(conn, sql) do
      {:ok, [[version]]} ->
        if version == @schema_version do
          :ok
        else
          Logger.warning("Schema version mismatch",
            expected: @schema_version,
            actual: version
          )

          :ok
        end

      {:ok, []} ->
        Logger.info("Schema version table empty, inserting version #{@schema_version}")
        insert_schema_version(conn)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_schema_version(conn) do
    sql = "INSERT INTO schema_version (version, applied_at) VALUES (#{@schema_version}, '#{DateTime.to_iso8601(DateTime.utc_now())}')"
    case exec_sql(conn, sql) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_datetime(iso8601_string) when is_binary(iso8601_string) do
    case DateTime.from_iso8601(iso8601_string) do
      {:ok, dt, _} ->
        dt

      {:error, :missing_offset} ->
        case DateTime.from_iso8601(iso8601_string <> "Z") do
          {:ok, dt, _} ->
            dt

          {:error, _} ->
            case NaiveDateTime.from_iso8601(iso8601_string) do
              {:ok, ndt} ->
                DateTime.from_naive!(ndt, "Etc/UTC")

              {:error, reason} ->
                raise "Failed to parse datetime: #{iso8601_string}, reason: #{inspect(reason)}"
            end
        end

      {:error, reason} ->
        raise "Failed to parse datetime: #{iso8601_string}, reason: #{inspect(reason)}"
    end
  end

  defp query_rows(conn, sql, params \\ []) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        result =
          with :ok <- bind_params(stmt, params),
               {:ok, rows} <- step_all(conn, stmt) do
            {:ok, rows}
          else
            error -> error
          end

        Exqlite.Sqlite3.close(stmt)
        result
      {:error, reason} ->
        Logger.error("query_rows prepare failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  def exec_sql(conn, sql, params \\ []) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        result =
          with :ok <- bind_params(stmt, params),
               :done <- Exqlite.Sqlite3.step(conn, stmt) do
            {:ok, []}
          else
            {:row, _} -> {:ok, []}
            error -> error
          end

        Exqlite.Sqlite3.close(stmt)
        result
      {:error, reason} ->
        Logger.error("exec_sql prepare failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def execute(conn, sql, params \\ []) do
    if String.starts_with?(String.upcase(String.trim(sql)), "SELECT") do
       query_rows(conn, sql, params)
    else
       exec_sql(conn, sql, params)
    end
  end

  defp bind_params(_stmt, []), do: :ok

  defp bind_params(stmt, params) do
    Exqlite.Sqlite3.bind(stmt, params)
  end

  defp step_all(conn, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      :done -> {:ok, Enum.reverse(acc)}
      {:row, row} -> step_all(conn, stmt, [row | acc])
      {:error, reason} -> {:error, reason}
    end
  end


end
