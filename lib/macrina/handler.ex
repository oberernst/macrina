defmodule Macrina.Handler do
  require Logger
  alias Macrina.{Connection, Message}

  @callback call(Connection.t(), Message.t()) :: :ok | {:error, term()}

  @spec call(Connection.t(), Message.t()) :: :ok | {:error, term()}
  def call(%Connection{ip: ip, port: port, socket: socket}, %Message{type: :con} = message) do
    ack = %Message{message | type: :ack}
    Logger.info("#{port} echoing #{ack.type |> Atom.to_string() |> String.upcase()}")
    :gen_udp.send(socket, {ip, port}, Message.encode(ack))

    non = %Message{message | message_id: Enum.random(10000..19999), type: :non}
    Logger.info("#{port} echoing #{non.type |> Atom.to_string() |> String.upcase()}")
    :gen_udp.send(socket, {ip, port}, Message.encode(non))
  end

  def call(%Connection{ip: ip, port: port, socket: socket}, %Message{} = message) do
    Logger.info("#{port} echoing #{message.type |> Atom.to_string() |> String.upcase()}")
    :gen_udp.send(socket, {ip, port}, Message.encode(message))
  end
end
