defmodule Macrina.Handler do
  require Logger
  alias Macrina.{Connection, Message}

  @callback call(Connection.t(), Message.t()) :: :ok | {:error, term()}

  @spec call(Connection.t(), Message.t()) :: :ok | {:error, term()}
  def call(%Connection{ip: ip, port: port, socket: socket}, %Message{type: :con} = message) do
    Logger.info("#{port} sending ACK")
    ack = %Message{message | type: :ack}
    :gen_udp.send(socket, {ip, port}, Message.encode(ack))

    Logger.info("#{port} echoing CON")
    :gen_udp.send(socket, {ip, port}, Message.encode(message))
  end

  def call(%Connection{ip: ip, port: port, socket: socket}, %Message{} = message) do
    Logger.info("#{port} echoing #{message.type |> Atom.to_string() |> String.upcase()}")
    :gen_udp.send(socket, {ip, port}, Message.encode(message))
  end
end
