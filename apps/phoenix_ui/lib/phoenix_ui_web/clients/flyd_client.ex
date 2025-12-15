defmodule PhoenixUiWeb.FlydClient do
  require Logger
  alias Finch.Response


  defp base_url do
    Application.get_env(:phoenix_ui, :flyd_base) || "http://localhost:8080"
  end

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
  def get_machine(id) when is_binary(id) do
    get("/get?id=#{URI.encode_www_form(id)}")
  end

  @spec list_machines_by_region(String.t()) :: {:ok, [map()]} | {:error, any()}
  def list_machines_by_region(_region) do
    Logger.debug("[FlydClient] list_machines_by_region called (currently returns empty list).")
    {:ok, []}
  end

  defp get(path) do
    {url, host_header} = resolve_url_with_ipv6(base_url() <> path)
    Logger.debug("[FlydClient] GET #{url}")
    headers = [{"content-type", "application/json"}, {"host", host_header}]
    req = Finch.build(:get, url, headers)

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
    {url, host_header} = resolve_url_with_ipv6(base_url() <> path)
    Logger.debug("[FlydClient] POST #{url}")
    headers = [{"content-type", "application/json"}, {"host", host_header}]
    req = Finch.build(:post, url, headers, body)

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

  defp resolve_url_with_ipv6(url) do
    uri = URI.parse(url)
    host = uri.host
    port = uri.port

    original_host = if port, do: "#{host}:#{port}", else: host

    if host && String.ends_with?(host, ".internal") do
      case :inet.getaddr(String.to_charlist(host), :inet6) do
        {:ok, ip_tuple} ->
          ip_str = :inet.ntoa(ip_tuple) |> to_string()
          port_str = if port, do: ":#{port}", else: ""
          path_str = uri.path || ""
          query_str = if uri.query, do: "?#{uri.query}", else: ""
          resolved_url = "#{uri.scheme}://[#{ip_str}]#{port_str}#{path_str}#{query_str}"
          {resolved_url, original_host}

        {:error, _reason} ->
          {url, original_host}
      end
    else
      {url, original_host}
    end
  end

  defp decode(nil), do: %{}
  defp decode(""), do: %{}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, val} ->
        val

      {:error, reason} ->
        Logger.warning(
          "[FlydClient] Failed to decode JSON response: #{inspect(reason)}. Raw body: #{inspect(body)}"
        )

        %{"raw_body" => body}
    end
  end
end
