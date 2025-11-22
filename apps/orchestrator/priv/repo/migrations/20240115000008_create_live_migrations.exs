defmodule Orchestrator.Repo.Migrations.CreateLiveMigrations do
  use Ecto.Migration

  def change do
    create table(:live_migrations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :machine_id, :string, null: false
      add :source_region, :string, null: false
      add :target_region, :string, null: false
      add :phase, :string, null: false
      add :status, :string, null: false
      add :strategy, :string, null: false

      # Migration metrics
      add :bytes_transferred, :bigint, default: 0
      add :iterations_completed, :integer, default: 0
      add :downtime_ms, :integer
      add :total_duration_ms, :integer

      # Checkpoint references
      add :checkpoint_id, :string
      add :last_sync_at, :utc_datetime_usec

      # Error tracking
      add :error_message, :text
      add :rollback_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:live_migrations, [:machine_id])
    create index(:live_migrations, [:phase])
    create index(:live_migrations, [:status])
    create index(:live_migrations, [:source_region])
    create index(:live_migrations, [:target_region])
    create index(:live_migrations, [:inserted_at])
  end
end
