defmodule Orchestrator.Security.VaultTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Security.Vault
  alias Orchestrator.Security.SecretInjector

  @moduletag :security

  setup do
    start_supervised!(Vault)
    {:ok, _} = SecretInjector.start_link()

    machine_id = "test_machine_#{:rand.uniform(100_000)}"

    on_exit(fn ->
      Vault.revoke_secret(machine_id)
    end)

    {:ok, machine_id: machine_id}
  end

  describe "Vault.generate_secret/2" do
    test "generates cryptographically secure secret", %{machine_id: machine_id} do
      {:ok, secret, _expires_at} = Vault.generate_secret(machine_id)

      assert is_binary(secret)
      assert byte_size(secret) > 0

      refute String.contains?(secret, "=")

      decoded = Base.url_decode64!(secret, padding: false)
      assert byte_size(decoded) == 32
    end

    test "generates unique secrets", %{machine_id: machine_id} do
      {:ok, secret1, _} = Vault.generate_secret(machine_id)

      Vault.revoke_secret(machine_id)

      {:ok, secret2, _} = Vault.generate_secret(machine_id)

      assert secret1 != secret2
    end

    test "sets expiration based on TTL", %{machine_id: machine_id} do
      ttl = 120

      {:ok, _secret, expires_at} = Vault.generate_secret(machine_id, ttl: ttl)

      now = DateTime.utc_now()
      diff = DateTime.diff(expires_at, now, :second)

      assert diff >= 119 and diff <= 121
    end

    test "uses default TTL of 300 seconds", %{machine_id: machine_id} do
      {:ok, _secret, expires_at} = Vault.generate_secret(machine_id)

      now = DateTime.utc_now()
      diff = DateTime.diff(expires_at, now, :second)

      assert diff >= 299 and diff <= 301
    end
  end

  describe "Vault.get_secret/1" do
    test "retrieves valid secret", %{machine_id: machine_id} do
      {:ok, secret, _} = Vault.generate_secret(machine_id)

      assert {:ok, ^secret, _expires_at} = Vault.get_secret(machine_id)
    end

    test "returns error for non-existent secret" do
      assert {:error, :not_found} = Vault.get_secret("nonexistent_machine")
    end

    test "returns error for expired secret", %{machine_id: machine_id} do
      {:ok, _secret, _} = Vault.generate_secret(machine_id, ttl: 1)

      Process.sleep(1100)

      assert {:error, :expired} = Vault.get_secret(machine_id)
    end

    test "cleans up expired secret on access", %{machine_id: machine_id} do
      {:ok, _secret, _} = Vault.generate_secret(machine_id, ttl: 1)

      Process.sleep(1100)

      {:error, :expired} = Vault.get_secret(machine_id)

      secrets = Vault.list_secrets()
      refute Enum.any?(secrets, fn {mid, _} -> mid == machine_id end)
    end
  end

  describe "Vault.revoke_secret/1" do
    test "immediately invalidates secret", %{machine_id: machine_id} do
      {:ok, secret, _} = Vault.generate_secret(machine_id)

      assert {:ok, ^secret, _} = Vault.get_secret(machine_id)

      :ok = Vault.revoke_secret(machine_id)

      assert {:error, :not_found} = Vault.get_secret(machine_id)
    end

    test "revoke is idempotent", %{machine_id: machine_id} do
      {:ok, _secret, _} = Vault.generate_secret(machine_id)

      :ok = Vault.revoke_secret(machine_id)
      :ok = Vault.revoke_secret(machine_id)

      assert {:error, :not_found} = Vault.get_secret(machine_id)
    end
  end

  describe "Vault.list_secrets/0" do
    test "lists active secrets without exposing plaintext" do
      machine1 = "machine_list_1"
      machine2 = "machine_list_2"

      {:ok, _secret1, _} = Vault.generate_secret(machine1)
      {:ok, _secret2, _} = Vault.generate_secret(machine2)

      secrets = Vault.list_secrets()

      machine_ids = Enum.map(secrets, fn {mid, _expires_at} -> mid end)
      assert machine1 in machine_ids
      assert machine2 in machine_ids

      Enum.each(secrets, fn entry ->
        assert match?({_machine_id, %DateTime{}}, entry)
      end)

      Vault.revoke_secret(machine1)
      Vault.revoke_secret(machine2)
    end
  end

  describe "Vault expiration worker" do
    test "automatically cleans expired secrets" do
      machine1 = "machine_expire_1"
      machine2 = "machine_expire_2"

      {:ok, _secret1, _} = Vault.generate_secret(machine1, ttl: 1)

      {:ok, _secret2, _} = Vault.generate_secret(machine2, ttl: 100)

      Process.sleep(12_000)

      secrets = Vault.list_secrets()
      machine_ids = Enum.map(secrets, fn {mid, _} -> mid end)

      refute machine1 in machine_ids
      assert machine2 in machine_ids

      Vault.revoke_secret(machine2)
    end
  end

  describe "SecretInjector" do
    test "prepares injection with access token", %{machine_id: machine_id} do
      {:ok, secret, _} = Vault.generate_secret(machine_id)

      {:ok, access_token} = SecretInjector.prepare_injection(machine_id, secret)

      assert is_binary(access_token)
      assert byte_size(access_token) > 0
    end

    test "retrieves secret with valid token", %{machine_id: machine_id} do
      {:ok, secret, _} = Vault.generate_secret(machine_id)

      {:ok, access_token} = SecretInjector.prepare_injection(machine_id, secret)

      assert {:ok, ^machine_id, ^secret} = SecretInjector.retrieve_secret(access_token)
    end

    test "access token is one-time use", %{machine_id: machine_id} do
      {:ok, secret, _} = Vault.generate_secret(machine_id)

      {:ok, access_token} = SecretInjector.prepare_injection(machine_id, secret)

      assert {:ok, ^machine_id, ^secret} = SecretInjector.retrieve_secret(access_token)

      assert {:error, :invalid_token} = SecretInjector.retrieve_secret(access_token)
    end

    test "returns error for invalid token" do
      assert {:error, :invalid_token} = SecretInjector.retrieve_secret("invalid_token")
    end

    test "access token expires after 60 seconds", %{machine_id: machine_id} do
      {:ok, secret, _} = Vault.generate_secret(machine_id)

      {:ok, access_token} = SecretInjector.prepare_injection(machine_id, secret)

      Process.sleep(61_000)

      assert {:error, :expired} = SecretInjector.retrieve_secret(access_token)
    end

    test "injects secret with metadata", %{machine_id: machine_id} do
      {:ok, secret, _} = Vault.generate_secret(machine_id)

      {:ok, metadata} = SecretInjector.inject_secret(machine_id, secret)

      assert is_map(metadata)
      assert metadata.method in [:shared_memory, :tmpfs, :unix_socket]
      assert is_binary(metadata.path)
      assert metadata.size == byte_size(secret)
      assert %DateTime{} = metadata.injected_at
    end

    test "cleans expired access tokens" do
      machine1 = "machine_token_cleanup_1"

      {:ok, secret, _} = Vault.generate_secret(machine1)
      {:ok, _token} = SecretInjector.prepare_injection(machine1, secret)

      Process.sleep(61_000)

      :ok = SecretInjector.cleanup_expired_tokens()
    end
  end

  describe "Integration: Full secret lifecycle" do
    test "complete workflow from generation to injection", %{machine_id: machine_id} do
      {:ok, secret, expires_at} = Vault.generate_secret(machine_id, ttl: 300)

      assert is_binary(secret)
      assert %DateTime{} = expires_at

      {:ok, access_token} = SecretInjector.prepare_injection(machine_id, secret)

      {:ok, retrieved_machine_id, retrieved_secret} =
        SecretInjector.retrieve_secret(access_token)

      assert retrieved_machine_id == machine_id
      assert retrieved_secret == secret

      {:ok, metadata} = SecretInjector.inject_secret(machine_id, secret)

      assert metadata.method in [:shared_memory, :tmpfs, :unix_socket]

      {:ok, ^secret, ^expires_at} = Vault.get_secret(machine_id)

      :ok = Vault.revoke_secret(machine_id)

      assert {:error, :not_found} = Vault.get_secret(machine_id)
    end

    test "secret rotation workflow", %{machine_id: machine_id} do
      {:ok, secret1, _} = Vault.generate_secret(machine_id, ttl: 10)

      Process.sleep(5_000)

      :ok = Vault.revoke_secret(machine_id)
      {:ok, secret2, _} = Vault.generate_secret(machine_id, ttl: 10)

      assert secret1 != secret2

      {:ok, ^secret2, _} = Vault.get_secret(machine_id)
    end

    test "handles concurrent secret generation for different machines" do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            machine_id = "concurrent_machine_#{i}"
            Vault.generate_secret(machine_id)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert Enum.all?(results, fn result -> match?({:ok, _, _}, result) end)

      secrets = Enum.map(results, fn {:ok, secret, _} -> secret end)
      assert length(Enum.uniq(secrets)) == 100

      for i <- 1..100 do
        Vault.revoke_secret("concurrent_machine_#{i}")
      end
    end
  end

  describe "Security properties" do
    test "secrets are cryptographically random" do
      secrets =
        for i <- 1..1000 do
          {:ok, secret, _} = Vault.generate_secret("test_#{i}")
          secret
        end

      assert length(Enum.uniq(secrets)) == 1000

      for i <- 1..1000 do
        Vault.revoke_secret("test_#{i}")
      end
    end

    test "secrets never touch disk (RAM-only)" do
      {:ok, secret, _} = Vault.generate_secret("disk_test")

      tables = :ets.all()
      assert :vault_secrets in tables

      Vault.revoke_secret("disk_test")
    end

    test "secrets expire automatically (no manual cleanup needed)" do
      {:ok, _secret, _} = Vault.generate_secret("auto_expire_test", ttl: 2)

      Process.sleep(12_000)

      assert {:error, :not_found} = Vault.get_secret("auto_expire_test")
    end
  end

  describe "Telemetry events" do
    test "emits secret_generated event" do
      test_pid = self()

      :telemetry.attach(
        "test-secret-generated",
        [:orchestrator, :security, :secret_generated],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _secret, _} = Vault.generate_secret("telemetry_test")

      assert_receive {:telemetry, [:orchestrator, :security, :secret_generated], measurements,
                      metadata}

      assert measurements.ttl_seconds > 0
      assert metadata.machine_id == "telemetry_test"

      :telemetry.detach("test-secret-generated")
      Vault.revoke_secret("telemetry_test")
    end

    test "emits secret_accessed event" do
      test_pid = self()

      :telemetry.attach(
        "test-secret-accessed",
        [:orchestrator, :security, :secret_accessed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _secret, _} = Vault.generate_secret("access_test")
      Vault.get_secret("access_test")

      assert_receive {:telemetry, [:orchestrator, :security, :secret_accessed], _measurements,
                      metadata}

      assert metadata.machine_id == "access_test"

      :telemetry.detach("test-secret-accessed")
      Vault.revoke_secret("access_test")
    end
  end
end
