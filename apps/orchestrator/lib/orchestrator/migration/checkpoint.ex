defmodule Orchestrator.Migration.Checkpoint do
  @moduledoc """
  Represents a migration checkpoint.
  """
  defstruct [
    :id,
    :machine_id,
    :type,
    :size_bytes,
    :compressed_size_bytes,
    :checksum,
    :created_at,
    :parent_id,
    :data
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          machine_id: String.t(),
          type: :full | :incremental,
          size_bytes: non_neg_integer(),
          compressed_size_bytes: non_neg_integer(),
          checksum: String.t(),
          created_at: DateTime.t(),
          parent_id: String.t() | nil,
          data: binary()
        }
end
