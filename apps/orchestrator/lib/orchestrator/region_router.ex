defmodule Orchestrator.RegionRouter do
  require Logger

  defp region_endpoints do
    Application.get_env(:orchestrator, :region_endpoints, %{
      "iad" => "http://aerophoenix-flyd-sim.internal:8080",
      "us-east-1" => "http://aerophoenix-flyd-sim.internal:8080",
      "eu-west-1" => "http://aerophoenix-flyd-sim.internal:8080",
      "ap-south-1" => "http://aerophoenix-flyd-sim.internal:8080",
      "us-west-2" => "http://aerophoenix-flyd-sim.internal:8080"
    })
  end

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

    case Map.get(region_endpoints(), normalized_region) do
      nil ->
        Logger.error("Unknown region: #{region} (normalized: #{normalized_region})")
        {:error, :unknown_region}

      url ->
        {:ok, url}
    end
  end

  @spec list_regions() :: list(String.t())
  def list_regions do
    Map.keys(region_endpoints())
  end

  @spec create_machine(String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def create_machine(name, region) do
    with {:ok, base_url} <- get_endpoint(region) do
      original_url = "#{base_url}/create"
      headers = [{"content-type", "application/json"}]
      body = Jason.encode!(%{"name" => name, "region" => region})

      Logger.info("Creating machine #{name} in region #{region} at #{original_url}")

      case make_ipv6_request(:post, original_url, headers, body) do
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
      original_url = "#{base_url}/get?id=#{machine_id}"
      headers = [{"content-type", "application/json"}]

      case make_ipv6_request(:get, original_url, headers, nil) do
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

  defp make_ipv6_request(method, url, headers, body) do
    uri = URI.parse(url)
    host = uri.host
    port = uri.port || 80
    path = uri.path || "/"
    path = if uri.query, do: "#{path}?#{uri.query}", else: path

    if host && String.ends_with?(host, ".internal") do
      Logger.info("Making IPv6 request to #{host}:#{port}#{path}")

      case :inet.getaddr(String.to_charlist(host), :inet6) do
        {:ok, ip_tuple} ->
          case :gen_tcp.connect(
                 ip_tuple,
                 port,
                 [:binary, {:active, false}, {:packet, :http_bin}, :inet6],
                 5000
               ) do
            {:ok, socket} ->
              request_line = "#{String.upcase(to_string(method))} #{path} HTTP/1.1\r\n"
              host_header = "Host: #{host}:#{port}\r\n"

              content_type =
                Enum.find(headers, fn {k, _} -> String.downcase(k) == "content-type" end)

              content_type_header =
                if content_type, do: "Content-Type: #{elem(content_type, 1)}\r\n", else: ""

              body_data = body || ""

              content_length_header =
                if body, do: "Content-Length: #{byte_size(body_data)}\r\n", else: ""

              http_request =
                request_line <>
                  host_header <>
                  content_type_header <>
                  content_length_header <> "Connection: close\r\n\r\n" <> body_data

              :ok = :gen_tcp.send(socket, http_request)

              result = read_http_response(socket)
              :gen_tcp.close(socket)
              result

            {:error, reason} ->
              Logger.error("TCP connect failed: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("IPv6 resolution failed for #{host}: #{inspect(reason)}")
          {:error, {:dns_error, reason}}
      end
    else
      req =
        if body do
          Finch.build(method, url, headers, body)
        else
          Finch.build(method, url, headers)
        end

      Finch.request(req, Orchestrator.Finch, receive_timeout: 5_000)
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

        case :gen_tcp.recv(socket, content_length, 5000) do
          {:ok, body} ->
            {:ok, %{status: status, body: body}}

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
    case :gen_tcp.recv(socket, 0, 5000) do
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
end
