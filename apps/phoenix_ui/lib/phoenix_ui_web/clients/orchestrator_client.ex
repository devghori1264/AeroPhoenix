defmodule PhoenixUiWeb.OrchestratorClient do
  require Logger

  defp config do
    Application.get_env(:phoenix_ui, __MODULE__, [])
  end

  defp base_url, do: config()[:base_url] || "http://localhost:4001"
  defp timeout, do: config()[:request_timeout] || 5000
  defp token, do: config()[:token] || "dev-token"

  @spec ping() :: {:ok, map()} | {:error, term()}
  def ping, do: request(:get, "/api/v1/ping")

  @spec list_machines() :: {:ok, [map()]} | {:error, term()}
  def list_machines, do: request(:get, "/api/v1/machines")

  @spec create_machine(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_machine(name, region) do
    request(:post, "/api/v1/machines", %{"name" => name, "region" => region})
  end

  @spec topology() :: {:ok, map()} | {:error, term()}
  def topology, do: request(:get, "/api/v1/topology")

  @spec action(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def action(id, body),
    do: request(:post, "/api/v1/machines/#{URI.encode(id)}/action", body)

  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(path), do: request(:get, path, nil)

  @spec post(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def post(path, body), do: request(:post, path, body)

  defp request(method, path, body \\ nil, attempt \\ 1)
  defp request(_method, _path, _body, attempt) when attempt > 4, do: {:error, :max_retries}

  defp request(method, path, body, attempt) do
    url = base_url() <> path

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{token()}"}
    ]

    body_data = if body, do: Jason.encode!(body), else: nil

    require OpenTelemetry.Tracer

    OpenTelemetry.Tracer.with_span "orch.request", %{
      attributes: [{"http.method", to_string(method)}, {"http.url", url}]
    } do
      case make_ipv6_request(method, url, headers, body_data) do
        {:ok, %{status: s, body: b}} when s in 200..299 ->
          decode_body(b)

        {:ok, %{status: s, body: b}} ->
          Logger.warning("[OrchestratorClient] Non-2xx status #{s} for #{path}: #{b}")
          backoff_and_retry(method, path, body, attempt)

        {:error, reason} ->
          Logger.warning(
            "[OrchestratorClient] Request error: #{inspect(reason)} attempt=#{attempt}"
          )

          backoff_and_retry(method, path, body, attempt)
      end
    end
  end

  defp make_ipv6_request(method, url, headers, body) do
    uri = URI.parse(url)
    host = uri.host
    port = uri.port || 80
    path = uri.path || "/"
    path = if uri.query, do: "#{path}?#{uri.query}", else: path

    if host && String.ends_with?(host, ".internal") do
      case :inet.getaddr(String.to_charlist(host), :inet6) do
        {:ok, ip_tuple} ->
          make_tcp_request(ip_tuple, port, host, method, path, headers, body)

        {:error, reason} ->
          Logger.error(
            "[OrchestratorClient] IPv6 resolution failed for #{host}: #{inspect(reason)}"
          )

          {:error, {:dns_error, reason}}
      end
    else
      make_finch_request(method, url, headers, body)
    end
  end

  defp make_finch_request(method, url, headers, body) do
    req =
      if body do
        Finch.build(method, url, headers, body)
      else
        Finch.build(method, url, headers)
      end

    case Finch.request(req, PhoenixUiWeb.Finch, receive_timeout: timeout()) do
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:ok, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp make_tcp_request(ip_tuple, port, host, method, path, headers, body) do
    case :gen_tcp.connect(
           ip_tuple,
           port,
           [:binary, {:active, false}, {:packet, :http_bin}, :inet6],
           timeout()
         ) do
      {:ok, socket} ->
        request_line = "#{String.upcase(to_string(method))} #{path} HTTP/1.1\r\n"
        host_header = "Host: #{host}:#{port}\r\n"

        header_lines = Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end) |> Enum.join()
        body_data = body || ""

        content_length_header =
          if body, do: "Content-Length: #{byte_size(body_data)}\r\n", else: ""

        http_request =
          request_line <>
            host_header <>
            header_lines <> content_length_header <> "Connection: close\r\n\r\n" <> body_data

        :ok = :gen_tcp.send(socket, http_request)

        result = read_http_response(socket)
        :gen_tcp.close(socket)
        result

      {:error, reason} ->
        Logger.error("[OrchestratorClient] TCP connect failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp read_http_response(socket) do
    case read_headers(socket, nil, []) do
      {:ok, status, headers} ->
        content_length =
          Enum.find_value(headers, fn
            {:http_header, _, :"Content-Length", _, len} -> String.to_integer(len)
            _ -> nil
          end) || 0

        :inet.setopts(socket, [{:packet, :raw}])

        case :gen_tcp.recv(socket, content_length, timeout()) do
          {:ok, resp_body} ->
            {:ok, %{status: status, body: resp_body}}

          {:error, :closed} when content_length == 0 ->
            {:ok, %{status: status, body: ""}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_headers(socket, status, headers) do
    case :gen_tcp.recv(socket, 0, timeout()) do
      {:ok, {:http_response, _, status_code, _}} ->
        read_headers(socket, status_code, headers)

      {:ok, {:http_header, _, _name, _, _value} = header} ->
        read_headers(socket, status, [header | headers])

      {:ok, :http_eoh} ->
        {:ok, status, headers}

      {:error, reason} ->
        {:error, reason}
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
