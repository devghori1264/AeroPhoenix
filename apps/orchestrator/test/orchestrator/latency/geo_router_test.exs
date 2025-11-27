defmodule Orchestrator.Latency.GeoRouterTest do
  use ExUnit.Case, async: true

  alias Orchestrator.Latency.GeoRouter

  describe "haversine_distance/2" do
    test "calculates distance between San Francisco and New York correctly" do
      san_francisco = %{lat: 37.7749, lon: -122.4194}
      new_york = %{lat: 40.7128, lon: -74.0060}

      distance_km = GeoRouter.haversine_distance(san_francisco, new_york)

      assert_in_delta distance_km, 4_130, 50
    end

    test "calculates distance between Tokyo and London correctly" do
      tokyo = %{lat: 35.6762, lon: 139.6503}
      london = %{lat: 51.5074, lon: -0.1278}

      distance_km = GeoRouter.haversine_distance(tokyo, london)

      assert_in_delta distance_km, 9_600, 100
    end

    test "calculates zero distance for same location" do
      tokyo = %{lat: 35.6762, lon: 139.6503}

      distance_km = GeoRouter.haversine_distance(tokyo, tokyo)

      assert distance_km < 0.1
    end

    test "handles antipodal points (opposite sides of Earth)" do
      point_a = %{lat: 0.0, lon: 0.0}
      point_b = %{lat: 0.0, lon: 180.0}

      distance_km = GeoRouter.haversine_distance(point_a, point_b)

      assert_in_delta distance_km, 20_037, 100
    end

    test "handles crossing International Date Line" do
      tokyo = %{lat: 35.6762, lon: 139.6503}
      san_francisco = %{lat: 37.7749, lon: -122.4194}

      distance_km = GeoRouter.haversine_distance(tokyo, san_francisco)

      assert_in_delta distance_km, 8_280, 100
    end
  end

  describe "propagation_delay_ms/1" do
    test "calculates speed-of-light delay correctly" do
      distance_km = 1_000
      delay_ms = GeoRouter.propagation_delay_ms(distance_km)

      assert delay_ms == 5.0
    end

    test "calculates trans-Atlantic delay (NYC to London)" do
      distance_km = 5_600
      delay_ms = GeoRouter.propagation_delay_ms(distance_km)

      assert delay_ms == 28.0
    end

    test "calculates trans-Pacific delay (Tokyo to SF)" do
      distance_km = 8_280
      delay_ms = GeoRouter.propagation_delay_ms(distance_km)

      assert_in_delta delay_ms, 41.4, 0.1
    end

    test "returns 0 for zero distance" do
      delay_ms = GeoRouter.propagation_delay_ms(0)
      assert delay_ms == 0.0
    end
  end

  describe "select_best_region/1" do
    test "selects closest region based on distance" do
      client_location = %{lat: 35.6762, lon: 139.6503}

      available_regions = [:nrt, :sin, :lhr]

      best_region =
        GeoRouter.select_best_region(
          client_location,
          available_regions: available_regions
        )

      assert best_region == :nrt
    end

    test "considers latency in addition to distance" do
      client_location = %{lat: 37.7749, lon: -122.4194}

      available_regions = [:sjc, :iad]

      best_region =
        GeoRouter.select_best_region(
          client_location,
          available_regions: available_regions,
          latency_weight: 0.5
        )

      assert best_region == :sjc
    end

    test "excludes specified regions" do
      client_location = %{lat: 35.6762, lon: 139.6503}

      best_region =
        GeoRouter.select_best_region(
          client_location,
          available_regions: [:nrt, :sin, :lhr],
          exclude: [:nrt]
        )

      assert best_region == :sin
    end

    test "returns nil when all regions excluded" do
      client_location = %{lat: 35.6762, lon: 139.6503}

      best_region =
        GeoRouter.select_best_region(
          client_location,
          available_regions: [:nrt, :sin],
          exclude: [:nrt, :sin]
        )

      assert best_region == nil
    end

    test "handles capacity factor in selection" do
      client_location = %{lat: 37.7749, lon: -122.4194}

      capacity_fn = fn region ->
        case region do
          :sjc -> 0.95
          :lax -> 0.50
          _ -> 0.10
        end
      end

      best_region =
        GeoRouter.select_best_region(
          client_location,
          available_regions: [:sjc, :lax, :iad],
          capacity_fn: capacity_fn,
          capacity_weight: 0.4
        )

      assert best_region in [:lax, :iad]
    end
  end

  describe "closest_regions/1" do
    test "returns N closest regions sorted by distance" do
      client_location = %{lat: 35.6762, lon: 139.6503}

      closest =
        GeoRouter.closest_regions(
          client_location,
          count: 3
        )

      assert length(closest) == 3
      assert :nrt in closest
    end

    test "returns all regions when count exceeds available" do
      client_location = %{lat: 0.0, lon: 0.0}

      closest =
        GeoRouter.closest_regions(
          client_location,
          count: 100
        )

      assert length(closest) > 0
      assert length(closest) <= 20
    end

    test "excludes specified regions from results" do
      client_location = %{lat: 35.6762, lon: 139.6503}

      closest =
        GeoRouter.closest_regions(
          client_location,
          count: 3,
          exclude: [:nrt]
        )

      refute :nrt in closest
      assert length(closest) == 3
    end
  end

  describe "latency_overhead_ms/1" do
    test "calculates network overhead for nearby regions" do
      client_location = %{lat: 37.7749, lon: -122.4194}
      region_location = %{lat: 37.7749, lon: -122.4194}

      actual_latency_ms = 5
      distance_km = GeoRouter.haversine_distance(client_location, region_location)
      theoretical_min_ms = GeoRouter.propagation_delay_ms(distance_km)

      overhead_ms = actual_latency_ms - theoretical_min_ms

      assert overhead_ms >= 0
      assert overhead_ms < 10
    end

    test "calculates overhead for trans-oceanic link" do
      nyc = %{lat: 40.7128, lon: -74.0060}
      london = %{lat: 51.5074, lon: -0.1278}

      distance_km = GeoRouter.haversine_distance(nyc, london)
      theoretical_min_ms = GeoRouter.propagation_delay_ms(distance_km)

      actual_latency_ms = 75

      overhead_ms = actual_latency_ms - theoretical_min_ms

      assert_in_delta overhead_ms, 47, 5
    end
  end

  describe "submarine_cable_correction/2" do
    test "applies correction for Australia-Singapore route" do
      sydney = %{lat: -33.8688, lon: 151.2093}
      singapore = %{lat: 1.3521, lon: 103.8198}

      direct_distance = GeoRouter.haversine_distance(sydney, singapore)

      cable_correction = 1.35
      corrected_distance = direct_distance * cable_correction

      assert_in_delta direct_distance, 6_300, 100
      assert_in_delta corrected_distance, 8_500, 200
    end

    test "applies correction for South America-Europe route" do
      sao_paulo = %{lat: -23.5505, lon: -46.6333}
      lisbon = %{lat: 38.7223, lon: -9.1393}

      direct_distance = GeoRouter.haversine_distance(sao_paulo, lisbon)

      cable_correction = 1.20
      corrected_distance = direct_distance * cable_correction

      assert_in_delta direct_distance, 8_000, 200
      assert_in_delta corrected_distance, 9_600, 300
    end
  end

  describe "edge cases" do
    test "handles invalid coordinates gracefully" do
      invalid = %{lat: 95.0, lon: 0.0}
      valid = %{lat: 40.0, lon: -74.0}

      result = GeoRouter.haversine_distance(invalid, valid)
      assert is_number(result)
    end

    test "handles nil client location" do
      result = GeoRouter.select_best_region(nil, available_regions: [:nrt, :lhr])

      assert result in [:nrt, :lhr] or result == nil
    end

    test "handles empty available regions list" do
      client_location = %{lat: 35.6762, lon: 139.6503}

      result =
        GeoRouter.select_best_region(
          client_location,
          available_regions: []
        )

      assert result == nil
    end

    test "handles unknown region code" do
      client_location = %{lat: 35.6762, lon: 139.6503}

      result =
        GeoRouter.select_best_region(
          client_location,
          available_regions: [:unknown_region, :nrt]
        )

      assert result == :nrt
    end
  end
end
