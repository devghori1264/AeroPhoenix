defmodule Orchestrator.Replication.CRDTState do
  alias Orchestrator.Replication.{DeltaBuffer, HybridLogicalClock, VectorClock}
  require Logger

  require Logger

  @type machine_id :: String.t()
  @type node_id :: atom()
  @type crdt_value :: map()
  @type delta :: %{
          machine_id: machine_id(),
          node_id: node_id(),
          hlc: HybridLogicalClock.t(),
          vclock: VectorClock.t(),
          operations: [crdt_operation()],
          compressed: boolean()
        }

  @type crdt_operation ::
          {:gcounter_inc, atom(), non_neg_integer()}
          | {:lww_set, atom(), term(), HybridLogicalClock.t()}
          | {:orset_add, atom(), term(), tag()}
          | {:orset_remove, atom(), term(), tag()}

  @type tag :: {node_id(), non_neg_integer()}

  @type t :: %__MODULE__{
          machine_id: machine_id(),
          node_id: node_id(),
          gcounters: %{atom() => %{node_id() => non_neg_integer()}},
          lww_registers: %{atom() => {term(), HybridLogicalClock.t()}},
          orsets: %{
            atom() => %{
              additions: %{term() => tag()},
              tombstones: %{term() => tag()}
            }
          },
          hlc: HybridLogicalClock.t(),
          vclock: VectorClock.t(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          delta_buffer: DeltaBuffer.t()
        }

  defstruct [
    :machine_id,
    :node_id,
    :gcounters,
    :lww_registers,
    :orsets,
    :hlc,
    :vclock,
    :created_at,
    :updated_at,
    :delta_buffer
  ]

  @spec init(keyword()) :: {:ok, t()} | {:error, term()}
  def init(opts) do
    machine_id = Keyword.fetch!(opts, :machine_id)
    node_id = Keyword.get(opts, :node_id, Node.self())
    initial_state = Keyword.get(opts, :initial_state, %{})

    now = DateTime.utc_now()

    crdt = %__MODULE__{
      machine_id: machine_id,
      node_id: node_id,
      gcounters: initialize_gcounters(initial_state[:stats]),
      lww_registers: initialize_lww_registers(initial_state[:metadata], node_id),
      orsets: initialize_orsets(initial_state[:capabilities], node_id),
      hlc: HybridLogicalClock.init(),
      vclock: VectorClock.init(node_id),
      created_at: now,
      updated_at: now,
      delta_buffer: DeltaBuffer.init(machine_id: machine_id)
    }

    {:ok, crdt}
  end

  @spec increment_counter(t(), atom(), non_neg_integer()) ::
          {:ok, delta(), t()} | {:error, term()}
  def increment_counter(_crdt, _counter_name, amount) when amount < 0 do
    {:error, :negative_increment}
  end

  def increment_counter(crdt, counter_name, amount) do
    current_value = get_in(crdt.gcounters, [counter_name, crdt.node_id]) || 0
    new_value = current_value + amount

    updated_gcounters =
      Map.update(
        crdt.gcounters,
        counter_name,
        %{crdt.node_id => new_value},
        fn counter ->
          Map.put(counter, crdt.node_id, new_value)
        end
      )

    new_hlc = HybridLogicalClock.tick(crdt.hlc)
    new_vclock = VectorClock.increment(crdt.vclock, crdt.node_id)

    delta = %{
      machine_id: crdt.machine_id,
      node_id: crdt.node_id,
      hlc: new_hlc,
      vclock: new_vclock,
      operations: [{:gcounter_inc, counter_name, amount}],
      compressed: false
    }

    updated_crdt = %{
      crdt
      | gcounters: updated_gcounters,
        hlc: new_hlc,
        vclock: new_vclock,
        updated_at: DateTime.utc_now()
    }

    :telemetry.execute(
      [:crdt_state, :counter_incremented],
      %{amount: amount},
      %{machine_id: crdt.machine_id, counter: counter_name}
    )

    {:ok, delta, updated_crdt}
  end

  @spec set_register(t(), atom(), term()) :: {:ok, delta(), t()}
  def set_register(crdt, register_name, value) do
    new_hlc = HybridLogicalClock.tick(crdt.hlc)
    new_vclock = VectorClock.increment(crdt.vclock, crdt.node_id)

    updated_registers = Map.put(crdt.lww_registers, register_name, {value, new_hlc})

    delta = %{
      machine_id: crdt.machine_id,
      node_id: crdt.node_id,
      hlc: new_hlc,
      vclock: new_vclock,
      operations: [{:lww_set, register_name, value, new_hlc}],
      compressed: false
    }

    updated_crdt = %{
      crdt
      | lww_registers: updated_registers,
        hlc: new_hlc,
        vclock: new_vclock,
        updated_at: DateTime.utc_now()
    }

    {:ok, updated_buffer} = DeltaBuffer.add(updated_crdt.delta_buffer, delta)
    final_crdt = %{updated_crdt | delta_buffer: updated_buffer}

    :telemetry.execute(
      [:crdt_state, :register_set],
      %{value_size: byte_size(inspect(value))},
      %{machine_id: crdt.machine_id, register: register_name}
    )

    {:ok, delta, final_crdt}
  end

  @spec add_to_set(t(), atom(), term()) :: {:ok, delta(), t()}
  def add_to_set(crdt, set_name, element) do
    new_hlc = HybridLogicalClock.tick(crdt.hlc)
    new_vclock = VectorClock.increment(crdt.vclock, crdt.node_id)

    tag_counter = VectorClock.get(crdt.vclock, crdt.node_id)
    tag = {crdt.node_id, tag_counter}

    current_set = Map.get(crdt.orsets, set_name, %{additions: %{}, tombstones: %{}})

    updated_additions = Map.put(current_set.additions, element, tag)
    updated_set = %{current_set | additions: updated_additions}
    updated_orsets = Map.put(crdt.orsets, set_name, updated_set)

    delta = %{
      machine_id: crdt.machine_id,
      node_id: crdt.node_id,
      hlc: new_hlc,
      vclock: new_vclock,
      operations: [{:orset_add, set_name, element, tag}],
      compressed: false
    }

    updated_crdt = %{
      crdt
      | orsets: updated_orsets,
        hlc: new_hlc,
        vclock: new_vclock,
        updated_at: DateTime.utc_now()
    }

    {:ok, updated_buffer} = DeltaBuffer.add(updated_crdt.delta_buffer, delta)
    final_crdt = %{updated_crdt | delta_buffer: updated_buffer}

    :telemetry.execute(
      [:crdt_state, :set_element_added],
      %{set_size: map_size(updated_additions)},
      %{machine_id: crdt.machine_id, set: set_name}
    )

    {:ok, delta, final_crdt}
  end

  @spec remove_from_set(t(), atom(), term()) :: {:ok, delta(), t()} | {:error, :not_found}
  def remove_from_set(crdt, set_name, element) do
    current_set = Map.get(crdt.orsets, set_name, %{additions: %{}, tombstones: %{}})

    case Map.get(current_set.additions, element) do
      nil ->
        {:error, :not_found}

      tag ->
        new_hlc = HybridLogicalClock.tick(crdt.hlc)
        new_vclock = VectorClock.increment(crdt.vclock, crdt.node_id)

        updated_tombstones = Map.put(current_set.tombstones, element, tag)
        updated_set = %{current_set | tombstones: updated_tombstones}
        updated_orsets = Map.put(crdt.orsets, set_name, updated_set)

        delta = %{
          machine_id: crdt.machine_id,
          node_id: crdt.node_id,
          hlc: new_hlc,
          vclock: new_vclock,
          operations: [{:orset_remove, set_name, element, tag}],
          compressed: false
        }

        updated_crdt = %{
          crdt
          | orsets: updated_orsets,
            hlc: new_hlc,
            vclock: new_vclock,
            updated_at: DateTime.utc_now()
        }

        {:ok, updated_buffer} = DeltaBuffer.add(updated_crdt.delta_buffer, delta)
        final_crdt = %{updated_crdt | delta_buffer: updated_buffer}

        :telemetry.execute(
          [:crdt_state, :set_element_removed],
          %{tombstone_count: map_size(updated_tombstones)},
          %{machine_id: crdt.machine_id, set: set_name}
        )

        {:ok, delta, final_crdt}
    end
  end

  @spec merge_delta(t(), delta()) :: {:ok, t()} | {:error, term()}
  def merge_delta(crdt, delta) do
    delta = maybe_decompress_delta(delta)

    if delta.machine_id != crdt.machine_id do
      {:error, {:machine_id_mismatch, expected: crdt.machine_id, got: delta.machine_id}}
    else
      new_hlc = HybridLogicalClock.update(crdt.hlc, delta.hlc)

      new_vclock = VectorClock.merge(crdt.vclock, delta.vclock)

      updated_crdt =
        Enum.reduce(delta.operations, crdt, fn op, acc ->
          apply_operation(acc, op)
        end)

      final_crdt = %{
        updated_crdt
        | hlc: new_hlc,
          vclock: new_vclock,
          updated_at: DateTime.utc_now()
      }

      :telemetry.execute(
        [:crdt_state, :delta_merged],
        %{operation_count: length(delta.operations)},
        %{
          machine_id: crdt.machine_id,
          from_node: delta.node_id,
          to_node: crdt.node_id
        }
      )

      {:ok, final_crdt}
    end
  end

  @spec get_value(t()) :: crdt_value()
  def get_value(crdt) do
    %{
      stats: materialize_gcounters(crdt.gcounters),
      metadata: materialize_lww_registers(crdt.lww_registers),
      capabilities: materialize_orsets(crdt.orsets),
      _meta: %{
        node_id: crdt.node_id,
        hlc: HybridLogicalClock.to_timestamp(crdt.hlc),
        vclock: VectorClock.to_map(crdt.vclock),
        updated_at: crdt.updated_at
      }
    }
  end

  @spec flush_deltas(t()) :: {:ok, delta() | nil, t()}
  def flush_deltas(crdt) do
    case DeltaBuffer.flush(crdt.delta_buffer) do
      {:ok, nil, updated_buffer} ->
        {:ok, nil, %{crdt | delta_buffer: updated_buffer}}

      {:ok, operations, updated_buffer} ->
        batched_delta = %{
          machine_id: crdt.machine_id,
          node_id: crdt.node_id,
          hlc: crdt.hlc,
          vclock: crdt.vclock,
          operations: operations,
          compressed: false
        }

        final_delta =
          if byte_size(:erlang.term_to_binary(batched_delta)) > 1024 do
            compress_delta(batched_delta)
          else
            batched_delta
          end

        {:ok, final_delta, %{crdt | delta_buffer: updated_buffer}}
    end
  end

  defp initialize_gcounters(nil), do: %{}

  defp initialize_gcounters(stats) when is_map(stats) do
    Enum.into(stats, %{}, fn {key, value} ->
      {key, %{Node.self() => value}}
    end)
  end

  defp initialize_lww_registers(nil, _node_id), do: %{}

  defp initialize_lww_registers(metadata, _node_id) when is_map(metadata) do
    hlc = HybridLogicalClock.init()

    Enum.into(metadata, %{}, fn {key, value} ->
      {key, {value, hlc}}
    end)
  end

  defp initialize_orsets(nil, _node_id), do: %{}

  defp initialize_orsets(capabilities, node_id) when is_list(capabilities) do
    additions =
      Enum.with_index(capabilities)
      |> Enum.into(%{}, fn {cap, idx} ->
        {cap, {node_id, idx}}
      end)

    %{capabilities: %{additions: additions, tombstones: %{}}}
  end

  defp apply_operation(crdt, {:gcounter_inc, counter_name, amount}) do
    updated_gcounters =
      Map.update(
        crdt.gcounters,
        counter_name,
        %{crdt.node_id => amount},
        fn counter ->
          current = Map.get(counter, crdt.node_id, 0)
          Map.put(counter, crdt.node_id, max(current, amount))
        end
      )

    %{crdt | gcounters: updated_gcounters}
  end

  defp apply_operation(crdt, {:lww_set, register_name, value, hlc}) do
    updated_registers =
      Map.update(
        crdt.lww_registers,
        register_name,
        {value, hlc},
        fn {current_value, current_hlc} ->
          if HybridLogicalClock.compare(hlc, current_hlc) == :gt do
            {value, hlc}
          else
            {current_value, current_hlc}
          end
        end
      )

    %{crdt | lww_registers: updated_registers}
  end

  defp apply_operation(crdt, {:orset_add, set_name, element, tag}) do
    updated_orsets =
      Map.update(
        crdt.orsets,
        set_name,
        %{additions: %{element => tag}, tombstones: %{}},
        fn current_set ->
          updated_additions = Map.put(current_set.additions, element, tag)
          %{current_set | additions: updated_additions}
        end
      )

    %{crdt | orsets: updated_orsets}
  end

  defp apply_operation(crdt, {:orset_remove, set_name, element, tag}) do
    updated_orsets =
      Map.update(
        crdt.orsets,
        set_name,
        %{additions: %{}, tombstones: %{element => tag}},
        fn current_set ->
          updated_tombstones = Map.put(current_set.tombstones, element, tag)
          %{current_set | tombstones: updated_tombstones}
        end
      )

    %{crdt | orsets: updated_orsets}
  end

  defp materialize_gcounters(gcounters) do
    Enum.into(gcounters, %{}, fn {counter_name, node_values} ->
      total = node_values |> Map.values() |> Enum.sum()
      {counter_name, total}
    end)
  end

  defp materialize_lww_registers(registers) do
    Enum.into(registers, %{}, fn {key, {value, _hlc}} ->
      {key, value}
    end)
  end

  defp materialize_orsets(orsets) do
    Enum.into(orsets, %{}, fn {set_name, set_data} ->
      live_elements =
        set_data.additions
        |> Map.keys()
        |> Enum.reject(fn elem ->
          Map.has_key?(set_data.tombstones, elem)
        end)

      {set_name, live_elements}
    end)
  end

  defp compress_delta(delta) do
    compressed_ops = :erlang.term_to_binary(delta.operations) |> :zlib.compress()

    %{delta | operations: {:compressed, compressed_ops}, compressed: true}
  end

  defp maybe_decompress_delta(%{compressed: true, operations: {:compressed, data}} = delta) do
    decompressed_ops = :zlib.uncompress(data) |> :erlang.binary_to_term()
    %{delta | operations: decompressed_ops, compressed: false}
  end

  defp maybe_decompress_delta(delta), do: delta
end
