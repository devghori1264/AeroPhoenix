defmodule Orchestrator.Security.OIDCProvider do
  use GenServer
  require Logger

  @type token :: String.t()
  @type claims :: map()
  @type machine_id :: String.t()
  @type region :: String.t()
  @type capability :: atom()

  @token_ttl_seconds 300

  @key_rotation_interval_ms 90 * 24 * 60 * 60 * 1000

  @issuer "https://api.aerophoenix.io"

  @audience "https://api.aerophoenix.io"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec issue_token(keyword()) :: {:ok, token()} | {:error, atom()}
  def issue_token(opts) do
    GenServer.call(__MODULE__, {:issue_token, opts})
  end

  @spec verify_token(token()) :: {:ok, claims()} | {:error, atom()}
  def verify_token(token) do
    GenServer.call(__MODULE__, {:verify_token, token})
  end

  @spec revoke_token(token()) :: :ok | {:error, atom()}
  def revoke_token(token) do
    GenServer.call(__MODULE__, {:revoke_token, token})
  end

  @spec get_jwks() :: map()
  def get_jwks do
    GenServer.call(__MODULE__, :get_jwks)
  end

  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def init(_opts) do
    :ets.new(:oidc_keys, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(:oidc_revoked_tokens, [:named_table, :set, :public, read_concurrency: true])

    key_id = generate_key_id()
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    :ets.insert(:oidc_keys, {:current_key, key_id, jwk})

    Process.send_after(self(), :rotate_keys, @key_rotation_interval_ms)

    state = %{
      total_issued: 0,
      total_revoked: 0,
      current_key_id: key_id
    }

    Logger.info("OIDC Provider started with key_id=#{key_id}")

    :telemetry.execute(
      [:orchestrator, :oidc, :provider_started],
      %{},
      %{key_id: key_id}
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:issue_token, opts}, _from, state) do
    machine_id = Keyword.fetch!(opts, :machine_id)
    region = Keyword.fetch!(opts, :region)
    capabilities = Keyword.get(opts, :capabilities, [])

    [{:current_key, key_id, jwk}] = :ets.lookup(:oidc_keys, :current_key)

    now = System.system_time(:second)
    jti = generate_jti()

    claims = %{
      "iss" => @issuer,
      "sub" => "machine_#{machine_id}",
      "aud" => @audience,
      "exp" => now + @token_ttl_seconds,
      "iat" => now,
      "jti" => jti,
      "machine_id" => machine_id,
      "region" => region,
      "capabilities" => Enum.map(capabilities, &to_string/1)
    }

    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => key_id}
    {_, token} = JOSE.JWK.sign(Jason.encode!(claims), header, jwk)
    token_string = JOSE.JWS.compact(token) |> elem(1)

    new_state = %{state | total_issued: state.total_issued + 1}

    Logger.debug("Issued token for machine=#{machine_id} jti=#{jti}")

    :telemetry.execute(
      [:orchestrator, :oidc, :token_issued],
      %{ttl_seconds: @token_ttl_seconds},
      %{machine_id: machine_id, region: region, jti: jti}
    )

    {:reply, {:ok, token_string}, new_state}
  end

  @impl true
  def handle_call({:verify_token, token}, _from, state) do
    result = do_verify_token(token)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:revoke_token, token}, _from, state) do
    case extract_jti(token) do
      {:ok, jti} ->
        now = System.system_time(:second)
        expires_at = now + @token_ttl_seconds
        :ets.insert(:oidc_revoked_tokens, {jti, expires_at})

        Logger.info("Revoked token jti=#{jti}")

        :telemetry.execute(
          [:orchestrator, :oidc, :token_revoked],
          %{},
          %{jti: jti}
        )

        new_state = %{state | total_revoked: state.total_revoked + 1}
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_jwks, _from, state) do
    [{:current_key, key_id, jwk}] = :ets.lookup(:oidc_keys, :current_key)

    public_jwk = JOSE.JWK.to_public(jwk)
    public_map = JOSE.JWK.to_map(public_jwk) |> elem(1)

    jwks = %{
      "keys" => [
        Map.merge(public_map, %{
          "use" => "sig",
          "kid" => key_id
        })
      ]
    }

    {:reply, jwks, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    revoked_count = :ets.info(:oidc_revoked_tokens, :size)
    active_count = state.total_issued - state.total_revoked

    stats = %{
      total_issued: state.total_issued,
      total_revoked: state.total_revoked,
      active_tokens: active_count,
      current_key_id: state.current_key_id,
      revoked_tokens_in_denylist: revoked_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:rotate_keys, state) do
    old_key_id = state.current_key_id
    new_key_id = generate_key_id()
    new_jwk = JOSE.JWK.generate_key({:rsa, 2048})

    :ets.insert(:oidc_keys, {:current_key, new_key_id, new_jwk})

    :ets.insert(:oidc_keys, {:old_key, old_key_id})

    Logger.info("Rotated signing key: #{old_key_id} -> #{new_key_id}")

    :telemetry.execute(
      [:orchestrator, :oidc, :key_rotated],
      %{},
      %{old_key_id: old_key_id, new_key_id: new_key_id}
    )

    Process.send_after(self(), :rotate_keys, @key_rotation_interval_ms)

    new_state = %{state | current_key_id: new_key_id}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:cleanup_revoked_tokens, state) do
    now = System.system_time(:second)

    revoked_tokens = :ets.tab2list(:oidc_revoked_tokens)
    expired_jtis = for {jti, expires_at} <- revoked_tokens, expires_at < now, do: jti

    Enum.each(expired_jtis, fn jti ->
      :ets.delete(:oidc_revoked_tokens, jti)
    end)

    if length(expired_jtis) > 0 do
      Logger.debug("Cleaned up #{length(expired_jtis)} expired revoked tokens")
    end

    Process.send_after(self(), :cleanup_revoked_tokens, 5 * 60 * 1000)

    {:noreply, state}
  end

  defp do_verify_token(token) do
    with {:ok, claims} <- decode_token(token),
         :ok <- verify_signature(token),
         :ok <- verify_expiration(claims),
         :ok <- verify_audience(claims),
         :ok <- verify_not_revoked(claims) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_token(token) do
    try do
      [_header_b64, payload_b64, _signature_b64] = String.split(token, ".")

      payload_json = Base.url_decode64!(payload_b64, padding: false)
      claims = Jason.decode!(payload_json)

      {:ok, claims}
    rescue
      _ -> {:error, :invalid_token}
    end
  end

  defp verify_signature(token) do
    try do
      [{:current_key, _key_id, jwk}] = :ets.lookup(:oidc_keys, :current_key)
      {verified, _payload, _jws} = JOSE.JWK.verify_strict(token, ["RS256"], jwk)

      if verified do
        :ok
      else
        {:error, :invalid_signature}
      end
    rescue
      _ -> {:error, :invalid_signature}
    end
  end

  defp verify_expiration(claims) do
    now = System.system_time(:second)
    exp = claims["exp"]

    if exp > now do
      :ok
    else
      {:error, :token_expired}
    end
  end

  defp verify_audience(claims) do
    aud = claims["aud"]

    if aud == @audience do
      :ok
    else
      {:error, :invalid_audience}
    end
  end

  defp verify_not_revoked(claims) do
    jti = claims["jti"]

    case :ets.lookup(:oidc_revoked_tokens, jti) do
      [] -> :ok
      [{^jti, _expires_at}] -> {:error, :token_revoked}
    end
  end

  defp extract_jti(token) do
    case decode_token(token) do
      {:ok, claims} -> {:ok, claims["jti"]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_key_id do
    {{year, month, _day}, _time} = :calendar.local_time()
    "#{year}-#{String.pad_leading(to_string(month), 2, "0")}"
  end

  defp generate_jti do
    UUID.uuid4()
  end
end
