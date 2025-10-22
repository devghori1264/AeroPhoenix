defmodule Orchestrator.Client do
  @moduledoc """
  Lightweight HTTP client to interact with flyd-sim HTTP shim.
  """

  require Logger
  alias Finch.Response

  @base Application.compile_env!(:orchestrator, :http)[:base_url]

  @default_headers [{"content-type", "application/json"}]

  def ping do
    url("/ping")
    |> get()
  end

  def create_machine(name, region) do
    body = %{"name" => name, "region" => region} |> Jason.encode!()
    url("/create")
    |> post(body)
  end

  def get_machine(id) do
    url("/get?id=#{id}") |> get()
  end

  # internal helpers

  defp url(path), do: "#{@base}#{path}"

  defp get(url) do
    req = Finch.build(:get, url, @default_headers)
    case Finch.request(req, Orchestrator.Finch, receive_timeout: 5_000) do
      {:ok, %Response{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}
      {:ok, %Response{status: status}} ->
        {:error, {:http_error, status}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post(url, body) do
    req = Finch.build(:post, url, @default_headers, body)
    case Finch.request(req, Orchestrator.Finch, receive_timeout: 5_000) do
      {:ok, %Response{status: 200, body: body}} -> {:ok, Jason.decode!(body)}
      {:ok, %Response{status: s}} -> {:error, {:http_error, s}}
      {:error, reason} -> {:error, reason}
    end
  end
end
