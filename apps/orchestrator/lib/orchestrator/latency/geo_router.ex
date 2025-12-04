defmodule Orchestrator.Latency.GeoRouter do
  require Logger

  @earth_radius_km 6371.0
  @speed_of_light_km_per_ms 200.0

  @type coordinates :: {latitude :: float(), longitude :: float()}
  @type region_id :: String.t()

  @type region_info :: %{
          id: region_id(),
          name: String.t(),
          coordinates: coordinates(),
          p95_latency_ms: float(),
          cpu_utilization_pct: float()
        }

  @region_coordinates %{
    "iad" => {38.9072, -77.0369},
    "ord" => {41.8781, -87.6298},
    "dfw" => {32.8998, -97.0403},
    "lax" => {33.9416, -118.4085},
    "sjc" => {37.3688, -121.9289},
    "sea" => {47.4502, -122.3088},
    "yyz" => {43.6777, -79.6248},
    "lhr" => {51.4700, -0.4543},
    "ams" => {52.3105, 4.7683},
    "fra" => {50.0379, 8.5622},
    "cdg" => {49.0097, 2.5479},
    "nrt" => {35.7720, 140.3929},
    "sin" => {1.3644, 103.9915},
    "syd" => {-33.9399, 151.1753},
    "hkg" => {22.3080, 113.9185},
    "gru" => {-23.4356, -46.4731},
    "scl" => {-33.3930, -70.7858},
    "dxb" => {25.2532, 55.3657},
    "jnb" => {-26.1393, 28.2460}
  }
  @spec haversine_distance(coordinates() | map(), coordinates() | map()) :: float()
  def haversine_distance(%{lat: lat1, lon: lon1}, loc2),
    do: haversine_distance({lat1, lon1}, loc2)

  def haversine_distance(loc1, %{lat: lat2, lon: lon2}),
    do: haversine_distance(loc1, {lat2, lon2})

  def haversine_distance({lat1, lon1}, {lat2, lon2}) do
    lat1_rad = degrees_to_radians(lat1)
    lon1_rad = degrees_to_radians(lon1)
    lat2_rad = degrees_to_radians(lat2)
    lon2_rad = degrees_to_radians(lon2)

    dlat = lat2_rad - lat1_rad
    dlon = lon2_rad - lon1_rad

    a =
      :math.pow(:math.sin(dlat / 2), 2) +
        :math.cos(lat1_rad) * :math.cos(lat2_rad) * :math.pow(:math.sin(dlon / 2), 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    @earth_radius_km * c
  end

  @spec propagation_delay_ms(float()) :: float()
  def propagation_delay_ms(distance_km) do
    distance_km / @speed_of_light_km_per_ms
  end

  @spec select_best_region(coordinates() | nil, keyword()) :: region_info() | nil
  def select_best_region(nil, _opts), do: nil

  def select_best_region(user_location, opts) do
    select_best_region([user_location: user_location] ++ opts)
  end

  @spec select_best_region(keyword()) :: region_info() | nil
  def select_best_region(opts) do
    user_location = Keyword.fetch!(opts, :user_location)

    available_regions =
      Keyword.fetch!(opts, :available_regions)
      |> Enum.map(fn
        region when is_atom(region) or is_binary(region) ->
          %{
            id: region,
            name: to_string(region),
            p95_latency_ms: 0.0,
            cpu_utilization_pct: 0.0
          }

        region ->
          region
      end)

    weights = Keyword.get(opts, :weights, %{distance: 0.5, latency: 0.3, capacity: 0.2})
    max_distance_km = Keyword.get(opts, :max_distance_km, 10_000)
    max_cpu_pct = Keyword.get(opts, :max_cpu_pct, 95.0)
    exclude_regions = Keyword.get(opts, :exclude_regions, [])

    enriched_regions =
      available_regions
      |> Enum.reject(&(&1.id in exclude_regions))
      |> Enum.map(fn region ->
        coordinates = Map.get(@region_coordinates, to_string(region.id), {0.0, 0.0})
        distance_km = haversine_distance(user_location, coordinates)

        Map.merge(region, %{
          coordinates: coordinates,
          distance_km: distance_km,
          propagation_delay_ms: propagation_delay_ms(distance_km)
        })
      end)
      |> Enum.reject(&(&1.distance_km > max_distance_km))
      |> Enum.reject(&(&1.cpu_utilization_pct > max_cpu_pct))

    if Enum.empty?(enriched_regions) do
      Logger.warning("No suitable regions found",
        user_location: user_location,
        available_count: length(available_regions)
      )

      nil
    else
      max_distance = Enum.max_by(enriched_regions, & &1.distance_km).distance_km
      max_latency = Enum.max_by(enriched_regions, & &1.p95_latency_ms).p95_latency_ms

      max_distance = if max_distance == 0, do: 1.0, else: max_distance
      max_latency = if max_latency == 0, do: 1.0, else: max_latency

      scored_regions =
        Enum.map(enriched_regions, fn region ->
          normalized_distance = region.distance_km / max_distance
          normalized_latency = region.p95_latency_ms / max_latency
          normalized_capacity = 1.0 - region.cpu_utilization_pct / 100.0

          score =
            weights.distance * normalized_distance +
              weights.latency * normalized_latency +
              weights.capacity * (1.0 - normalized_capacity)

          Map.put(region, :score, score)
        end)

      best_region = Enum.min_by(scored_regions, & &1.score)

      Logger.info("Selected best region",
        region_id: best_region.id,
        distance_km: Float.round(best_region.distance_km, 1),
        p95_latency_ms: best_region.p95_latency_ms,
        cpu_pct: best_region.cpu_utilization_pct,
        score: Float.round(best_region.score, 3)
      )

      best_region
    end
  end

  @spec closest_regions(coordinates(), keyword()) :: [map()]
  def closest_regions(user_location, opts) do
    closest_regions([user_location: user_location] ++ opts)
  end

  @spec closest_regions(keyword()) :: [map()]
  def closest_regions(opts) do
    user_location = Keyword.fetch!(opts, :user_location)
    count = Keyword.get(opts, :count, 3)
    exclude_regions = Keyword.get(opts, :exclude_regions, []) |> Enum.map(&to_string/1)

    @region_coordinates
    |> Enum.reject(fn {region_id, _coords} -> region_id in exclude_regions end)
    |> Enum.map(fn {region_id, coords} ->
      distance_km = haversine_distance(user_location, coords)

      %{
        id: region_id,
        coordinates: coords,
        distance_km: distance_km,
        propagation_delay_ms: propagation_delay_ms(distance_km)
      }
    end)
    |> Enum.sort_by(& &1.distance_km)
    |> Enum.take(count)
  end

  @spec latency_overhead_ms(keyword()) :: float()
  def latency_overhead_ms(opts) do
    distance_km = Keyword.fetch!(opts, :distance_km)
    actual_latency_ms = Keyword.fetch!(opts, :actual_latency_ms)

    theoretical_min = propagation_delay_ms(distance_km)
    max(0.0, actual_latency_ms - theoretical_min)
  end

  @spec stats() :: map()
  def stats do
    %{
      total_routes: 0,
      avg_distance_km: 0.0,
      avg_latency_overhead_ms: 0.0,
      region_distribution: %{}
    }
  end

  defp degrees_to_radians(degrees) do
    degrees * :math.pi() / 180.0
  end

  @spec region_coordinates(region_id()) :: coordinates() | nil
  def region_coordinates(region_id) do
    Map.get(@region_coordinates, region_id)
  end

  @spec register_region(region_id(), coordinates()) :: :ok
  def register_region(_region_id, _coordinates) do
    :ok
  end
end
