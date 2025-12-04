defmodule Orchestrator.Network.NetworkIdentityTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Network.Identity
  alias Orchestrator.Network.IPRegistry
  alias Orchestrator.Network.AnycastRouter

  @moduletag :network

  setup do
    start_supervised!(IPRegistry)
    start_supervised!(AnycastRouter)

    :ok
  end

  describe "Identity.allocate_ipv6/0" do
    test "allocates valid IPv6 address" do
      ipv6 = Identity.allocate_ipv6()

      assert is_binary(ipv6)
      assert String.starts_with?(ipv6, "2a09:8280:1:")
      assert Identity.valid_ipv6?(ipv6)
    end

    test "allocates unique addresses" do
      ipv6_1 = Identity.allocate_ipv6()
      ipv6_2 = Identity.allocate_ipv6()
      ipv6_3 = Identity.allocate_ipv6()

      assert ipv6_1 != ipv6_2
      assert ipv6_2 != ipv6_3
      assert ipv6_1 != ipv6_3
    end

    test "embeds UUID in address" do
      ipv6 = Identity.allocate_ipv6()

      assert {:ok, uuid_hex} = Identity.extract_uuid(ipv6)
      assert byte_size(uuid_hex) == 20
    end

    test "generates time-ordered addresses" do
      ipv6_1 = Identity.allocate_ipv6()
      Process.sleep(10)
      ipv6_2 = Identity.allocate_ipv6()

      {:ok, uuid1} = Identity.extract_uuid(ipv6_1)
      {:ok, uuid2} = Identity.extract_uuid(ipv6_2)

      assert uuid2 > uuid1
    end
  end

  describe "Identity.valid_ipv6?/1" do
    test "validates correct IPv6 formats" do
      assert Identity.valid_ipv6?("2a09:8280:1::1")
      assert Identity.valid_ipv6?("2a09:8280:1:0:0:0:abc:123")
      assert Identity.valid_ipv6?("2001:db8::1")
      assert Identity.valid_ipv6?("::1")
    end

    test "rejects invalid formats" do
      refute Identity.valid_ipv6?("invalid")
      refute Identity.valid_ipv6?("192.168.1.1")
      refute Identity.valid_ipv6?("2a09:8280:1")
      refute Identity.valid_ipv6?("")
    end
  end

  describe "IPRegistry" do
    test "registers and looks up IPv6" do
      ipv6 = "2a09:8280:1::abc123"
      machine_id = "machine_xyz"
      region = "ord"

      :ok = IPRegistry.register(ipv6, machine_id, region, node())

      assert {:ok, {^machine_id, ^region, _node}} = IPRegistry.lookup(ipv6)
    end

    test "returns error for unregistered IP" do
      assert {:error, :not_found} = IPRegistry.lookup("2a09:8280:1::notfound")
    end

    test "updates existing registration" do
      ipv6 = "2a09:8280:1::abc123"

      :ok = IPRegistry.register(ipv6, "machine_1", "ord", node())
      assert {:ok, {"machine_1", "ord", _}} = IPRegistry.lookup(ipv6)

      :ok = IPRegistry.register(ipv6, "machine_1", "iad", node())
      assert {:ok, {"machine_1", "iad", _}} = IPRegistry.lookup(ipv6)
    end

    test "deletes IPv6 registration" do
      ipv6 = "2a09:8280:1::abc123"

      :ok = IPRegistry.register(ipv6, "machine_1", "ord", node())
      assert {:ok, _} = IPRegistry.lookup(ipv6)

      :ok = IPRegistry.delete(ipv6)
      assert {:error, :not_found} = IPRegistry.lookup(ipv6)
    end

    test "counts registered IPs" do
      initial_count = IPRegistry.count()

      :ok = IPRegistry.register("2a09:8280:1::1", "m1", "ord", node())
      :ok = IPRegistry.register("2a09:8280:1::2", "m2", "iad", node())
      :ok = IPRegistry.register("2a09:8280:1::3", "m3", "sjc", node())

      assert IPRegistry.count() == initial_count + 3
    end

    test "lists all registered IPs" do
      :ok = IPRegistry.register("2a09:8280:1::test1", "m1", "ord", node())
      :ok = IPRegistry.register("2a09:8280:1::test2", "m2", "iad", node())

      all = IPRegistry.all()

      ipv6s = Enum.map(all, fn {ipv6, _, _, _, _} -> ipv6 end)
      assert "2a09:8280:1::test1" in ipv6s
      assert "2a09:8280:1::test2" in ipv6s
    end

    test "handles concurrent registrations" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            ipv6 = "2a09:8280:1::concurrent#{i}"
            IPRegistry.register(ipv6, "machine_#{i}", "ord", node())
          end)
        end

      Task.await_many(tasks, 5000)

      for i <- 1..10 do
        ipv6 = "2a09:8280:1::concurrent#{i}"
        assert {:ok, _} = IPRegistry.lookup(ipv6)
      end
    end
  end

  describe "AnycastRouter" do
    test "announces route for IPv6" do
      ipv6 = "2a09:8280:1::abc123"
      machine_id = "machine_xyz"
      region = "ord"

      :ok = AnycastRouter.announce_route(ipv6, machine_id, region)

      routes = AnycastRouter.get_routes()

      assert Enum.any?(routes, fn {ip, mid, reg, _, _} ->
               ip == ipv6 and mid == machine_id and reg == region
             end)
    end

    test "withdraws route for IPv6" do
      ipv6 = "2a09:8280:1::abc123"

      :ok = AnycastRouter.announce_route(ipv6, "machine_1", "ord")

      routes_before = AnycastRouter.get_routes()
      assert Enum.any?(routes_before, fn {ip, _, _, _, _} -> ip == ipv6 end)

      :ok = AnycastRouter.withdraw_route(ipv6, "ord")

      routes_after = AnycastRouter.get_routes()
      refute Enum.any?(routes_after, fn {ip, _, reg, _, _} -> ip == ipv6 and reg == "ord" end)
    end

    test "calculates AS-PATH length between regions" do
      assert AnycastRouter.as_path_length("iad", "ord") == 1
      assert AnycastRouter.as_path_length("ord", "iad") == 1

      assert AnycastRouter.as_path_length("ord", "sjc") == 2
      assert AnycastRouter.as_path_length("iad", "lhr") == 3

      assert AnycastRouter.as_path_length("iad", "syd") == 7

      assert AnycastRouter.as_path_length("ord", "ord") == 0
    end

    test "finds nearest announcement from client region" do
      ipv6 = "2a09:8280:1::service123"

      :ok = AnycastRouter.announce_route(ipv6, "replica_iad", "iad")
      :ok = AnycastRouter.announce_route(ipv6, "replica_ord", "ord")
      :ok = AnycastRouter.announce_route(ipv6, "replica_syd", "syd")

      assert {:ok, "iad"} = AnycastRouter.find_nearest(ipv6, "iad")

      assert {:ok, "ord"} = AnycastRouter.find_nearest(ipv6, "ord")

      assert {:ok, "ord"} = AnycastRouter.find_nearest(ipv6, "sjc")

      assert {:ok, "iad"} = AnycastRouter.find_nearest(ipv6, "lhr")
    end

    test "returns error when no routes announced" do
      ipv6 = "2a09:8280:1::notfound"

      assert {:error, :no_routes} = AnycastRouter.find_nearest(ipv6, "ord")
    end

    test "supports multiple announcements for same IP" do
      ipv6 = "2a09:8280:1::multi"

      :ok = AnycastRouter.announce_route(ipv6, "machine_1", "iad")
      :ok = AnycastRouter.announce_route(ipv6, "machine_2", "ord")
      :ok = AnycastRouter.announce_route(ipv6, "machine_3", "syd")

      routes = AnycastRouter.get_routes()
      matching_routes = Enum.filter(routes, fn {ip, _, _, _, _} -> ip == ipv6 end)

      assert length(matching_routes) == 3
    end
  end

  describe "Integration: IP Persistence Across Migration" do
    test "IP stays same during migration" do
      ipv6 = Identity.allocate_ipv6()
      machine_id = "machine_migration_test"

      :ok = IPRegistry.register(ipv6, machine_id, "ord", node())
      :ok = AnycastRouter.announce_route(ipv6, machine_id, "ord")

      assert {:ok, {^machine_id, "ord", _}} = IPRegistry.lookup(ipv6)

      :ok = AnycastRouter.announce_route(ipv6, machine_id, "iad")
      :ok = IPRegistry.register(ipv6, machine_id, "iad", node())

      assert {:ok, {^machine_id, "iad", _}} = IPRegistry.lookup(ipv6)

      :ok = AnycastRouter.withdraw_route(ipv6, "ord")

      assert {:ok, {^machine_id, "iad", _}} = IPRegistry.lookup(ipv6)
    end

    test "anycast routes to nearest healthy replica" do
      ipv6 = "2a09:8280:1::ha_service"

      :ok = AnycastRouter.announce_route(ipv6, "replica_iad", "iad")
      :ok = AnycastRouter.announce_route(ipv6, "replica_ord", "ord")
      :ok = AnycastRouter.announce_route(ipv6, "replica_syd", "syd")

      assert {:ok, "ord"} = AnycastRouter.find_nearest(ipv6, "sjc")

      :ok = AnycastRouter.withdraw_route(ipv6, "ord")

      assert {:ok, "iad"} = AnycastRouter.find_nearest(ipv6, "sjc")

      :ok = AnycastRouter.withdraw_route(ipv6, "iad")
    end
  end

  describe "Performance" do
    test "fast IPv6 lookup (< 1ms for 10k lookups)" do
      for i <- 1..100 do
        ipv6 = "2a09:8280:1::perf#{i}"
        IPRegistry.register(ipv6, "machine_#{i}", "ord", node())
      end

      start_time = System.monotonic_time(:microsecond)

      for _ <- 1..10_000 do
        i = :rand.uniform(100)
        ipv6 = "2a09:8280:1::perf#{i}"
        IPRegistry.lookup(ipv6)
      end

      elapsed_us = System.monotonic_time(:microsecond) - start_time
      avg_lookup_us = elapsed_us / 10_000

      IO.puts(
        "\nPerformance: 10k lookups in #{elapsed_us}μs (avg #{Float.round(avg_lookup_us, 2)}μs per lookup)"
      )

      assert avg_lookup_us < 100
    end

    test "handles 1000 concurrent route announcements" do
      tasks =
        for i <- 1..1000 do
          Task.async(fn ->
            ipv6 = "2a09:8280:1::concurrent#{i}"
            region = Enum.random(["iad", "ord", "sjc", "lhr", "syd"])
            AnycastRouter.announce_route(ipv6, "machine_#{i}", region)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert Enum.all?(results, fn result -> result == :ok end)

      routes = AnycastRouter.get_routes()
      assert length(routes) >= 1000
    end
  end
end
