defmodule Orchestrator.MachineActor.Storage do
  require Logger

  @type conn :: Exqlite.Conn.t()
  @schema_version 1

  @spec init(String.t()) :: {:ok, conn()} | {:error, term()}
  def init(db_path) do
    case Exqlite.Sqlite3.open(db_path) do
      {:ok, conn} ->
        _ = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=DELETE")
        _ = Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous=FULL")
        _ = Exqlite.Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")
        _ = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")

        case ensure_schema(conn) do
          :ok ->
            Logger.debug("SQLite storage initialized", db_path: db_path)
            {:ok, conn}

          {:error, reason} ->
            Exqlite.Sqlite3.close(conn)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to open SQLite database",
          db_path: db_path,
          reason: inspect(reason)
        )

        {:error, reason}
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

        metadata = %{
          id: id,
          region: region,
          state: String.to_existing_atom(state),
          image: image,
          size: Jason.decode!(size_json, keys: :atoms),
          capabilities: Jason.decode!(cap_json) |> Enum.map(&String.to_existing_atom/1),
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

    case Exqlite.Sqlite3.execute(conn, sql) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec close(conn()) :: :ok
  def close(conn) do
    Exqlite.Sqlite3.close(conn)
  end

  defp ensure_schema(conn) do
    check_sql = """
    SELECT name FROM sqlite_master
    WHERE type='table' AND name='schema_version'
    """

    case Exqlite.Sqlite3.execute(conn, check_sql) do
      {:ok, []} ->
        create_schema(conn)

      {:ok, _} ->
        validate_schema_version(conn)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_schema(conn) do
    version_table = """
    CREATE TABLE schema_version (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    )
    """

    machines_table = """
    CREATE TABLE machines (
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
    CREATE TABLE wal_entries (
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
    CREATE TABLE wal_entries_archive (
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
    CREATE INDEX idx_wal_status_timestamp
    ON wal_entries(status, timestamp)
    WHERE status = 'pending'
    """

    idx_wal_op_id = """
    CREATE INDEX idx_wal_operation_id
    ON wal_entries(operation_id)
    """

    with :ok <- Exqlite.Sqlite3.execute(conn, version_table),
         :ok <- Exqlite.Sqlite3.execute(conn, machines_table),
         :ok <- Exqlite.Sqlite3.execute(conn, wal_table),
         :ok <- Exqlite.Sqlite3.execute(conn, wal_archive_table),
         :ok <- Exqlite.Sqlite3.execute(conn, idx_wal_status),
         :ok <- Exqlite.Sqlite3.execute(conn, idx_wal_op_id) do
      insert_version = """
      INSERT INTO schema_version (version, applied_at)
      VALUES (?, ?)
      """

      case execute(conn, insert_version, [
             @schema_version,
             DateTime.to_iso8601(DateTime.utc_now())
           ]) do
        :ok ->
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

    case Exqlite.Sqlite3.execute(conn, sql) do
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_datetime(iso8601_string) when is_binary(iso8601_string) do
    {:ok, dt, _} = DateTime.from_iso8601(iso8601_string)
    dt
  end

  @doc false
  def execute(conn, sql, params \\ []) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- bind_params(stmt, params),
         {:ok, rows} <- step_all(conn, stmt),
         :ok <- Exqlite.Sqlite3.close(stmt) do
      {:ok, rows}
    else
      {:error, reason} -> {:error, reason}
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

  defp query_rows(conn, sql) do
    execute(conn, sql, [])
  end
end
