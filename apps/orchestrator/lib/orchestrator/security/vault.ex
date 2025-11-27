defmodule Orchestrator.Security.Vault do
  use GenServer
  require Logger

  @table_name :vault_secrets
  @default_ttl 300

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec generate_secret(String.t(), keyword()) :: {:ok, String.t(), DateTime.t()}
  def generate_secret(machine_id, opts \\ []) do
    GenServer.call(__MODULE__, {:generate_secret, machine_id, opts})
  end

  @spec get_secret(String.t()) ::
          {:ok, String.t(), DateTime.t()} | {:error, :expired | :not_found}
  def get_secret(machine_id) do
    GenServer.call(__MODULE__, {:get_secret, machine_id})
  end

  @spec revoke_secret(String.t()) :: :ok
  def revoke_secret(machine_id) do
    GenServer.call(__MODULE__, {:revoke_secret, machine_id})
  end

  @spec list_secrets() :: list({String.t(), DateTime.t()})
  def list_secrets do
    GenServer.call(__MODULE__, :list_secrets)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [
      :set,
      :named_table,
      :public,
      read_concurrency: true
    ])

    schedule_expiration_check()

    Logger.info("Vault started", table: @table_name)

    {:ok, %{}}
  end

  @impl true
  def handle_call({:generate_secret, machine_id, opts}, _from, state) do
    random_bytes = :crypto.strong_rand_bytes(32)

    secret = Base.url_encode64(random_bytes, padding: false)

    ttl = Keyword.get(opts, :ttl, @default_ttl)
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

    :ets.insert(@table_name, {machine_id, secret, expires_at})

    Logger.info("Secret generated",
      machine_id: machine_id,
      ttl_seconds: ttl,
      expires_at: expires_at
    )

    :telemetry.execute(
      [:orchestrator, :security, :secret_generated],
      %{ttl_seconds: ttl},
      %{machine_id: machine_id, expires_at: expires_at}
    )

    {:reply, {:ok, secret, expires_at}, state}
  end

  @impl true
  def handle_call({:get_secret, machine_id}, _from, state) do
    result =
      case :ets.lookup(@table_name, machine_id) do
        [{^machine_id, secret, expires_at}] ->
          if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
            :telemetry.execute(
              [:orchestrator, :security, :secret_accessed],
              %{},
              %{machine_id: machine_id}
            )

            {:ok, secret, expires_at}
          else
            :ets.delete(@table_name, machine_id)

            Logger.warning("Secret expired", machine_id: machine_id)

            :telemetry.execute(
              [:orchestrator, :security, :secret_expired],
              %{},
              %{machine_id: machine_id}
            )

            {:error, :expired}
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:revoke_secret, machine_id}, _from, state) do
    :ets.delete(@table_name, machine_id)

    Logger.info("Secret revoked", machine_id: machine_id)

    :telemetry.execute(
      [:orchestrator, :security, :secret_revoked],
      %{},
      %{machine_id: machine_id}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_secrets, _from, state) do
    secrets =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {machine_id, _secret, expires_at} -> {machine_id, expires_at} end)

    {:reply, secrets, state}
  end

  @impl true
  def handle_info(:expire_secrets, state) do
    now = DateTime.utc_now()

    expired =
      :ets.tab2list(@table_name)
      |> Enum.filter(fn {_machine_id, _secret, expires_at} ->
        DateTime.compare(now, expires_at) != :lt
      end)

    Enum.each(expired, fn {machine_id, _secret, _expires_at} ->
      :ets.delete(@table_name, machine_id)

      Logger.debug("Secret expired (cleanup)", machine_id: machine_id)

      :telemetry.execute(
        [:orchestrator, :security, :secret_expired],
        %{},
        %{machine_id: machine_id}
      )
    end)

    if length(expired) > 0 do
      Logger.info("Cleaned expired secrets", count: length(expired))
    end

    schedule_expiration_check()

    {:noreply, state}
  end

  defp schedule_expiration_check do
    Process.send_after(self(), :expire_secrets, 10_000)
  end
end
