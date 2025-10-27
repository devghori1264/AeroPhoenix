defmodule PhoenixUiWeb.OrchestratorClient do
  require Logger
  alias Finch.Response

  @config Application.compile_env!(:phoenix_ui, __MODULE__)
  @base @config[:base_url]
  @timeout @config[:request_timeout]
  @token @config[:token]

  @spec ping() :: {:ok, map()} | {:error, term()}
  def ping, do: request(:get, "/api/v1/ping")

  @spec list_machines() :: {:ok, [map()]} | {:error, term()}
  def list_machines, do: request(:get, "/api/v1/machines")

  @spec topology() :: {:ok, map()} | {:error, term()}
  def topology, do: request(:get, "/api/v1/topology")

  @spec action(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def action(id, body),
    do: request(:post, "/api/v1/machines/#{URI.encode(id)}/action", body)

  defp request(method, path, body \\ nil, attempt \\ 1)
  defp request(_method, _path, _body, attempt) when attempt > 4, do: {:error, :max_retries}

defp request(method, path, body, attempt) do
    url = @base <> path
    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{@token}"}
    ]

    require OpenTelemetry.Tracer
    OpenTelemetry.Tracer.with_span "orch.request", %{attributes: [{"http.method", to_string(method)}, {"http.url", url}]} do
      req =
        case body do
          nil -> Finch.build(method, url, headers)
          _ -> Finch.build(method, url, headers, Jason.encode!(body))
        end

      case Finch.request(req, PhoenixUiWeb.Finch, receive_timeout: @timeout) do
        {:ok, %Response{status: s, body: b}} when s in 200..299 ->
          decode_body(b)
        {:ok, %Response{status: s, body: b}} ->
          Logger.warning("[OrchestratorClient] Non-2xx status #{s} for #{path}: #{b}")
          backoff_and_retry(method, path, body, attempt)
        {:error, reason} ->
          Logger.warning("[OrchestratorClient] Request error: #{inspect(reason)} attempt=#{attempt}")
          backoff_and_retry(method, path, body, attempt)
      end
    end
  end

  defp backoff_and_retry(method, path, body, attempt) do
    delay = trunc(:math.pow(2, attempt) * 100) + :rand.uniform(80)
    Logger.debug("[OrchestratorClient] Retry ##{attempt} in #{delay}ms for #{path}")
    :timer.sleep(delay)
    request(method, path, body, attempt + 1)
  end

  defp decode_body(nil), do: {:ok, %{}}
  defp decode_body(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:ok, %{"raw" => binary}}
    end
  end
end
