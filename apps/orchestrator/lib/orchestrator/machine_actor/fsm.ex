defmodule Orchestrator.MachineActor.FSM do
  @type state ::
          :created
          | :starting
          | :running
          | :suspended
          | :stopping
          | :stopped
          | :migrating
          | :destroying
          | :destroyed
          | :error

  @type transition_type ::
          :start
          | :stop
          | :destroy
          | :suspend
          | :resume
          | :restart
          | :migrate

  @type transition_error ::
          {:invalid_transition, state(), state()}
          | {:locked_by_operation, String.t()}
          | {:missing_capability, atom()}
          | {:resource_exhausted, atom()}
          | {:precondition_failed, String.t()}

  @transitions %{
    {:created, :start} => :starting,
    {:starting, :provision_complete} => :running,
    {:starting, :provision_failed} => :error,
    {:running, :stop} => :stopping,
    {:running, :suspend} => :suspended,
    {:running, :migrate} => :migrating,
    {:running, :restart} => :stopping,
    {:running, :destroy} => :destroying,
    {:suspended, :resume} => :starting,
    {:suspended, :destroy} => :destroying,
    {:stopping, :stopped} => :stopped,
    {:stopping, :stop_failed} => :error,
    {:stopped, :start} => :starting,
    {:stopped, :destroy} => :destroying,
    {:migrating, :migration_complete} => :running,
    {:migrating, :migration_failed} => :running,
    {:destroying, :destroy_complete} => :destroyed,
    {:error, :restart} => :starting,
    {:error, :destroy} => :destroying
  }

  @terminal_states [:destroyed]

  @locked_states [:starting, :stopping, :migrating, :destroying]
  @spec validate_transition(state(), state()) :: :ok | {:error, transition_error()}
  def validate_transition(current_state, target_state) do
    cond do
      current_state == target_state ->
        :ok

      current_state in @terminal_states ->
        {:error, {:invalid_transition, current_state, target_state}}

      transition_exists?(current_state, target_state) ->
        :ok

      target_state == :destroying ->
        :ok

      true ->
        {:error, {:invalid_transition, current_state, target_state}}
    end
  end

  @spec resolve_target_state(transition_type(), keyword()) :: state()
  def resolve_target_state(transition_type, _opts \\ []) do
    case transition_type do
      :start -> :starting
      :stop -> :stopping
      :destroy -> :destroying
      :suspend -> :suspended
      :resume -> :starting
      :restart -> :stopping
      :migrate -> :migrating
    end
  end

  @spec next_states(state()) :: [state()]
  def next_states(current_state) do
    @transitions
    |> Enum.filter(fn {{from, _transition}, _to} -> from == current_state end)
    |> Enum.map(fn {_key, to_state} -> to_state end)
    |> Enum.uniq()
  end

  @spec next_transitions(state()) :: [transition_type()]
  def next_transitions(current_state) do
    @transitions
    |> Enum.filter(fn {{from, _transition}, _to} -> from == current_state end)
    |> Enum.map(fn {{_from, transition}, _to} -> transition end)
    |> Enum.uniq()
  end

  @spec terminal?(state()) :: boolean()
  def terminal?(state), do: state in @terminal_states
  @spec locked?(state()) :: boolean()
  def locked?(state), do: state in @locked_states

  @spec check_preconditions(transition_type(), state(), keyword()) ::
          :ok | {:error, transition_error()}
  def check_preconditions(transition_type, current_state, opts \\ []) do
    case transition_type do
      :migrate ->
        check_migration_preconditions(current_state, opts)

      :start ->
        check_start_preconditions(opts)

      :suspend ->
        check_suspend_preconditions(current_state)

      _ ->
        :ok
    end
  end

  defp transition_exists?(from_state, to_state) do
    Enum.any?(@transitions, fn
      {{^from_state, _transition}, ^to_state} -> true
      _ -> false
    end)
  end

  defp check_migration_preconditions(current_state, opts) do
    cond do
      current_state not in [:running, :stopped] ->
        {:error, {:precondition_failed, "machine must be running or stopped to migrate"}}

      !Keyword.has_key?(opts, :target_region) ->
        {:error, {:precondition_failed, "target_region required for migration"}}

      true ->
        :ok
    end
  end

  defp check_start_preconditions(opts) do
    requested_memory = get_in(opts, [:size, :memory_mb]) || 256
    requested_cpu = get_in(opts, [:size, :cpu_count]) || 1

    cond do
      requested_memory > 65536 ->
        {:error, {:resource_exhausted, :memory}}

      requested_cpu > 32 ->
        {:error, {:resource_exhausted, :cpu}}

      true ->
        :ok
    end
  end

  defp check_suspend_preconditions(current_state) do
    if current_state == :running do
      :ok
    else
      {:error, {:precondition_failed, "can only suspend running machines"}}
    end
  end

  @spec describe_state(state()) :: String.t()
  def describe_state(state) do
    case state do
      :created -> "Machine created, ready to start"
      :starting -> "Provisioning resources and booting machine"
      :running -> "Machine is running and healthy"
      :suspended -> "Execution paused, state preserved"
      :stopping -> "Gracefully shutting down"
      :stopped -> "Machine stopped, can be restarted"
      :migrating -> "Moving machine to different region"
      :destroying -> "Permanently removing machine"
      :destroyed -> "Machine destroyed, cannot be recovered"
      :error -> "Machine encountered error, needs manual intervention"
    end
  end

  @spec estimated_duration(transition_type()) :: non_neg_integer()
  def estimated_duration(transition_type) do
    case transition_type do
      :start -> 5_000
      :stop -> 3_000
      :destroy -> 2_000
      :suspend -> 4_000
      :resume -> 5_000
      :restart -> 8_000
      :migrate -> 30_000
    end
  end

  @spec reversible?(transition_type()) :: boolean()
  def reversible?(transition_type) do
    case transition_type do
      :migrate -> true
      :restart -> true
      :suspend -> true
      :destroy -> false
      _ -> false
    end
  end
end
