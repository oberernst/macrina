defmodule Macrina.Peer do
  @moduledoc false

  # Small helpers that identify or label the remote endpoint of a CoAP
  # exchange. Pure; no socket I/O. The effectful per-peer state machine lives
  # in `Macrina.Peer.Session` (an alias added by Wave B's rename slice).

  @doc """
  Returns a human-readable label for a peer address.

  Used as the unique key in the connection registry and as the `:peer` field
  in telemetry metadata.

  ## Examples

      iex> Macrina.Peer.label({127, 0, 0, 1}, 5683)
      "127.0.0.1/5683"

      iex> Macrina.Peer.label({0, 0, 0, 0, 0, 0, 0, 1}, 5683)
      "0:0:0:0:0:0:0:1/5683"

  """
  @spec label(:inet.ip_address(), :inet.port_number()) :: String.t()
  def label({_, _, _, _} = ip, port) do
    ip_string = ip |> Tuple.to_list() |> Enum.join(".")
    "#{ip_string}/#{port}"
  end

  def label({_, _, _, _, _, _, _, _} = ip, port) do
    ip_string = ip |> Tuple.to_list() |> Enum.join(":")
    "#{ip_string}/#{port}"
  end
end
