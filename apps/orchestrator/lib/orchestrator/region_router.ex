defmodule Orchestrator.RegionRouter do
  require Logger

  @region_endpoints %{
    "us-east-1" => "http://localhost:8080",
    "eu-west-1" => "http://localhost:8081",
    "ap-south-1" => "http://localhost:8082",
    "us-west-2" => "http://localhost:8083"
  }
  @spec get_endpoint(String.t()) :: {:ok, String.t()} | {:error, :unknown_region}
  def get_endpoint(region) do
    normalized_region =
      case region do
        "us-east" -> "us-east-1"
        "eu-west" -> "eu-west-1"
        "ap-south" -> "ap-south-1"
        "us-west" -> "us-west-2"
        r -> r
      end

    case Map.get(@region_endpoints, normalized_region) do
      nil ->
        Logger.error("Unknown region: #{region} (normalized: #{normalized_region})")
        {:error, :unknown_region}

      url ->
        {:ok, url}
    end
  end

  @spec list_regions() :: list(String.t())
  def list_regions do
    Map.keys(@region_endpoints)
  end

  @spec create_machine(String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def create_machine(name, region) do
    with {:ok, base_url} <- get_endpoint(region) do
      url = "#{base_url}/create"
      headers = [{"content-type", "application/json"}]
      body = Jason.encode!(%{"name" => name, "region" => region})

      Logger.info("Creating machine #{name} in region #{region} at #{url}")

      req = Finch.build(:post, url, headers, body)

      case Finch.request(req, Orchestrator.Finch, receive_timeout: 5_000) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          case Jason.decode(response_body) do
            {:ok, json} ->
              Logger.info("Machine created successfully: #{inspect(json)}")
              {:ok, json}

            {:error, _} ->
              {:ok, %{"id" => name, "status" => "running", "raw" => response_body}}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.error("Failed to create machine: HTTP #{status}, body: #{body}")
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          Logger.error("HTTP request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @spec get_machine(String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def get_machine(machine_id, region) do
    with {:ok, base_url} <- get_endpoint(region) do
      url = "#{base_url}/get?id=#{machine_id}"
      headers = [{"content-type", "application/json"}]

      req = Finch.build(:get, url, headers)

      case Finch.request(req, Orchestrator.Finch, receive_timeout: 5_000) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          Jason.decode(body)

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
