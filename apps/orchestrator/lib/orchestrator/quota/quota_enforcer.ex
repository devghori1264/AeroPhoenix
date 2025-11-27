defmodule Orchestrator.Quota.QuotaEnforcer do
  use GenServer
  require Logger

  alias Orchestrator.Quota.{TokenBucket, QuotaHierarchy}

  @type org_id :: String.t()
  @type machine_id :: String.t()
  @type resource_type :: :api_requests | :machines | :cpu_seconds | :memory_gb | :bandwidth_mbps

  @type state :: %{
          token_buckets: %{String.t() => TokenBucket.t()},
          quota_hierarchy: QuotaHierarchy.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec check_api_quota(org_id(), String.t()) :: :ok | {:error, term()}
  def check_api_quota(org_id, _endpoint) do
    GenServer.call(__MODULE__, {:check_quota, org_id, :api_requests, 1})
  end

  @spec check_machine_creation_quota(org_id()) :: :ok | {:error, term()}
  def check_machine_creation_quota(org_id) do
    GenServer.call(__MODULE__, {:check_quota, org_id, :machines, 1})
  end

  @spec check_cpu_quota(org_id(), non_neg_integer()) :: :ok | {:error, term()}
  def check_cpu_quota(org_id, cpu_seconds) do
    GenServer.call(__MODULE__, {:check_quota, org_id, :cpu_seconds, cpu_seconds})
  end

  @spec check_memory_quota(org_id(), non_neg_integer()) :: :ok | {:error, term()}
  def check_memory_quota(org_id, memory_gb) do
    GenServer.call(__MODULE__, {:check_quota, org_id, :memory_gb, memory_gb})
  end

  @spec get_quota_stats(org_id()) :: map()
  def get_quota_stats(org_id) do
    GenServer.call(__MODULE__, {:get_stats, org_id})
  end

  @impl true
  def init(_opts) do
    quota_hierarchy = QuotaHierarchy.new()

    state = %{
      token_buckets: %{},
      quota_hierarchy: quota_hierarchy
    }

    Logger.info("QuotaEnforcer started")

    {:ok, state}
  end

  @impl true
  def handle_call({:check_quota, org_id, resource_type, amount}, _from, state) do
    bucket_key = "#{org_id}:#{resource_type}"

    {bucket, new_state} =
      case Map.get(state.token_buckets, bucket_key) do
        nil ->
          config = get_bucket_config(resource_type)
          new_bucket = TokenBucket.new(config)
          {new_bucket, put_in(state, [:token_buckets, bucket_key], new_bucket)}

        existing_bucket ->
          {existing_bucket, state}
      end

    case TokenBucket.consume(bucket, amount) do
      {:ok, updated_bucket} ->
        final_state = put_in(new_state, [:token_buckets, bucket_key], updated_bucket)

        :telemetry.execute(
          [:orchestrator, :quota, :usage],
          %{amount: amount},
          %{org_id: org_id, resource_type: resource_type}
        )

        {:reply, :ok, final_state}

      {:error, :rate_limited} = error ->
        Logger.warning("Quota exceeded",
          org_id: org_id,
          resource_type: resource_type,
          amount: amount
        )

        :telemetry.execute(
          [:orchestrator, :quota, :rate_limited],
          %{},
          %{org_id: org_id, resource_type: resource_type}
        )

        {:reply, error, new_state}
    end
  end

  @impl true
  def handle_call({:get_stats, org_id}, _from, state) do
    stats =
      [:api_requests, :machines, :cpu_seconds, :memory_gb, :bandwidth_mbps]
      |> Enum.map(fn resource_type ->
        bucket_key = "#{org_id}:#{resource_type}"

        bucket_stats =
          case Map.get(state.token_buckets, bucket_key) do
            nil -> %{tokens: 0, capacity: 0}
            bucket -> TokenBucket.get_stats(bucket)
          end

        {resource_type, bucket_stats}
      end)
      |> Map.new()

    {:reply, stats, state}
  end

  defp get_bucket_config(:api_requests) do
    %{
      capacity: 1000,
      refill_rate: 100,
      refill_interval_ms: 1000
    }
  end

  defp get_bucket_config(:machines) do
    %{
      capacity: 100,
      refill_rate: 10,
      refill_interval_ms: 1000
    }
  end

  defp get_bucket_config(:cpu_seconds) do
    %{
      capacity: 36000,
      refill_rate: 100,
      refill_interval_ms: 1000
    }
  end

  defp get_bucket_config(:memory_gb) do
    %{
      capacity: 1000,
      refill_rate: 100,
      refill_interval_ms: 1000
    }
  end

  defp get_bucket_config(:bandwidth_mbps) do
    %{
      capacity: 10000,
      refill_rate: 1000,
      refill_interval_ms: 1000
    }
  end
end
