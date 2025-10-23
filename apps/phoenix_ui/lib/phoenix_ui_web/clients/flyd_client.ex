defmodule PhoenixUiWeb.FlydClient do

  require Logger
  alias Finch.Response

  @base Application.compile_env(:phoenix_ui, :flyd_base, "http://localhost:8080")
  @headers [{"content-type", "application/json"}]

  @spec ping() :: {:ok, map()} | {:error, any()}
  def ping do
    get("/ping")
  end

  @spec create_machine(String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def create_machine(name, region) do
    body = %{"name" => name, "region" => region} |> Jason.encode!()
    post("/create", body)
  end

  @spec get_machine(String.t()) :: {:ok, map()} | {:error, any()}
  def get_machine(id) do
    get("/get?id=#{URI.encode_query(id)}")
  end

  @spec list_machines_by_region(String.t()) :: {:ok, [map()]} | {:error, any()}
  def list_machines_by_region(_region) do
    Logger.debug("[FlydClient] list_machines_by_region called (currently returns empty list).")
    {:ok, []}
  end

  defp get(path) do
    url = @base <> path
    Logger.debug("[FlydClient] GET #{url}")
    req = Finch.build(:get, url, @headers)

    case Finch.request(req, PhoenixUiWeb.Finch) do
      {:ok, %Response{status: status, body: body}} when status in 200..299 ->
        Logger.debug("[FlydClient] GET success (Status: #{status}) for URL: #{url}")
        {:ok, decode(body)}

      {:ok, %Response{status: status}} ->
        Logger.warning("[FlydClient] GET failed (HTTP Status: #{status}) for URL: #{url}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("[FlydClient] GET error for URL: #{url}. Reason: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp post(path, body) do
    url = @base <> path
    Logger.debug("[FlydClient] POST #{url}")
    req = Finch.build(:post, url, @headers, body)

    case Finch.request(req, PhoenixUiWeb.Finch) do
      {:ok, %Response{status: status, body: body}} when status in 200..299 ->
        Logger.debug("[FlydClient] POST success (Status: #{status}) for URL: #{url}")
        {:ok, decode(body)}

      {:ok, %Response{status: status}} ->
        Logger.warning("[FlydClient] POST failed (HTTP Status: #{status}) for URL: #{url}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("[FlydClient] POST error for URL: #{url}. Reason: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp decode(nil), do: %{}
  defp decode(""), do: %{}
  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, val} ->
        val

      {:error, reason} ->
        Logger.warning("[FlydClient] Failed to decode JSON response: #{inspect(reason)}. Raw body: #{inspect(body)}")
        %{"raw_body" => body}
    end
  end
end
