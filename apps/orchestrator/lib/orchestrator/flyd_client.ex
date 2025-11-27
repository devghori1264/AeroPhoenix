defmodule Orchestrator.FlydClient do
  require Logger
  alias Orchestrator.Migration.{CircuitBreaker, Rollback}
  @base Application.compile_env(:orchestrator, [:flyd, :url], "http://localhost:8080")
  @spec start_machine(String.t()) :: {:ok, map()} | {:error, any()}
  def start_machine(id) do
    with_circuit_breaker(:flyd_lifecycle, fn ->
      call(:post, "/v1/machines/#{id}/start", %{})
    end)
  end

  def stop_machine(id) do
    with_circuit_breaker(:flyd_lifecycle, fn ->
      call(:post, "/v1/machines/#{id}/stop", %{})
    end)
  end

  def get_machine(id) do
    with_circuit_breaker(:flyd_read, fn ->
      call(:get, "/v1/machines/#{id}")
    end)
  end

  @spec migrate_machine(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def migrate_machine(machine_id, target_region, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, "stop_and_move")

    unless strategy in ["stop_and_move", "live_migration", "clone_and_redirect"] do
      {:error, {:invalid_strategy, strategy}}
    else
      payload = %{
        machine_id: machine_id,
        target_region: target_region,
        strategy: strategy,
        options: build_migration_options(opts)
      }

      start_time = System.monotonic_time(:millisecond)

      result =
        with_circuit_breaker(:flyd_migration, fn ->
          call(:post, "/migrate", payload)
        end)

      case result do
        {:ok, response} ->
          duration = System.monotonic_time(:millisecond) - start_time

          Logger.info("Migration started: #{machine_id} -> #{target_region}",
            migration_id: response["migration_id"],
            strategy: strategy,
            estimated_duration_ms: response["estimated_duration_ms"],
            api_latency_ms: duration
          )

          :telemetry.execute(
            [:orchestrator, :migration, :start],
            %{duration_ms: duration},
            %{
              machine_id: machine_id,
              target_region: target_region,
              strategy: strategy,
              migration_id: response["migration_id"]
            }
          )

          {:ok, response}

        {:error, :circuit_open} = error ->
          Logger.error("Migration failed: circuit breaker open",
            machine_id: machine_id,
            target_region: target_region,
            strategy: strategy
          )

          :telemetry.execute(
            [:orchestrator, :migration, :circuit_open],
            %{},
            %{machine_id: machine_id, target_region: target_region}
          )

          error

        {:error, reason} = error ->
          Logger.error("Migration failed to start: #{machine_id} -> #{target_region}",
            reason: inspect(reason),
            strategy: strategy
          )

          :telemetry.execute(
            [:orchestrator, :migration, :start_failed],
            %{},
            %{machine_id: machine_id, target_region: target_region, reason: reason}
          )

          error
      end
    end
  end

  @spec rollback_migration(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rollback_migration(migration_id, opts \\ []) do
    Logger.warning("Initiating migration rollback", migration_id: migration_id)

    with {:ok, plan} <- Rollback.create_rollback_plan(migration_id, opts),
         {:ok, result} <- Rollback.execute_rollback(plan, opts) do
      {:ok, result}
    end
  end

  @spec get_migration_status(String.t()) :: {:ok, map()} | {:error, any()}
  def get_migration_status(migration_id) do
    case call(:get, "/migration/status?migration_id=#{migration_id}") do
      {:ok, status} ->
        Logger.debug("Migration status retrieved: #{migration_id}",
          phase: status["phase"],
          state: status["state"],
          progress_percent: status["progress_percent"]
        )

        {:ok, status}

      {:error, reason} = error ->
        Logger.warning("Failed to get migration status: #{migration_id}",
          reason: inspect(reason)
        )

        error
    end
  end

  @spec stream_migration_progress(String.t(), function()) :: {:ok, pid()} | {:error, any()}
  def stream_migration_progress(migration_id, callback) when is_function(callback, 1) do
    parent = self()

    pid =
      spawn_link(fn ->
        url = @base <> "/migration/stream?migration_id=#{migration_id}"
        Logger.info("Starting migration progress stream: #{migration_id}", url: url)
        request = Finch.build(:get, url, [{"accept", "text/event-stream"}])

        case Finch.stream(request, Orchestrator.Finch, nil, fn
               {:status, status}, acc ->
                 if status != 200 do
                   send(parent, {:migration_error, {:http_status, status}})
                   {:halt, acc}
                 else
                   {:cont, acc}
                 end

               {:headers, _headers}, acc ->
                 {:cont, acc}

               {:data, data}, acc ->
                 case parse_sse_event(data) do
                   {:ok, event} ->
                     callback.(event)

                     case event["type"] do
                       "complete" ->
                         send(parent, {:migration_complete, event})
                         {:halt, acc}

                       "error" ->
                         send(parent, {:migration_error, event["error"]})
                         {:halt, acc}

                       "progress" ->
                         send(parent, {:migration_progress, event})
                         {:cont, acc}

                       _ ->
                         {:cont, acc}
                     end

                   {:error, _reason} ->
                     {:cont, acc}
                 end
             end) do
          {:ok, _response} ->
            Logger.info("Migration stream completed: #{migration_id}")

          {:error, reason} ->
            Logger.error("Migration stream error: #{migration_id}", reason: inspect(reason))
            send(parent, {:migration_error, reason})
        end
      end)

    {:ok, pid}
  end

  defp build_migration_options(opts) do
    options = %{}

    options =
      if timeout = Keyword.get(opts, :timeout_seconds) do
        Map.put(options, :timeout_seconds, timeout)
      else
        options
      end

    options =
      if preserve_ip = Keyword.get(opts, :preserve_ip) do
        Map.put(options, :preserve_ip, preserve_ip)
      else
        options
      end

    options =
      if skip_verification = Keyword.get(opts, :skip_state_verification) do
        Map.put(options, :skip_state_verification, skip_verification)
      else
        options
      end

    options =
      if metadata = Keyword.get(opts, :metadata) do
        Map.put(options, :metadata, metadata)
      else
        options
      end

    if map_size(options) == 0, do: nil, else: options
  end

  defp parse_sse_event(data) do
    case String.split(data, "\n", parts: 2) do
      ["data: " <> json_str | _] ->
        case Jason.decode(json_str) do
          {:ok, event} -> {:ok, event}
          error -> error
        end

      _ ->
        {:error, :invalid_sse_format}
    end
  end

  defp call(method, path, body \\ nil, attempt \\ 1)
  defp call(_m, _p, _b, attempt) when attempt > 4, do: {:error, :max_retries}

  defp call(method, path, body, attempt) do
    url = @base <> path
    headers = [{"content-type", "application/json"}]
    opts = [timeout: 5_000]
    payload = if body == %{} or body == nil, do: "", else: Jason.encode!(body)

    case Finch.build(method, url, headers, payload)
         |> Finch.request(Orchestrator.Finch, receive_timeout: opts[:timeout]) do
      {:ok, %{status: s, body: b}} when s in 200..299 ->
        case Jason.decode(b) do
          {:ok, json} -> {:ok, json}
          _ -> {:ok, %{"raw" => b}}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 400, body: b}} ->
        case Jason.decode(b) do
          {:ok, %{"error" => error}} -> {:error, {:bad_request, error}}
          _ -> {:error, :bad_request}
        end

      {:ok, %{status: s}} ->
        Logger.warning("flyd client non-200 #{s} for #{url}")
        :timer.sleep(100 * attempt)
        call(method, path, body, attempt + 1)

      {:error, reason} ->
        Logger.warning("flyd http error #{inspect(reason)}")
        :timer.sleep(100 * attempt)
        call(method, path, body, attempt + 1)
    end
  end

  @spec pause_machine(String.t(), String.t()) :: :ok | {:error, term()}
  def pause_machine(region, machine_id) do
    with_circuit_breaker(:flyd_lifecycle, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/pause", %{})
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec resume_machine(String.t(), String.t()) :: :ok | {:error, term()}
  def resume_machine(region, machine_id) do
    with_circuit_breaker(:flyd_lifecycle, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/resume", %{})
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec get_machine_pages(String.t(), String.t(), list(non_neg_integer())) ::
          {:ok, list(map())} | {:error, term()}
  def get_machine_pages(region, machine_id, page_numbers \\ []) do
    query = if page_numbers == [], do: "", else: "?pages=#{Enum.join(page_numbers, ",")}"

    with_circuit_breaker(:flyd_read, fn ->
      call(:get, "/v1/regions/#{region}/machines/#{machine_id}/pages#{query}")
    end)
    |> case do
      {:ok, %{"pages" => pages}} -> {:ok, pages}
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec write_machine_pages(String.t(), String.t(), list(map()), binary() | nil) ::
          :ok | {:error, term()}
  def write_machine_pages(region, machine_id, pages, checksum \\ nil) do
    payload = %{pages: pages}
    payload = if checksum, do: Map.put(payload, :checksum, checksum), else: payload

    with_circuit_breaker(:flyd_write, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/pages", payload)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec get_dirty_pages_since_checkpoint(String.t(), String.t(), String.t()) ::
          {:ok, list(non_neg_integer())} | {:error, term()}
  def get_dirty_pages_since_checkpoint(region, machine_id, checkpoint_id) do
    with_circuit_breaker(:flyd_read, fn ->
      call(
        :get,
        "/v1/regions/#{region}/machines/#{machine_id}/dirty_pages?checkpoint=#{checkpoint_id}"
      )
    end)
    |> case do
      {:ok, %{"dirty_pages" => pages}} -> {:ok, pages}
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec create_fs_snapshot(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def create_fs_snapshot(region, machine_id, opts \\ %{}) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/fs/snapshot", opts)
    end)
    |> case do
      {:ok, %{"snapshot_id" => id}} -> {:ok, id}
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec restore_fs_snapshot(String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def restore_fs_snapshot(region, machine_id, snapshot_id) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/fs/restore", %{
        snapshot_id: snapshot_id
      })
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec get_machine_network_state(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_machine_network_state(region, machine_id) do
    with_circuit_breaker(:flyd_read, fn ->
      call(:get, "/v1/regions/#{region}/machines/#{machine_id}/network/state")
    end)
    |> case do
      {:ok, state} -> {:ok, state}
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec restore_machine_network_state(String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def restore_machine_network_state(region, machine_id, state) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/network/restore", state)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec verify_pages_checksum(String.t(), String.t(), list(map())) ::
          {:ok, boolean()} | {:error, term()}
  def verify_pages_checksum(region, machine_id, page_checksums) do
    with_circuit_breaker(:flyd_read, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/pages/verify", %{
        checksums: page_checksums
      })
    end)
    |> case do
      {:ok, %{"valid" => valid}} -> {:ok, valid}
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec get_machine_health(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_machine_health(region, machine_id) do
    with_circuit_breaker(:flyd_read, fn ->
      call(:get, "/v1/regions/#{region}/machines/#{machine_id}/health")
    end)
    |> case do
      {:ok, health} -> {:ok, health}
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec drain_connections(String.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def drain_connections(region, machine_id, timeout_ms) do
    with_circuit_breaker(:flyd_lifecycle, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/drain", %{
        timeout_ms: timeout_ms
      })
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec release_ip(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def release_ip(region, machine_id) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/ip/release", %{})
    end)
    |> case do
      {:ok, %{"ip" => ip}} -> {:ok, ip}
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec assign_ip(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def assign_ip(region, machine_id, ip_address) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/ip/assign", %{
        ip: ip_address
      })
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec update_dns_record(String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def update_dns_record(machine_id, target_region, ttl) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:post, "/v1/dns/update", %{
        machine_id: machine_id,
        target_region: target_region,
        ttl: ttl
      })
    end)
    |> case do
      {:ok, %{"endpoint" => endpoint}} -> {:ok, endpoint}
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec start_traffic_capture(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def start_traffic_capture(region, machine_id) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/traffic/capture", %{})
    end)
    |> case do
      {:ok, %{"buffer_id" => id}} -> {:ok, id}
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec replay_captured_traffic(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def replay_captured_traffic(buffer_id, endpoint) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:post, "/v1/traffic/replay", %{
        buffer_id: buffer_id,
        endpoint: endpoint
      })
    end)
    |> case do
      {:ok, stats} -> {:ok, stats}
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec get_connection_stats(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_connection_stats(region, machine_id) do
    with_circuit_breaker(:flyd_read, fn ->
      call(:get, "/v1/regions/#{region}/machines/#{machine_id}/connections/stats")
    end)
    |> case do
      {:ok, stats} -> {:ok, stats}
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec destroy_machine(String.t(), String.t()) :: :ok | {:error, term()}
  def destroy_machine(region, machine_id) do
    with_circuit_breaker(:flyd_lifecycle, fn ->
      call(:delete, "/v1/regions/#{region}/machines/#{machine_id}", %{})
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, :not_implemented} -> {:error, :not_implemented}
      error -> error
    end
  end

  @spec get_region_capacity(String.t()) :: {:ok, map()} | {:error, term()}
  def get_region_capacity(region) do
    with_circuit_breaker(:flyd_read, fn ->
      call(:get, "/v1/regions/#{region}/capacity")
    end)
  end

  @spec ping_region(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def ping_region(source_region, target_region) do
    with_circuit_breaker(:flyd_read, fn ->
      call(:post, "/v1/regions/#{source_region}/ping", %{target: target_region})
    end)
  end

  @spec get_machine_size(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_machine_size(region, machine_id) do
    with_circuit_breaker(:flyd_read, fn ->
      call(:get, "/v1/regions/#{region}/machines/#{machine_id}/size")
    end)
  end

  @spec update_machine_config(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_machine_config(region, machine_id, config) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:patch, "/v1/regions/#{region}/machines/#{machine_id}/config", config)
    end)
  end

  @spec update_machine_resources(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_machine_resources(region, machine_id, resources) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:patch, "/v1/regions/#{region}/machines/#{machine_id}/resources", resources)
    end)
  end

  @spec update_machine_network(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_machine_network(region, machine_id, network) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:patch, "/v1/regions/#{region}/machines/#{machine_id}/network", network)
    end)
  end

  @spec get_machine_memory_dump(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def get_machine_memory_dump(region, machine_id) do
    with_circuit_breaker(:flyd_read, fn ->
      call(:get, "/v1/regions/#{region}/machines/#{machine_id}/memory")
    end)
  end

  @spec get_machine_app_state(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_machine_app_state(region, machine_id) do
    with_circuit_breaker(:flyd_read, fn ->
      call(:get, "/v1/regions/#{region}/machines/#{machine_id}/app_state")
    end)
  end

  @spec restore_machine_memory(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def restore_machine_memory(region, machine_id, dump) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/memory/restore", %{dump: dump})
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @spec restore_machine_app_state(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def restore_machine_app_state(region, machine_id, state) do
    with_circuit_breaker(:flyd_write, fn ->
      call(:post, "/v1/regions/#{region}/machines/#{machine_id}/app_state/restore", state)
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @spec get_critical_pages(String.t(), String.t()) ::
          {:ok, list(non_neg_integer())} | {:error, term()}
  def get_critical_pages(region, machine_id) do
    with_circuit_breaker(:flyd_read, fn ->
      call(:get, "/v1/regions/#{region}/machines/#{machine_id}/pages/critical")
    end)
    |> case do
      {:ok, %{"pages" => pages}} -> {:ok, pages}
      error -> error
    end
  end

  @spec get_machine_state(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_machine_state(machine_id, opts \\ []) do
    region = Keyword.get(opts, :region)

    path =
      if region,
        do: "/v1/regions/#{region}/machines/#{machine_id}/state",
        else: "/v1/machines/#{machine_id}/state"

    with_circuit_breaker(:flyd_read, fn ->
      call(:get, path)
    end)
  end

  defp with_circuit_breaker(circuit_name, fun) do
    case Process.whereis(CircuitBreaker) do
      nil ->
        fun.()

      _pid ->
        CircuitBreaker.call(circuit_name, fun)
    end
  end
end
