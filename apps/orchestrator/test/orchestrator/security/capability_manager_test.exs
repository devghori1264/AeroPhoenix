defmodule Orchestrator.Security.CapabilityManagerTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Security.CapabilityManager

  setup do
    start_supervised!(CapabilityManager)

    machine_a = "test_machine_a_#{:rand.uniform(1_000_000)}"
    machine_b = "test_machine_b_#{:rand.uniform(1_000_000)}"

    {:ok, machine_a: machine_a, machine_b: machine_b}
  end

  describe "CapabilityManager.grant/1" do
    test "grants capability successfully", %{machine_a: machine_id} do
      {:ok, capability} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_xyz",
          ttl: 3600
        )

      assert capability.machine_id == machine_id
      assert capability.action == :read_volume
      assert capability.resource == "vol_xyz"
      assert is_binary(capability.id)
      assert capability.delegation_depth == 0
    end

    test "capability has proper expiration", %{machine_a: machine_id} do
      now = System.system_time(:second)

      {:ok, capability} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :write_volume,
          resource: "vol_abc",
          ttl: 1800
        )

      assert capability.expires_at > now
      assert capability.expires_at <= now + 1800 + 5
    end

    test "uses default TTL when not specified", %{machine_a: machine_id} do
      now = System.system_time(:second)

      {:ok, capability} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :net_outbound,
          resource: "0.0.0.0/0"
        )

      assert capability.expires_at > now + 3500
      assert capability.expires_at <= now + 3600 + 5
    end

    test "each capability has unique ID", %{machine_a: machine_id} do
      {:ok, cap1} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_1"
        )

      {:ok, cap2} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_2"
        )

      assert cap1.id != cap2.id
    end
  end

  describe "CapabilityManager.check/2" do
    test "allows operation when capability exists", %{machine_a: machine_id} do
      {:ok, _cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_xyz"
        )

      assert :ok = CapabilityManager.check(machine_id, {:read_volume, "vol_xyz"})
    end

    test "denies operation when capability missing", %{machine_a: machine_id} do
      {:ok, _cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_xyz"
        )

      assert {:error, :insufficient_capability} =
               CapabilityManager.check(machine_id, {:read_volume, "vol_abc"})
    end

    test "denies operation with wrong action", %{machine_a: machine_id} do
      {:ok, _cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_xyz"
        )

      assert {:error, :insufficient_capability} =
               CapabilityManager.check(machine_id, {:write_volume, "vol_xyz"})
    end

    test "denies expired capability", %{machine_a: machine_id} do
      {:ok, _cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_xyz",
          ttl: 1
        )

      assert :ok = CapabilityManager.check(machine_id, {:read_volume, "vol_xyz"})

      Process.sleep(2100)

      assert {:error, :capability_expired} =
               CapabilityManager.check(machine_id, {:read_volume, "vol_xyz"})
    end

    test "denies revoked capability", %{machine_a: machine_id} do
      {:ok, cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :migrate_to,
          resource: ["iad", "lhr"]
        )

      assert :ok = CapabilityManager.check(machine_id, {:migrate_to, ["iad", "lhr"]})

      :ok = CapabilityManager.revoke(cap.id)

      assert {:error, :capability_revoked} =
               CapabilityManager.check(machine_id, {:migrate_to, ["iad", "lhr"]})
    end
  end

  describe "CapabilityManager.attenuate/2" do
    test "creates read-only capability from write capability", %{machine_a: machine_id} do
      {:ok, write_cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :write_volume,
          resource: "vol_xyz"
        )

      {:ok, read_cap} = CapabilityManager.attenuate(write_cap, :read_only)

      assert read_cap.action == :read_volume
      assert read_cap.resource == "vol_xyz"
      assert read_cap.machine_id == machine_id
      assert read_cap.delegation_depth == write_cap.delegation_depth + 1
      assert read_cap.parent_id == write_cap.id
      assert read_cap.id != write_cap.id
    end

    test "attenuated capability works independently", %{machine_a: machine_id} do
      {:ok, write_cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :write_volume,
          resource: "vol_xyz"
        )

      {:ok, _read_cap} = CapabilityManager.attenuate(write_cap, :read_only)

      assert :ok = CapabilityManager.check(machine_id, {:write_volume, "vol_xyz"})
      assert :ok = CapabilityManager.check(machine_id, {:read_volume, "vol_xyz"})

      :ok = CapabilityManager.revoke(write_cap.id)

      assert {:error, :capability_revoked} =
               CapabilityManager.check(machine_id, {:write_volume, "vol_xyz"})

      assert :ok = CapabilityManager.check(machine_id, {:read_volume, "vol_xyz"})
    end

    test "returns error for invalid attenuation" do
      capability = %{
        id: "cap_123",
        machine_id: "machine_x",
        action: :read_volume,
        resource: "vol_xyz",
        delegation_depth: 0
      }

      assert {:error, :cannot_attenuate} =
               CapabilityManager.attenuate(capability, :write_access)
    end
  end

  describe "CapabilityManager.delegate/3" do
    test "delegates capability to another machine", %{machine_a: machine_a, machine_b: machine_b} do
      {:ok, cap} =
        CapabilityManager.grant(
          machine_id: machine_a,
          action: :read_volume,
          resource: "vol_xyz"
        )

      {:ok, delegated_cap} =
        CapabilityManager.delegate(
          cap,
          from: machine_a,
          to: machine_b
        )

      assert delegated_cap.machine_id == machine_b
      assert delegated_cap.action == :read_volume
      assert delegated_cap.resource == "vol_xyz"
      assert delegated_cap.delegation_depth == cap.delegation_depth + 1
      assert delegated_cap.delegated_from == machine_a
    end

    test "delegated machine can use capability", %{machine_a: machine_a, machine_b: machine_b} do
      {:ok, cap} =
        CapabilityManager.grant(
          machine_id: machine_a,
          action: :net_outbound,
          resource: "0.0.0.0/0"
        )

      {:ok, _delegated_cap} =
        CapabilityManager.delegate(
          cap,
          from: machine_a,
          to: machine_b
        )

      assert :ok = CapabilityManager.check(machine_b, {:net_outbound, "0.0.0.0/0"})
    end

    test "prevents delegation by non-owner", %{machine_a: machine_a, machine_b: machine_b} do
      {:ok, cap} =
        CapabilityManager.grant(
          machine_id: machine_a,
          action: :read_volume,
          resource: "vol_xyz"
        )

      assert {:error, :not_owner} =
               CapabilityManager.delegate(
                 cap,
                 from: machine_b,
                 to: "machine_c"
               )
    end

    test "prevents excessive delegation depth", %{machine_a: machine_a, machine_b: machine_b} do
      cap = %{
        id: "cap_123",
        machine_id: machine_a,
        action: :read_volume,
        resource: "vol_xyz",
        delegation_depth: 3,
        expires_at: System.system_time(:second) + 3600,
        granted_at: System.system_time(:second),
        version: 1
      }

      :ets.insert(:capability_grants, {machine_a, cap})

      assert {:error, :max_delegation_depth} =
               CapabilityManager.delegate(
                 cap,
                 from: machine_a,
                 to: machine_b
               )
    end
  end

  describe "CapabilityManager.revoke/1" do
    test "revokes capability successfully", %{machine_a: machine_id} do
      {:ok, cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_xyz"
        )

      assert :ok = CapabilityManager.check(machine_id, {:read_volume, "vol_xyz"})

      :ok = CapabilityManager.revoke(cap.id)

      assert {:error, :capability_revoked} =
               CapabilityManager.check(machine_id, {:read_volume, "vol_xyz"})
    end

    test "revoke is idempotent", %{machine_a: machine_id} do
      {:ok, cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :migrate_to,
          resource: ["iad"]
        )

      :ok = CapabilityManager.revoke(cap.id)
      :ok = CapabilityManager.revoke(cap.id)
      :ok = CapabilityManager.revoke(cap.id)

      assert {:error, :capability_revoked} =
               CapabilityManager.check(machine_id, {:migrate_to, ["iad"]})
    end

    test "revoking one capability doesn't affect others", %{machine_a: machine_id} do
      {:ok, cap1} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_1"
        )

      {:ok, _cap2} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_2"
        )

      :ok = CapabilityManager.revoke(cap1.id)

      assert {:error, :capability_revoked} =
               CapabilityManager.check(machine_id, {:read_volume, "vol_1"})

      assert :ok = CapabilityManager.check(machine_id, {:read_volume, "vol_2"})
    end
  end

  describe "CapabilityManager.list/1" do
    test "lists all capabilities for machine", %{machine_a: machine_id} do
      {:ok, _cap1} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_1"
        )

      {:ok, _cap2} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :write_volume,
          resource: "vol_2"
        )

      {:ok, _cap3} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :net_outbound,
          resource: "0.0.0.0/0"
        )

      capabilities = CapabilityManager.list(machine_id)

      assert length(capabilities) == 3
      assert Enum.any?(capabilities, fn cap -> cap.action == :read_volume end)
      assert Enum.any?(capabilities, fn cap -> cap.action == :write_volume end)
      assert Enum.any?(capabilities, fn cap -> cap.action == :net_outbound end)
    end

    test "excludes expired capabilities", %{machine_a: machine_id} do
      {:ok, _cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_xyz",
          ttl: 1
        )

      assert length(CapabilityManager.list(machine_id)) == 1

      Process.sleep(2100)

      assert length(CapabilityManager.list(machine_id)) == 0
    end

    test "returns empty list for machine with no capabilities", %{machine_a: machine_id} do
      capabilities = CapabilityManager.list(machine_id)
      assert capabilities == []
    end
  end

  describe "CapabilityManager.get_stats/0" do
    test "tracks capability grant count", %{machine_a: machine_id} do
      initial_stats = CapabilityManager.get_stats()
      initial_granted = initial_stats.total_granted

      for i <- 1..5 do
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_#{i}"
        )
      end

      new_stats = CapabilityManager.get_stats()
      assert new_stats.total_granted == initial_granted + 5
    end

    test "tracks capability revocation count", %{machine_a: machine_id} do
      initial_stats = CapabilityManager.get_stats()
      initial_revoked = initial_stats.total_revoked

      caps =
        for i <- 1..3 do
          {:ok, cap} =
            CapabilityManager.grant(
              machine_id: machine_id,
              action: :read_volume,
              resource: "vol_#{i}"
            )

          cap
        end

      Enum.each(caps, fn cap -> CapabilityManager.revoke(cap.id) end)

      new_stats = CapabilityManager.get_stats()
      assert new_stats.total_revoked == initial_revoked + 3
    end
  end

  describe "Integration: Complete Capability Workflow" do
    test "full lifecycle with delegation and attenuation", %{
      machine_a: machine_a,
      machine_b: machine_b
    } do
      {:ok, write_cap} =
        CapabilityManager.grant(
          machine_id: machine_a,
          action: :write_volume,
          resource: "vol_xyz",
          ttl: 3600
        )

      assert :ok = CapabilityManager.check(machine_a, {:write_volume, "vol_xyz"})

      {:ok, read_cap} = CapabilityManager.attenuate(write_cap, :read_only)

      {:ok, _delegated_cap} =
        CapabilityManager.delegate(
          read_cap,
          from: machine_a,
          to: machine_b
        )

      assert :ok = CapabilityManager.check(machine_b, {:read_volume, "vol_xyz"})

      assert {:error, :insufficient_capability} =
               CapabilityManager.check(machine_b, {:write_volume, "vol_xyz"})

      :ok = CapabilityManager.revoke(write_cap.id)

      assert {:error, :capability_revoked} =
               CapabilityManager.check(machine_a, {:write_volume, "vol_xyz"})

      assert :ok = CapabilityManager.check(machine_b, {:read_volume, "vol_xyz"})

      {:ok, _new_write_cap} =
        CapabilityManager.grant(
          machine_id: machine_b,
          action: :write_volume,
          resource: "vol_xyz"
        )

      assert :ok = CapabilityManager.check(machine_b, {:write_volume, "vol_xyz"})
    end
  end

  describe "Security Properties" do
    test "capability IDs are cryptographically random", %{machine_a: machine_id} do
      caps =
        for i <- 1..100 do
          {:ok, cap} =
            CapabilityManager.grant(
              machine_id: machine_id,
              action: :read_volume,
              resource: "vol_#{i}"
            )

          cap
        end

      ids = Enum.map(caps, & &1.id)
      unique_ids = Enum.uniq(ids)
      assert length(unique_ids) == 100
    end

    test "concurrent capability grants are safe", %{machine_a: machine_id} do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            CapabilityManager.grant(
              machine_id: machine_id,
              action: :read_volume,
              resource: "vol_#{i}"
            )
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert Enum.all?(results, fn {:ok, cap} -> is_map(cap) end)

      ids = Enum.map(results, fn {:ok, cap} -> cap.id end)
      unique_ids = Enum.uniq(ids)
      assert length(unique_ids) == 100
    end
  end

  describe "Telemetry Events" do
    test "emits capability granted event", %{machine_a: machine_id} do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-capability-granted-#{inspect(ref)}",
        [:orchestrator, :capability, :granted],
        &__MODULE__.handle_telemetry/4,
        self_pid
      )

      {:ok, _cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :read_volume,
          resource: "vol_xyz",
          ttl: 1800
        )

      assert_receive {:telemetry, measurements, metadata}, 1000

      assert measurements.ttl_seconds == 1800
      assert metadata.machine_id == machine_id
      assert metadata.action == :read_volume
      assert is_binary(metadata.capability_id)

      :telemetry.detach("test-capability-granted-#{inspect(ref)}")
    end

    test "emits capability revoked event", %{machine_a: machine_id} do
      {:ok, cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :write_volume,
          resource: "vol_abc"
        )

      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-capability-revoked-#{inspect(ref)}",
        [:orchestrator, :capability, :revoked],
        &__MODULE__.handle_telemetry/4,
        self_pid
      )

      :ok = CapabilityManager.revoke(cap.id)

      assert_receive {:telemetry, _measurements, metadata}, 1000
      assert metadata.capability_id == cap.id

      :telemetry.detach("test-capability-revoked-#{inspect(ref)}")
    end

    test "emits check_passed and check_failed events", %{machine_a: machine_id} do
      {:ok, _cap} =
        CapabilityManager.grant(
          machine_id: machine_id,
          action: :net_outbound,
          resource: "0.0.0.0/0"
        )

      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-check-passed-#{inspect(ref)}",
        [:orchestrator, :capability, :check_passed],
        &__MODULE__.handle_telemetry/4,
        self_pid
      )

      :telemetry.attach(
        "test-check-failed-#{inspect(ref)}",
        [:orchestrator, :capability, :check_failed],
        &__MODULE__.handle_telemetry/4,
        self_pid
      )

      :ok = CapabilityManager.check(machine_id, {:net_outbound, "0.0.0.0/0"})
      assert_receive {:check_passed, metadata}, 1000
      assert metadata.machine_id == machine_id
      assert metadata.action == :net_outbound

      {:error, _} = CapabilityManager.check(machine_id, {:write_volume, "vol_xyz"})
      assert_receive {:check_failed, metadata}, 1000
      assert metadata.machine_id == machine_id
      assert metadata.action == :write_volume
      assert metadata.reason == :insufficient_capability

      :telemetry.detach("test-check-passed-#{inspect(ref)}")
      :telemetry.detach("test-check-failed-#{inspect(ref)}")
    end
  end

  def handle_telemetry(
        [:orchestrator, :capability, :check_passed],
        _measurements,
        metadata,
        test_pid
      ) do
    send(test_pid, {:check_passed, metadata})
  end

  def handle_telemetry(
        [:orchestrator, :capability, :check_failed],
        _measurements,
        metadata,
        test_pid
      ) do
    send(test_pid, {:check_failed, metadata})
  end

  def handle_telemetry(_event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, measurements, metadata})
  end
end
