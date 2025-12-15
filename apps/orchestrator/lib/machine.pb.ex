defmodule Aerophoenix.Machine.MigrationStrategy do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:STOP_AND_MOVE, 0)
  field(:LIVE_MIGRATION, 1)
  field(:CLONE_AND_REDIRECT, 2)
end

defmodule Aerophoenix.Machine.MigrationPhase do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:PHASE_UNKNOWN, 0)
  field(:PHASE_VALIDATING, 1)
  field(:PHASE_PREPARING_SOURCE, 2)
  field(:PHASE_CREATING_TARGET, 3)
  field(:PHASE_TRANSFERRING_STATE, 4)
  field(:PHASE_VERIFYING_STATE, 5)
  field(:PHASE_NETWORK_CUTOVER, 6)
  field(:PHASE_CLEANUP, 7)
  field(:PHASE_COMPLETED, 8)
  field(:PHASE_FAILED, 9)
  field(:PHASE_ROLLING_BACK, 10)
end

defmodule Aerophoenix.Machine.MigrationState do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:STATE_PENDING, 0)
  field(:STATE_IN_PROGRESS, 1)
  field(:STATE_COMPLETED, 2)
  field(:STATE_FAILED, 3)
  field(:STATE_ROLLED_BACK, 4)
end

defmodule Aerophoenix.Machine.PingRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3
end

defmodule Aerophoenix.Machine.PingResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:msg, 1, type: :string)
end

defmodule Aerophoenix.Machine.CreateRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:name, 1, type: :string)
  field(:region, 2, type: :string)
end

defmodule Aerophoenix.Machine.CreateResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:id, 1, type: :string)
  field(:status, 2, type: :string)
end

defmodule Aerophoenix.Machine.GetRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:id, 1, type: :string)
end

defmodule Aerophoenix.Machine.GetResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:id, 1, type: :string)
  field(:status, 2, type: :string)
  field(:region, 3, type: :string)
end

defmodule Aerophoenix.Machine.ActionRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:id, 1, type: :string)
end

defmodule Aerophoenix.Machine.ActionResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:result, 1, type: :string)
end

defmodule Aerophoenix.Machine.MigrateRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:machine_id, 1, type: :string, json_name: "machineId")
  field(:target_region, 2, type: :string, json_name: "targetRegion")
  field(:strategy, 3, type: Aerophoenix.Machine.MigrationStrategy, enum: true)
  field(:options, 4, type: Aerophoenix.Machine.MigrationOptions)
end

defmodule Aerophoenix.Machine.MigrationOptions.MetadataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Aerophoenix.Machine.MigrationOptions do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:timeout_seconds, 1, type: :int64, json_name: "timeoutSeconds")
  field(:preserve_ip, 2, type: :bool, json_name: "preserveIp")
  field(:skip_state_verification, 3, type: :bool, json_name: "skipStateVerification")

  field(:metadata, 4,
    repeated: true,
    type: Aerophoenix.Machine.MigrationOptions.MetadataEntry,
    map: true
  )
end

defmodule Aerophoenix.Machine.MigrateResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:migration_id, 1, type: :string, json_name: "migrationId")

  field(:current_phase, 2,
    type: Aerophoenix.Machine.MigrationPhase,
    json_name: "currentPhase",
    enum: true
  )

  field(:message, 3, type: :string)
  field(:estimated_duration_ms, 4, type: :int64, json_name: "estimatedDurationMs")
end

defmodule Aerophoenix.Machine.MigrationStatusRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:migration_id, 1, type: :string, json_name: "migrationId")
end

defmodule Aerophoenix.Machine.MigrationStatusResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:migration_id, 1, type: :string, json_name: "migrationId")
  field(:phase, 2, type: Aerophoenix.Machine.MigrationPhase, enum: true)
  field(:state, 3, type: Aerophoenix.Machine.MigrationState, enum: true)
  field(:source_region, 4, type: :string, json_name: "sourceRegion")
  field(:target_region, 5, type: :string, json_name: "targetRegion")
  field(:bytes_transferred, 6, type: :int64, json_name: "bytesTransferred")
  field(:total_bytes, 7, type: :int64, json_name: "totalBytes")
  field(:steps, 8, repeated: true, type: Aerophoenix.Machine.MigrationStepStatus)
  field(:error_message, 9, type: :string, json_name: "errorMessage")
  field(:started_at, 10, type: :int64, json_name: "startedAt")
  field(:completed_at, 11, type: :int64, json_name: "completedAt")
end

defmodule Aerophoenix.Machine.MigrationStepStatus do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:step_name, 1, type: :string, json_name: "stepName")
  field(:completed, 2, type: :bool)
  field(:duration_ms, 3, type: :int64, json_name: "durationMs")
  field(:error, 4, type: :string)
end

defmodule Aerophoenix.Machine.MigrationProgressEvent do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:migration_id, 1, type: :string, json_name: "migrationId")
  field(:phase, 2, type: Aerophoenix.Machine.MigrationPhase, enum: true)
  field(:progress_percent, 3, type: :int32, json_name: "progressPercent")
  field(:message, 4, type: :string)
  field(:timestamp, 5, type: :int64)
end

defmodule Aerophoenix.Machine.PTYRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:machine_id, 1, type: :string, json_name: "machineId")
  field(:shell, 2, type: :string)
  field(:cwd, 3, type: :string)
  field(:rows, 4, type: :int32)
  field(:cols, 5, type: :int32)
  field(:env, 6, repeated: true, type: Aerophoenix.Machine.EnvVar)
end

defmodule Aerophoenix.Machine.EnvVar do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Aerophoenix.Machine.PTYInput do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:data, 1, type: :string)
end

defmodule Aerophoenix.Machine.PTYResize do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:rows, 1, type: :int32)
  field(:cols, 2, type: :int32)
end

defmodule Aerophoenix.Machine.PTYOutput do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field(:data, 1, type: :string)
  field(:exit_code, 2, type: :int32, json_name: "exitCode")
end

defmodule Aerophoenix.Machine.MachineService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "aerophoenix.machine.MachineService",
    protoc_gen_elixir_version: "0.15.0"

  rpc(:Ping, Aerophoenix.Machine.PingRequest, Aerophoenix.Machine.PingResponse)

  rpc(:CreateMachine, Aerophoenix.Machine.CreateRequest, Aerophoenix.Machine.CreateResponse)

  rpc(:GetMachine, Aerophoenix.Machine.GetRequest, Aerophoenix.Machine.GetResponse)

  rpc(:StartMachine, Aerophoenix.Machine.ActionRequest, Aerophoenix.Machine.ActionResponse)

  rpc(:StopMachine, Aerophoenix.Machine.ActionRequest, Aerophoenix.Machine.ActionResponse)

  rpc(:MigrateMachine, Aerophoenix.Machine.MigrateRequest, Aerophoenix.Machine.MigrateResponse)

  rpc(
    :GetMigrationStatus,
    Aerophoenix.Machine.MigrationStatusRequest,
    Aerophoenix.Machine.MigrationStatusResponse
  )

  rpc(
    :StreamMigrationProgress,
    Aerophoenix.Machine.MigrationStatusRequest,
    stream(Aerophoenix.Machine.MigrationProgressEvent)
  )
end

defmodule Aerophoenix.Machine.MachineService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Aerophoenix.Machine.MachineService.Service
end

defmodule Aerophoenix.Machine.DebugService.Service do
  @moduledoc false

  use GRPC.Service, name: "aerophoenix.machine.DebugService", protoc_gen_elixir_version: "0.15.0"

  rpc(:StartPTY, Aerophoenix.Machine.PTYRequest, stream(Aerophoenix.Machine.PTYOutput))
end

defmodule Aerophoenix.Machine.DebugService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Aerophoenix.Machine.DebugService.Service
end
