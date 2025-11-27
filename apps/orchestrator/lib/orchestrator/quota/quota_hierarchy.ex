defmodule Orchestrator.Quota.QuotaHierarchy do
  @type org_id :: String.t()
  @type resource_type :: atom()
  @type quota :: non_neg_integer()

  @type t :: %__MODULE__{
          global_quotas: %{resource_type() => quota()},
          org_quotas: %{org_id() => %{resource_type() => quota()}},
          org_usage: %{org_id() => %{resource_type() => non_neg_integer()}}
        }

  defstruct global_quotas: %{},
            org_quotas: %{},
            org_usage: %{}

  @spec new() :: t()
  def new do
    %__MODULE__{
      global_quotas: %{
        machines: 1_000_000,
        cpu_cores: 10_000_000,
        memory_gb: 100_000_000,
        bandwidth_gbps: 1_000_000,
        api_requests: 1_000_000_000
      },
      org_quotas: %{},
      org_usage: %{}
    }
  end

  @spec set_org_quota(t(), org_id(), resource_type(), quota()) :: t()
  def set_org_quota(hierarchy, org_id, resource_type, quota) do
    put_in(hierarchy, [:org_quotas, org_id, resource_type], quota)
  end

  @spec get_org_quota(t(), org_id(), resource_type()) :: quota()
  def get_org_quota(hierarchy, org_id, resource_type) do
    get_in(hierarchy, [:org_quotas, org_id, resource_type]) ||
      Map.get(hierarchy.global_quotas, resource_type, 0)
  end

  @spec record_usage(t(), org_id(), resource_type(), non_neg_integer()) :: t()
  def record_usage(hierarchy, org_id, resource_type, amount) do
    current_usage = get_in(hierarchy, [:org_usage, org_id, resource_type]) || 0
    new_usage = current_usage + amount

    put_in(hierarchy, [:org_usage, org_id, resource_type], new_usage)
  end

  @spec get_org_usage(t(), org_id(), resource_type()) :: non_neg_integer()
  def get_org_usage(hierarchy, org_id, resource_type) do
    get_in(hierarchy, [:org_usage, org_id, resource_type]) || 0
  end

  @spec check_quota(t(), org_id(), resource_type(), non_neg_integer()) ::
          :ok | {:error, term()}
  def check_quota(hierarchy, org_id, resource_type, amount) do
    org_usage = get_org_usage(hierarchy, org_id, resource_type)
    org_quota = get_org_quota(hierarchy, org_id, resource_type)

    if org_usage + amount <= org_quota do
      :ok
    else
      {:error,
       {:quota_exceeded, level: :org, usage: org_usage, quota: org_quota, requested: amount}}
    end
  end

  @spec get_stats(t(), org_id()) :: map()
  def get_stats(hierarchy, org_id) do
    resource_types = [:machines, :cpu_cores, :memory_gb, :bandwidth_gbps, :api_requests]

    Enum.map(resource_types, fn resource_type ->
      usage = get_org_usage(hierarchy, org_id, resource_type)
      quota = get_org_quota(hierarchy, org_id, resource_type)

      utilization = if quota > 0, do: usage / quota, else: 0.0

      {resource_type,
       %{
         usage: usage,
         quota: quota,
         available: quota - usage,
         utilization: utilization
       }}
    end)
    |> Map.new()
  end
end
