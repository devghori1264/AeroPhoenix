defmodule Orchestrator.Reconciliation.DriftAnalyzer do
  require Logger
  @type state_map :: map()
  @type drift_severity :: :critical | :major | :minor | :none
  @type inconsistency :: %{
          field: String.t(),
          source_value: any(),
          target_value: any(),
          severity: drift_severity(),
          category: atom(),
          description: String.t()
        }
  @type analysis_result :: %{
          has_drift: boolean(),
          severity: drift_severity(),
          inconsistencies: [inconsistency()],
          summary: map(),
          recommendations: [String.t()]
        }
  @status_equivalents %{
    "running" => MapSet.new(["started", "active", "running", "alive"]),
    "stopped" => MapSet.new(["stopped", "halted", "terminated", "down"]),
    "starting" => MapSet.new(["starting", "initializing", "booting"]),
    "error" => MapSet.new(["error", "failed", "crashed", "broken"])
  }
  @critical_fields ~w[id name machine_type cpu_count memory_mb]
  @major_fields ~w[status region ip_address dns_name]
  @minor_fields ~w[uptime_seconds last_health_check metadata_labels]
  @spec analyze(state_map(), state_map(), map()) ::
          {:ok, analysis_result()} | {:error, term()}
  def analyze(source_state, target_state, config) do
    start_time = System.monotonic_time(:millisecond)

    Logger.debug("Starting drift analysis",
      level: config.level,
      verify_checksums: config.verify_checksums
    )

    inconsistencies =
      case config.level do
        :basic ->
          analyze_basic(source_state, target_state)

        :standard ->
          analyze_basic(source_state, target_state) ++
            analyze_configuration(source_state, target_state) ++
            analyze_network(source_state, target_state)

        :deep ->
          analyze_basic(source_state, target_state) ++
            analyze_configuration(source_state, target_state) ++
            analyze_network(source_state, target_state) ++
            analyze_application_state(source_state, target_state, config)

        :paranoid ->
          analyze_basic(source_state, target_state) ++
            analyze_configuration(source_state, target_state) ++
            analyze_network(source_state, target_state) ++
            analyze_application_state(source_state, target_state, config) ++
            analyze_filesystem(source_state, target_state, config) ++
            analyze_process_state(source_state, target_state)
      end

    severity = calculate_severity(inconsistencies)
    recommendations = generate_recommendations(inconsistencies, config)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    result = %{
      has_drift: length(inconsistencies) > 0,
      severity: severity,
      inconsistencies: inconsistencies,
      summary: %{
        total_drifts: length(inconsistencies),
        critical_count: count_by_severity(inconsistencies, :critical),
        major_count: count_by_severity(inconsistencies, :major),
        minor_count: count_by_severity(inconsistencies, :minor),
        analysis_duration_ms: duration_ms
      },
      recommendations: recommendations
    }

    Logger.info("Drift analysis completed",
      has_drift: result.has_drift,
      severity: severity,
      drift_count: length(inconsistencies),
      duration_ms: duration_ms
    )

    :telemetry.execute(
      [:orchestrator, :reconciliation, :drift_analysis, :completed],
      %{duration_ms: duration_ms, drift_count: length(inconsistencies)},
      %{severity: severity, level: config.level}
    )

    {:ok, result}
  end

  defp analyze_basic(source, target) do
    [
      compare_field("id", source, target, :critical, :identity),
      compare_field("name", source, target, :critical, :identity),
      compare_status(source, target),
      compare_field("region", source, target, :major, :configuration),
      compare_field("cpu_count", source, target, :critical, :resource),
      compare_field("memory_mb", source, target, :critical, :resource)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp analyze_configuration(source, target) do
    [
      compare_environment_variables(source, target),
      compare_volumes(source, target),
      compare_labels(source, target),
      compare_restart_policy(source, target),
      compare_resource_limits(source, target)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp analyze_network(source, target) do
    [
      compare_field("ip_address", source, target, :major, :network),
      compare_field("dns_name", source, target, :major, :network),
      compare_ports(source, target),
      compare_network_config(source, target),
      verify_connectivity(source, target)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp analyze_application_state(source, target, config) do
    drifts =
      [
        compare_process_list(source, target),
        compare_open_files(source, target)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    if config.verify_checksums do
      drifts ++ verify_data_checksums(source, target)
    else
      drifts
    end
  end

  defp analyze_filesystem(source, target, _config) do
    [
      compare_file_permissions(source, target),
      compare_directory_structure(source, target),
      verify_critical_files(source, target)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp analyze_process_state(source, target) do
    [
      compare_running_processes(source, target),
      compare_process_tree(source, target),
      compare_system_resources(source, target)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp compare_field(field, source, target, severity, category) do
    source_value = Map.get(source, field) || Map.get(source, String.to_atom(field))
    target_value = Map.get(target, field) || Map.get(target, String.to_atom(field))

    if source_value != target_value and
         not semantically_equivalent?(field, source_value, target_value) do
      %{
        field: field,
        source_value: source_value,
        target_value: target_value,
        severity: severity,
        category: category,
        description:
          "Field '#{field}' mismatch: source=#{inspect(source_value)}, target=#{inspect(target_value)}"
      }
    else
      nil
    end
  end

  defp compare_status(source, target) do
    source_status = normalize_status(Map.get(source, "status") || Map.get(source, :status))
    target_status = normalize_status(Map.get(target, "status") || Map.get(target, :status))

    if not status_equivalent?(source_status, target_status) do
      severity =
        if source_status in ["running", "started"] and target_status in ["stopped", "error"] do
          :critical
        else
          :major
        end

      %{
        field: "status",
        source_value: source_status,
        target_value: target_status,
        severity: severity,
        category: :state,
        description: "Status mismatch: source=#{source_status}, target=#{target_status}"
      }
    else
      nil
    end
  end

  defp compare_environment_variables(source, target) do
    source_env = Map.get(source, "environment") || Map.get(source, :environment) || %{}
    target_env = Map.get(target, "environment") || Map.get(target, :environment) || %{}
    missing_in_target = Map.drop(source_env, Map.keys(target_env))
    missing_in_source = Map.drop(target_env, Map.keys(source_env))

    different_values =
      Map.keys(source_env)
      |> Enum.filter(fn key ->
        Map.has_key?(target_env, key) and Map.get(source_env, key) != Map.get(target_env, key)
      end)

    inconsistencies = []

    inconsistencies =
      if map_size(missing_in_target) > 0 do
        [
          %{
            field: "environment",
            source_value: missing_in_target,
            target_value: nil,
            severity: :major,
            category: :configuration,
            description:
              "Environment variables missing in target: #{inspect(Map.keys(missing_in_target))}"
          }
          | inconsistencies
        ]
      else
        inconsistencies
      end

    inconsistencies =
      if map_size(missing_in_source) > 0 do
        [
          %{
            field: "environment",
            source_value: nil,
            target_value: missing_in_source,
            severity: :minor,
            category: :configuration,
            description:
              "Extra environment variables in target: #{inspect(Map.keys(missing_in_source))}"
          }
          | inconsistencies
        ]
      else
        inconsistencies
      end

    inconsistencies =
      if length(different_values) > 0 do
        Enum.map(different_values, fn key ->
          %{
            field: "environment.#{key}",
            source_value: Map.get(source_env, key),
            target_value: Map.get(target_env, key),
            severity: :major,
            category: :configuration,
            description: "Environment variable '#{key}' value mismatch"
          }
        end) ++ inconsistencies
      else
        inconsistencies
      end

    inconsistencies
  end

  defp compare_volumes(source, target) do
    source_volumes = Map.get(source, "volumes") || Map.get(source, :volumes) || []
    target_volumes = Map.get(target, "volumes") || Map.get(target, :volumes) || []
    source_mounts = MapSet.new(Enum.map(source_volumes, & &1["mount_path"]))
    target_mounts = MapSet.new(Enum.map(target_volumes, & &1["mount_path"]))
    missing = MapSet.difference(source_mounts, target_mounts)
    extra = MapSet.difference(target_mounts, source_mounts)
    inconsistencies = []

    inconsistencies =
      if MapSet.size(missing) > 0 do
        [
          %{
            field: "volumes",
            source_value: MapSet.to_list(missing),
            target_value: nil,
            severity: :critical,
            category: :storage,
            description: "Volume mounts missing in target: #{inspect(MapSet.to_list(missing))}"
          }
          | inconsistencies
        ]
      else
        inconsistencies
      end

    inconsistencies =
      if MapSet.size(extra) > 0 do
        [
          %{
            field: "volumes",
            source_value: nil,
            target_value: MapSet.to_list(extra),
            severity: :minor,
            category: :storage,
            description: "Extra volume mounts in target: #{inspect(MapSet.to_list(extra))}"
          }
          | inconsistencies
        ]
      else
        inconsistencies
      end

    inconsistencies
  end

  defp compare_labels(source, target) do
    source_labels = Map.get(source, "labels") || Map.get(source, :labels) || %{}
    target_labels = Map.get(target, "labels") || Map.get(target, :labels) || %{}

    different =
      Map.keys(source_labels)
      |> Enum.filter(fn key ->
        Map.get(source_labels, key) != Map.get(target_labels, key)
      end)

    if length(different) > 0 do
      [
        %{
          field: "labels",
          source_value: Map.take(source_labels, different),
          target_value: Map.take(target_labels, different),
          severity: :minor,
          category: :metadata,
          description: "Label mismatch for keys: #{inspect(different)}"
        }
      ]
    else
      []
    end
  end

  defp compare_restart_policy(source, target) do
    source_policy = Map.get(source, "restart_policy") || Map.get(source, :restart_policy)
    target_policy = Map.get(target, "restart_policy") || Map.get(target, :restart_policy)

    if source_policy != target_policy do
      [
        %{
          field: "restart_policy",
          source_value: source_policy,
          target_value: target_policy,
          severity: :major,
          category: :configuration,
          description: "Restart policy mismatch"
        }
      ]
    else
      []
    end
  end

  defp compare_resource_limits(source, target) do
    source_limits = Map.get(source, "resource_limits") || Map.get(source, :resource_limits) || %{}
    target_limits = Map.get(target, "resource_limits") || Map.get(target, :resource_limits) || %{}

    [
      compare_limit_field("cpu_limit", source_limits, target_limits, :major),
      compare_limit_field("memory_limit", source_limits, target_limits, :major),
      compare_limit_field("disk_limit", source_limits, target_limits, :minor)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp compare_limit_field(field, source_limits, target_limits, severity) do
    source_val = Map.get(source_limits, field) || Map.get(source_limits, String.to_atom(field))
    target_val = Map.get(target_limits, field) || Map.get(target_limits, String.to_atom(field))

    if source_val != target_val do
      %{
        field: "resource_limits.#{field}",
        source_value: source_val,
        target_value: target_val,
        severity: severity,
        category: :resource,
        description: "Resource limit '#{field}' mismatch"
      }
    else
      nil
    end
  end

  defp compare_ports(source, target) do
    source_ports = Map.get(source, "ports") || Map.get(source, :ports) || []
    target_ports = Map.get(target, "ports") || Map.get(target, :ports) || []
    source_set = MapSet.new(source_ports)
    target_set = MapSet.new(target_ports)
    missing = MapSet.difference(source_set, target_set)
    extra = MapSet.difference(target_set, source_set)
    inconsistencies = []

    inconsistencies =
      if MapSet.size(missing) > 0 do
        [
          %{
            field: "ports",
            source_value: MapSet.to_list(missing),
            target_value: nil,
            severity: :critical,
            category: :network,
            description: "Ports missing in target: #{inspect(MapSet.to_list(missing))}"
          }
          | inconsistencies
        ]
      else
        inconsistencies
      end

    inconsistencies =
      if MapSet.size(extra) > 0 do
        [
          %{
            field: "ports",
            source_value: nil,
            target_value: MapSet.to_list(extra),
            severity: :minor,
            category: :network,
            description: "Extra ports in target: #{inspect(MapSet.to_list(extra))}"
          }
          | inconsistencies
        ]
      else
        inconsistencies
      end

    inconsistencies
  end

  defp compare_network_config(source, target) do
    source_net = Map.get(source, "network_config") || Map.get(source, :network_config) || %{}
    target_net = Map.get(target, "network_config") || Map.get(target, :network_config) || %{}

    [
      compare_field_in_map("subnet", source_net, target_net, :major, :network),
      compare_field_in_map("gateway", source_net, target_net, :major, :network),
      compare_field_in_map("dns_servers", source_net, target_net, :minor, :network)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp compare_field_in_map(field, source_map, target_map, severity, category) do
    source_val = Map.get(source_map, field) || Map.get(source_map, String.to_atom(field))
    target_val = Map.get(target_map, field) || Map.get(target_map, String.to_atom(field))

    if source_val != target_val do
      %{
        field: field,
        source_value: source_val,
        target_value: target_val,
        severity: severity,
        category: category,
        description: "Network config '#{field}' mismatch"
      }
    else
      nil
    end
  end

  defp verify_connectivity(_source, _target) do
    []
  end

  defp compare_process_list(_source, _target) do
    []
  end

  defp compare_open_files(_source, _target) do
    []
  end

  defp verify_data_checksums(source, target) do
    source_checksum = Map.get(source, "data_checksum") || Map.get(source, :data_checksum)
    target_checksum = Map.get(target, "data_checksum") || Map.get(target, :data_checksum)

    if source_checksum != nil and target_checksum != nil and source_checksum != target_checksum do
      [
        %{
          field: "data_checksum",
          source_value: source_checksum,
          target_value: target_checksum,
          severity: :critical,
          category: :integrity,
          description: "Data checksum mismatch - possible data corruption or incomplete migration"
        }
      ]
    else
      []
    end
  end

  defp compare_file_permissions(_source, _target), do: []
  defp compare_directory_structure(_source, _target), do: []
  defp verify_critical_files(_source, _target), do: []
  defp compare_running_processes(_source, _target), do: []
  defp compare_process_tree(_source, _target), do: []
  defp compare_system_resources(_source, _target), do: []
  defp semantically_equivalent?(_field, nil, nil), do: true
  defp semantically_equivalent?(_field, nil, _), do: false
  defp semantically_equivalent?(_field, _, nil), do: false

  defp semantically_equivalent?("status", source, target) do
    status_equivalent?(source, target)
  end

  defp semantically_equivalent?(_field, source, target) do
    cond do
      is_number(source) and is_binary(target) ->
        to_string(source) == target

      is_binary(source) and is_number(target) ->
        source == to_string(target)

      true ->
        source == target
    end
  end

  defp status_equivalent?(source, target) when is_binary(source) and is_binary(target) do
    normalized_source = normalize_status(source)
    normalized_target = normalize_status(target)

    normalized_source == normalized_target or
      MapSet.member?(
        Map.get(@status_equivalents, normalized_source, MapSet.new()),
        normalized_target
      )
  end

  defp status_equivalent?(_, _), do: false

  defp normalize_status(status) when is_binary(status) do
    String.downcase(String.trim(status))
  end

  defp normalize_status(status) when is_atom(status) do
    status |> Atom.to_string() |> normalize_status()
  end

  defp normalize_status(_), do: "unknown"

  defp calculate_severity(inconsistencies) do
    cond do
      Enum.any?(inconsistencies, &(&1.severity == :critical)) -> :critical
      Enum.any?(inconsistencies, &(&1.severity == :major)) -> :major
      Enum.any?(inconsistencies, &(&1.severity == :minor)) -> :minor
      true -> :none
    end
  end

  defp count_by_severity(inconsistencies, severity) do
    Enum.count(inconsistencies, &(&1.severity == severity))
  end

  defp generate_recommendations(inconsistencies, config) do
    recommendations = []
    critical = Enum.filter(inconsistencies, &(&1.severity == :critical))

    recommendations =
      if length(critical) > 0 do
        [
          "URGENT: #{length(critical)} critical inconsistencies detected. Immediate intervention required."
          | recommendations
        ]
      else
        recommendations
      end

    major = Enum.filter(inconsistencies, &(&1.severity == :major))

    recommendations =
      if length(major) > 0 do
        [
          "#{length(major)} major inconsistencies detected. Consider automatic healing or manual review."
          | recommendations
        ]
      else
        recommendations
      end

    config_issues = Enum.filter(inconsistencies, &(&1.category == :configuration))

    recommendations =
      if length(config_issues) > 3 do
        [
          "Multiple configuration drifts detected. Verify migration configuration templates."
          | recommendations
        ]
      else
        recommendations
      end

    integrity_issues = Enum.filter(inconsistencies, &(&1.category == :integrity))

    recommendations =
      if length(integrity_issues) > 0 do
        ["Data integrity issues detected. Consider rollback or data re-sync." | recommendations]
      else
        recommendations
      end

    recommendations =
      if config.healing_strategy != :auto and length(inconsistencies) > 0 do
        [
          "Consider enabling auto-healing (healing_strategy: :auto) for automatic drift correction."
          | recommendations
        ]
      else
        recommendations
      end

    Enum.reverse(recommendations)
  end
end
