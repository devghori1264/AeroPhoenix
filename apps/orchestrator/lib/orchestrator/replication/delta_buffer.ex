defmodule Orchestrator.Replication.DeltaBuffer do
  require Logger
  alias Orchestrator.Replication.HybridLogicalClock

  @default_max_size_bytes 64 * 1024
  @default_max_operations 1000
  @compression_level 6

  @type operation ::
          {:increment, key :: atom(), value :: integer()}
          | {:set, key :: atom(), value :: term(), hlc :: HybridLogicalClock.t()}
          | {:add, key :: atom(), element :: term(), tag :: term()}
          | {:remove, key :: atom(), element :: term(), tag :: term()}

  @type t :: %__MODULE__{
          operations: [operation()],
          size_bytes: non_neg_integer(),
          machine_id: String.t(),
          max_size_bytes: pos_integer(),
          max_operations: pos_integer(),
          total_flushes: non_neg_integer(),
          total_operations: non_neg_integer(),
          total_bytes_uncompressed: non_neg_integer(),
          total_bytes_compressed: non_neg_integer()
        }

  defstruct operations: [],
            size_bytes: 0,
            machine_id: nil,
            max_size_bytes: @default_max_size_bytes,
            max_operations: @default_max_operations,
            total_flushes: 0,
            total_operations: 0,
            total_bytes_uncompressed: 0,
            total_bytes_compressed: 0

  @spec init(keyword()) :: t()
  def init(opts) do
    machine_id = Keyword.fetch!(opts, :machine_id)

    %__MODULE__{
      machine_id: machine_id,
      max_size_bytes: Keyword.get(opts, :max_size_bytes, @default_max_size_bytes),
      max_operations: Keyword.get(opts, :max_operations, @default_max_operations)
    }
  end

  @spec add(t(), operation()) :: {:ok, t()}
  def add(buffer, operation) do
    operations = [operation | buffer.operations]
    size_bytes = buffer.size_bytes + estimate_operation_size(operation)

    new_buffer = %{buffer | operations: operations, size_bytes: size_bytes}
    {:ok, new_buffer}
  end

  @spec flush(t()) :: {:ok, list(operation()) | nil, t()}
  def flush(buffer) do
    if length(buffer.operations) == 0 do
      {:ok, nil, buffer}
    else
      operations = Enum.reverse(buffer.operations)
      count = length(operations)

      {uncompressed_size, compressed_size} = compress_operations(operations)

      :telemetry.execute(
        [:orchestrator, :delta_buffer, :flush],
        %{
          operation_count: count,
          uncompressed_bytes: uncompressed_size,
          compressed_bytes: compressed_size,
          compression_ratio: compressed_size / max(uncompressed_size, 1)
        },
        %{machine_id: buffer.machine_id}
      )

      new_buffer = %{
        buffer
        | operations: [],
          size_bytes: 0,
          total_flushes: buffer.total_flushes + 1,
          total_operations: buffer.total_operations + count,
          total_bytes_uncompressed: buffer.total_bytes_uncompressed + uncompressed_size,
          total_bytes_compressed: buffer.total_bytes_compressed + compressed_size
      }

      {:ok, operations, new_buffer}
    end
  end

  @spec stats(t()) :: map()
  def stats(buffer) do
    compression_ratio =
      if buffer.total_bytes_uncompressed > 0 do
        buffer.total_bytes_compressed / buffer.total_bytes_uncompressed
      else
        0.0
      end

    %{
      pending_operations: length(buffer.operations),
      pending_bytes: buffer.size_bytes,
      total_flushes: buffer.total_flushes,
      total_operations: buffer.total_operations,
      total_bytes_uncompressed: buffer.total_bytes_uncompressed,
      total_bytes_compressed: buffer.total_bytes_compressed,
      compression_ratio: compression_ratio
    }
  end

  defp compress_operations(operations) do
    binary = :erlang.term_to_binary(operations)
    uncompressed_size = byte_size(binary)

    z = :zlib.open()
    :zlib.deflateInit(z, @compression_level)
    compressed = :zlib.deflate(z, binary, :finish)
    :zlib.deflateEnd(z)
    :zlib.close(z)

    compressed_binary = IO.iodata_to_binary(compressed)
    compressed_size = byte_size(compressed_binary)

    {uncompressed_size, compressed_size}
  end

  defp estimate_operation_size(operation) do
    case operation do
      {:increment, _key, _value} -> 50
      {:set, _key, value, _hlc} -> 100 + estimate_value_size(value)
      {:add, _key, element, _tag} -> 100 + estimate_value_size(element)
      {:remove, _key, element, _tag} -> 100 + estimate_value_size(element)
      _ -> 100
    end
  end

  defp estimate_value_size(value) when is_binary(value), do: byte_size(value)
  defp estimate_value_size(value) when is_list(value), do: length(value) * 10
  defp estimate_value_size(_value), do: 20
end
