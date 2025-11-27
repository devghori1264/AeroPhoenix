defmodule Orchestrator.Security.CapabilityManager do
  use GenServer
  require Logger

  @type machine_id :: String.t()
  @type action :: atom()
  @type resource :: String.t()
  @type capability :: map()
  @type capability_id :: String.t()

  @default_ttl_seconds 3600

  @max_delegation_depth 3

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec grant(keyword()) :: {:ok, capability()}
  def grant(opts) do
    GenServer.call(__MODULE__, {:grant, opts})
  end

  @spec check(machine_id(), {action(), resource()}) :: :ok | {:error, atom()}
  def check(machine_id, {action, resource}) do
    GenServer.call(__MODULE__, {:check, machine_id, action, resource})
  end

  @spec attenuate(capability(), atom()) :: {:ok, capability()} | {:error, atom()}
  def attenuate(capability, restriction) do
    GenServer.call(__MODULE__, {:attenuate, capability, restriction})
  end

  @spec delegate(capability(), keyword()) :: {:ok, capability()} | {:error, atom()}
  def delegate(capability, opts) do
    GenServer.call(__MODULE__, {:delegate, capability, opts})
  end

  @spec revoke(capability_id()) :: :ok
  def revoke(capability_id) do
    GenServer.call(__MODULE__, {:revoke, capability_id})
  end

  @spec list(machine_id()) :: [capability()]
  def list(machine_id) do
    GenServer.call(__MODULE__, {:list, machine_id})
  end

  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def init(_opts) do
    :ets.new(:capability_grants, [:named_table, :bag, :public, read_concurrency: true])
    :ets.new(:capability_revocations, [:named_table, :set, :public, read_concurrency: true])

    Process.send_after(self(), :cleanup_expired, 60_000)

    state = %{
      total_granted: 0,
      total_revoked: 0
    }

    Logger.info("Capability Manager started")

    :telemetry.execute(
      [:orchestrator, :capability, :manager_started],
      %{},
      %{}
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:grant, opts}, _from, state) do
    machine_id = Keyword.fetch!(opts, :machine_id)
    action = Keyword.fetch!(opts, :action)
    resource = Keyword.fetch!(opts, :resource)
    ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)

    now = System.system_time(:second)
    cap_id = UUID.uuid4()

    capability = %{
      id: cap_id,
      machine_id: machine_id,
      action: action,
      resource: resource,
      granted_at: now,
      expires_at: now + ttl,
      delegation_depth: 0,
      version: get_machine_capability_version(machine_id)
    }

    :ets.insert(:capability_grants, {machine_id, capability})

    Logger.debug(
      "Granted capability: machine=#{machine_id} action=#{action} resource=#{resource}"
    )

    :telemetry.execute(
      [:orchestrator, :capability, :granted],
      %{ttl_seconds: ttl},
      %{machine_id: machine_id, action: action, capability_id: cap_id}
    )

    new_state = %{state | total_granted: state.total_granted + 1}
    {:reply, {:ok, capability}, new_state}
  end

  @impl true
  def handle_call({:check, machine_id, action, resource}, _from, state) do
    capabilities = :ets.lookup(:capability_grants, machine_id)

    result =
      capabilities
      |> Enum.find_value(fn {_mid, cap} ->
        if cap.action == action and cap.resource == resource do
          cap
        end
      end)
      |> case do
        nil ->
          {:error, :insufficient_capability}

        cap ->
          now = System.system_time(:second)

          if cap.expires_at < now do
            {:error, :capability_expired}
          else
            case :ets.lookup(:capability_revocations, cap.id) do
              [] -> :ok
              _ -> {:error, :capability_revoked}
            end
          end
      end

    if result == :ok do
      :telemetry.execute(
        [:orchestrator, :capability, :check_passed],
        %{},
        %{machine_id: machine_id, action: action}
      )
    else
      :telemetry.execute(
        [:orchestrator, :capability, :check_failed],
        %{},
        %{machine_id: machine_id, action: action, reason: elem(result, 1)}
      )
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:attenuate, capability, restriction}, _from, state) do
    result =
      case {capability.action, restriction} do
        {:write_volume, :read_only} ->
          attenuated_cap = %{
            capability
            | id: UUID.uuid4(),
              action: :read_volume,
              delegation_depth: capability.delegation_depth + 1,
              parent_id: capability.id
          }

          :ets.insert(:capability_grants, {capability.machine_id, attenuated_cap})

          Logger.debug(
            "Attenuated capability: #{capability.id} -> #{attenuated_cap.id} (read_only)"
          )

          :telemetry.execute(
            [:orchestrator, :capability, :attenuated],
            %{},
            %{
              parent_id: capability.id,
              child_id: attenuated_cap.id,
              restriction: restriction
            }
          )

          {:ok, attenuated_cap}

        _ ->
          {:error, :cannot_attenuate}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:delegate, capability, opts}, _from, state) do
    from_machine = Keyword.fetch!(opts, :from)
    to_machine = Keyword.fetch!(opts, :to)

    result =
      cond do
        capability.machine_id != from_machine ->
          {:error, :not_owner}

        capability.delegation_depth >= @max_delegation_depth ->
          {:error, :max_delegation_depth}

        true ->
          delegated_cap = %{
            capability
            | id: UUID.uuid4(),
              machine_id: to_machine,
              delegation_depth: capability.delegation_depth + 1,
              delegated_from: capability.machine_id,
              delegated_at: System.system_time(:second)
          }

          :ets.insert(:capability_grants, {to_machine, delegated_cap})

          Logger.info(
            "Delegated capability: #{from_machine} -> #{to_machine} (#{capability.action})"
          )

          :telemetry.execute(
            [:orchestrator, :capability, :delegated],
            %{delegation_depth: delegated_cap.delegation_depth},
            %{
              from: from_machine,
              to: to_machine,
              capability_id: delegated_cap.id
            }
          )

          {:ok, delegated_cap}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:revoke, capability_id}, _from, state) do
    :ets.insert(:capability_revocations, {capability_id, System.system_time(:second)})

    Logger.info("Revoked capability: #{capability_id}")

    :telemetry.execute(
      [:orchestrator, :capability, :revoked],
      %{},
      %{capability_id: capability_id}
    )

    new_state = %{state | total_revoked: state.total_revoked + 1}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:list, machine_id}, _from, state) do
    capabilities =
      :ets.lookup(:capability_grants, machine_id)
      |> Enum.map(fn {_mid, cap} -> cap end)
      |> Enum.filter(fn cap ->
        now = System.system_time(:second)
        cap.expires_at >= now
      end)

    {:reply, capabilities, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    active_count = :ets.info(:capability_grants, :size)
    revoked_count = :ets.info(:capability_revocations, :size)

    stats = %{
      total_granted: state.total_granted,
      total_revoked: state.total_revoked,
      active_capabilities: active_count,
      revoked_capabilities: revoked_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    now = System.system_time(:second)

    all_grants = :ets.tab2list(:capability_grants)

    expired_grants =
      Enum.filter(all_grants, fn {_mid, cap} ->
        cap.expires_at < now
      end)

    Enum.each(expired_grants, fn {machine_id, cap} ->
      :ets.delete_object(:capability_grants, {machine_id, cap})
    end)

    if length(expired_grants) > 0 do
      Logger.debug("Cleaned up #{length(expired_grants)} expired capabilities")
    end

    Process.send_after(self(), :cleanup_expired, 60_000)

    {:noreply, state}
  end

  defp get_machine_capability_version(machine_id) do
    case :ets.lookup(:capability_versions, machine_id) do
      [] -> 1
      [{^machine_id, version}] -> version
    end
  end
end
