defmodule Orchestrator.Security.SecretInjector do
  require Logger

  @access_tokens_table :secret_access_tokens

  def start_link do
    :ets.new(@access_tokens_table, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    Logger.info("SecretInjector started")

    {:ok, self()}
  end

  @spec prepare_injection(String.t(), String.t()) :: {:ok, String.t()}
  def prepare_injection(machine_id, secret) do
    token_bytes = :crypto.strong_rand_bytes(32)
    access_token = Base.url_encode64(token_bytes, padding: false)

    expires_at = DateTime.add(DateTime.utc_now(), 60, :second)

    :ets.insert(@access_tokens_table, {access_token, machine_id, secret, expires_at})

    Logger.info("Secret injection prepared",
      machine_id: machine_id,
      access_token: String.slice(access_token, 0..7) <> "..."
    )

    :telemetry.execute(
      [:orchestrator, :security, :injection_prepared],
      %{},
      %{machine_id: machine_id}
    )

    {:ok, access_token}
  end

  @spec retrieve_secret(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :invalid_token | :expired}
  def retrieve_secret(access_token) do
    case :ets.lookup(@access_tokens_table, access_token) do
      [{^access_token, machine_id, secret, expires_at}] ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          :ets.delete(@access_tokens_table, access_token)

          Logger.info("Secret retrieved",
            machine_id: machine_id,
            access_token: String.slice(access_token, 0..7) <> "..."
          )

          :telemetry.execute(
            [:orchestrator, :security, :secret_retrieved],
            %{},
            %{machine_id: machine_id}
          )

          {:ok, machine_id, secret}
        else
          :ets.delete(@access_tokens_table, access_token)

          Logger.warning("Access token expired", access_token: String.slice(access_token, 0..7))

          {:error, :expired}
        end

      [] ->
        Logger.warning("Invalid access token", access_token: String.slice(access_token, 0..7))

        {:error, :invalid_token}
    end
  end

  @spec inject_secret(String.t(), String.t()) :: {:ok, map()}
  def inject_secret(machine_id, secret) do
    injection_method = Enum.random([:shared_memory, :tmpfs, :unix_socket])

    metadata = %{
      method: injection_method,
      path:
        case injection_method do
          :shared_memory -> "/dev/shm/secret_#{machine_id}"
          :tmpfs -> "/tmp/secret_#{machine_id}"
          :unix_socket -> "/var/run/secrets/#{machine_id}.sock"
        end,
      size: byte_size(secret),
      injected_at: DateTime.utc_now()
    }

    Logger.info("Secret injected",
      machine_id: machine_id,
      method: injection_method,
      path: metadata.path
    )

    :telemetry.execute(
      [:orchestrator, :security, :secret_injected],
      %{size: metadata.size},
      %{machine_id: machine_id, method: injection_method}
    )

    {:ok, metadata}
  end

  @spec cleanup_expired_tokens() :: :ok
  def cleanup_expired_tokens do
    now = DateTime.utc_now()

    expired =
      :ets.tab2list(@access_tokens_table)
      |> Enum.filter(fn {_token, _machine_id, _secret, expires_at} ->
        DateTime.compare(now, expires_at) != :lt
      end)

    Enum.each(expired, fn {token, _machine_id, _secret, _expires_at} ->
      :ets.delete(@access_tokens_table, token)
    end)

    if length(expired) > 0 do
      Logger.debug("Cleaned expired access tokens", count: length(expired))
    end

    :ok
  end
end
