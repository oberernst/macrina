defmodule Macrina.Client do
  alias Macrina.{Endpoint, Connection, Message}

  defstruct [:conn]

  def build(ip, port, endpoint \\ Endpoint) do
    {:ok, socket} = Endpoint.socket(endpoint)

    case Connection.start_link(ip: ip, port: port, socket: socket, type: :client) do
      {:ok, conn} -> %__MODULE__{conn: conn}
      {:error, {:already_started, conn}} -> %__MODULE__{conn: conn}
    end
  end

  def get(%__MODULE__{conn: pid}, url) do
    message = Message.build(:get, options: parse_url(url), type: :con)
    Connection.call(pid, message)
  end

  def post(%__MODULE__{conn: pid}, url, payload \\ <<>>) do
    message = Message.build(:post, options: parse_url(url), payload: payload)
    Connection.call(pid, message)
  end

  def put(%__MODULE__{conn: pid}, url, payload \\ <<>>) do
    message = Message.build(:put, options: parse_url(url), payload: payload)
    Connection.call(pid, message)
  end

  def delete(%__MODULE__{conn: pid}, url) do
    message = Message.build(:delete, options: parse_url(url))
    Connection.call(pid, message)
  end

  defp parse_url(url) do
    url |> Path.split() |> Enum.map(&{"Uri-Path", &1})
  end
end
