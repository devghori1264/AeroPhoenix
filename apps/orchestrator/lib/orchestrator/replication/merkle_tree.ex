defmodule Orchestrator.Replication.MerkleTree do
  require Logger

  @bucket_count 256
  @hash_algorithm :sha256
  @empty_hash :crypto.hash(@hash_algorithm, <<>>)

  @type bucket_id :: 0..255
  @type hash :: binary()
  @type entry :: {machine_id :: String.t(), vclock :: map()}

  @type t :: %__MODULE__{
          leaves: %{bucket_id() => hash()},
          nodes: %{(level :: non_neg_integer()) => [hash()]},
          root: hash(),
          entry_count: non_neg_integer(),
          built_at: DateTime.t()
        }

  defstruct leaves: %{},
            nodes: %{},
            root: @empty_hash,
            entry_count: 0,
            built_at: nil

  @spec build([entry()]) :: t()
  def build(entries) do
    buckets = partition_into_buckets(entries)

    leaf_hashes =
      Enum.map(0..(@bucket_count - 1), fn bucket_id ->
        bucket_entries = Map.get(buckets, bucket_id, [])
        hash = hash_bucket(bucket_entries)
        {bucket_id, hash}
      end)
      |> Map.new()

    {nodes, root_hash} = build_tree_levels(leaf_hashes)

    %__MODULE__{
      leaves: leaf_hashes,
      nodes: nodes,
      root: root_hash,
      entry_count: length(entries),
      built_at: DateTime.utc_now()
    }
  end

  @spec compare(t(), t()) :: {:equal, []} | {:divergent, [bucket_id()]}
  def compare(tree_a, tree_b) do
    if tree_a.root == tree_b.root do
      {:equal, []}
    else
      divergent_buckets = find_divergent_buckets(tree_a, tree_b)
      {:divergent, divergent_buckets}
    end
  end

  @spec extract_buckets([entry()], [bucket_id()]) :: %{bucket_id() => [entry()]}
  def extract_buckets(entries, bucket_ids) do
    all_buckets = partition_into_buckets(entries)

    bucket_ids
    |> Enum.map(fn bucket_id ->
      {bucket_id, Map.get(all_buckets, bucket_id, [])}
    end)
    |> Map.new()
  end

  @spec verify(t()) :: :ok | {:error, :hash_mismatch}
  def verify(tree) do
    {_nodes, computed_root} = build_tree_levels(tree.leaves)

    if computed_root == tree.root do
      :ok
    else
      {:error, :hash_mismatch}
    end
  end

  @spec stats(t()) :: map()
  def stats(tree) do
    bucket_sizes =
      tree.leaves
      |> Map.values()
      |> Enum.map(&count_entries_in_hash/1)

    non_empty_buckets = Enum.count(bucket_sizes, &(&1 > 0))
    max_bucket_size = Enum.max(bucket_sizes, fn -> 0 end)

    avg_bucket_size =
      if non_empty_buckets > 0 do
        tree.entry_count / non_empty_buckets
      else
        0.0
      end

    %{
      entry_count: tree.entry_count,
      bucket_count: @bucket_count,
      avg_bucket_size: Float.round(avg_bucket_size, 1),
      max_bucket_size: max_bucket_size,
      empty_buckets: @bucket_count - non_empty_buckets,
      tree_depth: tree_depth(),
      built_at: tree.built_at
    }
  end

  defp partition_into_buckets(entries) do
    Enum.group_by(entries, fn {machine_id, _vclock} ->
      bucket_id_for(machine_id)
    end)
  end

  defp bucket_id_for(machine_id) do
    hash = :crypto.hash(@hash_algorithm, machine_id)
    <<bucket_id::8, _rest::binary>> = hash
    bucket_id
  end

  defp hash_bucket([]) do
    @empty_hash
  end

  defp hash_bucket(entries) do
    sorted_entries = Enum.sort_by(entries, fn {machine_id, _} -> machine_id end)

    binary =
      sorted_entries
      |> Enum.map(fn {machine_id, vclock} ->
        vclock_str = serialize_vclock(vclock)
        "#{machine_id}:#{vclock_str}"
      end)
      |> Enum.join("|")

    :crypto.hash(@hash_algorithm, binary)
  end

  defp serialize_vclock(vclock) when is_map(vclock) do
    vclock
    |> Enum.sort()
    |> Enum.map(fn {node, count} -> "#{node}=#{count}" end)
    |> Enum.join(",")
  end

  defp build_tree_levels(leaf_hashes) when map_size(leaf_hashes) == 0 do
    {%{}, @empty_hash}
  end

  defp build_tree_levels(leaf_hashes) do
    level_0 =
      0..(@bucket_count - 1)
      |> Enum.map(fn bucket_id -> Map.get(leaf_hashes, bucket_id, @empty_hash) end)

    nodes = %{0 => level_0}
    build_tree_recursive(nodes, 0)
  end

  defp build_tree_recursive(nodes, level) do
    current_level = Map.fetch!(nodes, level)

    if length(current_level) == 1 do
      root_hash = hd(current_level)
      {nodes, root_hash}
    else
      next_level = hash_pairs(current_level)
      updated_nodes = Map.put(nodes, level + 1, next_level)
      build_tree_recursive(updated_nodes, level + 1)
    end
  end

  defp hash_pairs([]), do: []

  defp hash_pairs([single]) do
    [hash_pair(single, single)]
  end

  defp hash_pairs([left, right | rest]) do
    pair_hash = hash_pair(left, right)
    [pair_hash | hash_pairs(rest)]
  end

  defp hash_pair(left_hash, right_hash) do
    :crypto.hash(@hash_algorithm, <<left_hash::binary, right_hash::binary>>)
  end

  defp find_divergent_buckets(tree_a, tree_b) do
    max_level = tree_depth() - 1
    find_divergent_recursive(tree_a, tree_b, max_level, 0, @bucket_count - 1)
  end

  defp find_divergent_recursive(tree_a, tree_b, level, start_bucket, end_bucket) do
    if level == 0 do
      start_bucket..end_bucket
      |> Enum.filter(fn bucket_id ->
        hash_a = Map.get(tree_a.leaves, bucket_id, @empty_hash)
        hash_b = Map.get(tree_b.leaves, bucket_id, @empty_hash)
        hash_a != hash_b
      end)
    else
      mid_bucket = div(start_bucket + end_bucket, 2)
      node_idx = node_index_for_range(level, start_bucket, end_bucket)

      hash_a = get_node_hash(tree_a, level, node_idx)
      hash_b = get_node_hash(tree_b, level, node_idx)

      if hash_a == hash_b do
        []
      else
        left_divergent =
          find_divergent_recursive(tree_a, tree_b, level - 1, start_bucket, mid_bucket)

        right_divergent =
          find_divergent_recursive(tree_a, tree_b, level - 1, mid_bucket + 1, end_bucket)

        left_divergent ++ right_divergent
      end
    end
  end

  defp get_node_hash(tree, level, index) do
    level_nodes = Map.get(tree.nodes, level, [])
    Enum.at(level_nodes, index, @empty_hash)
  end

  defp node_index_for_range(level, start_bucket, end_bucket) do
    _range_size = end_bucket - start_bucket + 1
    nodes_per_level = div(@bucket_count, :math.pow(2, level) |> round())
    div(start_bucket, div(@bucket_count, nodes_per_level))
  end

  defp tree_depth do
    :math.log2(@bucket_count) |> ceil()
  end

  defp count_entries_in_hash(hash) do
    if hash == @empty_hash, do: 0, else: 1
  end
end
