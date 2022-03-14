defmodule Macrina.Handler do
  alias Macrina.{Connection, Message}

  @callback call(Connection.t(), Message.t()) :: :ok | {:error, term()}

  @spec call(Connection.t(), Message.t()) :: :ok | {:error, term()}
  def call(%Connection{ip: ip, port: port, socket: socket}, %Message{} = message) do
    :gen_udp.send(socket, {ip, port}, Message.encode(message))
  end
end
