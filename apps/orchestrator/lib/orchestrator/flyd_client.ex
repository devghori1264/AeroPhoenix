defmodule Orchestrator.FlydClient do
  require Logger
  @base Application.get_env(:orchestrator, :flyd)[:url] || "http://localhost:8080"

  @spec start_machine(String.t()) :: {:ok, map()} | {:error, any()}
  def start_machine(id) do
    call(:post, "/v1/machines/#{id}/start", %{})
  end

  def stop_machine(id) do
    call(:post, "/v1/machines/#{id}/stop", %{})
  end

  def migrate_machine(id, target_region) do
    call(:post, "/v1/machines/#{id}/migrate", %{target: target_region})
  end

  def get_machine(id), do: call(:get, "/v1/machines/#{id}")

  defp call(method, path, body \\ nil, attempt \\ 1)
  defp call(_m, _p, _b, attempt) when attempt > 4, do: {:error, :max_retries}

  defp call(method, path, body, attempt) do
    url = @base <> path
    headers = [{"content-type", "application/json"}]
    opts = [timeout: 5_000]

    payload = if body == %{} or body == nil, do: "", else: Jason.encode!(body)

    case Finch.build(method, url, headers, payload) |> Finch.request(Orchestrator.Finch, receive_timeout: opts[:timeout]) do
      {:ok, %{status: s, body: b}} when s in 200..299 ->
        case Jason.decode(b) do
          {:ok, json} -> {:ok, json}
          _ -> {:ok, %{"raw" => b}}
        end
      {:ok, %{status: s}} ->
        Logger.warn("flyd client non-200 #{s} for #{url}")
        :timer.sleep(100 * attempt)
        call(method, path, body, attempt + 1)
      {:error, reason} ->
        Logger.warn("flyd http error #{inspect(reason)}")
        :timer.sleep(100 * attempt)
        call(method, path, body, attempt + 1)
    end
  end
end
