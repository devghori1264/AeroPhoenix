defmodule Orchestrator.MachineActor.WAL do
  require Logger

  @type wal_entry :: %{
          operation_id: String.t(),
          from_state: atom(),
          to_state: atom(),
          transition_type: atom(),
          opts: keyword(),
          timestamp: DateTime.t(),
          status: :pending | :completed | :failed
        }

  @type replay_result :: {:ok, atom(), [wal_entry()]} | {:error, term()}
  @spec append(Exqlite.Conn.t(), wal_entry()) :: {:ok, non_neg_integer()} | {:error, term()}
  def append(conn, entry) do
    sql = """
    INSERT INTO wal_entries (
      operation_id, from_state, to_state, transition_type,
      opts_json, timestamp, status, error_reason
    ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
    """

    params = [
      entry.operation_id,
      Atom.to_string(entry.from_state),
      Atom.to_string(entry.to_state),
      Atom.to_string(entry.transition_type),
      Jason.encode!(entry.opts),
      DateTime.to_iso8601(entry.timestamp),
      "pending"
    ]

    case Orchestrator.MachineActor.Storage.execute(conn, sql, params) do
      {:ok, _rows} ->
        {:ok, [[seq]]} =
          Orchestrator.MachineActor.Storage.execute(conn, "SELECT last_insert_rowid()")

        {:ok, seq}

      {:error, reason} ->
        Logger.error("WAL append failed",
          operation_id: entry.operation_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  @spec mark_completed(Exqlite.Conn.t(), String.t(), atom() | nil) :: :ok | {:error, term()}
  def mark_completed(conn, operation_id, final_state \\ nil) do
    {sql, params} =
      if final_state do
        {"""
         UPDATE wal_entries
         SET status = 'completed',
             completed_at = ?,
             to_state = ?
         WHERE operation_id = ?
         """,
         [
           DateTime.to_iso8601(DateTime.utc_now()),
           Atom.to_string(final_state),
           operation_id
         ]}
      else
        {"""
         UPDATE wal_entries
         SET status = 'completed',
             completed_at = ?
         WHERE operation_id = ?
         """, [DateTime.to_iso8601(DateTime.utc_now()), operation_id]}
      end

    case Orchestrator.MachineActor.Storage.execute(conn, sql, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec mark_failed(Exqlite.Conn.t(), String.t(), term()) :: :ok | {:error, term()}
  def mark_failed(conn, operation_id, error_reason) do
    sql = """
    UPDATE wal_entries
    SET status = 'failed',
        error_reason = ?,
        completed_at = ?
    WHERE operation_id = ?
    """

    params = [
      inspect(error_reason),
      DateTime.to_iso8601(DateTime.utc_now()),
      operation_id
    ]

    case Orchestrator.MachineActor.Storage.execute(conn, sql, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec replay(Exqlite.Conn.t(), atom()) :: replay_result()
  def replay(conn, initial_state) do
    sql = """
    SELECT operation_id, from_state, to_state, transition_type,
           opts_json, timestamp, status, completed_at, error_reason
    FROM wal_entries
    ORDER BY id ASC
    """

    case Orchestrator.MachineActor.Storage.execute(conn, sql) do
      {:ok, rows} ->
        entries =
          Enum.map(rows, fn row ->
            [op_id, from, to, trans_type, opts_json, ts, status, completed_at, error] = row

            %{
              operation_id: op_id,
              from_state: String.to_existing_atom(from),
              to_state: String.to_existing_atom(to),
              transition_type: String.to_existing_atom(trans_type),
              opts: Jason.decode!(opts_json, keys: :atoms),
              timestamp: parse_datetime(ts),
              status: String.to_existing_atom(status),
              completed_at: completed_at && parse_datetime(completed_at),
              error_reason: error
            }
          end)

        {completed, pending} = Enum.split_with(entries, &(&1.status == :completed))

        final_state =
          Enum.reduce(completed, initial_state, fn entry, _current_state ->
            entry.to_state
          end)

        Logger.info("WAL replay finished",
          initial_state: initial_state,
          final_state: final_state,
          completed_count: length(completed),
          pending_count: length(pending)
        )

        {:ok, final_state, pending}

      {:error, reason} ->
        Logger.error("WAL replay failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  @spec replay_uncommitted_intents(Exqlite.Conn.t(), keyword()) ::
          {:ok,
           %{
             completed: [String.t()],
             rolled_back: [String.t()],
             conflicts: [String.t()]
           }}
          | {:error, term()}
  def replay_uncommitted_intents(conn, opts \\ []) do
    current_state = Keyword.get(opts, :current_state, :created)

    sql = """
    SELECT operation_id, from_state, to_state, transition_type,
           opts_json, timestamp, status
    FROM wal_entries
    WHERE status = 'pending'
    ORDER BY timestamp ASC
    """

    case Orchestrator.MachineActor.Storage.execute(conn, sql) do
      {:ok, rows} when rows == [] ->
        {:ok, %{completed: [], rolled_back: [], conflicts: [], final_state: current_state}}

      {:ok, rows} ->
        now = DateTime.utc_now()

        intents =
          Enum.map(rows, fn [op_id, from, to, trans_type, opts_json, ts, status] ->
            timestamp = parse_datetime(ts)

            %{
              operation_id: op_id,
              from_state: String.to_existing_atom(from),
              to_state: String.to_existing_atom(to),
              transition_type: String.to_existing_atom(trans_type),
              opts: Jason.decode!(opts_json, keys: :atoms),
              timestamp: timestamp,
              age_seconds: DateTime.diff(now, timestamp, :second),
              status: String.to_existing_atom(status)
            }
          end)

        Logger.warning("Found uncommitted WAL intents",
          count: length(intents),
          current_state: current_state
        )

        results =
          Enum.map(intents, fn intent ->
            decide_recovery_action(conn, intent, current_state)
          end)

        completed =
          results
          |> Enum.filter(&match?({:complete, _, _}, &1))
          |> Enum.map(fn {:complete, op_id, _} -> op_id end)

        rolled_back =
          results
          |> Enum.filter(&match?({:rollback, _, _}, &1))
          |> Enum.map(fn {:rollback, op_id, _reason} -> op_id end)

        conflicts =
          results
          |> Enum.filter(&match?({:conflict, _}, &1))
          |> Enum.map(fn {:conflict, op_id} -> op_id end)

        final_state =
          Enum.reduce(results, current_state, fn
            {:complete, _op_id, to_state}, _acc -> to_state
            _, acc -> acc
          end)

        Logger.info("Uncommitted intent replay complete",
          completed: length(completed),
          rolled_back: length(rolled_back),
          conflicts: length(conflicts),
          final_state: final_state
        )

        {:ok,
         %{
           completed: completed,
           rolled_back: rolled_back,
           conflicts: conflicts,
           final_state: final_state
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec decide_recovery_action(Exqlite.Conn.t(), map(), atom()) ::
          {:complete, String.t(), atom()}
          | {:rollback, String.t(), atom()}
          | {:conflict, String.t()}
  defp decide_recovery_action(conn, intent, current_state) do
    cond do
      intent.age_seconds < 5 ->
        Logger.info("Completing recent intent",
          operation_id: intent.operation_id,
          age_seconds: intent.age_seconds
        )

        mark_completed(conn, intent.operation_id)
        {:complete, intent.operation_id, intent.to_state}

      current_state == intent.to_state ->
        Logger.info("Intent already completed (state matches)",
          operation_id: intent.operation_id,
          current_state: current_state
        )

        mark_completed(conn, intent.operation_id)
        {:complete, intent.operation_id, intent.to_state}

      current_state == intent.from_state ->
        Logger.info("Completing safe intent",
          operation_id: intent.operation_id,
          from_state: intent.from_state,
          to_state: intent.to_state
        )

        mark_completed(conn, intent.operation_id)
        {:complete, intent.operation_id, intent.to_state}

      intent.age_seconds > 60 ->
        Logger.warning("Rolling back abandoned intent",
          operation_id: intent.operation_id,
          age_seconds: intent.age_seconds
        )

        mark_failed(conn, intent.operation_id, :abandoned_timeout)
        {:rollback, intent.operation_id, :timeout}

      intent.transition_type == :migrate ->
        case recover_migration_intent(conn, intent) do
          :completed -> {:complete, intent.operation_id, intent.to_state}
          :rolled_back -> {:rollback, intent.operation_id, :migration_failed}
        end

      true ->
        Logger.warning("Rolling back conflicting intent",
          operation_id: intent.operation_id,
          from_state: intent.from_state,
          to_state: intent.to_state,
          current_state: current_state
        )

        mark_failed(conn, intent.operation_id, :state_conflict)
        {:rollback, intent.operation_id, :state_conflict}
    end
  end

  @spec recover_migration_intent(Exqlite.Conn.t(), map()) :: :completed | :rolled_back
  defp recover_migration_intent(conn, intent) do
    dest_machine_id = get_in(intent.opts, [:dest_machine_id])
    migration_id = get_in(intent.opts, [:migration_id])

    if dest_machine_id && migration_id do
      if intent.age_seconds < 10 do
        Logger.info("Migration intent assumed completed",
          migration_id: migration_id,
          operation_id: intent.operation_id
        )

        mark_completed(conn, intent.operation_id)
        :completed
      else
        Logger.warning("Migration intent timed out, rolling back",
          migration_id: migration_id,
          operation_id: intent.operation_id
        )

        mark_failed(conn, intent.operation_id, :migration_timeout)
        :rolled_back
      end
    else
      mark_failed(conn, intent.operation_id, :invalid_migration_opts)
      :rolled_back
    end
  end

  @spec read_history(Exqlite.Conn.t(), keyword()) :: {:ok, [wal_entry()]} | {:error, term()}
  def read_history(conn, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    since = Keyword.get(opts, :since)
    status_filter = Keyword.get(opts, :status)

    base_sql = """
    SELECT operation_id, from_state, to_state, transition_type,
           opts_json, timestamp, status, completed_at, error_reason
    FROM wal_entries
    WHERE 1=1
    """

    {where_clauses, params} =
      {[], []}
      |> add_since_filter(since)
      |> add_status_filter(status_filter)

    final_sql =
      base_sql <>
        Enum.join(where_clauses, " ") <>
        " ORDER BY id DESC LIMIT ?"

    final_params = params ++ [limit]

    case Orchestrator.MachineActor.Storage.execute(conn, final_sql, final_params) do
      {:ok, rows} ->
        entries =
          Enum.map(rows, fn row ->
            [op_id, from, to, trans_type, opts_json, ts, status, completed_at, error] = row

            %{
              operation_id: op_id,
              from_state: String.to_existing_atom(from),
              to_state: String.to_existing_atom(to),
              transition_type: String.to_existing_atom(trans_type),
              opts: Jason.decode!(opts_json, keys: :atoms),
              timestamp: parse_datetime(ts),
              status: String.to_existing_atom(status),
              completed_at: completed_at && parse_datetime(completed_at),
              error_reason: error
            }
          end)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec archive_old_entries(Exqlite.Conn.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def archive_old_entries(conn, retention_days \\ 30) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-retention_days * 24 * 60 * 60, :second)
      |> DateTime.to_iso8601()

    archive_sql = """
    INSERT INTO wal_entries_archive
    SELECT * FROM wal_entries
    WHERE status IN ('completed', 'failed')
      AND completed_at < ?
    """

    delete_sql = """
    DELETE FROM wal_entries
    WHERE status IN ('completed', 'failed')
      AND completed_at < ?
    """

    with {:ok, _} <- Orchestrator.MachineActor.Storage.execute(conn, archive_sql, [cutoff]),
         {:ok, _} <- Orchestrator.MachineActor.Storage.execute(conn, delete_sql, [cutoff]) do
      {:ok, [[count]]} = Orchestrator.MachineActor.Storage.execute(conn, "SELECT changes()")

      Logger.info("WAL archival completed",
        archived_count: count,
        retention_days: retention_days
      )

      {:ok, count}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_since_filter({clauses, params}, nil), do: {clauses, params}

  defp add_since_filter({clauses, params}, since_dt) do
    {clauses ++ [" AND timestamp >= ?"], params ++ [DateTime.to_iso8601(since_dt)]}
  end

  defp add_status_filter({clauses, params}, nil), do: {clauses, params}

  defp add_status_filter({clauses, params}, status) do
    {clauses ++ [" AND status = ?"], params ++ [Atom.to_string(status)]}
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
end
