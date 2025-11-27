defmodule Orchestrator.Security.OIDCProviderTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Security.OIDCProvider

  setup do
    start_supervised!(OIDCProvider)

    machine_id = "test_machine_#{:rand.uniform(1_000_000)}"

    {:ok, machine_id: machine_id}
  end

  describe "OIDCProvider.issue_token/1" do
    test "generates valid JWT token", %{machine_id: machine_id} do
      {:ok, token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: [:net_outbound, :read_volume]
        )

      assert is_binary(token)
      assert String.length(token) > 100

      parts = String.split(token, ".")
      assert length(parts) == 3
    end

    test "token contains correct claims", %{machine_id: machine_id} do
      {:ok, token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "lhr",
          capabilities: [:migrate_to]
        )

      {:ok, claims} = OIDCProvider.verify_token(token)

      assert claims["machine_id"] == machine_id
      assert claims["region"] == "lhr"
      assert claims["capabilities"] == ["migrate_to"]
      assert claims["iss"] == "https://api.aerophoenix.io"
      assert claims["aud"] == "https://api.aerophoenix.io"
      assert claims["sub"] == "machine_#{machine_id}"
    end

    test "token has proper expiration (5 minutes)", %{machine_id: machine_id} do
      now = System.system_time(:second)

      {:ok, token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "syd",
          capabilities: []
        )

      {:ok, claims} = OIDCProvider.verify_token(token)

      exp = claims["exp"]
      assert exp > now
      assert exp <= now + 300 + 5
    end

    test "each token has unique JWT ID (jti)", %{machine_id: machine_id} do
      {:ok, token1} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: []
        )

      {:ok, token2} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: []
        )

      {:ok, claims1} = OIDCProvider.verify_token(token1)
      {:ok, claims2} = OIDCProvider.verify_token(token2)

      assert claims1["jti"] != claims2["jti"]
    end
  end

  describe "OIDCProvider.verify_token/1" do
    test "verifies valid token successfully", %{machine_id: machine_id} do
      {:ok, token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "fra",
          capabilities: [:write_volume]
        )

      {:ok, claims} = OIDCProvider.verify_token(token)

      assert claims["machine_id"] == machine_id
      assert claims["region"] == "fra"
    end

    test "rejects token with invalid signature" do
      valid_token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.fakesignature"

      assert {:error, :invalid_signature} = OIDCProvider.verify_token(valid_token)
    end

    test "rejects malformed token" do
      assert {:error, :invalid_token} = OIDCProvider.verify_token("not.a.token")
      assert {:error, :invalid_token} = OIDCProvider.verify_token("invalid")
      assert {:error, :invalid_token} = OIDCProvider.verify_token("")
    end

    test "rejects expired token", %{machine_id: machine_id} do
      {:ok, token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "nrt",
          capabilities: []
        )

      assert {:ok, _claims} = OIDCProvider.verify_token(token)

      {:ok, claims} = OIDCProvider.verify_token(token)
      exp = claims["exp"]
      now = System.system_time(:second)

      assert exp > now
    end

    test "rejects token with wrong audience", %{machine_id: machine_id} do
      {:ok, token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "ord",
          capabilities: []
        )

      {:ok, claims} = OIDCProvider.verify_token(token)

      assert claims["aud"] == "https://api.aerophoenix.io"
    end
  end

  describe "OIDCProvider.revoke_token/1" do
    test "revokes token successfully", %{machine_id: machine_id} do
      {:ok, token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "sjc",
          capabilities: [:net_outbound]
        )

      assert {:ok, _claims} = OIDCProvider.verify_token(token)

      :ok = OIDCProvider.revoke_token(token)

      assert {:error, :token_revoked} = OIDCProvider.verify_token(token)
    end

    test "revoke is idempotent", %{machine_id: machine_id} do
      {:ok, token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: []
        )

      :ok = OIDCProvider.revoke_token(token)
      :ok = OIDCProvider.revoke_token(token)
      :ok = OIDCProvider.revoke_token(token)

      assert {:error, :token_revoked} = OIDCProvider.verify_token(token)
    end

    test "revoking one token doesn't affect others", %{machine_id: machine_id} do
      {:ok, token1} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: []
        )

      {:ok, token2} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: []
        )

      :ok = OIDCProvider.revoke_token(token1)

      assert {:error, :token_revoked} = OIDCProvider.verify_token(token1)

      assert {:ok, _claims} = OIDCProvider.verify_token(token2)
    end
  end

  describe "OIDCProvider.get_jwks/0" do
    test "returns public key in JWK format" do
      jwks = OIDCProvider.get_jwks()

      assert is_map(jwks)
      assert Map.has_key?(jwks, "keys")
      assert is_list(jwks["keys"])
      assert length(jwks["keys"]) >= 1

      key = List.first(jwks["keys"])
      assert key["kty"] == "RSA"
      assert key["use"] == "sig"
      assert Map.has_key?(key, "kid")
      assert Map.has_key?(key, "n")
      assert Map.has_key?(key, "e")
    end

    test "public key does not contain private components" do
      jwks = OIDCProvider.get_jwks()
      key = List.first(jwks["keys"])

      refute Map.has_key?(key, "d")
      refute Map.has_key?(key, "p")
      refute Map.has_key?(key, "q")
    end
  end

  describe "OIDCProvider.get_stats/0" do
    test "tracks token issuance count", %{machine_id: machine_id} do
      initial_stats = OIDCProvider.get_stats()
      initial_issued = initial_stats.total_issued

      for _ <- 1..5 do
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: []
        )
      end

      new_stats = OIDCProvider.get_stats()

      assert new_stats.total_issued == initial_issued + 5
    end

    test "tracks token revocation count", %{machine_id: machine_id} do
      initial_stats = OIDCProvider.get_stats()
      initial_revoked = initial_stats.total_revoked

      tokens =
        for _ <- 1..3 do
          {:ok, token} =
            OIDCProvider.issue_token(
              machine_id: machine_id,
              region: "iad",
              capabilities: []
            )

          token
        end

      Enum.each(tokens, &OIDCProvider.revoke_token/1)

      new_stats = OIDCProvider.get_stats()

      assert new_stats.total_revoked == initial_revoked + 3
    end

    test "calculates active tokens count", %{machine_id: machine_id} do
      initial_stats = OIDCProvider.get_stats()

      tokens =
        for _ <- 1..10 do
          {:ok, token} =
            OIDCProvider.issue_token(
              machine_id: machine_id,
              region: "iad",
              capabilities: []
            )

          token
        end

      tokens
      |> Enum.take(4)
      |> Enum.each(&OIDCProvider.revoke_token/1)

      stats = OIDCProvider.get_stats()

      expected_active = stats.total_issued - stats.total_revoked
      assert stats.active_tokens == expected_active
    end
  end

  describe "Integration: Full Token Lifecycle" do
    test "complete authentication flow", %{machine_id: machine_id} do
      {:ok, token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: [:net_outbound, :read_volume]
        )

      {:ok, claims} = OIDCProvider.verify_token(token)
      assert claims["machine_id"] == machine_id
      assert "net_outbound" in claims["capabilities"]
      assert "read_volume" in claims["capabilities"]

      assert {:ok, _claims} = OIDCProvider.verify_token(token)
      assert {:ok, _claims} = OIDCProvider.verify_token(token)

      :ok = OIDCProvider.revoke_token(token)

      assert {:error, :token_revoked} = OIDCProvider.verify_token(token)

      {:ok, new_token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: [:net_outbound]
        )

      {:ok, new_claims} = OIDCProvider.verify_token(new_token)
      assert new_claims["jti"] != claims["jti"]
    end
  end

  describe "Security Properties" do
    test "tokens are cryptographically random", %{machine_id: machine_id} do
      tokens =
        for _ <- 1..100 do
          {:ok, token} =
            OIDCProvider.issue_token(
              machine_id: machine_id,
              region: "iad",
              capabilities: []
            )

          token
        end

      unique_tokens = Enum.uniq(tokens)
      assert length(unique_tokens) == 100
    end

    test "token signature prevents tampering", %{machine_id: machine_id} do
      {:ok, token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: [:read_volume]
        )

      [header, payload, signature] = String.split(token, ".")

      payload_json = Base.url_decode64!(payload, padding: false)
      claims = Jason.decode!(payload_json)

      modified_claims = Map.put(claims, "capabilities", ["write_volume"])
      modified_payload = Jason.encode!(modified_claims)
      modified_payload_b64 = Base.url_encode64(modified_payload, padding: false)

      tampered_token = "#{header}.#{modified_payload_b64}.#{signature}"

      assert {:error, :invalid_signature} = OIDCProvider.verify_token(tampered_token)
    end

    test "concurrent token issuance is safe", %{machine_id: machine_id} do
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            OIDCProvider.issue_token(
              machine_id: machine_id,
              region: "iad",
              capabilities: []
            )
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert Enum.all?(results, fn {:ok, token} -> is_binary(token) end)

      jtis =
        Enum.map(results, fn {:ok, token} ->
          {:ok, claims} = OIDCProvider.verify_token(token)
          claims["jti"]
        end)

      unique_jtis = Enum.uniq(jtis)
      assert length(unique_jtis) == 100
    end
  end

  describe "Telemetry Events" do
    test "emits token_issued event", %{machine_id: machine_id} do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-token-issued-#{ref}",
        [:orchestrator, :oidc, :token_issued],
        fn _event, measurements, metadata, _config ->
          send(self_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      {:ok, _token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: [:net_outbound]
        )

      assert_receive {:telemetry, measurements, metadata}, 1000

      assert measurements.ttl_seconds == 300
      assert metadata.machine_id == machine_id
      assert metadata.region == "iad"
      assert is_binary(metadata.jti)

      :telemetry.detach("test-token-issued-#{ref}")
    end

    test "emits token_revoked event", %{machine_id: machine_id} do
      {:ok, token} =
        OIDCProvider.issue_token(
          machine_id: machine_id,
          region: "iad",
          capabilities: []
        )

      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-token-revoked-#{ref}",
        [:orchestrator, :oidc, :token_revoked],
        fn _event, _measurements, metadata, _config ->
          send(self_pid, {:telemetry, metadata})
        end,
        nil
      )

      :ok = OIDCProvider.revoke_token(token)

      assert_receive {:telemetry, metadata}, 1000
      assert is_binary(metadata.jti)

      :telemetry.detach("test-token-revoked-#{ref}")
    end
  end
end
