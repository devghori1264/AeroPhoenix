defmodule Orchestrator.Network.Identity do
  require Logger

  @ipv6_prefix "2a09:8280:1"

  @spec allocate_ipv6() :: String.t()
  def allocate_ipv6 do
    uuid = Uniq.UUID.uuid7()

    hex = String.replace(uuid, "-", "") |> String.downcase()

    hex = String.pad_trailing(hex, 32, "0")

    host_id =
      String.slice(hex, 0..19)
      |> String.to_charlist()
      |> Enum.chunk_every(4)
      |> Enum.map(&List.to_string/1)
      |> Enum.join(":")

    ipv6 = "#{@ipv6_prefix}:#{host_id}"

    Logger.debug("Allocated IPv6", ipv6: ipv6, uuid: uuid)

    :telemetry.execute(
      [:orchestrator, :network, :ipv6_allocated],
      %{},
      %{ipv6: ipv6}
    )

    ipv6
  end

  @spec extract_uuid(String.t()) :: {:ok, String.t()} | {:error, :invalid_format}
  def extract_uuid(ipv6) do
    case String.split(ipv6, ":") do
      parts when length(parts) == 8 ->
        uuid_hex =
          parts
          |> Enum.slice(-5, 5)
          |> Enum.join("")

        {:ok, uuid_hex}

      _ ->
        {:error, :invalid_format}
    end
  end

  @spec valid_ipv6?(String.t()) :: boolean()
  def valid_ipv6?(ipv6) do
    case :inet.parse_address(String.to_charlist(ipv6)) do
      {:ok, {_, _, _, _, _, _, _, _}} -> true
      _ -> false
    end
  end
end
